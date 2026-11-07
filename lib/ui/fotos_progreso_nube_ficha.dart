import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../auth.dart';
import '../config.dart';
import '../negocio.dart' show fmtFecha;
import 'componentes.dart';
import 'diseno.dart';

/// 1.27 (Fotos de progreso en la nube, Pieza G): las
/// fotos que el cliente decidió guardar EN LA NUBE,
/// vistas desde su ficha.
///
/// SOLO el dueño: la ficha monta este widget solo si
/// isOwner, y da igual lo que la UI haga — la puerta
/// es la Edge Function cliente-foto-progreso, que
/// verifica es_dueno() por UID en el servidor para
/// cada acción (listar, ver, eliminar). El bucket es
/// privado y sin policies: ni siquiera hay URL que
/// firmar desde aquí.
///
/// Eliminar aquí es moderación: borra objeto y fila en
/// el servidor, y la app del cliente lo refleja en su
/// próxima fusión. Cargadores inyectables para tests.
class SeccionFotosProgresoNube extends StatefulWidget {
  final int clienteId;
  final Future<List<Map<String, dynamic>>> Function()? cargarFotos;
  final Future<Uint8List?> Function(String fotoId)? descargarFoto;
  final Future<bool> Function(String fotoId)? eliminarFoto;

  const SeccionFotosProgresoNube({
    super.key,
    required this.clienteId,
    this.cargarFotos,
    this.descargarFoto,
    this.eliminarFoto,
  });

  @override
  State<SeccionFotosProgresoNube> createState() =>
      _SeccionFotosProgresoNubeState();
}

/// 1.28 (M4-A13): la llamada de listado falló por SESIÓN
/// (sin token o 401/403), no por red: el aviso al dueño es
/// otro («vuelve a entrar»), no «sin conexión».
class _ErrorSesionFotos implements Exception {
  const _ErrorSesionFotos();
}

class _SeccionFotosProgresoNubeState
    extends State<SeccionFotosProgresoNube> {
  bool _cargando = true;
  bool _error = false;
  bool _errorSesion = false;
  List<Map<String, dynamic>> _fotos = const [];

  // 1.28 (M4-A13): descargas en vuelo por foto y caché de
  // BYTES con tope (LRU por orden de inserción): antes cada
  // miniatura era la foto ENTERA retenida sin límite
  // (~100 fotos × 2 MB) y la celda quedaba atada al futuro
  // fallido aunque el visor sí hubiera descargado la foto.
  final Map<String, Future<Uint8List?>> _enVuelo = {};
  final Map<String, Uint8List> _bytesCache = {};
  int _bytesCacheTotal = 0;
  static const int _maxBytesCache = 24 * 1024 * 1024;
  static const int _maxFotosCache = 40;

  // 1.28 (M4-A13): caché NEGATIVA con pausa (reloj
  // monótono): una foto que falla no se re-descarga en
  // cada reconstrucción; el toque explícito la reintenta
  // al momento (forzar), como manda H-08.
  final Stopwatch _reloj = Stopwatch()..start();
  final Map<String, int> _falloEnMs = {};
  final Map<String, Future<Uint8List?>> _futuroFallo = {};
  static const int _pausaFalloMs = 30000;

  // 1.28 (M4-A13): semáforo de descargas reales a la vez.
  static const int _maxDescargas = 4;
  int _descargasActivas = 0;
  final List<Completer<void>> _esperaDescarga = [];

  bool _dispuesto = false;
  int _cargaGen = 0;
  String? _viendoId;

  // H-06 (Argón 1.27): fotos con la eliminación de
  // moderación EN VUELO (la llamada puede tardar
  // segundos): su celda se congela con un indicador y
  // no admite otro toque que dispare un segundo
  // admin_eliminar sobre la misma foto.
  final Set<String> _eliminandoIds = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  // 1.28 (M4-A13/R1M4-M9): si la ficha reutiliza la sección
  // para OTRO cliente, fuera la foto del anterior: reset
  // completo y recarga.
  @override
  void didUpdateWidget(SeccionFotosProgresoNube oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clienteId != widget.clienteId) {
      _bytesCache.clear();
      _bytesCacheTotal = 0;
      _enVuelo.clear();
      _falloEnMs.clear();
      _futuroFallo.clear();
      _eliminandoIds.clear();
      _viendoId = null;
      _fotos = const [];
      _cargar();
    }
  }

  // 1.28 (M4-A13/C-R2M4-H3): al salir, las descargas en
  // vuelo se descartan (el http no se puede cancelar) y
  // los que esperan hueco se despiertan para terminar.
  @override
  void dispose() {
    _dispuesto = true;
    for (final c in _esperaDescarga) {
      if (!c.isCompleted) c.complete();
    }
    _esperaDescarga.clear();
    _bytesCache.clear();
    super.dispose();
  }

  Map<String, String> _cabeceras(Map<String, String> extra) {
    final token = AuthService().session?.accessToken ?? '';
    return {
      'apikey': AppConfig.anonKey,
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      ...extra,
    };
  }

  Uri get _uri => Uri.parse(
      '${AppConfig.supabaseUrl}/functions/v1/cliente-foto-progreso');

  Future<List<Map<String, dynamic>>> _cargarReal() async {
    // 1.28 (M4-A13/C-R1M4-H6): sin token no hay llamada que
    // valga — es sesión vencida, no «sin conexión».
    if ((AuthService().session?.accessToken ?? '').isEmpty) {
      throw const _ErrorSesionFotos();
    }
    final r = await http
        .post(
          _uri,
          headers: _cabeceras({
            'x-accion': 'admin_listar',
            'x-cliente-id': '${widget.clienteId}',
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw const _ErrorSesionFotos();
    }
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final j = jsonDecode(r.body);
    if (j is! Map || j['ok'] != true) throw Exception('respuesta');
    final fotos = j['fotos'];
    if (fotos is! List) return const [];
    return [
      for (final f in fotos)
        if (f is Map) Map<String, dynamic>.from(f),
    ];
  }

  Future<Uint8List?> _descargarReal(String fotoId) async {
    final r = await http
        .post(
          _uri,
          headers: _cabeceras({
            'x-accion': 'admin_descargar',
            'x-foto-id': fotoId,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) return null;
    final tipo = r.headers['content-type'] ?? '';
    if (!tipo.startsWith('image/')) return null;
    return r.bodyBytes;
  }

  Future<bool> _eliminarReal(String fotoId) async {
    // 1.28 (M4-A13/C-R1M4-H2): el http/timeout va envuelto
    // — sin red, la excepción escapaba y el aviso «El
    // servidor no eliminó la foto» nunca se alcanzaba.
    try {
      final r = await http
          .post(
            _uri,
            headers: _cabeceras({
              'x-accion': 'admin_eliminar',
              'x-foto-id': fotoId,
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return false;
      final j = jsonDecode(r.body);
      return j is Map && j['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _cargar() async {
    // 1.28 (M4-A13): guarda anti-doble-carga (el Reintentar
    // podía apilar dos listados) y generación por cliente.
    if (_cargando && _fotos.isNotEmpty) return;
    final id = widget.clienteId;
    final gen = ++_cargaGen;
    setState(() {
      _cargando = true;
      _error = false;
      _errorSesion = false;
    });
    try {
      final fotos = await (widget.cargarFotos ?? _cargarReal)();
      if (!mounted || gen != _cargaGen || widget.clienteId != id) {
        return;
      }
      setState(() {
        _fotos = fotos;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted || gen != _cargaGen || widget.clienteId != id) {
        return;
      }
      setState(() {
        _cargando = false;
        _error = true;
        _errorSesion = e is _ErrorSesionFotos;
      });
    }
  }

  void _guardarEnCache(String fotoId, Uint8List bytes) {
    final viejo = _bytesCache.remove(fotoId);
    if (viejo != null) _bytesCacheTotal -= viejo.length;
    _bytesCache[fotoId] = bytes;
    _bytesCacheTotal += bytes.length;
    while ((_bytesCacheTotal > _maxBytesCache ||
            _bytesCache.length > _maxFotosCache) &&
        _bytesCache.isNotEmpty) {
      final primera = _bytesCache.keys.first;
      _bytesCacheTotal -= _bytesCache.remove(primera)!.length;
    }
  }

  Future<void> _adquirirDescarga() async {
    if (_descargasActivas < _maxDescargas) {
      _descargasActivas++;
      return;
    }
    final c = Completer<void>();
    _esperaDescarga.add(c);
    await c.future;
    _descargasActivas++;
  }

  void _liberarDescarga() {
    _descargasActivas--;
    if (_esperaDescarga.isNotEmpty) {
      _esperaDescarga.removeAt(0).complete();
    }
  }

  Future<Uint8List?> _descargarConLimite(String fotoId) async {
    await _adquirirDescarga();
    try {
      if (_dispuesto) return null;
      final bytes =
          await (widget.descargarFoto ?? _descargarReal)(fotoId);
      if (_dispuesto) return null;
      if (bytes == null) {
        _falloEnMs[fotoId] = _reloj.elapsedMilliseconds;
      } else {
        _falloEnMs.remove(fotoId);
        _futuroFallo.remove(fotoId);
        _guardarEnCache(fotoId, bytes);
      }
      return bytes;
    } catch (_) {
      _falloEnMs[fotoId] = _reloj.elapsedMilliseconds;
      return null;
    } finally {
      _liberarDescarga();
    }
  }

  /// Miniatura de [fotoId]: bytes cacheados, descarga en
  /// vuelo compartida o caché negativa con pausa. Con
  /// [forzar] (toque explícito) la pausa se ignora: H-08.
  Future<Uint8List?> _miniatura(String fotoId, {bool forzar = false}) {
    final cacheados = _bytesCache[fotoId];
    if (cacheados != null) {
      // Tocar la entrada la mueve al final (LRU).
      _bytesCache.remove(fotoId);
      _bytesCache[fotoId] = cacheados;
      return Future.value(cacheados);
    }
    final enVuelo = _enVuelo[fotoId];
    if (enVuelo != null) return enVuelo;
    if (!forzar) {
      final fallo = _falloEnMs[fotoId];
      if (fallo != null &&
          _reloj.elapsedMilliseconds - fallo < _pausaFalloMs) {
        // Futuro completado ESTABLE: la celda pinta la
        // marca de rota sin re-disparar la descarga.
        return _futuroFallo.putIfAbsent(
            fotoId, () => Future<Uint8List?>.value(null));
      }
    } else {
      _falloEnMs.remove(fotoId);
      _futuroFallo.remove(fotoId);
    }
    final futuro = _descargarConLimite(fotoId);
    _enVuelo[fotoId] = futuro;
    futuro.whenComplete(() {
      if (identical(_enVuelo[fotoId], futuro)) {
        _enVuelo.remove(fotoId);
      }
    });
    return futuro;
  }

  Future<void> _verGrande(Map<String, dynamic> foto) async {
    final fotoId = foto['id']?.toString() ?? '';
    // O-01 (delta 1.27): si esta foto ya se está eliminando,
    // ni siquiera abrir el visor — blinda también una futura
    // entrada directa que no pase por el onTap de la rejilla.
    if (_eliminandoIds.contains(fotoId)) return;
    // 1.28 (M4-A13/C-R1M4-H4): la guarda O-01 solo miraba
    // «eliminando» — dos toques abrían DOS visores de la
    // misma foto. El visor en curso se recuerda.
    if (_viendoId == fotoId) return;
    _viendoId = fotoId;
    try {
      await _verGrandeFlujo(foto, fotoId);
    } finally {
      _viendoId = null;
    }
  }

  Future<void> _verGrandeFlujo(
      Map<String, dynamic> foto, String fotoId) async {
    // Toque explícito: reintenta al momento aunque la
    // miniatura fallara hace nada (H-08); la pausa de la
    // caché negativa solo frena reconstrucciones.
    final bytes = await _miniatura(fotoId, forzar: true);
    if (!mounted) return;
    if (bytes == null) {
      mostrarSnack(context, 'No se pudo descargar la foto.',
          significado: SignificadoChip.error);
      return;
    }
    // La celda se re-enlaza a los bytes ya cacheados al
    // volver (C-R2M4-H2: quedaba en «rota» con el futuro
    // fallido aunque el visor sí descargó la foto).
    setState(() {});
    // 1.28 (M4-A13/C-R2M4-H1): la confirmación de eliminar
    // DENTRO del visor no tenía guarda: doble toque, dos
    // confirmaciones apiladas.
    var confirmando = false;
    final borrada = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Foto del ${fmtFecha(foto['fecha']?.toString() ?? '')}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(false),
                  ),
                ],
              ),
            ),
            Flexible(
              // 1.28 (M4-A13): decodificación acotada al
              // ancho pintado y marca visible si los bytes
              // no decodifican (antes: bitmap completo de
              // ~1280 px y celda vacía sin marca).
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                cacheWidth: (MediaQuery.sizeOf(context).width *
                        MediaQuery.devicePixelRatioOf(context))
                    .round(),
                errorBuilder: (_, __, ___) => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Icon(Icons.broken_image_outlined, size: 40),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
                      if (confirmando) return;
                      confirmando = true;
                      try {
                        final ok = await showDialog<bool>(
                          context: ctx,
                          builder: (c2) => AlertDialog(
                            title: const Text('¿Eliminar esta foto?'),
                            content: const Text(
                                'Se borra de la nube y el cliente '
                                'dejará de verla en su app. No se '
                                'puede deshacer.'),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(c2).pop(false),
                                child: const Text('Cancelar'),
                              ),
                              FilledButton(
                                onPressed: () =>
                                    Navigator.of(c2).pop(true),
                                child: const Text('Eliminar'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          Navigator.of(ctx).pop(true);
                        }
                      } finally {
                        confirmando = false;
                      }
                    },
                    icon: const Icon(Icons.delete_outline,
                        color: AppColores.error),
                    label: const Text('Eliminar de la nube',
                        style: TextStyle(color: AppColores.error)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (borrada != true || !mounted) return;
    // H-06 (Argón 1.27): la celda queda marcada como
    // «eliminando» ANTES del await (que puede tardar
    // hasta el timeout): el grid la congela y un
    // segundo toque no dispara otro admin_eliminar.
    setState(() => _eliminandoIds.add(fotoId));
    bool ok;
    try {
      ok = await (widget.eliminarFoto ?? _eliminarReal)(fotoId);
    } finally {
      _eliminandoIds.remove(fotoId);
      if (mounted) setState(() {});
    }
    if (!mounted) return;
    if (ok) {
      setState(() {
        _fotos = [
          for (final f in _fotos)
            if (f['id']?.toString() != fotoId) f,
        ];
        final quitados = _bytesCache.remove(fotoId);
        if (quitados != null) _bytesCacheTotal -= quitados.length;
        _falloEnMs.remove(fotoId);
        _futuroFallo.remove(fotoId);
      });
    } else {
      mostrarSnack(
          context, 'El servidor no eliminó la foto. Inténtalo de nuevo.',
          significado: SignificadoChip.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const Tarjeta(
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('Verificando sus fotos en la nube…'),
          ],
        ),
      );
    }
    if (_error) {
      return Tarjeta(
        child: Row(
          children: [
            Expanded(
              // 1.28 (M4-A13/C-R1M4-H6): sesión vencida no es
              // «sin conexión» — el aviso dice la causa.
              child: Text(_errorSesion
                  ? 'Sesión vencida: vuelve a entrar para ver '
                      'sus fotos en la nube.'
                  : 'Sin conexión: no se pudieron verificar sus '
                      'fotos en la nube.'),
            ),
            TextButton(onPressed: _cargar, child: const Text('Reintentar')),
          ],
        ),
      );
    }
    // Sin fotos en la nube, la sección no ocupa espacio
    // (patrón de la foto personal).
    if (_fotos.isEmpty) return const SizedBox.shrink();
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Fotos de progreso (nube)',
              style: AppTexto.titulo),
          const SizedBox(height: 4),
          const Text(
            'Las que el cliente decidió guardar en la nube. '
            'Solo tú puedes verlas.',
            style: TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 0.78,
            ),
            itemCount: _fotos.length,
            itemBuilder: (ctx, i) {
              final f = _fotos[i];
              final fotoId = f['id']?.toString() ?? '';
              // H-06: celda congelada mientras su
              // eliminación está en vuelo.
              final eliminando = _eliminandoIds.contains(fotoId);
              return InkWell(
                onTap: eliminando ? null : () => _verGrande(f),
                borderRadius: BorderRadius.circular(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            // 1.28 (M4-A13): con los bytes ya
                            // en caché (p. ej. los bajó el
                            // visor), la celda pinta directo;
                            // si no, el futuro de la descarga.
                            // La decodificación va acotada al
                            // ancho real de la celda.
                            if (_bytesCache[fotoId] != null)
                              LayoutBuilder(
                                builder: (ctx, cons) => Image.memory(
                                  _bytesCache[fotoId]!,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
                                  cacheWidth: (cons.maxWidth *
                                          MediaQuery
                                              .devicePixelRatioOf(ctx))
                                      .round(),
                                  errorBuilder: (_, __, ___) =>
                                      Container(
                                    color: Colors.black12,
                                    child: const Center(
                                      child: Icon(
                                          Icons.broken_image_outlined),
                                    ),
                                  ),
                                ),
                              )
                            else
                              FutureBuilder<Uint8List?>(
                                future: _miniatura(fotoId),
                                builder: (ctx, snap) {
                                  final bytes = snap.data;
                                  if (bytes == null) {
                                    return Container(
                                      color: Colors.black12,
                                      child: Center(
                                        child: snap.connectionState ==
                                                ConnectionState.waiting
                                            ? const CircularProgressIndicator(
                                                strokeWidth: 2)
                                            : const Icon(
                                                Icons.broken_image_outlined),
                                      ),
                                    );
                                  }
                                  return LayoutBuilder(
                                    builder: (ctx2, cons) =>
                                        Image.memory(
                                      bytes,
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      cacheWidth: (cons.maxWidth *
                                              MediaQuery
                                                  .devicePixelRatioOf(
                                                      ctx2))
                                          .round(),
                                      errorBuilder: (_, __, ___) =>
                                          Container(
                                        color: Colors.black12,
                                        child: const Center(
                                          child: Icon(Icons
                                              .broken_image_outlined),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            if (eliminando)
                              Container(
                                color: Colors.black38,
                                child: const Center(
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      fmtFecha(f['fecha']?.toString() ?? ''),
                      style: const TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
