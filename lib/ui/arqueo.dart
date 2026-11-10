/// v1.3.6 (ítem 1B): Arqueo de caja — liquidación del pendiente a entregar.
///
/// Solo dueño. El monto esperado se calcula SOLO sobre espejos confirmados
/// (invariante 2 de Argón: ignora ops_queue). Cada liquidación guarda
/// monto_esperado vs monto_entregado; si es parcial, el resto queda como
/// saldo de arrastre sin partir ops.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../diferencias_caja.dart';
import '../localdb.dart';
import '../models/pendiente.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart' show ahoraHabana, hoyHabanaIso;
import 'app_bar.dart';
import 'componentes.dart';
import 'diferencias_caja.dart';
import 'diseno.dart';
import 'hoja_liquidar.dart';
import 'liquidaciones_historial.dart';
import 'skeleton.dart';
import 'widgets.dart';
import '../errores_sync.dart';
import '../app_log.dart';

class ArqueoScreen extends StatefulWidget {
  const ArqueoScreen({super.key});

  @override
  State<ArqueoScreen> createState() => _ArqueoScreenState();
}

class _ArqueoScreenState extends State<ArqueoScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _entrenadores = [];
  // T5 (1.20): expedientes de diferencia abiertos (badge de
  // la entrada a la bandeja).
  int _difAbiertas = 0;
  // (M2-BC C3) antigüedad del pendiente por entrenador
  // (telegram_id en texto → días/nivel), de la foto canónica
  // agrupada que ya usa Pendiente.
  Map<String, EntrenadorPendiente> _antiguedad = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final lista = await entrenadoresConPendiente();
      var difAbiertas = _difAbiertas;
      try {
        difAbiertas =
            await DiferenciasCajaService.instance.conteoAbiertas();
      } catch (_) {}
      var antiguedad = _antiguedad;
      try {
        final agrupados =
            procesarPendientes(await pagosPendientesDetalle());
        antiguedad = {
          for (final e in agrupados) e.trainerTelegramId: e,
        };
      } catch (_) {}
      if (mounted) {
        setState(() {
          _entrenadores = lista;
          _difAbiertas = difAbiertas;
          _antiguedad = antiguedad;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _sincronizar() async {
    await SyncEngine.instance.sincronizarScope('arqueo');
    await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Arqueo del día'),
        body: const Center(
            child: Text('Solo el dueño puede ver el arqueo de caja.')),
      );
    }
    return Scaffold(
      appBar: appBarIron(
        context,
        'Arqueo del día',
        acciones: [
          IconButton(
            tooltip: 'Sincronizar arqueo',
            icon: const Icon(Icons.sync_rounded),
            onPressed: _sincronizar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          // T5 (1.20): entrada a la bandeja de diferencias
          // de caja, con el conteo de expedientes abiertos.
          Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.sm, AppEspacio.lg, 0),
            child: Tarjeta(
              onTap: () async {
                await Navigator.of(context).push(
                  RutaIron(
                    builder: (_) => const DiferenciasCajaScreen(),
                  ),
                );
                _cargar();
              },
              child: Row(
                children: [
                  Icon(Icons.folder_open_rounded,
                      color: AppColores.textoSecundario(context),
                      size: 28),
                  const SizedBox(width: AppEspacio.sm),
                  const Expanded(
                    child: Text('Diferencias de caja',
                        style: AppTexto.subtitulo),
                  ),
                  if (_difAbiertas > 0) ...[
                    ContadorBadge(numero: _difAbiertas),
                    const SizedBox(width: AppEspacio.sm),
                  ],
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
          // (M2-BC B5) entrada a la vista única de
          // liquidaciones (todos los entrenadores, con
          // búsqueda por nombre y por mes).
          Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.sm, AppEspacio.lg, 0),
            child: Tarjeta(
              onTap: () async {
                await Navigator.of(context).push(
                  RutaIron(
                    builder: (_) =>
                        const LiquidacionesHistorialScreen(),
                  ),
                );
                _cargar();
              },
              child: Row(
                children: [
                  Icon(Icons.receipt_long_rounded,
                      color: AppColores.textoSecundario(context),
                      size: 28),
                  const SizedBox(width: AppEspacio.sm),
                  const Expanded(
                    child: Text('Últimas liquidaciones',
                        style: AppTexto.subtitulo),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _cargar,
              child: CruceEstados(
                // Corrección A1-D4: fundido esqueleto→contenido
                // con el cruce de la casa (antes, ternario seco).
                estado: _cargando ? 'cargando' : 'contenido',
                child: _cargando
                    // (M2-BC C5) esqueleto estructural en vez
                    // del spinner genérico.
                    ? const SkeletonArqueo()
                    : _entrenadores.isEmpty
                      ? ListView(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(AppEspacio.xxl),
                              child: Column(
                                children: [
                                  const Icon(Icons.check_circle_outline_rounded,
                                      size: 56, color: Colors.green),
                                  const SizedBox(height: 12),
                                  const Text('Nada pendiente. Todo cuadrado.',
                                      style: AppTexto.subtitulo),
                                  const SizedBox(height: 8),
                                  Text(
                                    'El esperado se calcula solo sobre datos '
                                    'confirmados por el servidor.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: AppColores.textoSecundario(
                                            context)),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(AppEspacio.lg),
                          itemCount: _entrenadores.length,
                          itemBuilder: (_, i) {
                            final e = _entrenadores[i];
                            final cup = (e['cup'] as num).toDouble();
                            final usd = (e['usd'] as num).toDouble();
                            // (M2-BC C3) porción del total a
                            // recoger que le toca a este
                            // entrenador y color por antigüedad
                            // de su día más viejo sin entregar.
                            final totalGeneral = _entrenadores.fold<double>(
                                0,
                                (s, x) =>
                                    s +
                                    (x['cup'] as num).toDouble() +
                                    (x['usd'] as num).toDouble());
                            final porcion = totalGeneral > 0
                                ? (cup + usd) / totalGeneral
                                : 0.0;
                            final ant =
                                _antiguedad['${e['telegram_id']}'];
                            final nivel = ant?.nivelAlertaMax ?? 0;
                            final diasViejo = ant?.diasMasViejo ?? 0;
                            final colorAntiguedad = nivel == 2
                                ? AppColores.error
                                : nivel == 1
                                    ? AppColores.alerta
                                    : AppColores.exito;
                            final nombre = '${e['nombre']}';
                            return Padding(
                              padding:
                                  const EdgeInsets.only(bottom: AppEspacio.sm),
                              child: Tarjeta(
                                onTap: () async {
                                  await Navigator.of(context).push(
                                    RutaIron(
                                      builder: (_) => DetalleArqueoScreen(
                                        telegramId: e['telegram_id'] as int,
                                        nombre: nombre,
                                      ),
                                    ),
                                  );
                                  _cargar();
                                },
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      backgroundColor: AppColores
                                          .naranja
                                          .withValues(alpha: 0.15),
                                      child: Text(
                                        nombre.isNotEmpty
                                            ? nombre[0].toUpperCase()
                                            : '?',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: AppColores.naranja),
                                      ),
                                    ),
                                    const SizedBox(width: AppEspacio.sm),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(nombre,
                                              style: AppTexto.subtitulo),
                                          if (cup > 0)
                                            Text(
                                                '${fmtMonto(cup)} CUP pendientes',
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w600)),
                                          if (usd > 0)
                                            Text(
                                                '${fmtMonto(usd)} USD pendientes',
                                                style: const TextStyle(
                                                    fontWeight:
                                                        FontWeight.w600)),
                                          if (diasViejo > 0) ...[
                                            const SizedBox(height: 2),
                                            Text(
                                              'Día más viejo: hace $diasViejo día${diasViejo == 1 ? '' : 's'}',
                                              style: AppTexto.metadato.copyWith(
                                                  color: colorAntiguedad,
                                                  fontWeight:
                                                      FontWeight.w600),
                                            ),
                                          ],
                                          const SizedBox(height: 6),
                                          ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(4),
                                            child: LinearProgressIndicator(
                                              value: porcion.clamp(0.0, 1.0),
                                              minHeight: 5,
                                              backgroundColor: AppColores
                                                  .borde(context)
                                                  .withValues(alpha: 0.3),
                                              valueColor:
                                                  AlwaysStoppedAnimation<
                                                          Color>(
                                                      colorAntiguedad),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const Icon(Icons.chevron_right_rounded),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Detalle de un entrenador: esperado confirmado, historial y formulario
/// de liquidación.
class DetalleArqueoScreen extends StatefulWidget {
  final int telegramId;
  final String nombre;

  const DetalleArqueoScreen(
      {required this.telegramId, required this.nombre});

  @override
  State<DetalleArqueoScreen> createState() => _DetalleArqueoScreenState();
}

class _DetalleArqueoScreenState extends State<DetalleArqueoScreen> {
  bool _cargando = true;
  bool _liquidando = false;
  double _cup = 0;
  double _usd = 0;
  // 1.25 T05: totales canónicos (con la cola) del resumen
  // reconciliado; _cup/_usd son el confirmado (espejo).
  double _cupTotal = 0;
  double _usdTotal = 0;
  String _moneda = 'CUP';
  List<Map<String, dynamic>> _historial = [];
  // T5 (1.20): expedientes por liquidación (chip o botón
  // «Abrir expediente» en el historial).
  Map<String, Map<String, dynamic>> _expedientes = {};
  // Yunque R4-M7-1: liquidaciones con la apertura de
  // expediente en vuelo (doble toque no abre dos veces;
  // el servicio además lo impide en la cola).
  final Set<String> _abriendoExpediente = {};
  // (M2-BC B2/C4) UUID de la liquidación de la moneda
  // elegida que sigue EN COLA en este teléfono: mientras
  // exista, la tarjeta lleva el sello «Liquidado» y el
  // panel de acciones (resumen B1 + Deshacer B2).
  String? _uuidEnCola;
  // (M2-BC B1) resumen de la última liquidación de la
  // moneda elegida, para enviarlo por WhatsApp; se compone
  // al liquidar y se persiste en meta para sobrevivir a
  // la recarga de la pantalla.
  String? _resumenReciente;
  final _entregadoCtrl = TextEditingController();
  final _notaCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _entregadoCtrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  double get _esperado => _moneda == 'USD' ? _usd : _cup;

  // 1.25 T05: el total canónico (con la cola) de la moneda
  // elegida, para el puente con las demás pantallas.
  double get _totalMoneda => _moneda == 'USD' ? _usdTotal : _cupTotal;

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      // 1.25 T05: el resumen reconciliado (única función):
      // _cup/_usd siguen siendo el CONFIRMADO (base de la
      // liquidación) y los totales quedan para el puente.
      final pend = await resumenPendienteEntrega(widget.telegramId);
      final hist = await liquidacionesDeEntrenador(widget.telegramId);
      var exps = _expedientes;
      try {
        exps = await DiferenciasCajaService.instance
            .porLiquidacion();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _cup = pend.cupConfirmado;
          _usd = pend.usdConfirmado;
          _cupTotal = pend.cupTotal;
          _usdTotal = pend.usdTotal;
          _historial = hist;
          _expedientes = exps;
          _cargando = false;
          if (_moneda == 'USD' && _usd <= 0) _moneda = 'CUP';
          _entregadoCtrl.text = _esperado > 0
              ? _esperado.toStringAsFixed(
                  _esperado == _esperado.roundToDouble() ? 0 : 2)
              : '';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
    unawaited(_refrescarEnCola());
  }

  /// (M2-BC B2/C4) refresca el estado «liquidación en cola»
  /// de la moneda elegida (sello, resumen y Deshacer).
  Future<void> _refrescarEnCola() async {
    final uuid =
        await uuidLiquidacionEnCola(widget.telegramId, _moneda);
    String? resumen;
    try {
      resumen = await LocalDb.instance
          .getMeta('resumen_liq_${widget.telegramId}_$_moneda');
    } catch (_) {}
    if (mounted) {
      setState(() {
        _uuidEnCola = uuid;
        _resumenReciente = resumen;
      });
    }
  }

  /// (M2-BC B1) abre WhatsApp con el resumen de la
  /// liquidación para enviárselo al entrenador (sin número
  /// fijo: el dueño elige su chat; el espejo de usuarios no
  /// trae un teléfono fiable del entrenador).
  Future<void> _enviarResumen() async {
    final r = _resumenReciente;
    if (r == null) return;
    final uri =
        Uri.parse('https://wa.me/?text=${Uri.encodeComponent(r)}');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// (M2-BC B1) copia el resumen al portapapeles.
  Future<void> _copiarResumen() async {
    final r = _resumenReciente;
    if (r == null) return;
    await Clipboard.setData(ClipboardData(text: r));
    if (!mounted) return;
    mostrarSnack(context, 'Resumen copiado, pégalo en WhatsApp');
  }

  /// Corrección A3-D2 (auditorías 1.28): guarda de vuelo
  /// del deshacer en cola — sin ella, un doble toque
  /// lanzaba dos deshacerLiquidacion: la primera deshacía
  /// y la segunda, al no encontrar la op, enseñaba el
  /// FALSO «ya sincronizó» tras un deshacer correcto.
  bool _deshaciendo = false;

  /// (M2-BC B2) Deshacer desde el panel «en cola» (la misma
  /// vía que la barra de aviso): solo si la op sigue en el
  /// teléfono; si ya sincronizó, se dice y no se toca nada.
  Future<void> _deshacerEnCola() async {
    if (_deshaciendo) return;
    final uuid = _uuidEnCola;
    if (uuid == null) return;
    setState(() => _deshaciendo = true);
    try {
      await _deshacerEnColaReal(uuid);
    } finally {
      if (mounted) setState(() => _deshaciendo = false);
    }
  }

  Future<void> _deshacerEnColaReal(String uuid) async {
    final ok = await deshacerLiquidacion(uuid);
    if (!mounted) return;
    if (ok) {
      mostrarSnack(context, 'Liquidación deshecha',
          significado: SignificadoChip.exito);
    } else {
      mostrarSnack(context,
          'Ya no se puede deshacer: la liquidación ya sincronizó.',
          significado: SignificadoChip.error);
    }
    await _cargar();
  }

  // (M2-A A1) guarda SÍNCRONA al entrar: antes el setState de
  // _liquidando llegaba DESPUÉS del diálogo de confirmación y
  // un doble toque pasaba dos veces por todo el flujo. La
  // guarda de servicio (crearLiquidacion rechaza la segunda
  // liquidación en cola del mismo entrenador+moneda) es la red
  // final; esta evita el doble diálogo.
  Future<void> _liquidar() async {
    if (_liquidando) return;
    setState(() => _liquidando = true);
    try {
      await _liquidarReal();
    } finally {
      if (mounted) setState(() => _liquidando = false);
    }
  }

  Future<void> _liquidarReal() async {
    final entregado =
        double.tryParse(_entregadoCtrl.text.replaceAll(',', '.'));
    // Autoauditoría 1.22 #2 (clase N-2 fuera de nómina): NaN no
    // es < 0 ni supera lo esperado (toda comparación con NaN es
    // falsa) y se colaba como monto de liquidación válido.
    if (entregado == null || !entregado.isFinite || entregado < 0) {
      _aviso('Escribe un monto válido.');
      return;
    }
    final esperado = _esperado;
    if (entregado - esperado > 0.01) {
      _aviso('Lo entregado no puede superar lo esperado '
          '(${fmtMonto(esperado)} $_moneda).');
      return;
    }
    if (esperado <= 0) {
      _aviso('No hay pendiente confirmado en $_moneda.');
      return;
    }
    // Autoauditoría 1.22 #2 (D2-04): el «esperado» de la
    // pantalla es una FOTO de _cargar(); los ids se leen frescos
    // aquí. Si entre la carga y la confirmación entró un cobro
    // nuevo (o se anuló uno), validar y confirmar contra la
    // foto liquidaba un monto que ya no era el real y dejaba el
    // resto como arrastre fantasma. Se recalcula y, si cambió,
    // se avisa y se aborta ESTE intento (patrón C1 de
    // panel_resto_caja): Jc confirma de nuevo con la cifra real.
    final fresco = await pendienteArqueo(widget.telegramId);
    final esperadoFresco = _moneda == 'USD' ? fresco.usd : fresco.cup;
    if ((esperadoFresco - esperado).abs() > 0.01) {
      _aviso('El pendiente cambió: era ${fmtMonto(esperado)} '
          '$_moneda y ahora es ${fmtMonto(esperadoFresco)} '
          '$_moneda. La pantalla se actualizó; confirma de nuevo.');
      await _cargar();
      return;
    }
    final opIds =
        await idsPendienteArqueo(widget.telegramId, moneda: _moneda);
    final totalIds = opIds.values.fold<int>(0, (s, l) => s + l.length);
    // 1.15-turnos (#8): el arrastre puro SÍ se puede liquidar: el
    // servidor permite op_ids vacío cuando hay arrastre pendiente.
    // Antes esta guarda atrapaba ese caso (esperado > 0 sin ops
    // nuevas). El servidor sigue siendo el backstop (rechaza el
    // vacío sin arrastre y con esperado > 0.01).
    final parcial = entregado < esperado - 0.01;
    if (!mounted) return;
    // T5 (1.20): la marca de expediente solo tiene sentido
    // con diferencia; el servidor la ignora sin diferencia.
    // 1.29 (Oleada 4, barrido): el diálogo de confirmación
    // vive en un StatefulWidget dueño de su controlador
    // (_DialogoConfirmarLiquidacion); ver su doc.
    final r = await showDialog<({bool abrirExp, String explicacion})>(
      context: context,
      builder: (_) => _DialogoConfirmarLiquidacion(
        nombre: widget.nombre,
        esperado: esperado,
        entregado: entregado,
        parcial: parcial,
        moneda: _moneda,
        totalIds: totalIds,
      ),
    );
    if (r == null || !mounted) return;
    final quiereExpediente = r.abrirExp;
    final explicacionExpediente = r.explicacion;
    // (M2-BC B1) el resumen para el entrenador se compone
    // con la MISMA foto (opIds frescos) antes de encolar.
    final resumen = resumenLiquidacionTexto(
      nombre: widget.nombre,
      fecha: ahoraHabana(),
      moneda: _moneda,
      esperado: esperado,
      entregado: entregado,
      opIds: opIds,
      nota: _notaCtrl.text.trim().isEmpty
          ? null
          : _notaCtrl.text.trim(),
    );
    final messenger = ScaffoldMessenger.of(context);
    try {
      final liqId = await crearLiquidacion(
        entrenadorTelegramId: widget.telegramId,
        entrenadorNombre: widget.nombre,
        montoEsperado: esperado,
        montoEntregado: entregado,
        opIds: opIds,
        moneda: _moneda,
        nota: _notaCtrl.text.trim().isEmpty
            ? null
            : _notaCtrl.text.trim(),
        abrirExpediente: quiereExpediente,
        explicacionExpediente: explicacionExpediente,
      );
      try {
        await LocalDb.instance.setMeta(
            'resumen_liq_${widget.telegramId}_$_moneda', resumen);
      } catch (_) {}
      if (mounted) {
        // (M2-BC B2) el aviso de éxito lleva «Deshacer»
        // mientras la op siga en el teléfono.
        mostrarAvisoLiquidacionConDeshacer(
          messenger,
          mensaje: parcial
              ? 'Liquidación parcial registrada. Arrastre: '
                  '${fmtMonto(esperado - entregado)} $_moneda.'
              : 'Liquidación registrada. Se sincronizará en breve.',
          liqId: liqId,
          alDeshacer: () async {
            if (mounted) await _cargar();
          },
        );
        _notaCtrl.clear();
        await _cargar();
      }
    } catch (e) {
      AppLog.error('arqueo', 'liquidar_fallo', d: '$e');
      _aviso('No se pudo liquidar: ${mensajeErrorAmable(e)}');
    }
  }

  void _aviso(String msg) {
    if (!mounted) return;
    mostrarSnack(context, msg);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Arqueo · ${widget.nombre}'),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: _cargando
                // (M2-BC C5) esqueleto estructural en vez del
                // spinner genérico.
                ? ListView(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    children: const [SkeletonLista(items: 3)],
                  )
                : ListView(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    children: [
                      // Selector de moneda (solo si hay USD).
                      if (_usd > 0)
                        Padding(
                          padding:
                              const EdgeInsets.only(bottom: AppEspacio.sm),
                          child: SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(
                                  value: 'CUP', label: Text('CUP')),
                              ButtonSegment(
                                  value: 'USD', label: Text('USD')),
                            ],
                            selected: {_moneda},
                            onSelectionChanged: (s) {
                              setState(() {
                                _moneda = s.first;
                                _entregadoCtrl.text = _esperado > 0
                                    ? _esperado.toStringAsFixed(
                                        _esperado ==
                                                _esperado.roundToDouble()
                                            ? 0
                                            : 2)
                                    : '';
                              });
                              unawaited(_refrescarEnCola());
                            },
                          ),
                        ),
                      Tarjeta(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Text('Pendiente confirmado',
                                    style: AppTexto.subtitulo),
                                const Spacer(),
                                if (_uuidEnCola != null)
                                  // (M2-BC C4) sello «LIQUIDADO»
                                  // con micro-animación (escala +
                                  // fundido en 350 ms) mientras la
                                  // liquidación de esta moneda sigue
                                  // en cola en este teléfono.
                                  TweenAnimationBuilder<double>(
                                    tween:
                                        Tween(begin: 0.0, end: 1.0),
                                    duration: AppMovimiento.larga,
                                    builder: (ctx, t, _) => Opacity(
                                      opacity: t,
                                      child: Transform.scale(
                                        scale: 1.5 - 0.5 * t,
                                        child: Transform.rotate(
                                          angle: -0.18,
                                          child: Container(
                                            padding: const EdgeInsets
                                                .symmetric(
                                                horizontal: 8,
                                                vertical: 3),
                                            decoration: BoxDecoration(
                                              border: Border.all(
                                                  color:
                                                      AppColores.exito,
                                                  width: 1.6),
                                              borderRadius:
                                                  BorderRadius.circular(
                                                      AppRadio.sm),
                                            ),
                                            child: Text('LIQUIDADO',
                                                style: AppTexto.metadato
                                                    .copyWith(
                                                        color: AppColores
                                                            .exito,
                                                        fontWeight:
                                                            FontWeight
                                                                .w800,
                                                        letterSpacing:
                                                            1.2)),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${fmtMonto(_esperado)} $_moneda',
                              style: AppTexto.displayPequeno.copyWith(
                                  color: AppColores.naranja),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Calculado solo sobre datos confirmados por '
                              'el servidor (sin operaciones en cola).',
                              style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
                                      context)),
                            ),
                            // 1.25 T05: el puente con la cifra de
                            // Hub/Mi Turno/Detalle cuando difiere:
                            // la diferencia es lo sin sincronizar,
                            // no un error de cuentas.
                            if ((_totalMoneda - _esperado).abs() > 0.01) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Pendiente total: '
                                '${fmtMonto(_totalMoneda)} $_moneda. '
                                'La diferencia con el confirmado es '
                                'dinero aún sin sincronizar: se podrá '
                                'liquidar cuando suba al servidor.',
                                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
                                        context)),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // (M2-BC B1/B2) panel de la liquidación
                      // EN COLA de esta moneda: enviar el
                      // resumen al entrenador o deshacerla
                      // mientras no haya sincronizado.
                      if (_uuidEnCola != null) ...[
                        const SizedBox(height: AppEspacio.md),
                        Tarjeta(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Liquidación en cola de '
                                'sincronización',
                                style: AppTexto.cuerpo.copyWith(
                                    fontWeight: FontWeight.w600),
                              ),
                              Text(
                                'Aún está en este teléfono: puedes '
                                'enviar el resumen o deshacerla. '
                                'Cuando sincronice, el pendiente '
                                'bajará y ya no se podrá deshacer '
                                'desde aquí.',
                                style: AppTexto.metadato.copyWith(
                                    color: AppColores.textoSecundario(
                                        context)),
                              ),
                              const SizedBox(height: AppEspacio.sm),
                              Wrap(
                                spacing: AppEspacio.sm,
                                children: [
                                  if (_resumenReciente != null)
                                    OutlinedButton.icon(
                                      icon: const Icon(
                                          Icons.chat_rounded,
                                          size: 18),
                                      label: const Text(
                                          'Resumen por WhatsApp'),
                                      onPressed: _enviarResumen,
                                    ),
                                  if (_resumenReciente != null)
                                    TextButton.icon(
                                      icon: const Icon(
                                          Icons.copy_rounded,
                                          size: 18),
                                      label:
                                          const Text('Copiar resumen'),
                                      onPressed: _copiarResumen,
                                    ),
                                  TextButton.icon(
                                    icon: const Icon(
                                        Icons.undo_rounded,
                                        size: 18),
                                    label: const Text(
                                        'Deshacer liquidación'),
                                    onPressed: _deshaciendo
                                        ? null
                                        : _deshacerEnCola,
                                    style: TextButton.styleFrom(
                                        foregroundColor:
                                            AppColores.error),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: AppEspacio.md),
                      const Text('Nueva liquidación', style: AppTexto.subtitulo),
                      const SizedBox(height: AppEspacio.sm),
                      TextField(
                        controller: _entregadoCtrl,
                        keyboardType:
                            const TextInputType.numberWithOptions(
                                decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.,]')),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Monto entregado ($_moneda)',
                          border: const OutlineInputBorder(),
                          suffixText: _moneda,
                        ),
                      ),
                      const SizedBox(height: AppEspacio.sm),
                      TextField(
                        controller: _notaCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Nota (opcional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: AppEspacio.md),
                      BotonPrimario(
                        texto: 'Liquidar',
                        icono: Icons.point_of_sale_rounded,
                        cargando: _liquidando,
                        onPressed: _liquidando ? null : _liquidar,
                      ),
                      const SizedBox(height: AppEspacio.lg),
                      const Text('Historial', style: AppTexto.subtitulo),
                      const SizedBox(height: AppEspacio.sm),
                      // 1.25 T118 (F2-21): resumen del mes
                      // sobre la lista plana (antes había que
                      // sumar las tarjetas a ojo). Solo CUP en
                      // las cifras: las monedas no se mezclan.
                      if (_historial.isNotEmpty)
                        Builder(builder: (ctx) {
                          final prefMes = hoyHabanaIso().substring(0, 7);
                          final delMes = _historial
                              .where((h) =>
                                  '${h['creada_en'] ?? ''}'
                                      .startsWith(prefMes))
                              .toList();
                          if (delMes.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          final entregadoCup = delMes
                              .where((h) =>
                                  (h['moneda'] ?? 'CUP') == 'CUP')
                              .fold<double>(
                                  0,
                                  (a, h) =>
                                      a +
                                      ((h['monto_entregado'] as num?)
                                              ?.toDouble() ??
                                          0));
                          final entregadoUsd = delMes
                              .where((h) =>
                                  (h['moneda'] ?? 'CUP') == 'USD')
                              .fold<double>(
                                  0,
                                  (a, h) =>
                                      a +
                                      ((h['monto_entregado'] as num?)
                                              ?.toDouble() ??
                                          0));
                          final diferenciasCup = delMes
                              .where((h) =>
                                  (h['moneda'] ?? 'CUP') == 'CUP')
                              .fold<double>(
                                  0,
                                  (a, h) =>
                                      a + diferenciaDeLiquidacion(h));
                          return Padding(
                            padding: const EdgeInsets.only(
                                bottom: AppEspacio.sm),
                            child: Text(
                              'Este mes: ${delMes.length} '
                              'liquidaci${delMes.length == 1 ? 'ón' : 'ones'} · '
                              '${fmtMonto(entregadoCup)} CUP entregados'
                              '${entregadoUsd > 0 ? ' + ${fmtMonto(entregadoUsd)} USD' : ''} · '
                              'diferencias: ${fmtMonto(diferenciasCup)} CUP',
                              style: AppTexto.secundario,
                            ),
                          );
                        }),
                      if (_historial.isEmpty)
                        Text('Sin liquidaciones registradas.',
                            style: TextStyle(
                                color:
                                    AppColores.textoSecundario(context))),
                      for (final h in _historial)
                        Padding(
                          padding: const EdgeInsets.only(
                              bottom: AppEspacio.sm),
                          child: Tarjeta(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '${fmtMonto(h['monto_entregado'])} '
                                      '${h['moneda'] ?? 'CUP'}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700),
                                    ),
                                    Container(
                                      padding:
                                          const EdgeInsets.symmetric(
                                              horizontal: AppEspacio.sm, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: (h['estado'] == 'parcial'
                                                ? AppColores.alerta
                                                : Colors.green)
                                            .withValues(alpha: 0.15),
                                        borderRadius:
                                            BorderRadius.circular(AppRadio.md),
                                      ),
                                      child: Text(
                                        h['estado'] == 'parcial'
                                            ? 'Parcial'
                                            : 'Liquidado',
                                        style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Esperado: ${fmtMonto(h['monto_esperado'])}'
                                  '${(h['saldo_arrastre'] as num? ?? 0) > 0 ? ' · Arrastre: ${fmtMonto(h['saldo_arrastre'])}' : ''}',
                                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
                                          context)),
                                ),
                                Text(
                                  '${h['creada_en'] ?? ''} · por ${h['creada_por'] ?? ''}',
                                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
                                          context)),
                                ),
                                if ((h['nota'] as String?)?.isNotEmpty ==
                                    true)
                                  Text('${h['nota']}',
                                      style:
                                          AppTexto.metadato),
                                // T5 (1.20): el expediente de
                                // esta liquidación, o el botón
                                // para abrirlo si faltó dinero.
                                if (_expedientes['${h['id']}'] !=
                                    null) ...[
                                  const SizedBox(
                                      height: AppEspacio.sm),
                                  chipExpedienteDiferencia(
                                      _expedientes['${h['id']}']!),
                                ] else if (diferenciaDeLiquidacion(
                                        h) >
                                    0.01)
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                      icon: const Icon(
                                          Icons.folder_open_rounded,
                                          size: 18),
                                      label: const Text(
                                          'Abrir expediente'),
                                      // Yunque R4-M7-1: guarda
                                      // de vuelo + error
                                      // visible (la guarda del
                                      // servicio lanza si ya
                                      // hay expediente o
                                      // apertura en curso).
                                      onPressed: _abriendoExpediente
                                              .contains(
                                                  '${h['id']}')
                                          ? null
                                          : () async {
                                              final liqId =
                                                  '${h['id']}';
                                              setState(() =>
                                                  _abriendoExpediente
                                                      .add(liqId));
                                              try {
                                                await DiferenciasCajaService
                                                    .instance
                                                    .abrir(
                                                        liquidacionId:
                                                            liqId);
                                                if (!context
                                                    .mounted) {
                                                  return;
                                                }
                                                mostrarSnack(context,
                                                    'Expediente abierto '
                                                    '(se sincronizará)',
                                                    significado:
                                                        SignificadoChip
                                                            .exito);
                                                _cargar();
                                              } catch (e) {
                                                if (!context
                                                    .mounted) {
                                                  return;
                                                }
                                                mostrarSnack(context,
                                                    '$e',
                                                    significado:
                                                        SignificadoChip
                                                            .error);
                                              } finally {
                                                if (mounted) {
                                                  setState(() =>
                                                      _abriendoExpediente
                                                          .remove(
                                                              liqId));
                                                }
                                              }
                                            },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 1.29 (Oleada 4, barrido de diálogos): «Confirmar
/// liquidación» del arqueo como StatefulWidget DUEÑO de su
/// controlador (el de la explicación del expediente),
/// dispuesto en dispose() — el patrón de la casa. Antes el
/// controlador se creaba en el método y se disponía nada
/// más resolver el showDialog, con la animación de salida
/// aún reconstruyendo el campo (defecto D-B1-08). El cuerpo
/// del diálogo (recibo, barra y marca de expediente) se
/// movió verbatim; devuelve si se abre expediente y la
/// explicación tecleada.
class _DialogoConfirmarLiquidacion extends StatefulWidget {
  const _DialogoConfirmarLiquidacion({
    required this.nombre,
    required this.esperado,
    required this.entregado,
    required this.parcial,
    required this.moneda,
    required this.totalIds,
  });

  final String nombre;
  final double esperado;
  final double entregado;
  final bool parcial;
  final String moneda;
  final int totalIds;

  @override
  State<_DialogoConfirmarLiquidacion> createState() =>
      _DialogoConfirmarLiquidacionState();
}

class _DialogoConfirmarLiquidacionState
    extends State<_DialogoConfirmarLiquidacion> {
  final _expCtrl = TextEditingController();
  bool _abrirExp = false;

  @override
  void dispose() {
    _expCtrl.dispose();
    super.dispose();
  }

  /// (M2-BC C4) fila del recibo: la misma de la pantalla.
  Widget _filaRecibo(String etiqueta, String valor,
      {bool destacado = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(etiqueta, style: AppTexto.secundario),
          Text(
            valor,
            style: AppTexto.cuerpo.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: destacado ? 18 : null,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return         AlertDialog(
        title: const Text('Confirmar liquidación'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // (M2-BC C4) el diálogo como RECIBO: filas
            // claras widget.esperado / widget.entregado / diferencia o
            // arrastre dentro de una tarjeta con borde, en
            // vez de textos sueltos.
            Container(
              padding: const EdgeInsets.all(AppEspacio.md),
              decoration: BoxDecoration(
                color: AppColores.superficie(context),
                border: Border.all(color: AppColores.borde(context)),
                borderRadius: BorderRadius.circular(AppRadio.md),
              ),
              child: Column(
                children: [
                  _filaRecibo('Entrenador', widget.nombre),
                  _filaRecibo('Esperado',
                      '${fmtMonto(widget.esperado)} ${widget.moneda}'),
                  _filaRecibo(
                    'Entregado',
                    '${fmtMonto(widget.entregado)} ${widget.moneda}',
                    destacado: true,
                  ),
                  const Divider(height: 16),
                  _filaRecibo(
                    widget.parcial ? 'Queda de arrastre' : 'Diferencia',
                    widget.parcial
                        ? '${fmtMonto(widget.esperado - widget.entregado)} ${widget.moneda}'
                        : 'Sin diferencia',
                    color: widget.parcial
                        ? AppColores.error
                        : AppColores.exito,
                  ),
                ],
              ),
            ),
            // C3 (estéticas 1.19): comparación visual — barra
            // de cuánto se entregó y diferencia destacada
            // (verde si cuadra, rojo si falta; lo parcial
            // queda como arrastre).
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadio.circular),
              child: LinearProgressIndicator(
                value: widget.esperado > 0
                    ? (widget.entregado / widget.esperado).clamp(0.0, 1.0)
                    : 0,
                minHeight: 8,
                backgroundColor:
                    AppColores.borde(context).withValues(alpha: 0.3),
                valueColor: AlwaysStoppedAnimation<Color>(
                    widget.parcial ? AppColores.alerta : AppColores.exito),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.parcial
                  ? 'Faltan ${fmtMonto(widget.esperado - widget.entregado)} '
                      '${widget.moneda} · quedan como saldo de arrastre.'
                  : 'Cuadra exacto.',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: widget.parcial
                      ? AppColores.error
                      : AppColores.exito),
            ),
            const SizedBox(height: 8),
            Text('${widget.totalIds} operación(es) incluida(s).',
                style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
            // T5 (1.20): abrir el expediente AQUÍ, en la
            // misma op, solo si la diferencia no es el
            // arrastre normal.
            if (widget.parcial) ...[
              const SizedBox(height: AppEspacio.sm),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _abrirExp,
                onChanged: (v) =>
                    setState(() => _abrirExp = v ?? false),
                title: const Text(
                    'Abrir expediente por esta diferencia',
                    style: AppTexto.cuerpo),
                subtitle: const Text(
                    'Solo si NO es el arrastre normal: queda '
                    'registrada con causa y resolución.',
                    style: AppTexto.metadato),
              ),
              if (_abrirExp)
                TextField(
                  controller: _expCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Explicación (opcional)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop((
              abrirExp: _abrirExp,
              explicacion: _expCtrl.text,
            )),
            child: const Text('Liquidar'),
          ),
        ],
    );
  }
}
