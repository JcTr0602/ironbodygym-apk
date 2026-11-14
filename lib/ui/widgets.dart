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

/// 1.29 (Oleada 5, D-04): la variante visual del banner
/// según la foto del motor. Es la MISMA partición que el
/// build pintaba a mano (fase + las tres dimensiones de
/// reposo), extraída a función pura para fijar por test
/// el gradiente y la letra de cada estado.
enum VarianteBanner {
  enviando,
  descargando,
  fotos,
  error,
  sinConexion,
  pendientes,
  novedades,
  sinSincronizar,
  // SYNC-12 (1.35): la foto no pudo verificar las novedades
  // (lectura de watermark/server_seq fallida): ni «hay
  // cambios» ni «al día» — el estado no se sabe.
  sinVerificar,
  alDia,
}

/// PURO: la variante de una foto del motor.
///
/// SYNC-12 (1.35): la partición con los neutros del
/// triestado — `enLinea` null NO es sinConexion (solo el
/// false comprobado lo es) y `hayNovedades` null NO es
/// alDia: con sync previa cae en [VarianteBanner.sinVerificar].
/// El aviso persistido (un error CONOCIDO) manda sobre el
/// «sin verificar» (un estado desconocido).
VarianteBanner varianteBannerDe(SyncStatus s) {
  switch (s.phase) {
    case SyncPhase.uploading:
      return VarianteBanner.enviando;
    case SyncPhase.downloading:
      return VarianteBanner.descargando;
    case SyncPhase.photos:
      return VarianteBanner.fotos;
    case SyncPhase.error:
      return VarianteBanner.error;
    case SyncPhase.idle:
      if (s.enLinea == false) return VarianteBanner.sinConexion;
      if (s.pending > 0) return VarianteBanner.pendientes;
      if (s.hayNovedades == true) return VarianteBanner.novedades;
      if (s.lastOk == null) return VarianteBanner.sinSincronizar;
      // Yunque 2.34 (A-3, el residual C3-4 de Y1): un error
      // PERSISTIDO (avisoSyncCorto) con la cola vacía y sin
      // novedades apagaba el banner mientras la píldora de la
      // misma cabecera decía «La bajada falló»: superficies
      // contradictorias. El aviso manda sobre el «al día».
      if (s.avisoSyncCorto != null) return VarianteBanner.error;
      if (s.hayNovedades == null) return VarianteBanner.sinVerificar;
      return VarianteBanner.alDia;
  }
}

/// 1.30 (Oleada D2, UI130-07): el NIVEL del lenguaje
/// único de sync al que pertenece cada variante. La
/// jerarquía de la auditoría: la píldora (nivel 1) vive
/// siempre en la cabecera; el banner global solo existe
/// si pide algo — fila neutra compacta (nivel 2) — o si
/// es error, que se dice con `AvisoEstado` sólido; «al
/// día» no ocupa banda en ninguna pantalla. El detalle
/// completo es la Cola (nivel 3). Mapa fijado por test
/// ANTES de tocar las pantallas (exigencia de la
/// auditoría); el motor de sync no se toca.
enum NivelBanner { ninguno, filaNeutra, avisoError }

/// PURO: el nivel de cada variante del banner.
NivelBanner nivelBannerDe(VarianteBanner v) {
  switch (v) {
    case VarianteBanner.alDia:
      return NivelBanner.ninguno;
    case VarianteBanner.error:
      return NivelBanner.avisoError;
    case VarianteBanner.enviando:
    case VarianteBanner.descargando:
    case VarianteBanner.fotos:
    case VarianteBanner.sinConexion:
    case VarianteBanner.pendientes:
    case VarianteBanner.novedades:
    case VarianteBanner.sinSincronizar:
    case VarianteBanner.sinVerificar:
      return NivelBanner.filaNeutra;
  }
}

/// PURO: el color del estado en el lenguaje nuevo. Lo
/// llevan el icono y el progreso de la fila neutra; el
/// texto va en los tokens de texto de siempre (la letra
/// sobre gradiente de D-04 desaparece con el gradiente).
Color colorEstadoBanner(VarianteBanner v) {
  switch (v) {
    case VarianteBanner.enviando:
      return AppColores.alerta;
    case VarianteBanner.descargando:
      return AppColores.info;
    case VarianteBanner.fotos:
      return AppColores.info;
    case VarianteBanner.error:
      return AppColores.error;
    case VarianteBanner.sinConexion:
      return AppColores.alertaOscuro;
    case VarianteBanner.pendientes:
      return AppColores.alerta;
    case VarianteBanner.novedades:
      return AppColores.info;
    case VarianteBanner.sinSincronizar:
      return AppColores.alertaOscuro;
    case VarianteBanner.sinVerificar:
      return AppColores.alertaOscuro;
    case VarianteBanner.alDia:
      return AppColores.exito;
  }
}

/// Franja de estado de sincronización (visible en todas las pantallas).
///
/// 1.30 (Oleada D2, UI130-07): el nivel 2 del lenguaje
/// único de sync. En «al día» no ocupa banda (devuelve
/// shrink); si pide algo, es una fila neutra compacta
/// con el color del estado solo en el icono y el
/// progreso; si es error, un [AvisoEstado] sólido con
/// sus acciones. Toca para sincronizar (en reposo) o
/// para ver el desglose (en curso). La píldora de la
/// cabecera es el nivel 1 y la Cola el nivel 3.
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

  @override
  void initState() {
    super.initState();
    _giro = AnimationController(
        // 1.35 (UI-13): período del giro en bucle, no una
        // transición: fuera de los tokens a propósito.
        vsync: this, duration: const Duration(seconds: 2));
  }

  @override
  void dispose() {
    _giro.dispose();
    super.dispose();
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
        // 1.30 (Oleada D2, UI130-07): el lenguaje único —
        // la variante fija el NIVEL (mapa puro, fijado por
        // test antes de tocar pantallas): «al día» no
        // ocupa banda; el error es AvisoEstado sólido;
        // todo lo que pide algo es una fila neutra
        // compacta con el color solo en icono y progreso.
        final variante = varianteBannerDe(s);
        final nivel = nivelBannerDe(variante);
        if (nivel == NivelBanner.ninguno) {
          return const SizedBox.shrink();
        }
        final color = colorEstadoBanner(variante);
        IconData icono;
        String titulo;
        String? subtitulo;
        switch (s.phase) {
          case SyncPhase.uploading:
            icono = Icons.sync_rounded;
            titulo = 'Enviando tus cambios';
            subtitulo = s.detalle;
            break;
          case SyncPhase.downloading:
            icono = Icons.cloud_download_rounded;
            titulo = 'Descargando datos';
            subtitulo = s.detalle;
            break;
          case SyncPhase.photos:
            icono = Icons.photo_camera_rounded;
            titulo = 'Subiendo fotos';
            subtitulo = s.detalle;
            break;
          case SyncPhase.error:
            icono = Icons.error_outline_rounded;
            titulo = 'No se pudo sincronizar';
            subtitulo = s.lastError?.mensaje;
            break;
          case SyncPhase.idle:
            // v1.2.5 (D11): frase en lenguaje humano según 3 dimensiones.
            titulo = s.frase;
            if (s.enLinea == false) {
              icono = Icons.cloud_off_rounded;
              // v1.2.5 (D12): guardado vs sincronizado, sin tecnicismos.
              subtitulo = s.ultimoGuardado != null
                  ? 'Guardado en este teléfono ${_hace(s.ultimoGuardado)}'
                  : 'Toca para intentar de nuevo';
            } else if (s.pending > 0) {
              icono = Icons.schedule_rounded;
              // v1.2.6 (Gemini): prioriza lo pendiente sobre el último sync.
              final nCambios = '${s.pending} cambio${s.pending == 1 ? '' : 's'}';
              subtitulo = s.ultimoSincronizado != null
                  ? '$nCambios listos para subir · Último respaldo ${_hace(s.ultimoSincronizado)}'
                  : '$nCambios listos para subir';
            } else if (s.hayNovedades == true) {
              icono = Icons.cloud_download_rounded;
              titulo = 'Hay cambios nuevos';
              subtitulo = 'Toca para descargar';
            } else if (s.lastOk == null) {
              // v1.1.1: nunca se ha sincronizado: no decir \"Todo al día\"
              icono = Icons.cloud_off_rounded;
              titulo = 'Sin sincronizar';
              subtitulo = 'Toca para sincronizar';
            } else if (variante == VarianteBanner.error) {
              // Yunque 3.34 (K1-1): A-3 del Y2 hizo que el
              // idle con error PERSISTIDO (avisoSyncCorto)
              // pinte la cáscara de error, pero esta
              // composición seguía cayendo en la rama «al
              // día» de abajo: cáscara roja con título
              // «Todo guardado y sincronizado», icono check
              // y subtítulo de éxito — contradicción DENTRO
              // del banner (la píldora de la misma cabecera
              // sí decía el aviso). Aquí la variante manda:
              // título = el aviso, icono de problema de
              // sync y subtítulo = la hora del aviso, con
              // el mismo formato `hace(...)` de la píldora.
              // Vale para el modo completo (AvisoEstado) y
              // para el compacto, que compone de estas
              // mismas variables antes del bloque de error.
              icono = Icons.sync_problem_rounded;
              titulo = s.avisoSyncCorto!;
              final haceAviso =
                  s.avisoSyncTs == null ? '' : hace(s.avisoSyncTs!);
              subtitulo =
                  haceAviso.isEmpty || haceAviso == 'nunca'
                      ? null
                      : haceAviso;
            } else if (variante == VarianteBanner.sinVerificar) {
              // SYNC-12 (1.35): la foto no pudo leer las
              // novedades — el banner lo declara en vez de
              // caer en la rama «al día» de abajo (que era
              // exactamente el falso verde del sitio 1).
              icono = Icons.help_outline_rounded;
              titulo = 'Sin verificar';
              subtitulo = 'Toca para sincronizar';
            } else {
              // Variante «al día»: el nivel ya devolvió
              // shrink arriba; esta rama es inalcanzable
              // (el idle con aviso persistido se compone en
              // la rama K1-1 de arriba) y se conserva solo
              // por exhaustividad del switch de fases.
              icono = Icons.check_circle_outline_rounded;
              subtitulo =
                  'Sincronizado ${_hace(s.ultimoSincronizado ?? s.lastOk)}';
            }
            break;
        }
        final enProgreso = s.phase == SyncPhase.uploading ||
            s.phase == SyncPhase.downloading ||
            s.phase == SyncPhase.photos;
        final esError = variante == VarianteBanner.error;
        if (enProgreso && !_giro.isAnimating) {
          _giro.repeat();
        } else if (!enProgreso && _giro.isAnimating) {
          _giro.stop();
        }
        final pct = s.progreso == null
            ? null
            : '${(s.progreso! * 100).round()}%';
        // Variante compacta: una línea neutra, sin
        // subtítulo ni progreso (mismo lenguaje que la
        // fila completa, sin gradiente).
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
              // tocable sube a 48 con la píldora (icono y
              // texto) intacta y centrada.
              child: SizedBox(
                height: 48,
                child: Center(
                  widthFactor: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      border: Border.all(
                          color: Theme.of(context).dividerColor),
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
                          child: Icon(icono, color: color, size: 16),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(titulo,
                              style: AppTexto.metadato.copyWith(
                                  fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (pct != null) ...[
                          const SizedBox(width: 8),
                          Text(pct,
                              style: AppTexto.metadato.copyWith(
                                  color: color,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        // Nivel error: AvisoEstado sólido (el mismo
        // componente de Salud del sync), con las acciones
        // del error y su detalle desplegable.
        if (esError) {
          return Container(
            margin: const EdgeInsets.symmetric(
                horizontal: AppEspacio.md, vertical: AppEspacio.sm),
            child: AvisoEstado(
              tipo: TipoAviso.error,
              icono: icono,
              texto: titulo,
              detalle: subtitulo,
              acciones: [
                TextButton.icon(
                  onPressed: _dispararSync,
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.white),
                  icon: const Icon(Icons.refresh_rounded,
                      color: Colors.white, size: 18),
                  label: const Text('Reintentar ahora'),
                ),
                TextButton.icon(
                  onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute(
                        builder: (_) => const RepararSyncScreen()),
                  ),
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.white),
                  icon: const Icon(Icons.build_rounded,
                      color: Colors.white, size: 18),
                  label: const Text('Ver qué quedó'),
                ),
                // Yunque 4 (L4-2): el pie desplegable ES el
                // lastError en memoria; con el error solo
                // persistido (tras reiniciar la app,
                // lastError == null) el botón alternaba un
                // pie inexistente: no se ofrece.
                if (s.lastError != null)
                  TextButton(
                    onPressed: () =>
                        setState(() => _expandido = !_expandido),
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.white),
                    child: Text(
                        _expandido ? 'Ocultar detalle' : 'Ver detalle'),
                  ),
              ],
              pie: _expandido && s.lastError != null
                  ? Column(
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
                      ],
                    )
                  : null,
            ),
          );
        }
        // Nivel 2: fila neutra compacta — superficie de
        // tarjeta con borde, el color del estado solo en
        // el icono y en el progreso.
        return Container(
          margin: const EdgeInsets.symmetric(
              horizontal: AppEspacio.md, vertical: AppEspacio.sm),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(AppRadio.lg),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadio.lg),
            onTap: () {
              if (enProgreso) {
                // En curso, el toque despliega el desglose
                // de pendientes (como antes).
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
                        child: Icon(icono, color: color, size: 24),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(titulo,
                                style: AppTexto.cuerpo.copyWith(
                                    fontWeight: FontWeight.bold),
                                // 1.27 (error gráfico de campo):
                                // el título a UNA línea siempre
                                // (el detalle vive en el
                                // subtítulo): la fila no cambia
                                // de altura entre estados.
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            // 1.28 (M1-C1): el hueco del
                            // subtítulo se reserva SIEMPRE
                            // (una línea de metadato), haya o
                            // no texto: la fila no salta al
                            // cambiar la fase.
                            ConstrainedBox(
                              constraints: const BoxConstraints(
                                  minHeight: 17),
                              child: AnimatedSwitcher(
                                duration: AppMovimiento.larga,
                                child: Text(
                                  subtitulo ?? '',
                                  key: ValueKey<String>(
                                      subtitulo ?? ''),
                                  style: AppTexto.metadato.copyWith(
                                      color: AppColores.textoSecundario(
                                          context)),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (pct != null)
                        Text(pct,
                            style: AppTexto.titulo
                                .copyWith(color: color)),
                      if (!enProgreso)
                        Icon(Icons.chevron_right_rounded,
                            color: AppColores.textoSecundario(context)
                                .withValues(alpha: 0.7),
                            size: 20),
                    ],
                  ),
                  if (enProgreso) ...[
                    const SizedBox(height: AppEspacio.sm),
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                          begin: 0, end: s.progreso ?? 0),
                      duration: AppMovimiento.larga,
                      builder: (c, v, _) => ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: s.progreso == null ? null : v,
                          backgroundColor:
                              color.withValues(alpha: 0.15),
                          valueColor:
                              AlwaysStoppedAnimation<Color>(color),
                          minHeight: 6,
                        ),
                      ),
                    ),
                  ],
                  if (_expandido && s.pending > 0 && !enProgreso)
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
                              style: AppTexto.metadato.copyWith(
                                  color: AppColores.textoSecundario(
                                      context))),
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

Future<void> copiar(BuildContext context, String texto) async {
  await Clipboard.setData(ClipboardData(text: texto));
  if (context.mounted) {
    mostrarSnack(context, 'Copiado');
  }
}
// ---------------------------------------------------------------------------
// Píldora de sincronización para el encabezado (tocable → ColaScreen).
// 1.30 (Oleada D2, UI130-07): es el nivel 1 del lenguaje
// único de sync — icono, punto de estado y una palabra
// (o el resumen del ciclo durante 30 s). Siempre visible.
// ---------------------------------------------------------------------------

class SyncPill extends StatefulWidget {
  final VoidCallback onTap;

  /// 1.30 (D2, UI130-05): en la fila de estado de la
  /// cabecera la píldora va A LO ANCHO: ocupa el espacio
  /// disponible con su contenido centrado.
  final bool anchoCompleto;

  const SyncPill(
      {super.key, required this.onTap, this.anchoCompleto = false});

  @override
  State<SyncPill> createState() => _SyncPillState();
}

class _SyncPillState extends State<SyncPill> {
  /// 1.30 (D2, UI130-07): temporizador de un disparo que
  /// retira el resumen protagonista a los 30 s aunque no
  /// llegue ninguna emisión nueva del motor (el mismo
  /// mecanismo que el banner usaba en 1.28 M1-C2: el
  /// resumen vive ahora en la píldora porque el banner
  /// en «al día» ya no ocupa banda).
  Timer? _timerResumen;
  DateTime? _resumenProgramado;

  @override
  void dispose() {
    _timerResumen?.cancel();
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
          // 1.29 (Oleada 5, D-04): token, no literal.
          color = AppColores.error;
          icono = Icons.error_outline_rounded;
          texto = 'Error';
        } else if (enProgreso) {
          color = AppColores.alerta;
          icono = Icons.sync_rounded;
          texto = 'Sincronizando';
        } else if (s.pending > 0) {
          color = AppColores.alerta;
          icono = Icons.schedule_rounded;
          texto = '${s.pending} por subir';
        } else if (s.avisoSyncCorto != null) {
          // 1.33 (coherencia de sync, §7.4 de la
          // investigación): el error de corrida PERSISTIDO
          // manda sobre el verde. Hasta la 1.32 la píldora
          // solo miraba la fase y la cola de SUBIDA: con la
          // bajada rota la corrida cerraba en idle y volvía
          // el «Al día» — y tras reiniciar la app nacía
          // verde, con el error persistido intacto. La foto
          // del motor trae el aviso desde el registro (y del
          // semáforo de bajada), con la hora del desenlace.
          color = AppColores.alerta;
          icono = Icons.sync_problem_rounded;
          final haceAviso =
              s.avisoSyncTs == null ? '' : hace(s.avisoSyncTs!);
          texto = haceAviso.isEmpty || haceAviso == 'nunca'
              ? s.avisoSyncCorto!
              : '${s.avisoSyncCorto} · $haceAviso';
        } else if (s.hayNovedades == null) {
          // SYNC-12 (1.35): la foto aún no verificó las
          // novedades (recién nacida o su lectura falló):
          // la píldora lo declara en neutro en vez del
          // «Al día» verde fantasma — el verde exige la
          // lectura hecha (hayNovedades == false).
          color = AppColores.alertaOscuro;
          icono = Icons.help_outline_rounded;
          texto = 'Sin verificar';
        } else {
          color = AppColores.exito;
          icono = Icons.check_circle_outline_rounded;
          // 1.30 (D2, UI130-07): recién terminado (< 30 s)
          // el resumen del ciclo ES el texto de la
          // píldora («↑ 2 enviados · ↓ 3 nuevos» / «Sin
          // cambios»); pasada la ventana vuelve el «Al
          // día · hace…» de siempre y el State programa el
          // redespliegue a los 30 s.
          final protagonista = resumenBannerProtagonista(
              resumen: s.ultimoResumen,
              resumenHora: s.ultimoResumenHora,
              ahora: ahoraHabana());
          if (protagonista) {
            _programarFinResumen(s.ultimoResumenHora!);
            texto = s.ultimoResumen!;
          } else {
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
        }
        return InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: widget.onTap,
          // 1.23 B11: el chip medía ~32 de alto; el área
          // tocable sube a 48 con el chip intacto y centrado.
          child: SizedBox(
            height: 48,
            child: Center(
              widthFactor: 1,
              child: Container(
                width: widget.anchoCompleto ? double.infinity : null,
                padding: const EdgeInsets.symmetric(
                    horizontal: AppEspacio.md, vertical: AppEspacio.sm),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border:
                      Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: widget.anchoCompleto
                      ? MainAxisSize.max
                      : MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icono, size: 16, color: color),
                    const SizedBox(width: 6),
                    // 1.30 (D2, UI130-07): el punto de
                    // estado del diseño (icono + punto +
                    // palabra).
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: color,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(texto,
                          style: AppTexto.metadato.copyWith(
                              color: color, fontWeight: FontWeight.w700),
                          overflow: TextOverflow.ellipsis),
                    ),
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
