/// Widgets compartidos.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'diseno.dart';
import 'componentes.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';

/// Franja de estado de sincronización (visible en todas las pantallas).
///
/// Tarjeta flotante con gradiente por fase, icono animado, progreso suave
/// con porcentaje y mensajes en lenguaje humano. Toca para sincronizar
/// (cuando está en reposo) o para ver el detalle (en curso).
class SyncBanner extends StatefulWidget {
  /// Variante compacta de una línea para formularios.
  final bool compact;

  /// Alcance de sincronización (scope de SyncScope). Si se indica, al
  /// tocar el banner se ejecuta sincronizarScope(alcance) en vez del
  /// sync completo: el push sigue siendo global, solo el pull se limita
  /// a la categoría visible (v1.3.5, luz verde de Argón).
  final String? alcance;

  const SyncBanner({super.key, this.compact = false, this.alcance});

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
    final d = ahoraHabana().difference(fecha);
    if (d.inMinutes < 1) return 'ahora mismo';
    if (d.inMinutes < 60) return 'hace ${d.inMinutes} min';
    if (d.inHours < 24) return 'hace ${d.inHours} h';
    return 'hace ${d.inDays} d';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncStatus>(
      stream: SyncEngine.instance.statusStream,
      // v1.8.0: nacer con el último estado real del motor, no con
      // el vacío (pending=0 → «Al día» fantasma hasta el próximo
      // _emit; el stream broadcast no tiene replay).
      initialData: SyncEngine.instance.currentStatus,
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
            icono = Icons.sync_rounded;
            titulo = 'Enviando tus cambios';
            subtitulo = s.detalle;
            break;
          case SyncPhase.downloading:
            gradiente = const [
              Color(0xFF3B82F6),
              Color(0xFF1D4ED8)
            ];
            icono = Icons.cloud_download_rounded;
            titulo = 'Descargando datos';
            subtitulo = s.detalle;
            break;
          case SyncPhase.photos:
            gradiente = const [
              Color(0xFFA855F7),
              Color(0xFF7C3AED)
            ];
            icono = Icons.photo_camera_rounded;
            titulo = 'Subiendo fotos';
            subtitulo = s.detalle;
            break;
          case SyncPhase.error:
            gradiente = const [
              Color(0xFFEF4444),
              Color(0xFFB91C1C)
            ];
            icono = Icons.error_outline_rounded;
            titulo = 'No se pudo sincronizar';
            subtitulo = s.lastError?.mensaje;
            break;
          case SyncPhase.idle:
            // v1.2.5 (D11): frase en lenguaje humano según 3 dimensiones.
            titulo = s.frase;
            if (!s.enLinea) {
              gradiente = const [
                AppColores.bannerGrisA,
                AppColores.bannerGrisB
              ];
              icono = Icons.cloud_off_rounded;
              // v1.2.5 (D12): guardado vs sincronizado, sin tecnicismos.
              subtitulo = s.ultimoGuardado != null
                  ? 'Guardado en este teléfono ${_hace(s.ultimoGuardado)}'
                  : 'Toca para intentar de nuevo';
            } else if (s.pending > 0) {
              gradiente = const [
                AppColores.bannerAlertaA,
                AppColores.alertaOscuro
              ];
              icono = Icons.schedule_rounded;
              // v1.2.6 (Gemini): prioriza lo pendiente sobre el último sync.
              final nCambios = '${s.pending} cambio${s.pending == 1 ? '' : 's'}';
              subtitulo = s.ultimoSincronizado != null
                  ? '$nCambios listos para subir · Último respaldo ${_hace(s.ultimoSincronizado)}'
                  : '$nCambios listos para subir';
            } else if (s.hayNovedades) {
              gradiente = const [
                AppColores.bannerInfoA,
                AppColores.bannerInfoB
              ];
              icono = Icons.cloud_download_rounded;
              titulo = 'Hay cambios nuevos';
              subtitulo = 'Toca para descargar';
            } else if (s.lastOk == null) {
              // v1.1.1: nunca se ha sincronizado: no decir "Todo al día"
              gradiente = const [
                AppColores.bannerGrisA,
                AppColores.bannerGrisB
              ];
              icono = Icons.cloud_off_rounded;
              titulo = 'Sin sincronizar';
              subtitulo = 'Toca para sincronizar';
            } else {
              gradiente = const [
                AppColores.exito,
                AppColores.exitoOscuro
              ];
              icono = Icons.check_circle_outline_rounded;
              // v1.0.17: resumen discreto de la última sincronización
              final res = s.ultimoResumen;
              final resHora = s.ultimoResumenHora;
              final reciente = res != null &&
                  resHora != null &&
                  DateTime.now()
                          .difference(resHora)
                          .inMinutes <
                      10;
              subtitulo = reciente
                  ? 'Última sincronización: $res'
                  : 'Sincronizado ${_hace(s.ultimoSincronizado ?? s.lastOk)}';
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
        // Variante compacta: una línea, sin subtítulo ni progreso.
        if (widget.compact) {
          return Container(
            margin: const EdgeInsets.symmetric(
                horizontal: AppEspacio.md, vertical: AppEspacio.xs),
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadio.md),
              onTap: () {
                if (enProgreso) return;
                final alc = widget.alcance;
                if (alc != null) {
                  SyncEngine.instance.sincronizarScope(alc);
                } else {
                  SyncEngine.instance.run();
                }
              },
              // 1.23 B11: la píldora medía ~32 de alto; el área
              // tocable sube a 48 con la píldora (gradiente,
              // icono y texto) intacta y centrada.
              child: SizedBox(
                height: 48,
                child: Center(
                  widthFactor: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: gradiente,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius:
                          BorderRadius.circular(AppRadio.md),
                    ),
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppEspacio.md, vertical: AppEspacio.sm),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RotationTransition(
                          turns: enProgreso
                              ? _giro
                              : const AlwaysStoppedAnimation(0),
                          child: Icon(icono,
                              color: Colors.white, size: 16),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(titulo,
                              style: AppTexto.metadato.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (pct != null) ...[
                          const SizedBox(width: 8),
                          Text(pct,
                              style: AppTexto.metadato.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        return Container(
          margin: const EdgeInsets.symmetric(
              horizontal: AppEspacio.md, vertical: AppEspacio.sm),
          decoration: BoxDecoration(
            gradient: LinearGradient(
                colors: gradiente,
                begin: Alignment.topLeft,
                end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(AppRadio.lg),
            boxShadow: [
              BoxShadow(
                  color: gradiente.last.withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 3)),
            ],
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadio.lg),
            onTap: () {
              if (enProgreso) {
                setState(() => _expandido = !_expandido);
              } else {
                final alc = widget.alcance;
                if (alc != null) {
                  SyncEngine.instance.sincronizarScope(alc);
                } else {
                  SyncEngine.instance.run();
                }
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppEspacio.lg, vertical: AppEspacio.md),
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
                                style: AppTexto.cuerpo.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
                            if (subtitulo != null &&
                                subtitulo.isNotEmpty)
                              Text(subtitulo,
                                  style: AppTexto.metadato.copyWith(color: Colors.white),
                                  maxLines:
                                      _expandido ? 10 : 1,
                                  overflow:
                                      TextOverflow.ellipsis),
                          ],
                        ),
                      ),
                      if (pct != null)
                        Text(pct,
                            style: AppTexto.titulo.copyWith(color: Colors.white)),
                      if (!enProgreso)
                        const Icon(Icons.chevron_right_rounded,
                            color: Colors.white70,
                            size: 20),
                    ],
                  ),
                  if (enProgreso)
                    Padding(
                      padding:
                          const EdgeInsets.only(top: AppEspacio.sm),
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
                              top: AppEspacio.sm),
                          child: Text(det,
                              style: AppTexto.metadato.copyWith(color: Colors.white)),
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
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
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
    mostrarSnack(context, 'Copiado');
  }
}

// ---------------------------------------------------------------------------
// Píldora de sincronización para el encabezado (tocable → ColaScreen).
// ---------------------------------------------------------------------------

class SyncPill extends StatelessWidget {
  final VoidCallback onTap;
  const SyncPill({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SyncStatus>(
      stream: SyncEngine.instance.statusStream,
      // v1.8.0: nacer con el último estado real del motor, no con
      // el vacío (pending=0 → «Al día» fantasma hasta el próximo
      // _emit; el stream broadcast no tiene replay).
      initialData: SyncEngine.instance.currentStatus,
      builder: (ctx, snap) {
        final s = snap.data!;
        final enProgreso = s.phase == SyncPhase.uploading ||
            s.phase == SyncPhase.downloading ||
            s.phase == SyncPhase.photos;
        final Color color;
        final IconData icono;
        final String texto;
        if (s.phase == SyncPhase.error) {
          color = const Color(0xFFEF4444);
          icono = Icons.error_outline_rounded;
          texto = 'Error';
        } else if (enProgreso) {
          color = const Color(0xFFF59E0B);
          icono = Icons.sync_rounded;
          texto = 'Sincronizando';
        } else if (s.pending > 0) {
          color = AppColores.alerta;
          icono = Icons.schedule_rounded;
          texto = '${s.pending} por subir';
        } else {
          color = AppColores.exito;
          icono = Icons.check_circle_outline_rounded;
          // A2 (estéticas 1.19): el chip dice también hace cuánto
          // fue el último sync confirmado («Al día · hace 12 min»);
          // sin marca previa queda solo «Al día». La cifra se
          // refresca con cada evento del motor, como el resto del
          // pill (no hay ticker propio).
          final ultimo = s.ultimoSincronizado ?? s.lastOk;
          final haceTxt = ultimo == null ? '' : hace(ultimo);
          texto = haceTxt.isEmpty || haceTxt == 'nunca'
              ? 'Al día'
              : 'Al día · $haceTxt';
        }
        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          // 1.23 B11: el chip medía ~32 de alto; el área
          // tocable sube a 48 con el chip intacto y centrado.
          child: SizedBox(
            height: 48,
            child: Center(
              widthFactor: 1,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppEspacio.md, vertical: AppEspacio.sm),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border:
                      Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icono, size: 16, color: color),
                    const SizedBox(width: 4),
                    Text(texto,
                        style: AppTexto.metadato.copyWith(color: color, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
