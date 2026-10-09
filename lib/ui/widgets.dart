/// Widgets compartidos.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../localdb.dart';
import '../sync.dart';

/// Franja de estado de sincronización (visible en todas las pantallas).
///
/// Tarjeta flotante con gradiente por fase, icono animado, progreso suave
/// con porcentaje y mensajes en lenguaje humano. Toca para sincronizar
/// (cuando está en reposo) o para ver el detalle (en curso).
class SyncBanner extends StatefulWidget {
  const SyncBanner({super.key});

  @override
  State<SyncBanner> createState() => _SyncBannerState();
}

class _SyncBannerState extends State<SyncBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _giro;
  bool _expandido = false;

  @override
  void initState() {
    super.initState();
    _giro = AnimationController(
        vsync: this, duration: const Duration(seconds: 2));
  }

  @override
  void dispose() {
    _giro.dispose();
    super.dispose();
  }

  String _etiqueta(String tipo, int n) {
    final plural = n == 1 ? '' : 'es';
    switch (tipo) {
      case 'inscribir':
        return '$n inscripción$plural';
      case 'pago_mensual':
        return '$n pago$plural';
      case 'pago_diario':
        return '$n diario$plural';
      case 'foto':
        return '$n foto$plural';
      default:
        return '$n $tipo';
    }
  }

  String _hace(DateTime? fecha) {
    if (fecha == null) return 'nunca';
    final d = DateTime.now().difference(fecha);
    if (d.inMinutes < 1) return 'ahora mismo';
    if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
    if (d.inHours < 24) return 'hace ${d.inHours} h';
    return 'hace ${d.inDays} d';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncStatus>(
      stream: SyncEngine.instance.statusStream,
      initialData: const SyncStatus(),
      builder: (ctx, snap) {
        final s = snap.data!;
        List<Color> gradiente;
        IconData icono;
        String titulo;
        String? subtitulo;
        switch (s.phase) {
          case SyncPhase.uploading:
            gradiente = const [
              Color(0xFFF59E0B),
              Color(0xFFEA580C)
            ];
            icono = Icons.sync;
            titulo = 'Enviando tus cambios';
            subtitulo = s.detalle;
            break;
          case SyncPhase.downloading:
            gradiente = const [
              Color(0xFF3B82F6),
              Color(0xFF1D4ED8)
            ];
            icono = Icons.cloud_download_outlined;
            titulo = 'Descargando datos';
            subtitulo = s.detalle;
            break;
          case SyncPhase.photos:
            gradiente = const [
              Color(0xFFA855F7),
              Color(0xFF7C3AED)
            ];
            icono = Icons.photo_camera_outlined;
            titulo = 'Subiendo fotos';
            subtitulo = s.detalle;
            break;
          case SyncPhase.error:
            gradiente = const [
              Color(0xFFEF4444),
              Color(0xFFB91C1C)
            ];
            icono = Icons.error_outline;
            titulo = 'No se pudo sincronizar';
            subtitulo = s.lastError;
            break;
          case SyncPhase.idle:
            if (s.pending > 0) {
              gradiente = const [
                Color(0xFFFBBF24),
                Color(0xFFD97706)
              ];
              icono = Icons.schedule;
              titulo =
                  '${s.pending} cambio${s.pending == 1 ? '' : 's'} pendientes';
              subtitulo = 'Toca para enviar';
            } else if (s.hayNovedades) {
              gradiente = const [
                Color(0xFF60A5FA),
                Color(0xFF2563EB)
              ];
              icono = Icons.cloud_download_outlined;
              titulo = 'Hay cambios nuevos';
              subtitulo = 'Toca para descargar';
            } else {
              gradiente = const [
                Color(0xFF22C55E),
                Color(0xFF15803D)
              ];
              icono = Icons.check_circle_outline;
              titulo = 'Todo al día';
              subtitulo =
                  'Última sincronización: ${_hace(s.lastOk)}';
            }
            break;
        }
        final enProgreso = s.phase == SyncPhase.uploading ||
            s.phase == SyncPhase.downloading ||
            s.phase == SyncPhase.photos;
        if (enProgreso && !_giro.isAnimating) {
          _giro.repeat();
        } else if (!enProgreso && _giro.isAnimating) {
          _giro.stop();
        }
        final pct = s.progreso == null
            ? null
            : '${(s.progreso! * 100).round()}%';
        return Container(
          margin: const EdgeInsets.symmetric(
              horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: gradiente,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                  color: gradiente.last.withOpacity(0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 3)),
            ],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              if (enProgreso) {
                setState(() => _expandido = !_expandido);
              } else {
                SyncEngine.instance.run();
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      RotationTransition(
                        turns: enProgreso
                            ? _giro
                            : const AlwaysStoppedAnimation(0),
                        child: Icon(icono,
                            color: Colors.white, size: 26),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(titulo,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight:
                                        FontWeight.bold)),
                            if (subtitulo != null &&
                                subtitulo.isNotEmpty)
                              Text(subtitulo,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12),
                                  maxLines:
                                      _expandido ? 10 : 1,
                                  overflow:
                                      TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      if (pct != null)
                        Text(pct,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                      if (!enProgreso)
                        const Icon(Icons.chevron_right,
                            color: Colors.white70,
                            size: 20),
                    ],
                  ),
                  if (enProgreso)
                    Padding(
                      padding:
                          const EdgeInsets.only(top: 8),
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(
                            begin: 0,
                            end: s.progreso ?? 0),
                        duration: const Duration(
                            milliseconds: 400),
                        builder: (c, v, _) =>
                            ClipRRect(
                          borderRadius:
                              BorderRadius.circular(4),
                          child:
                              LinearProgressIndicator(
                            value: s.progreso == null
                                ? null
                                : v,
                            backgroundColor:
                                Colors.white30,
                            valueColor:
                                const AlwaysStoppedAnimation<
                                        Color>(
                                    Colors.white),
                            minHeight: 6,
                          ),
                        ),
                      ),
                    ),
                  if (_expandido &&
                      s.pending > 0 &&
                      !enProgreso)
                    FutureBuilder<Map<String, int>>(
                      future:
                          LocalDb.instance.pendingByType(),
                      builder: (c2, s2) {
                        final det = (s2.data ?? {})
                            .entries
                            .map((e) =>
                                _etiqueta(e.key, e.value))
                            .join(' · ');
                        if (det.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(
                              top: 8),
                          child: Text(det,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12)),
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class Campo extends StatelessWidget {
  final TextEditingController ctrl;
  final String etiqueta;
  final TextInputType teclado;
  final List<TextInputFormatter>? formato;
  const Campo(
      {super.key,
      required this.ctrl,
      required this.etiqueta,
      this.teclado = TextInputType.text,
      this.formato});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: ctrl,
        keyboardType: teclado,
        inputFormatters: formato,
        decoration: InputDecoration(
            labelText: etiqueta, border: const OutlineInputBorder()),
      ),
    );
  }
}

Future<void> copiar(BuildContext context, String texto) async {
  await Clipboard.setData(ClipboardData(text: texto));
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copiado')));
  }
}
