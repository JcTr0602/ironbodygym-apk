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

class _SeccionFotosProgresoNubeState
    extends State<SeccionFotosProgresoNube> {
  bool _cargando = true;
  bool _error = false;
  List<Map<String, dynamic>> _fotos = const [];
  final Map<String, Future<Uint8List?>> _miniaturas = {};

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
    final r = await http
        .post(
          _uri,
          headers: _cabeceras({
            'x-accion': 'admin_listar',
            'x-cliente-id': '${widget.clienteId}',
          }),
        )
        .timeout(const Duration(seconds: 12));
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
    try {
      final j = jsonDecode(r.body);
      return j is Map && j['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = false;
    });
    try {
      final fotos = await (widget.cargarFotos ?? _cargarReal)();
      if (!mounted) return;
      setState(() {
        _fotos = fotos;
        _cargando = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _error = true;
        });
      }
    }
  }

  Future<Uint8List?> _miniatura(String fotoId) {
    return _miniaturas.putIfAbsent(fotoId, () {
      final descarga =
          (widget.descargarFoto ?? _descargarReal)(fotoId);
      // H-08 (Argón 1.27): si la descarga resuelve
      // null (o falla), la entrada se EXPULSA de la
      // caché al completar: antes el Future fallido
      // quedaba cacheado para siempre y ningún toque
      // posterior podía reintentar la descarga.
      return descarga.then<Uint8List?>((bytes) {
        if (bytes == null) _miniaturas.remove(fotoId);
        return bytes;
      }, onError: (Object _) {
        _miniaturas.remove(fotoId);
        return null;
      });
    });
  }

  Future<void> _verGrande(Map<String, dynamic> foto) async {
    final fotoId = foto['id']?.toString() ?? '';
    // O-01 (delta 1.27): si esta foto ya se está eliminando,
    // ni siquiera abrir el visor — blinda también una futura
    // entrada directa que no pase por el onTap de la rejilla.
    if (_eliminandoIds.contains(fotoId)) return;
    final bytes = await _miniatura(fotoId);
    if (!mounted) return;
    if (bytes == null) {
      // H-08: expulsar también aquí por si la entrada
      // se cacheó por otra vía — el próximo toque
      // reintenta la descarga.
      _miniaturas.remove(fotoId);
      mostrarSnack(context, 'No se pudo descargar la foto.',
          significado: SignificadoChip.error);
      return;
    }
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
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () async {
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
        _miniaturas.remove(fotoId);
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
            const Expanded(
              child: Text(
                  'Sin conexión: no se pudieron verificar sus '
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
                                return Image.memory(
                                  bytes,
                                  fit: BoxFit.cover,
                                  width: double.infinity,
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
