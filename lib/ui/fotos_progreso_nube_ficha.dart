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

/// 1.28 (M4-C5): un mes de la galería — título legible y
/// sus fotos, en el orden en que llegaron.
class GrupoFotosMes {
  final String titulo;
  final List<Map<String, dynamic>> fotos;
  const GrupoFotosMes(this.titulo, this.fotos);
}

const List<String> _mesesEs = [
  'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
  'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre',
  'Diciembre',
];

/// 1.28 (M4-C5, PURA): agrupa las fotos por mes de su
/// fecha, del mes más reciente al más viejo (el orden de
/// entrada se conserva DENTRO de cada mes). Las fotos sin
/// fecha legible van al grupo final «Sin fecha». Función
/// pura para poder probarla sin widgets.
List<GrupoFotosMes> agruparFotosPorMes(
    List<Map<String, dynamic>> fotos) {
  final porClave = <String, List<Map<String, dynamic>>>{};
  final titulos = <String, String>{};
  final sinFecha = <Map<String, dynamic>>[];
  for (final f in fotos) {
    final fecha = DateTime.tryParse(f['fecha']?.toString() ?? '');
    if (fecha == null) {
      sinFecha.add(f);
      continue;
    }
    final clave =
        '${fecha.year.toString().padLeft(4, '0')}-${fecha.month.toString().padLeft(2, '0')}';
    porClave.putIfAbsent(clave, () => []).add(f);
    titulos[clave] =
        '${_mesesEs[fecha.month - 1]} ${fecha.year}';
  }
  final claves = porClave.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final k in claves)
      GrupoFotosMes(
          '${titulos[k]} · ${porClave[k]!.length} '
          '${porClave[k]!.length == 1 ? 'foto' : 'fotos'}',
          porClave[k]!),
    if (sinFecha.isNotEmpty)
      GrupoFotosMes('Sin fecha · ${sinFecha.length} '
          '${sinFecha.length == 1 ? 'foto' : 'fotos'}', sinFecha),
  ];
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

  // 1.28 (M4-C5): proporción real (ancho/alto) de cada
  // foto, resuelta al descargar sus bytes: la rejilla
  // pinta cada celda con la forma de SU foto en vez de
  // recortar todas al mismo rectángulo.

  // 1.28 (M4-B6): selección para moderar por tandas
  // (pulsación larga entra en el modo; vacío = modo
  // normal).
  final Set<String> _seleccion = {};

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
      _seleccion.clear();
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
    // Yunque R4-M6-5: un 200 con el campo fotos corrupto o
    // renombrado en el servidor es un fallo de CONTRATO,
    // no «este cliente no tiene fotos»: se lanza y la
    // sección pinta error con Reintentar, como el resto
    // de fallos de esta misma función.
    if (fotos is! List) throw Exception('respuesta');
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
        // 1.36 FICHA (136-208): ya NO se resuelve la
        // proporción por foto: cada resolución hacía
        // setState de toda la sección y las alturas
        // cambiaban bajo el dedo. Las celdas son de
        // proporción fija y estable (ver _celdaFoto).
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

  /// 1.28 (M4-C5): el visor es una GALERÍA — se abre en
  /// la foto tocada y se hojea con PageView, sin cerrar
  /// y reabrir por foto. Devuelve el id a eliminar (la
  /// confirmación vive dentro; el borrado lo ejecuta la
  /// sección tras cerrarse el visor, como manda H-06).
  Future<void> _verGrande(int indice) async {
    if (indice < 0 || indice >= _fotos.length) return;
    final fotoId = _fotos[indice]['id']?.toString() ?? '';
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
      final aBorrar = await showDialog<String>(
        context: context,
        builder: (ctx) => _VisorFotosNube(
          fotos: _fotos,
          indiceInicial: indice,
          descargar: (id) => _miniatura(id, forzar: true),
        ),
      );
      if (aBorrar == null || !mounted) return;
      await _eliminarFotoModeracion(aBorrar);
    } finally {
      _viendoId = null;
    }
  }

  /// H-06 (Argón 1.27): la celda queda marcada como
  /// «eliminando» ANTES del await (que puede tardar
  /// hasta el timeout): el grid la congela y un
  /// segundo toque no dispara otro admin_eliminar.
  /// Devuelve si el servidor borró la foto.
  Future<bool> _eliminarFotoModeracion(String fotoId) async {
    if (_eliminandoIds.contains(fotoId)) return false;
    setState(() => _eliminandoIds.add(fotoId));
    bool ok;
    try {
      ok = await (widget.eliminarFoto ?? _eliminarReal)(fotoId);
    } finally {
      _eliminandoIds.remove(fotoId);
      if (mounted) setState(() {});
    }
    if (!mounted) return ok;
    if (ok) {
      _borrarFotoLocal(fotoId);
    } else {
      mostrarSnack(
          context, 'El servidor no eliminó la foto. Inténtalo de nuevo.',
          significado: SignificadoChip.error);
    }
    return ok;
  }

  /// Retira la foto de la vista y de todas las cachés
  /// (bytes, proporción, fallos y selección).
  void _borrarFotoLocal(String fotoId) {
    setState(() {
      _fotos = [
        for (final f in _fotos)
          if (f['id']?.toString() != fotoId) f,
      ];
      final quitados = _bytesCache.remove(fotoId);
      if (quitados != null) _bytesCacheTotal -= quitados.length;
      _falloEnMs.remove(fotoId);
      _futuroFallo.remove(fotoId);
      _seleccion.remove(fotoId);
    });
  }

  // ── 1.28 (M4-B6): moderación por tandas ─────────────

  void _alternarSeleccion(String fotoId, bool entra) {
    setState(() {
      if (entra) {
        _seleccion.add(fotoId);
      } else {
        _seleccion.remove(fotoId);
      }
    });
  }

  String get _rangoSeleccion {
    final fechas = <String>[];
    for (final f in _fotos) {
      if (_seleccion.contains(f['id']?.toString())) {
        fechas.add(f['fecha']?.toString() ?? '');
      }
    }
    fechas.sort();
    if (fechas.isEmpty) return '';
    final primera = fmtFecha(fechas.first);
    final ultima = fmtFecha(fechas.last);
    return primera == ultima ? primera : 'del $primera al $ultima';
  }

  /// UNA confirmación para toda la tanda (con el conteo
  /// y el rango de fechas) y borrado secuencial con el
  /// mismo candado H-06 por foto; el resultado se resume
  /// en un solo aviso.
  Future<void> _eliminarSeleccion() async {
    final ids = [
      for (final f in _fotos)
        if (_seleccion.contains(f['id']?.toString()))
          f['id']?.toString() ?? '',
    ]..removeWhere((id) => id.isEmpty);
    if (ids.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c2) => AlertDialog(
        title: Text('¿Eliminar ${ids.length} '
            '${ids.length == 1 ? 'foto' : 'fotos'}?'),
        content: Text('Fotos $_rangoSeleccion. Se borran de '
            'la nube y el cliente dejará de verlas en su '
            'app. No se puede deshacer.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(c2).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(c2).pop(true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    var borradas = 0;
    for (final id in ids) {
      if (!mounted) break;
      if (await _eliminarFotoModeracion(id)) borradas++;
    }
    if (!mounted) return;
    setState(() => _seleccion.clear());
    mostrarSnack(
      context,
      borradas == ids.length
          ? '${ids.length} ${ids.length == 1 ? 'foto eliminada' : 'fotos eliminadas'} de la nube'
          : 'Se eliminaron $borradas de ${ids.length}; el resto '
              'no se pudo. Inténtalo de nuevo.',
      significado: borradas == ids.length
          ? SignificadoChip.exito
          : SignificadoChip.error,
    );
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
    // 1.28 (M4-C5): la rejilla pasa a GALERÍA — fotos
    // agrupadas por mes con su cabecera, cada celda con
    // la proporción real de su foto. M4-B6: pulsación
    // larga = selección para moderar por tandas.
    final enSeleccion = _seleccion.isNotEmpty;
    final grupos = agruparFotosPorMes(_fotos);
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
            style: TextStyle(fontSize: 13),
          ),
          if (enSeleccion) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColores.naranja.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(AppRadio.sm),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                        '${_seleccion.length} seleccionada'
                        '${_seleccion.length == 1 ? '' : 's'}',
                        style: AppTexto.cuerpo
                            .copyWith(fontWeight: FontWeight.w700)),
                  ),
                  TextButton.icon(
                    onPressed: _eliminarSeleccion,
                    icon: const Icon(Icons.delete_outline,
                        size: 18, color: AppColores.error),
                    label: const Text('Eliminar de la nube',
                        style: TextStyle(color: AppColores.error)),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _seleccion.clear()),
                    child: const Text('Cancelar'),
                  ),
                ],
              ),
            ),
          ],
          for (final g in grupos) ...[
            const SizedBox(height: 14),
            Text(g.titulo, style: AppTexto.subtitulo),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (ctx, cons) {
                final ancho = (cons.maxWidth - 16) / 3;
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final f in g.fotos)
                      SizedBox(
                        width: ancho,
                        child: _celdaFoto(f),
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  /// Una celda de la galería: imagen con la proporción
  /// real de la foto (o la de por defecto mientras no se
  /// conoce), fecha debajo y, según el modo, toque para
  /// abrir el visor o para (des)seleccionar; la pulsación
  /// larga entra en el modo selección (M4-B6).
  Widget _celdaFoto(Map<String, dynamic> f) {
    final fotoId = f['id']?.toString() ?? '';
    // H-06: celda congelada mientras su eliminación está
    // en vuelo.
    final eliminando = _eliminandoIds.contains(fotoId);
    final seleccionada = _seleccion.contains(fotoId);
    final enSeleccion = _seleccion.isNotEmpty;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: eliminando
          ? null
          : () {
              if (enSeleccion) {
                _alternarSeleccion(fotoId, !seleccionada);
              } else {
                _verGrande(_fotos.indexOf(f));
              }
            },
      onLongPress: eliminando
          ? null
          : () => _alternarSeleccion(fotoId, true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            // 136-208: proporción ÚNICA y estable de la
            // rejilla (1:1): ninguna foto recoloca la
            // galería al llegar.
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _imagenCelda(fotoId),
                  if (seleccionada)
                    Container(
                      decoration: BoxDecoration(
                        border: Border.all(
                            color: AppColores.naranja, width: 3),
                        borderRadius: BorderRadius.circular(10),
                        color:
                            AppColores.naranja.withValues(alpha: 0.15),
                      ),
                      alignment: Alignment.topRight,
                      padding: const EdgeInsets.all(4),
                      child: const Icon(Icons.check_circle_rounded,
                          color: AppColores.naranja, size: 20),
                    ),
                  if (eliminando)
                    Container(
                      color: Colors.black38,
                      child: const Center(
                        child:
                            CircularProgressIndicator(strokeWidth: 2),
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
                fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  /// La imagen de una celda: bytes cacheados directos o
  /// el futuro de la descarga (M4-A13, sin cambios).
  Widget _imagenCelda(String fotoId) {
    // 1.28 (M4-A13): con los bytes ya en caché (p. ej. los
    // bajó el visor), la celda pinta directo; si no, el
    // futuro de la descarga. La decodificación va acotada
    // al ancho real de la celda.
    if (_bytesCache[fotoId] != null) {
      return LayoutBuilder(
        builder: (ctx, cons) => Image.memory(
          _bytesCache[fotoId]!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth:
              (cons.maxWidth * MediaQuery.devicePixelRatioOf(ctx))
                  .round(),
          errorBuilder: (_, __, ___) => Container(
            color: Colors.black12,
            child: const Center(
              child: Icon(Icons.broken_image_outlined),
            ),
          ),
        ),
      );
    }
    return FutureBuilder<Uint8List?>(
      future: _miniatura(fotoId),
      builder: (ctx, snap) {
        final bytes = snap.data;
        if (bytes == null) {
          return Container(
            color: Colors.black12,
            child: Center(
              child: snap.connectionState == ConnectionState.waiting
                  ? const CircularProgressIndicator(strokeWidth: 2)
                  : const Icon(Icons.broken_image_outlined),
            ),
          );
        }
        return LayoutBuilder(
          builder: (ctx2, cons) => Image.memory(
            bytes,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: (cons.maxWidth *
                    MediaQuery.devicePixelRatioOf(ctx2))
                .round(),
            errorBuilder: (_, __, ___) => Container(
              color: Colors.black12,
              child: const Center(
                child: Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 1.28 (M4-C5): el visor como galería hojeable — se abre
/// en la foto tocada y se pasa de una a otra con el dedo
/// (PageView); cada página descarga con el mismo
/// cargador de la sección (toque explícito: reintenta al
/// momento, H-08). «Eliminar de la nube» actúa sobre la
/// foto EN PANTALLA: confirma y CIERRA el visor
/// devolviendo su id; el borrado lo ejecuta la sección
/// (H-06: la celda se congela fuera, con el visor ya
/// cerrado).
class _VisorFotosNube extends StatefulWidget {
  final List<Map<String, dynamic>> fotos;
  final int indiceInicial;
  final Future<Uint8List?> Function(String fotoId) descargar;

  const _VisorFotosNube({
    required this.fotos,
    required this.indiceInicial,
    required this.descargar,
  });

  @override
  State<_VisorFotosNube> createState() => _VisorFotosNubeState();
}

class _VisorFotosNubeState extends State<_VisorFotosNube> {
  late final PageController _paginas;
  late int _indice;
  // La confirmación de eliminar DENTRO del visor no
  // tenía guarda: doble toque, dos confirmaciones
  // apiladas (M4-A13/C-R2M4-H1).
  bool _confirmando = false;

  @override
  void initState() {
    super.initState();
    _indice = widget.indiceInicial;
    _paginas = PageController(initialPage: widget.indiceInicial);
  }

  @override
  void dispose() {
    _paginas.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _foto => widget.fotos[_indice];

  Future<void> _pedirEliminar() async {
    if (_confirmando) return;
    _confirmando = true;
    try {
      final fotoId = _foto['id']?.toString() ?? '';
      final ok = await showDialog<bool>(
        context: context,
        builder: (c2) => AlertDialog(
          title: const Text('¿Eliminar esta foto?'),
          content: const Text(
              'Se borra de la nube y el cliente '
              'dejará de verla en su app. No se '
              'puede deshacer.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c2).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(c2).pop(true),
              child: const Text('Eliminar'),
            ),
          ],
        ),
      );
      if (ok == true && mounted) {
        Navigator.of(context).pop(fotoId);
      }
    } finally {
      _confirmando = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Foto del '
                    '${fmtFecha(_foto['fecha']?.toString() ?? '')}',
                    style: AppTexto.subtitulo
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                if (widget.fotos.length > 1)
                  Text('${_indice + 1} de ${widget.fotos.length}',
                      style: AppTexto.secundario),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Flexible(
            child: PageView.builder(
              controller: _paginas,
              itemCount: widget.fotos.length,
              onPageChanged: (i) => setState(() => _indice = i),
              itemBuilder: (ctx, i) {
                final id = widget.fotos[i]['id']?.toString() ?? '';
                return FutureBuilder<Uint8List?>(
                  future: widget.descargar(id),
                  builder: (ctx, snap) {
                    final bytes = snap.data;
                    if (bytes == null) {
                      return Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: snap.connectionState ==
                                  ConnectionState.waiting
                              ? const CircularProgressIndicator(
                                  strokeWidth: 2)
                              : const Icon(
                                  Icons.broken_image_outlined,
                                  size: 40),
                        ),
                      );
                    }
                    // Decodificación acotada al ancho
                    // pintado y marca visible si los bytes
                    // no decodifican (M4-A13).
                    return Image.memory(
                      bytes,
                      fit: BoxFit.contain,
                      cacheWidth: (MediaQuery.sizeOf(context).width *
                              MediaQuery.devicePixelRatioOf(context))
                          .round(),
                      errorBuilder: (_, __, ___) => const Padding(
                        padding: EdgeInsets.all(24),
                        child: Icon(Icons.broken_image_outlined,
                            size: 40),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _pedirEliminar,
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
    );
  }
}
