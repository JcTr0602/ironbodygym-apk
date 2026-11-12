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
import '../sync.dart';
import '../tiempo.dart';
import '../vigilancia_sync.dart';
import 'admin_secciones.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
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
  List<CorridaSync> _corridas = [];
  List<AvisoSync> _avisos = [];
  Map<String, int> _locales = {};
  Map<String, int>? _publicados;
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
    var locales = <String, int>{};
    Map<String, int>? publicados;
    var avisos = <AvisoSync>[];
    try {
      corridas = await DiarioSync.instance.historial(limite: 30);
    } catch (_) {}
    try {
      locales = await DiarioSync.instance.conteosLocales(tablas);
    } catch (_) {}
    try {
      publicados = await DiarioSync.instance.conteosPublicados();
    } catch (_) {}
    try {
      avisos = await evaluarVigilanciaSync();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _corridas = corridas;
      _locales = locales;
      _publicados = publicados;
      _avisos = avisos;
      _tablasRol = tablas;
      _cargando = false;
    });
  }

  void _sincronizarAhora() {
    unawaited(() async {
      try {
        await SyncEngine.instance.run();
      } catch (_) {}
      if (mounted) await _cargar();
    }());
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
        // La Cola es la pantalla que abrió este Centro.
        Navigator.of(context).pop();
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Centro de sincronización'),
      body: _cargando
          ? const Padding(
              padding: EdgeInsets.all(AppEspacio.lg),
              child: SkeletonLista(items: 5))
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  _tarjetaEnVivo(),
                  if (_avisos.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _seccionAvisos(),
                  ],
                  const SizedBox(height: 16),
                  _seccionCobertura(),
                  const SizedBox(height: 16),
                  _seccionHistorial(),
                  const SizedBox(height: 16),
                  _seccionPuertas(),
                  const SizedBox(height: 16),
                  BotonPrimario(
                    texto: 'Sincronizar ahora',
                    icono: Icons.sync_rounded,
                    onPressed: _sincronizarAhora,
                  ),
                ],
              ),
            ),
    );
  }

  /// En vivo: la fase del motor (stream) y, si el diario
  /// tiene una corrida abierta, su tabla/página en curso.
  Widget _tarjetaEnVivo() {
    return StreamBuilder<SyncStatus>(
      stream: SyncEngine.instance.statusStream,
      initialData: SyncEngine.instance.currentStatus,
      builder: (context, snap) {
        final st = snap.data ?? SyncEngine.instance.currentStatus;
        final corriendo = st.phase != SyncPhase.idle;
        return Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    corriendo
                        ? Icons.sync_rounded
                        : Icons.check_circle_rounded,
                    color: corriendo
                        ? AppColores.info
                        : AppColores.exito,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      corriendo
                          ? 'Sincronizando ahora'
                          : 'Sin sincronización en curso',
                      style: AppTexto.subtitulo,
                    ),
                  ),
                ],
              ),
              if (st.detalle != null && st.detalle!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(st.detalle!,
                    style: AppTexto.cuerpo.copyWith(
                        color:
                            AppColores.textoSecundario(context))),
              ],
              if (st.pending > 0) ...[
                const SizedBox(height: 6),
                Text(
                  '${st.pending} por subir',
                  style: AppTexto.cuerpo,
                ),
              ],
              FutureBuilder<CorridaSync?>(
                future: DiarioSync.instance.corridaEnCurso(),
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
                          color:
                              AppColores.textoSecundario(context)),
                    ),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

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
              trailing: a.destino != null && a.destino != 'reloj'
                  ? const Icon(Icons.chevron_right_rounded)
                  : null,
              onTap: a.destino == null
                  ? null
                  : () => _abrirDestinoAviso(a),
            ),
          );
        }),
      ],
    );
  }

  /// Cobertura: «en el teléfono: X» por tabla del rol; el
  /// denominador SOLO si el servidor publica conteos, y
  /// etiquetado «total publicado» (H-5/H-6 de la
  /// adjudicación: jamás un «de Y» inventado).
  Widget _seccionCobertura() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('En este teléfono', style: AppTexto.subtitulo),
        const SizedBox(height: 4),
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
        Tarjeta(
          child: Column(
            children: [
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
                        _publicados != null &&
                                (_publicados![t] ??
                                        _publicados!['sync_$t']) !=
                                    null
                            ? '${_locales[t] ?? 0} de '
                                '${_publicados![t] ?? _publicados!['sync_$t']} '
                                '(total publicado)'
                            : '${_locales[t] ?? 0} en el teléfono',
                        style: AppTexto.cuerpo.copyWith(
                            color: AppColores.textoSecundario(
                                context)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
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
          Text(
            'Todavía no hay corridas registradas en el diario.',
            style: AppTexto.cuerpo.copyWith(
                color: AppColores.textoSecundario(context)),
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
                () => Navigator.of(context).pop()),
          ],
        ),
      ],
    );
  }
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

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    var tablas = <CorridaTablaSync>[];
    var ops = <CorridaOpSync>[];
    try {
      tablas = await DiarioSync.instance.tablasDe(widget.corrida.id);
    } catch (_) {}
    try {
      ops = await DiarioSync.instance.opsDe(widget.corrida.id);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _tablas = tablas;
      _ops = ops;
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
                          c.errorDetalle!,
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
                if (_tablas.isEmpty && _ops.isEmpty)
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
