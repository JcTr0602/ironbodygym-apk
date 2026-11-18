/// Centro de Sincronización (1.32, O2F2S — M2/M3 del
/// diseño de detalle de sync, plano G-75..G-79).
///
/// La pantalla que por fin responde «¿sincronizó de
/// verdad?» con la foto del DIARIO de corridas (M1):
/// estado en vivo, avisos de la vigilancia (M4), cobertura
/// por tabla («en el teléfono: X», con el «total
/// publicado» del servidor SOLO cuando existe y etiquetado
/// como tal) e historial de corridas con su detalle.
///
/// Offline-first estricto: todo pinta desde local (diario,
/// metas, espejos) sin ninguna RPC con await antes de
/// pintar; la única red que toca esta pantalla es el botón
/// «Sincronizar ahora», que es la acción misma.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../diario_sync.dart';
import '../errores_sync.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../vigilancia_sync.dart';
import 'admin_secciones.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'cola.dart';
import 'salud_sync_screen.dart';
import 'skeleton.dart';

/// Tipos de corrida en lenguaje llano.
String etiquetaTipoCorrida(String tipo) => switch (tipo) {
      TipoCorrida.completa => 'Sincronización completa',
      TipoCorrida.soloPush => 'Solo subida',
      TipoCorrida.soloPull => 'Solo bajada',
      TipoCorrida.bajadaCompleta => 'Bajada completa',
      TipoCorrida.scope => 'Sincronización parcial',
      _ => tipo,
    };

String etiquetaOrigenCorrida(String origen) => switch (origen) {
      OrigenCorrida.manual => 'manual',
      OrigenCorrida.automatica => 'automática',
      OrigenCorrida.instalacion => 'instalación',
      OrigenCorrida.trasPush => 'tras la subida',
      _ => origen,
    };

String etiquetaEstadoCorrida(String estado) => switch (estado) {
      EstadoCorrida.completa => 'Completa',
      EstadoCorrida.parcial => 'Parcial',
      EstadoCorrida.fallida => 'Falló',
      EstadoCorrida.cortada => 'Cortada',
      EstadoCorrida.enCurso => 'En curso',
      _ => estado,
    };

Color colorEstadoCorrida(String estado, BuildContext context) =>
    switch (estado) {
      EstadoCorrida.completa => AppColores.exito,
      EstadoCorrida.parcial => AppColores.alerta,
      EstadoCorrida.fallida ||
      EstadoCorrida.cortada =>
        AppColores.error,
      _ => AppColores.info,
    };

/// HH:mm del dd/MM en hora de La Habana (epoch en segundos).
String horaCorridaHabana(int epochSeg) {
  final h = aHabana(
      DateTime.fromMillisecondsSinceEpoch(epochSeg * 1000));
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(h.hour)}:${p(h.minute)} del ${p(h.day)}/${p(h.month)}';
}

String duracionCorrida(int? ms) {
  if (ms == null) return '—';
  if (ms < 1000) return '$ms ms';
  final s = ms ~/ 1000;
  if (s < 60) return '$s s';
  return '${s ~/ 60} min ${p2(s % 60)} s';
}

String p2(int n) => n.toString().padLeft(2, '0');

class CentroSyncScreen extends StatefulWidget {
  const CentroSyncScreen({super.key});

  @override
  State<CentroSyncScreen> createState() => _CentroSyncScreenState();
}

class _CentroSyncScreenState extends State<CentroSyncScreen> {
  bool _cargando = true;
  // 1.36 H-C2 (136-894): una corrida manual en curso —
  // el botón se apaga mientras corre.
  bool _sincronizando = false;
  List<CorridaSync> _corridas = [];
  List<AvisoSync> _avisos = [];
  // SYNC-12 (1.35): null por tabla = «sin leer», no 0.
  Map<String, int?> _locales = {};
  // Yunque 4 (L4-1): lecturas de _cargar que fallaron;
  // >0 obliga a declarar la foto parcial (ver _cargar).
  int _lecturasFallidas = 0;
  Map<String, int?>? _publicados;
  List<String> _tablasRol = [];

  @override
  void initState() {
    super.initState();
    _cargar();
    // A8 se alimenta de la meta que verificarReloj escribe:
    // se refresca tras pintar y los avisos se re-evalúan.
    unawaited(() async {
      try {
        await SyncEngine.instance.verificarReloj();
        final nuevos = await evaluarVigilanciaSync();
        if (mounted) setState(() => _avisos = nuevos);
      } catch (_) {}
    }());
  }

  Future<void> _cargar() async {
    final esAdmin = AuthService().isAdmin;
    final tablas = SyncEngine.tablasEspejoActivasParaRol(esAdmin);
    var corridas = <CorridaSync>[];
    var locales = <String, int?>{};
    Map<String, int?>? publicados;
    var avisos = <AvisoSync>[];
    // Yunque 4 (L4-1, espejo de R4-M3-1 de Reparar): una
    // lectura fallida NO es un vacío — se cuenta y la
    // pantalla lo declara en vez de afirmar «no hay
    // corridas» o «0 en el teléfono» sobre un fallo de BD.
    var fallidas = 0;
    try {
      corridas = await DiarioSync.instance.historial(limite: 30);
    } catch (_) {
      fallidas++;
    }
    try {
      locales = await DiarioSync.instance.conteosLocales(tablas);
    } catch (_) {
      fallidas++;
    }
    try {
      publicados = await DiarioSync.instance.conteosPublicados();
    } catch (_) {
      fallidas++;
    }
    try {
      avisos = await evaluarVigilanciaSync();
    } catch (_) {
      fallidas++;
    }
    if (!mounted) return;
    setState(() {
      _corridas = corridas;
      _locales = locales;
      _publicados = publicados;
      _avisos = avisos;
      _tablasRol = tablas;
      _lecturasFallidas = fallidas;
      _cargando = false;
    });
  }

  Widget _avisoLecturasFallidas() {
    // (1.36 H-B4 136-896) la misma severidad que Reparar da
    // a una lectura fallida: error, con reintento.
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded,
                color: AppColores.errorTexto(context)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No se pudo leer el diario completo: lo que '
                'falta puede existir. Las cifras de abajo '
                'son parciales.',
                style: AppTexto.cuerpo,
              ),
            ),
            TextButton(
              onPressed: _cargar,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }

  /// 1.35 (SP-10): «Sincronizar ahora» significa lo mismo
  /// aquí que en la Cola: forzado de verdad (cancela el
  /// backoff de reintentos) y, al volver, el resumen del
  /// desenlace de ESTA corrida. Antes este botón corría
  /// sin forzar y en silencio: el mismo gesto producía
  /// dos resultados distintos según la pantalla desde la
  /// que se tocara.
  void _sincronizarAhora() {
    // 136-894: guarda síncrona — un segundo toque
    // mientras corre no lanza otra corrida.
    if (_sincronizando) return;
    setState(() => _sincronizando = true);
    unawaited(() async {
      SyncResultado? res;
      try {
        res = await SyncEngine.instance.run(forzar: true);
      } catch (_) {
        res = null;
      }
      if (!mounted) return;
      await _cargar();
      if (mounted) setState(() => _sincronizando = false);
      if (mounted) await _mostrarResumenSync(res);
    }());
  }

  /// El resumen de desenlace, con el mismo veredicto que
  /// enseña la Cola (SyncResultado.resumenCorto y sus
  /// conteos): si el ciclo no corrió, jamás se dice éxito.
  Future<void> _mostrarResumenSync(SyncResultado? res) async {
    if (!mounted) return;
    if (res == null || !res.corrio) {
      final enCurso =
          res != null && res.motivoNoCorrio == SyncMotivoNoCorrio.enCurso;
      await showDialog(
        context: context,
        builder: (ctx) => DialogoApp(
          titulo:
              enCurso ? 'Sincronización en curso' : 'No se pudo sincronizar',
          iconoTitulo: Icons.sync_rounded,
          contenido: Text(
            enCurso
                ? 'Ya hay una sincronización en curso en este '
                    'teléfono. Espera unos segundos y vuelve a '
                    'intentarlo.'
                : res == null
                    ? 'La sincronización no se pudo completar. '
                        'Inténtalo de nuevo.'
                    : 'No hay una sesión activa para sincronizar. '
                        'Entra de nuevo e inténtalo.',
            style: AppTexto.cuerpo.copyWith(height: 1.4),
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
      return;
    }
    final error = res.error;
    await showDialog(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: res.resumenCorto,
        iconoTitulo: error != null && error.isNotEmpty
            ? Icons.error_outline_rounded
            : Icons.sync_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _filaResumenSync(
                Icons.upload_rounded, 'Subidos', '${res.subidos}'),
            const SizedBox(height: 8),
            _filaResumenSync(
                Icons.download_rounded, 'Bajados', '${res.bajados}'),
            if (res.reactivadas > 0) ...[
              const SizedBox(height: 12),
              Text(
                'Se reintentaron ${res.reactivadas} operaciones '
                'que estaban atascadas.',
                style: AppTexto.secundario,
              ),
            ],
            if (error != null && error.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                error,
                style: AppTexto.secundario
                    .copyWith(color: AppColores.error),
              ),
            ],
            if (res.pendientesRestantes > 0 ||
                res.trabajoFueraCola > 0 ||
                res.conteoIndeterminado) ...[
              const SizedBox(height: 12),
              Text(res.textoPendientes, style: AppTexto.secundario),
            ],
            if (res.subidos == 0 &&
                res.bajados == 0 &&
                res.pendientesRestantes == 0 &&
                res.trabajoFueraCola == 0 &&
                !res.conteoIndeterminado &&
                (error == null || error.isEmpty))
              const Padding(
                padding: EdgeInsets.only(top: AppEspacio.md),
                child: Text(
                  'Todo estaba al día: no había nada nuevo que '
                  'subir ni bajar.',
                  style: AppTexto.secundario,
                ),
              ),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  Widget _filaResumenSync(IconData icono, String etiqueta, String valor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(icono,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(etiqueta, style: AppTexto.titulo),
          ],
        ),
        Text(valor, style: AppTexto.titulo),
      ],
    );
  }

  void _ir(Widget pantalla) {
    Navigator.of(context).push(RutaIron(builder: (_) => pantalla));
  }

  void _abrirDestinoAviso(AvisoSync aviso) {
    switch (aviso.destino) {
      case 'salud':
        _ir(const SaludSyncScreen());
      case 'bajada':
        _ir(const BajadaCompletaScreen());
      case 'cola':
        // (1.36 H-B4 136-895) navegar a la Cola de forma
        // explícita, sin asumir desde dónde se abrió el Centro.
        _ir(const ColaScreen());
      default:
        break;
    }
  }

  /// (1.36 H-B4 136-895) destinos que de verdad navegan.
  bool _destinoReal(String? destino) =>
      destino == 'salud' || destino == 'bajada' || destino == 'cola';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Centro de sincronización'),
      body: _cargando
          ? const Padding(
              padding: EdgeInsets.all(AppEspacio.lg),
              child: SkeletonLista(items: 5))
          : RefrescoIron(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  _tarjetaEnVivo(),
                  // (1.36 H-B4 136-896) «Sincronizar ahora»
                  // junto al veredicto, no al final.
                  const SizedBox(height: 12),
                  BotonPrimario(
                    texto: _sincronizando
                        ? 'Sincronizando…'
                        : 'Sincronizar ahora',
                    icono: Icons.sync_rounded,
                    onPressed:
                        _sincronizando ? null : _sincronizarAhora,
                  ),
                  if (_lecturasFallidas > 0) ...[
                    const SizedBox(height: 16),
                    _avisoLecturasFallidas(),
                  ],
                  if (_avisos.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _seccionAvisos(),
                  ],
                  const SizedBox(height: 16),
                  _seccionDetalleTecnico(),
                  const SizedBox(height: 16),
                  _seccionHistorial(),
                  const SizedBox(height: 16),
                  _seccionPuertas(),
                ],
              ),
            ),
    );
  }

  /// En vivo: la fase del motor (stream) y, si el diario
  /// tiene una corrida abierta, su tabla/página en curso.
  /// 1.34 Campo 2 (P-4): vive en un widget con State propio
  /// (_TarjetaEnVivoSync): el futuro de la corrida en curso
  /// se crea en su State al cambiar la fase/el detalle, no
  /// dentro del builder en cada emisión del motor.
  Widget _tarjetaEnVivo() => const _TarjetaEnVivoSync();

  Widget _seccionAvisos() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Avisos', style: AppTexto.subtitulo),
        const SizedBox(height: 8),
        ..._avisos.map((a) {
          final color = switch (a.severidad) {
            SeveridadAvisoSync.alta => AppColores.error,
            SeveridadAvisoSync.media => AppColores.alerta,
            SeveridadAvisoSync.info => AppColores.info,
          };
          return Card(
            margin: const EdgeInsets.only(bottom: AppEspacio.sm),
            child: ListTile(
              leading: Icon(
                a.severidad == SeveridadAvisoSync.info
                    ? Icons.info_rounded
                    : Icons.warning_amber_rounded,
                color: color,
              ),
              title: Text(a.titulo),
              subtitle: Text(a.detalle),
              // (1.36 H-B4 136-895) sin destino real, la fila
              // no parece tocable: ni chevron ni onTap.
              trailing: _destinoReal(a.destino)
                  ? const Icon(Icons.chevron_right_rounded)
                  : null,
              onTap: _destinoReal(a.destino)
                  ? () => _abrirDestinoAviso(a)
                  : null,
            ),
          );
        }),
      ],
    );
  }

  /// SYNC-12 (1.35): el texto de una fila de cobertura con
  /// los neutros del triestado — un conteo local que no se
  /// pudo leer se declara «sin leer» (nunca un 0 inventado)
  /// y un total publicado ausente deja la fila sin
  /// denominador (nunca «X de 0»).
  String _textoCobertura(String t) {
    final local = _locales[t];
    if (local == null) return 'sin leer';
    final pub = _publicados == null
        ? null
        : (_publicados![t] ?? _publicados!['sync_$t']);
    if (pub != null) return '$local de $pub (total publicado)';
    return '$local en el teléfono';
  }

  /// Cobertura: «en el teléfono: X» por tabla del rol; el
  /// denominador SOLO si el servidor publica conteos, y
  /// etiquetado «total publicado» (H-5/H-6 de la
  /// adjudicación: jamás un «de Y» inventado).
  ///
  /// 1.35 (UI-19): la cobertura por tabla es el detalle
  /// técnico del Centro: baja a la sección plegable
  /// «Detalle técnico» (cerrada al entrar). El primer
  /// nivel de la pantalla es el veredicto de mostrador,
  /// los avisos y el historial en palabras llanas.
  Widget _seccionDetalleTecnico() {
    return Tarjeta(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        title: const Text('Detalle técnico',
            style: AppTexto.subtitulo),
        subtitle: const Text('Conteos por tabla en este teléfono'),
        childrenPadding: const EdgeInsets.fromLTRB(
            AppEspacio.lg, 0, AppEspacio.lg, AppEspacio.lg),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _publicados == null
                    ? 'El servidor aún no publica los totales por '
                        'tabla: se muestra solo lo que hay en el '
                        'teléfono.'
                    : 'El «total publicado» es el conteo que el '
                        'servidor declara por tabla.',
                style: AppTexto.minuscula.copyWith(
                    color: AppColores.textoSecundario(context)),
              ),
              const SizedBox(height: 8),
              for (final t in _tablasRol)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          SyncEngine.nombreAmigableTabla(t),
                          style: AppTexto.cuerpo,
                        ),
                      ),
                      Text(
                        _textoCobertura(t),
                        style: AppTexto.cuerpo.copyWith(
                            color: AppColores.textoSecundario(
                                context)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _seccionHistorial() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Historial de sincronizaciones',
            style: AppTexto.subtitulo),
        const SizedBox(height: 8),
        if (_corridas.isEmpty)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                // L4-1: con lecturas fallidas el vacío no se
                // afirma: puede haber corridas y no leerse.
                _lecturasFallidas > 0
                    ? 'No se pudo leer el historial del diario.'
                    : 'Todavía no hay corridas registradas en el diario.',
                style: AppTexto.cuerpo.copyWith(
                    color: AppColores.textoSecundario(context)),
              ),
              // (1.36 H-B4 136-896) el vacío trae su acción.
              TextButton.icon(
                onPressed: _cargar,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Revisar de nuevo'),
              ),
            ],
          )
        else
          ..._corridas.map((c) {
            final flechas = [
              if (c.subidos > 0) '↑ ${c.subidos}',
              if (c.bajados > 0) '↓ ${c.bajados}',
              if (c.fotosSubidas > 0) 'fotos ${c.fotosSubidas}',
            ].join(' · ');
            return Card(
              margin: const EdgeInsets.only(bottom: AppEspacio.sm),
              child: ListTile(
                leading: Icon(Icons.sync_rounded,
                    color: colorEstadoCorrida(c.estado, context)),
                title: Text(
                    '${etiquetaTipoCorrida(c.tipo)} · '
                    '${etiquetaEstadoCorrida(c.estado)}'),
                subtitle: Text(
                  '${horaCorridaHabana(c.inicioEpoch)} · '
                  '${duracionCorrida(c.duracionMs)} · '
                  '${etiquetaOrigenCorrida(c.origen)}'
                  '${flechas.isEmpty ? '' : ' · $flechas'}'
                  '${c.motivoNoSello != null ? '\n${c.motivoNoSello}' : ''}',
                ),
                trailing:
                    const Icon(Icons.chevron_right_rounded),
                onTap: () => _ir(DetalleCorridaSyncScreen(corrida: c)),
              ),
            );
          }),
      ],
    );
  }

  Widget _seccionPuertas() {
    Widget puerta(IconData icono, String texto, VoidCallback onTap) {
      return Expanded(
        child: OutlinedButton.icon(
          icon: Icon(icono, size: 18),
          label: Text(texto),
          onPressed: onTap,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Herramientas', style: AppTexto.subtitulo),
        const SizedBox(height: 8),
        Row(
          children: [
            puerta(Icons.health_and_safety_rounded, 'Salud',
                () => _ir(const SaludSyncScreen())),
            const SizedBox(width: 8),
            puerta(Icons.build_rounded, 'Taller del espejo',
                () => _ir(const SeccionDiagnosticoScreen())),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            puerta(Icons.download_rounded, 'Bajada completa',
                () => _ir(const BajadaCompletaScreen())),
            const SizedBox(width: 8),
            puerta(Icons.list_alt_rounded, 'Cola',
                () => _ir(const ColaScreen())),
          ],
        ),
      ],
    );
  }
}

/// 1.35 (corrección E3, C2-01): ¿la fase del motor es una
/// corrida EN CURSO? `error` NO corre: es el desenlace de
/// una corrida que ya falló — contarlo como «corriendo»
/// pintaba «Sincronizando ahora…» sobre la sync muerta y
/// dejaba la rama de error del veredicto inalcanzable.
/// PURA, misma lectura que `estadoSyncCabecera`.
bool faseSyncEnCurso(SyncPhase fase) =>
    fase == SyncPhase.uploading ||
    fase == SyncPhase.downloading ||
    fase == SyncPhase.photos;

/// 1.35 (UI-19): el veredicto del Centro en lenguaje de
/// mostrador — UNA frase que responde «¿estoy al día?»
/// sin saber qué es una corrida ni una cola. PURA.
/// El orden manda: lo que se puede ACCIONAR va primero
/// (faltan por subir), el fallo después; «sin verificar»
/// (hayNovedades null: la lectura de novedades no se ha
/// hecho o falló) NUNCA afirma «al día» (corrección E3,
/// C2-02): sin lectura válida el veredicto dice que no se
/// pudo comprobar, en neutro.
String resumenMostradorSync({
  required bool corriendo,
  required int pendientes,
  required bool? enLinea,
  required bool hayError,
  required bool? hayNovedades,
  // Yunque Exhaustivo 1.35 (S-01): el error de corrida
  // PERSISTIDO (avisoSyncCorto de la foto, p. ej. tras un
  // reinicio con sesion_invalida) también es un fallo
  // conocido, aunque la fase ya sea idle y lastError de
  // memoria sea null. Comparte la rama de error con
  // [hayError] y va tras hayNovedades==true y antes de
  // hayNovedades==null — el mismo orden que
  // varianteBannerDe: el error conocido manda sobre el
  // «sin verificar», pero no sobre pendientes, novedades
  // ni la falta de conexión, que van antes.
  bool avisoPersistido = false,
  // 1.36 (136-142, E-01; absorbe a D-11): el trabajo fuera
  // de la cola de subida (revisión/rechazadas sin
  // reconocer, fotos pendientes/en error, comprobantes e
  // incidencias en error, de la foto del motor). Con esta
  // cifra > 0 el veredicto NO es «Todo al día»: va tras los
  // pendientes de la cola (lo accionable primero) y antes
  // del resto de ramas tranquilas.
  int fueraCola = 0,
}) {
  if (corriendo) return 'Sincronizando ahora…';
  if (pendientes > 0) {
    return pendientes == 1
        ? 'Falta 1 por subir'
        : 'Faltan $pendientes por subir';
  }
  if (fueraCola > 0) {
    return fueraCola == 1
        ? 'Queda 1 por atender fuera de la cola'
        : 'Quedan $fueraCola por atender fuera de la cola';
  }
  // 1.36 (136-892): prioridad DOCUMENTADA de las ramas —
  // pendientes → sin conexión → novedades → error. El orden
  // anterior ponía hayError antes que la conexión y las
  // novedades: un fallo VIEJO (p. ej. el de anoche) tapaba el
  // «Sin conexión» de ahora y el «Hay novedades» real, y el
  // Mostrador mandaba a «Sincronizar ahora» contra un muro.
  // El error (de memoria o persistido, S-01) manda solo
  // sobre el «sin verificar» de hayNovedades==null, como en
  // varianteBannerDe.
  if (enLinea == false) {
    return 'Sin conexión: todo se subirá solo cuando vuelva';
  }
  if (hayNovedades == true) {
    return 'Hay novedades por bajar del servidor';
  }
  if (hayError || avisoPersistido) {
    return 'La última sincronización falló: toca '
        '«Sincronizar ahora»';
  }
  if (hayNovedades == null) {
    return 'Sin verificar: aún no se ha podido comprobar';
  }
  return 'Todo al día';
}

/// Detalle de UNA corrida del diario (M3): por tabla —
/// vistas, nuevas, sin cambio, eliminadas y fallidas — y
/// las ops que subieron con su desenlace.
class DetalleCorridaSyncScreen extends StatefulWidget {
  final CorridaSync corrida;
  const DetalleCorridaSyncScreen({super.key, required this.corrida});

  @override
  State<DetalleCorridaSyncScreen> createState() =>
      _DetalleCorridaSyncScreenState();
}

class _DetalleCorridaSyncScreenState
    extends State<DetalleCorridaSyncScreen> {
  bool _cargando = true;
  List<CorridaTablaSync> _tablas = [];
  List<CorridaOpSync> _ops = [];
  // Yunque 4 (L4-1): lecturas fallidas de este detalle;
  // con alguna, el vacío no se atribuye a la corrida.
  int _lecturasFallidas = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    var tablas = <CorridaTablaSync>[];
    var ops = <CorridaOpSync>[];
    var fallidas = 0;
    try {
      tablas = await DiarioSync.instance.tablasDe(widget.corrida.id);
    } catch (_) {
      fallidas++;
    }
    try {
      ops = await DiarioSync.instance.opsDe(widget.corrida.id);
    } catch (_) {
      fallidas++;
    }
    if (!mounted) return;
    setState(() {
      _tablas = tablas;
      _ops = ops;
      _lecturasFallidas = fallidas;
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.corrida;
    return Scaffold(
      appBar: appBarIron(context, 'Detalle de la corrida'),
      body: _cargando
          ? const Padding(
              padding: EdgeInsets.all(AppEspacio.lg),
              child: SkeletonLista(items: 5))
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                Tarjeta(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${etiquetaTipoCorrida(c.tipo)} · '
                        '${etiquetaEstadoCorrida(c.estado)}',
                        style: AppTexto.subtitulo,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${horaCorridaHabana(c.inicioEpoch)} · '
                        'duró ${duracionCorrida(c.duracionMs)} · '
                        'origen ${etiquetaOrigenCorrida(c.origen)}',
                        style: AppTexto.cuerpo,
                      ),
                      Text(
                        'Aplicadas en esta corrida: '
                        '↑ ${c.subidos} subidas · ↓ ${c.bajados} '
                        'bajadas'
                        '${c.fotosSubidas > 0 ? ' · ${c.fotosSubidas} fotos' : ''}'
                        '${c.comprobantesSubidos > 0 ? ' · ${c.comprobantesSubidos} comprobantes' : ''}',
                        style: AppTexto.cuerpo,
                      ),
                      if (c.motivoNoSello != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          c.motivoNoSello!,
                          style: AppTexto.cuerpo.copyWith(
                              color: AppColores.error),
                        ),
                      ],
                      if (c.errorDetalle != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          // Yunque 1.34 (C3-3): el errorDetalle
                          // del Diario es FORENSE (SYNC-04): si
                          // parece excepción cruda se traduce
                          // con el traductor de la casa, como ya
                          // hace detalle(); jamás verbatim.
                          pareceTextoTecnicoCrudo(c.errorDetalle!)
                              ? describirErrorCorrida(c.errorDetalle!)
                              : c.errorDetalle!,
                          style: AppTexto.minuscula.copyWith(
                              color: AppColores.textoSecundario(
                                  context)),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_tablas.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Por tabla', style: AppTexto.subtitulo),
                  const SizedBox(height: 8),
                  ..._tablas.map((t) {
                    final partes = [
                      if (t.recibidas > 0) '${t.recibidas} vistas',
                      if (t.aplicadas > 0) '${t.aplicadas} nuevas',
                      if (t.sinCambio > 0)
                        '${t.sinCambio} sin cambio',
                      if (t.tumbas > 0) '${t.tumbas} eliminadas',
                      if (t.fallidas > 0)
                        '${t.fallidas} fallidas',
                    ].join(' · ');
                    return Card(
                      margin: const EdgeInsets.only(
                          bottom: AppEspacio.sm),
                      child: ListTile(
                        title: Text(
                            SyncEngine.nombreAmigableTabla(t.tabla)),
                        subtitle: Text(partes.isEmpty
                            ? 'Sin movimientos'
                            : partes),
                        trailing: Text(
                          t.estado,
                          style: AppTexto.minuscula.copyWith(
                              color: colorEstadoCorrida(
                                  t.estado == EstadoTablaDiario.fallida
                                      ? EstadoCorrida.fallida
                                      : t.estado ==
                                              EstadoTablaDiario.ok
                                          ? EstadoCorrida.completa
                                          : EstadoCorrida.parcial,
                                  context)),
                        ),
                      ),
                    );
                  }),
                ],
                if (_ops.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('Operaciones subidas',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 8),
                  ..._ops.map((op) => Card(
                        margin: const EdgeInsets.only(
                            bottom: AppEspacio.sm),
                        child: ListTile(
                          title: Text(op.resumen ?? op.tipo),
                          subtitle: op.motivo != null
                              ? Text(op.motivo!)
                              : null,
                          trailing: Text(
                            op.resultado,
                            style: AppTexto.minuscula.copyWith(
                                color: op.resultado == 'aplicada'
                                    ? AppColores.exito
                                    : op.resultado == 'rechazada'
                                        ? AppColores.error
                                        : AppColores.alerta),
                          ),
                        ),
                      )),
                ],
                if (_lecturasFallidas > 0)
                  Text(
                    'No se pudo leer el desglose completo de '
                    'esta corrida: lo que falta puede existir.',
                    style: AppTexto.cuerpo.copyWith(
                        color: AppColores.alerta),
                  ),
                if (_tablas.isEmpty && _ops.isEmpty &&
                    _lecturasFallidas == 0)
                  Text(
                    'Esta corrida no dejó desglose (chequeo sin '
                    'movimientos).',
                    style: AppTexto.cuerpo.copyWith(
                        color:
                            AppColores.textoSecundario(context)),
                  ),
              ],
            ),
    );
  }
}

/// 1.34 Campo 2 (P-4): tarjeta «en vivo» del Centro de
/// Sincronización con State propio. Antes era un método de
/// la pantalla cuyo StreamBuilder creaba el futuro de la
/// corrida en curso DENTRO del builder: cada una de las
/// ~45 emisiones de una corrida relanzaba la consulta al
/// diario. Ahora el futuro vive en este State y solo se
/// renueva cuando cambian la fase o el detalle del motor
/// (que es cuando la tabla/página en curso puede cambiar).
class _TarjetaEnVivoSync extends StatefulWidget {
  const _TarjetaEnVivoSync();

  @override
  State<_TarjetaEnVivoSync> createState() => _TarjetaEnVivoSyncState();
}

class _TarjetaEnVivoSyncState extends State<_TarjetaEnVivoSync> {
  late SyncStatus _st;
  late Future<CorridaSync?> _futuraCorrida;
  StreamSubscription<SyncStatus>? _sub;

  @override
  void initState() {
    super.initState();
    _st = SyncEngine.instance.currentStatus;
    _futuraCorrida = DiarioSync.instance.corridaEnCurso();
    _sub = SyncEngine.instance.statusStream.listen((s) {
      if (!mounted) return;
      final cambia = s.phase != _st.phase || s.detalle != _st.detalle;
      setState(() => _st = s);
      if (cambia) {
        _futuraCorrida = DiarioSync.instance.corridaEnCurso();
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final st = _st;
    // E3 (C2-01): `error` no es «corriendo» y SÍ es error
    // aunque la foto no traiga texto de error.
    final corriendo = faseSyncEnCurso(st.phase);
    final enError =
        st.lastError != null || st.phase == SyncPhase.error;
    // Yunque Exhaustivo 1.35 (S-01): el error PERSISTIDO
    // (avisoSyncCorto) se pinta como error SOLO cuando su
    // rama es la que manda en el veredicto (no corriendo,
    // sin pendientes, con línea no descartada y sin
    // novedades por bajar que vayan antes); en otro caso
    // mandan el icono/color de la rama ganadora.
    // (1.36 H-B4 136-893) un aviso vacío o de solo espacios
    // NO pinta la tarjeta como error.
    final hayAvisoPersistido =
        (st.avisoSyncCorto?.trim() ?? '').isNotEmpty;
    final avisoPersistidoManda = hayAvisoPersistido &&
        !corriendo &&
        st.pending == 0 &&
        st.enLinea != false &&
        st.hayNovedades != true;
    // 1.36 (136-142): el trabajo fuera de la cola también
    // pinta el icono de problema, nunca el check verde.
    final enErrorVisible =
        enError || avisoPersistidoManda || st.fueraCola > 0;
    // E3 (C2-02): el veredicto «Sin verificar» se pinta en
    // neutro, nunca con el check verde de «al día».
    // S-01: con aviso persistido mandando, el veredicto es
    // el de error, no el de «sin verificar».
    final sinVerificar = !corriendo &&
        !enError &&
        !avisoPersistidoManda &&
        st.pending == 0 &&
        st.enLinea != false &&
        st.hayNovedades == null;
    // 1.35 (UI-19): el titular de la tarjeta es el
    // veredicto en lenguaje de mostrador; el detalle de
    // la fase queda debajo, como hasta ahora.
    final veredicto = resumenMostradorSync(
      corriendo: corriendo,
      pendientes: st.pending,
      enLinea: st.enLinea,
      hayError: enError,
      hayNovedades: st.hayNovedades,
      avisoPersistido: hayAvisoPersistido,
      fueraCola: st.fueraCola,
    );
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                corriendo
                    ? Icons.sync_rounded
                    : enErrorVisible
                        ? Icons.error_outline_rounded
                        : sinVerificar
                            ? Icons.help_outline_rounded
                            : Icons.check_circle_rounded,
                color: corriendo
                    ? AppColores.info
                    : enErrorVisible
                        ? AppColores.error
                        : sinVerificar
                            // (1.36 H-B4 136-896) «sin
                            // verificar» en neutro.
                            ? AppColores.textoSecundario(context)
                            : AppColores.exito,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  veredicto,
                  style: AppTexto.subtitulo,
                ),
              ),
            ],
          ),
          if (st.detalle != null && st.detalle!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(st.detalle!,
                style: AppTexto.cuerpo.copyWith(
                    color: AppColores.textoSecundario(context))),
          ],
          if (st.pending > 0) ...[
            const SizedBox(height: 6),
            Text(
              '${st.pending} por subir',
              style: AppTexto.cuerpo,
            ),
          ],
          FutureBuilder<CorridaSync?>(
            future: _futuraCorrida,
            builder: (context, s2) {
              final c = s2.data;
              if (c == null) return const SizedBox.shrink();
              final donde = c.tablaActual == null
                  ? ''
                  : ' · ${SyncEngine.nombreAmigableTabla(c.tablaActual!)}'
                      '${c.paginaActual != null ? ' (página ${c.paginaActual})' : ''}';
              return Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Corrida en curso: ${etiquetaTipoCorrida(c.tipo)}$donde',
                  style: AppTexto.minuscula.copyWith(
                      color: AppColores.textoSecundario(context)),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
