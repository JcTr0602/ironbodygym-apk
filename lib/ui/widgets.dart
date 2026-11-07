/// Widgets compartidos.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'diseno.dart';
import 'componentes.dart';
import 'reparar_sync_screen.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';

/// 1.28 (M1-C2): ¿el resumen de la última sincronización
/// («↑ N enviados · ↓ M nuevos» / «Sin cambios») se muestra
/// como protagonista del banner? Solo recién terminado
/// (< 30 s): el banner CUENTA el resultado al terminar y
/// después el subtítulo vuelve a su texto normal, con la
/// transición suave del AnimatedSwitcher. Función pura.
bool resumenBannerProtagonista({
  required String? resumen,
  required DateTime? resumenHora,
  required DateTime ahora,
}) {
  if (resumen == null || resumen.isEmpty || resumenHora == null) {
    return false;
  }
  final edad = ahora.difference(resumenHora);
  return !edad.isNegative && edad < const Duration(seconds: 30);
}

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

  /// 1.26 (auditoría de botones, BAJA): aviso al terminar
  /// el ciclo que ESTE banner disparó. Antes el banner
  /// sincronizaba «a la sorda» y la pantalla quedaba con
  /// los datos viejos en pantalla (Suplementos era el
  /// caso: el catálogo no se recargaba tras el banner).
  final VoidCallback? alTerminarSync;

  const SyncBanner(
      {super.key, this.compact = false, this.alcance, this.alTerminarSync});

  @override
  State<SyncBanner> createState() => _SyncBannerState();
}

class _SyncBannerState extends State<SyncBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _giro;
  bool _expandido = false;

  /// 1.28 (M1-C2): temporizador de un disparo que retira el
  /// resumen protagonista a los 30 s aunque no llegue
  /// ninguna emisión nueva del motor.
  Timer? _timerResumen;
  DateTime? _resumenProgramado;

  @override
  void initState() {
    super.initState();
    _giro = AnimationController(
        vsync: this, duration: const Duration(seconds: 2));
  }

  @override
  void dispose() {
    _timerResumen?.cancel();
    _giro.dispose();
    super.dispose();
  }

  void _programarFinResumen(DateTime hora) {
    if (_resumenProgramado == hora && _timerResumen != null) return;
    _timerResumen?.cancel();
    _resumenProgramado = hora;
    final restante =
        const Duration(seconds: 30) - ahoraHabana().difference(hora);
    _timerResumen =
        Timer(restante.isNegative ? Duration.zero : restante, () {
      if (mounted) setState(() {});
    });
  }

  /// Dispara el ciclo (por alcance o completo) y, si la
  /// pantalla lo pidió, la avisa al terminar.
  void _dispararSync() {
    final alc = widget.alcance;
    final Future<void> ciclo = alc != null
        ? SyncEngine.instance.sincronizarScope(alc).then((_) {})
        : SyncEngine.instance.run().then((_) {});
    final cb = widget.alTerminarSync;
    if (cb != null) {
      // El aviso corre igual si el ciclo falló (la
      // pantalla recarga y muestra lo que haya), y el
      // error del ciclo no queda flotando como error
      // asíncrono no manejado (autoauditoría 1.26).
      unawaited(ciclo.then((_) => cb(),
          onError: (Object _) => cb()));
    }
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
        // 1.28 (M1-C2): el resumen recién terminado manda
        // en el subtítulo durante 30 s.
        var resumenProtagonista = false;
        DateTime? resumenHoraActiva;
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
              // v1.0.17: resumen discreto de la última sincronización.
              // 1.28 (M1-C2): recién terminado (< 30 s) el
              // resumen ES el subtítulo, protagonista («↑ 2
              // enviados · ↓ 3 nuevos» / «Sin cambios»); antes
              // se mostraba débil y hasta 10 min mezclado con
              // el «Sincronizado hace…». Pasada la ventana,
              // vuelve el texto normal (el State programa el
              // redespliegue a los 30 s). La ventana se mide
              // en hora Habana, no con el reloj crudo.
              final res = s.ultimoResumen;
              final resHora = s.ultimoResumenHora;
              resumenProtagonista = resumenBannerProtagonista(
                  resumen: res,
                  resumenHora: resHora,
                  ahora: ahoraHabana());
              if (resumenProtagonista) {
                resumenHoraActiva = resHora;
                subtitulo = res;
              } else {
                subtitulo =
                    'Sincronizado ${_hace(s.ultimoSincronizado ?? s.lastOk)}';
              }
            }
            break;
        }
        if (resumenProtagonista && resumenHoraActiva != null) {
          _programarFinResumen(resumenHoraActiva);
        }
        final enProgreso = s.phase == SyncPhase.uploading ||
            s.phase == SyncPhase.downloading ||
            s.phase == SyncPhase.photos;
        // 1.24.2 (auditoría sync M3-H02): la fase de error tiene
        // su propio gesto (ver el onTap): el chevron prometía un
        // detalle que no existía.
        final esError = s.phase == SyncPhase.error;
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
                _dispararSync();
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
              if (enProgreso || esError) {
                // En error, el toque despliega el detalle (qué
                // pasó y qué hacer); el reintento vive dentro
                // como botón explícito. Antes el toque solo
                // relanzaba el sync y, si fallaba igual, la
                // pantalla quedaba idéntica: «no ocurre nada».
                setState(() => _expandido = !_expandido);
              } else {
                _dispararSync();
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
                                style: AppTexto.cuerpo.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                                // 1.27 (error gráfico de campo): el
                                // título a UNA línea siempre. La frase
                                // de «Sin conexión — N cambios…» se
                                // envolvía a 2 líneas y el banner
                                // cambiaba de altura entre estados:
                                // toda la pantalla saltaba al cambiar
                                // el estado de sync. El detalle vive
                                // en el subtítulo.
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            // 1.28 (M1-C1): el hueco del
                            // subtítulo se reserva SIEMPRE
                            // (una línea de metadato), haya o
                            // no texto: antes el subtítulo
                            // nacía y moría entre fases y el
                            // banner cambiaba de altura sin
                            // que el usuario tocara nada.
                            // 1.28 (M1-C2): el texto entra y
                            // sale con fundido (AnimatedSwitcher),
                            // p. ej. el resumen protagonista de
                            // los primeros 30 s.
                            ConstrainedBox(
                              constraints: const BoxConstraints(
                                  minHeight: 17),
                              child: AnimatedSwitcher(
                                duration:
                                    const Duration(milliseconds: 300),
                                child: Text(
                                  subtitulo ?? '',
                                  key: ValueKey<String>(
                                      subtitulo ?? ''),
                                  style: AppTexto.metadato
                                      .copyWith(color: Colors.white),
                                  maxLines: _expandido ? 10 : 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
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
                  // 1.28 (M1-C1): franja inferior de ALTURA
                  // FIJA (38) en TODOS los estados automáticos:
                  // hospeda la barra de progreso en curso, los
                  // botones de error (M1-C2) o nada — pero el
                  // hueco nunca nace ni muere, y la pantalla de
                  // debajo no salta al cambiar la fase. Las
                  // expansiones por TOQUE (detalle del error,
                  // desglose de pendientes) quedan fuera de la
                  // franja: son gesto del usuario, no salto.
                  const SizedBox(height: AppEspacio.xs),
                  SizedBox(
                    key: const Key('sync_banner_franja'),
                    height: 38,
                    child: enProgreso
                        ? Center(
                            child: TweenAnimationBuilder<double>(
                              tween: Tween<double>(
                                  begin: 0, end: s.progreso ?? 0),
                              duration:
                                  const Duration(milliseconds: 400),
                              builder: (c, v, _) => ClipRRect(
                                borderRadius:
                                    BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: s.progreso == null ? null : v,
                                  backgroundColor: Colors.white30,
                                  valueColor:
                                      const AlwaysStoppedAnimation<
                                          Color>(Colors.white),
                                  minHeight: 6,
                                ),
                              ),
                            ),
                          )
                        : esError && !_expandido
                            ? Row(
                                children: [
                                  TextButton.icon(
                                    onPressed: _dispararSync,
                                    icon: const Icon(
                                        Icons.refresh_rounded,
                                        color: Colors.white,
                                        size: 18),
                                    label: Text('Reintentar',
                                        style: AppTexto.metadato
                                            .copyWith(
                                                color: Colors.white,
                                                fontWeight:
                                                    FontWeight.bold)),
                                    style: TextButton.styleFrom(
                                      minimumSize:
                                          const Size(0, 36),
                                      visualDensity:
                                          VisualDensity.compact,
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () =>
                                        Navigator.of(ctx).push(
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              const RepararSyncScreen()),
                                    ),
                                    icon: const Icon(
                                        Icons.build_rounded,
                                        color: Colors.white,
                                        size: 18),
                                    label: Text('Ver qué quedó',
                                        style: AppTexto.metadato
                                            .copyWith(
                                                color: Colors.white,
                                                fontWeight:
                                                    FontWeight.bold)),
                                    style: TextButton.styleFrom(
                                      minimumSize:
                                          const Size(0, 36),
                                      visualDensity:
                                          VisualDensity.compact,
                                    ),
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(),
                  ),
                  if (_expandido && esError && s.lastError != null)
                    Padding(
                      padding:
                          const EdgeInsets.only(top: AppEspacio.sm),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (s.lastError!.accionTexto.isNotEmpty)
                            Text(
                              'Qué hacer: ${s.lastError!.accionTexto}',
                              style: AppTexto.metadato.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600),
                            ),
                          if (s.lastError!.datosGuardadosLocalmente)
                            Padding(
                              padding: const EdgeInsets.only(
                                  top: AppEspacio.xs),
                              child: Text(
                                'Tus cambios están guardados en '
                                'este teléfono.',
                                style: AppTexto.metadato.copyWith(
                                    color: Colors.white),
                              ),
                            ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: _dispararSync,
                              icon: const Icon(
                                  Icons.refresh_rounded,
                                  color: Colors.white,
                                  size: 18),
                              label: Text('Reintentar ahora',
                                  style: AppTexto.metadato.copyWith(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
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
