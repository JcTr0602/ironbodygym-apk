/// 1.32 «Mostrador Táctico» — la hoja ÚNICA de «Liquidar
/// Arqueo» (S-5 absorbido por el rediseño).
///
/// La dualidad histórica desaparece del marco: ni
/// ArqueoEntregaScreen ni el botón de ArqueoScreen son ya la
/// puerta — esta hoja es LA puerta de liquidar en el Pilar 4
/// (Caja) y en el acceso rápido del Pilar 1. Por dentro es la
/// liquidación canónica de siempre, sin tocar una sola regla
/// de dinero: esperado de [pendienteArqueo], reverificación
/// en fresco antes de encolar, ids de [idsPendienteArqueo],
/// [crearLiquidacion] con todas sus guardas y el mismo
/// [ResultadoLiquidacion] que devuelve HojaLiquidar (el
/// llamador reutiliza mostrarAvisoLiquidacionConDeshacer).
///
/// Lo nuevo es el gesto, como manda el plano: conteo con PAD
/// NUMÉRICO EMPOTRADO (sin teclado del sistema tapando la
/// hoja) y CONFIRMACIÓN POR DESLIZAMIENTO (el dinero crítico
/// no se confirma con un toque accidental). Desde la
/// Oleada 2 (Fase 0) ambos viven como primitivas
/// compartidas en primitivas.dart.
///
/// Nota de alcance (Oleada 2, Fase 1 — desviación 1 del
/// veredicto de Argón sobre g132dis_): la hoja es la puerta
/// ÚNICA de liquidar, con SELECTOR DE MODO superior. El modo
/// «Entrega anticipada C1» (registrarEntregaEfectivo, op
/// liquidar_entrega_efectivo) registra el efectivo recibido
/// en mano contra el LIBRO de entregas; el modo «Liquidación
/// de cierre» es la liquidación canónica de arriba. Las dos
/// operaciones NO se funden: cada modo ejecuta la suya, con
/// sus guardas, compartiendo solo el gesto (pad + deslizar).
/// Con esta puerta, ArqueoEntregaScreen quedó sin llamadores
/// y se retiró (panel_resto_caja.dart conserva solo la
/// función de datos completarPendientesArqueoC1, con su test).
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../bloque2_resto.dart';
import '../errores_sync.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'hoja_accion.dart';
import 'hoja_liquidar.dart';
import 'primitivas.dart';

// Las primitivas compartidas viven en primitivas.dart
// desde la Oleada 2 (Fase 0); este re-export conserva
// los llamadores históricos de la hoja.
export 'primitivas.dart' show PadNumerico, DeslizarConfirmar;

/// Muestra la hoja única de Liquidar Arqueo para un
/// entrenador y devuelve el [ResultadoLiquidacion] (o null
/// si se cerró sin liquidar).
/// El modo de la puerta única: qué operación ejecuta la
/// hoja al deslizar. Cada modo corre SU operación contable
/// (sin fundir mutaciones; ver la nota de alcance arriba).
enum ModoHojaArqueo { cierre, entregaC1 }

/// Lo que la hoja devuelve al cerrarse con éxito. En modo
/// cierre trae la liquidación (con su liqId para el
/// Deshacer); en modo C1 trae el op_uuid de la entrega
/// registrada, que NO tiene deshacer (igual que la pantalla
/// C1 original).
typedef ResultadoHojaArqueo = ({
  ModoHojaArqueo modo,
  ResultadoLiquidacion? liquidacion,
  String? entregaUuid,
  double entregado,
  String moneda,
});

/// Costuras de la capa de datos de la hoja (patrón de la
/// casa: los cargadores inyectados de «Por Decidir» y el
/// PlusReportesService de panel_resto_caja). En producción
/// valen null y la hoja llama a las funciones reales; los
/// tests de widget inyectan falsas porque bajo FakeAsync las
/// lecturas FFI de LocalDb no resuelven (límite probado del
/// banco de widgets, 2026-10-31). Los efectos reales de cada
/// operación los cubren sus tests unitarios.
typedef PendienteArqueoFn = Future<({double cup, double usd})>
    Function(int telegramId);
typedef PendienteDeltaC1Fn = Future<double> Function(int telegramId);
typedef IdsPendienteArqueoFn = Future<Map<String, List<int>>>
    Function(int telegramId, String moneda);
typedef CrearLiquidacionFn = Future<String> Function({
  required int entrenadorTelegramId,
  required String entrenadorNombre,
  required double montoEsperado,
  required double montoEntregado,
  required Map<String, List<int>> opIds,
  required String moneda,
  String? nota,
});
typedef RegistrarEntregaFn = Future<String> Function({
  required int entrenadorTelegramId,
  required double montoEntregado,
  required int autorDuenoId,
});

Future<ResultadoHojaArqueo?> mostrarHojaLiquidarArqueo(
  BuildContext context, {
  required int telegramId,
  required String nombre,
  PendienteArqueoFn? pendienteArqueoFn,
  PendienteDeltaC1Fn? pendienteDeltaC1Fn,
  IdsPendienteArqueoFn? idsPendienteArqueoFn,
  CrearLiquidacionFn? crearLiquidacionFn,
  RegistrarEntregaFn? registrarEntregaFn,
}) {
  return showModalBottomSheet<ResultadoHojaArqueo>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (_) => HojaLiquidarArqueo(
      telegramId: telegramId,
      nombre: nombre,
      pendienteArqueoFn: pendienteArqueoFn,
      pendienteDeltaC1Fn: pendienteDeltaC1Fn,
      idsPendienteArqueoFn: idsPendienteArqueoFn,
      crearLiquidacionFn: crearLiquidacionFn,
      registrarEntregaFn: registrarEntregaFn,
    ),
  );
}

class HojaLiquidarArqueo extends StatefulWidget {
  final int telegramId;
  final String nombre;
  final PendienteArqueoFn? pendienteArqueoFn;
  final PendienteDeltaC1Fn? pendienteDeltaC1Fn;
  final IdsPendienteArqueoFn? idsPendienteArqueoFn;
  final CrearLiquidacionFn? crearLiquidacionFn;
  final RegistrarEntregaFn? registrarEntregaFn;

  const HojaLiquidarArqueo({
    super.key,
    required this.telegramId,
    required this.nombre,
    this.pendienteArqueoFn,
    this.pendienteDeltaC1Fn,
    this.idsPendienteArqueoFn,
    this.crearLiquidacionFn,
    this.registrarEntregaFn,
  });

  @override
  State<HojaLiquidarArqueo> createState() => _HojaLiquidarArqueoState();
}

class _HojaLiquidarArqueoState extends State<HojaLiquidarArqueo> {
  ModoHojaArqueo _modo = ModoHojaArqueo.cierre;
  bool _cargaInicial = true;
  bool _cargando = true;

  // Resolvedores de la costura: la falsa inyectada o la real.
  Future<({double cup, double usd})> _pendArqueo() =>
      widget.pendienteArqueoFn?.call(widget.telegramId) ??
      pendienteArqueo(widget.telegramId);
  Future<double> _pendDeltaC1() =>
      widget.pendienteDeltaC1Fn?.call(widget.telegramId) ??
      pendienteDeltaC1(widget.telegramId);
  Future<Map<String, List<int>>> _idsPendiente() =>
      widget.idsPendienteArqueoFn?.call(widget.telegramId, _moneda) ??
      idsPendienteArqueo(widget.telegramId, moneda: _moneda);
  Future<String> _crearLiquidacion({
    required double montoEsperado,
    required double montoEntregado,
    required Map<String, List<int>> opIds,
    required String? nota,
  }) {
    final fn = widget.crearLiquidacionFn ?? crearLiquidacion;
    return fn(
      entrenadorTelegramId: widget.telegramId,
      entrenadorNombre: widget.nombre,
      montoEsperado: montoEsperado,
      montoEntregado: montoEntregado,
      opIds: opIds,
      moneda: _moneda,
      nota: nota,
    );
  }

  Future<String> _registrarEntrega(double montoEntregado) {
    final fn = widget.registrarEntregaFn ?? registrarEntregaEfectivo;
    return fn(
      entrenadorTelegramId: widget.telegramId,
      montoEntregado: montoEntregado,
      autorDuenoId: AuthService().telegramId ?? 0,
    );
  }
  bool _liquidando = false;
  double _cup = 0;
  double _usd = 0;
  double _deltaC1 = 0;
  String _moneda = 'CUP';
  String _contado = '';

  /// El esperado del MODO activo: en cierre manda la moneda
  /// elegida (CUP/USD del arqueo); en C1 manda el delta del
  /// libro de entregas, siempre CUP.
  double get _esperado => _modo == ModoHojaArqueo.entregaC1
      ? _deltaC1
      : (_moneda == 'USD' ? _usd : _cup);
  double? get _contadoNum =>
      _contado.isEmpty ? null : double.tryParse(_contado);

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  String _fmt(double v) =>
      v.toStringAsFixed(v == v.roundToDouble() ? 0 : 2);

  Future<void> _cargar() async {
    try {
      final pend = await _pendArqueo();
      // El delta C1 se lee SIEMPRE: el selector de modo
      // necesita saber si el libro de entregas tiene algo
      // que registrar (y arrancar en C1 si el arqueo está a 0
      // pero el libro no).
      final delta = await _pendDeltaC1();
      if (!mounted) return;
      setState(() {
        _cup = pend.cup;
        _usd = pend.usd;
        _deltaC1 = delta;
        if (_moneda == 'CUP' && _cup <= 0 && _usd > 0) _moneda = 'USD';
        if (_moneda == 'USD' && _usd <= 0) _moneda = 'CUP';
        if (_cargaInicial &&
            _cup <= 0 &&
            _usd <= 0 &&
            _deltaC1 > 0) {
          _modo = ModoHojaArqueo.entregaC1;
        }
        _cargaInicial = false;
        _contado = _esperado > 0 ? _fmt(_esperado) : '';
        _cargando = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  /// Cambiar de modo re-siembra el contado con el esperado
  /// del modo nuevo (mismo gesto que al abrir).
  void _cambiarModo(ModoHojaArqueo modo) {
    if (modo == _modo || _liquidando) return;
    setState(() {
      _modo = modo;
      _contado = _esperado > 0 ? _fmt(_esperado) : '';
    });
  }

  /// MODO C1: registrar el efectivo entregado en mano contra
  /// el LIBRO de entregas (registrarEntregaEfectivo). No crea
  /// la liquidación de cierre ni abre expediente: el resto
  /// simplemente sigue pendiente en el libro. Sin anticipada:
  /// un monto que supera el pendiente vigente no se acepta
  /// (la anticipada con sobregiro vive en la recogida del
  /// Panel, otra puerta con su propio candado).
  Future<void> _registrarEntregaC1() async {
    if (_liquidando) return;
    final entregado = _contadoNum;
    if (entregado == null || !entregado.isFinite || entregado <= 0) {
      mostrarSnack(context, 'Escribe un monto válido.',
          significado: SignificadoChip.error);
      return;
    }
    setState(() => _liquidando = true);
    try {
      // Re-verificación en fresco (patrón D2-04 de esta hoja):
      // si el pendiente del libro cambió desde que se abrió,
      // se avisa y se recarga en vez de registrar contra una
      // foto vieja.
      final fresco = await _pendDeltaC1();
      if (!mounted) return;
      if ((fresco - _deltaC1).abs() > 0.01) {
        setState(() {
          _deltaC1 = fresco;
          _contado = fresco > 0 ? _fmt(fresco) : '';
          _liquidando = false;
        });
        mostrarSnack(context,
            'El pendiente cambió mientras tanto; revisa la cifra nueva.',
            significado: SignificadoChip.alerta);
        return;
      }
      if (entregado - fresco > 0.01) {
        setState(() => _liquidando = false);
        mostrarSnack(context,
            'Lo entregado supera el pendiente del libro '
            '(${_fmt(fresco)} CUP).',
            significado: SignificadoChip.error);
        return;
      }
      final uuid = await _registrarEntrega(entregado);
      if (!mounted) return;
      Navigator.of(context).pop<ResultadoHojaArqueo>((
        modo: ModoHojaArqueo.entregaC1,
        liquidacion: null,
        entregaUuid: uuid,
        entregado: entregado,
        moneda: 'CUP',
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _liquidando = false);
      mostrarSnack(context, mensajeErrorAmable(e),
          significado: SignificadoChip.error);
    }
  }

  Future<void> _liquidar() async {
    if (_liquidando) return;
    final entregado = _contadoNum;
    if (entregado == null || !entregado.isFinite || entregado < 0) {
      mostrarSnack(context, 'Escribe un monto válido.',
          significado: SignificadoChip.error);
      return;
    }
    final esperado = _esperado;
    if (esperado <= 0) {
      mostrarSnack(context,
          'No hay pendiente confirmado en $_moneda.',
          significado: SignificadoChip.alerta);
      return;
    }
    if (entregado - esperado > 0.01) {
      mostrarSnack(context,
          'Lo entregado no puede superar lo esperado '
          '(${fmtMonto(esperado)} $_moneda).',
          significado: SignificadoChip.error);
      return;
    }
    setState(() => _liquidando = true);
    try {
      // Reverificación (patrón Arqueo, D2-04): si el
      // pendiente cambió con la hoja abierta, no se encola
      // sobre la foto vieja.
      final fresco = await _pendArqueo();
      final esperadoFresco = _moneda == 'USD' ? fresco.usd : fresco.cup;
      if (!mounted) return;
      if ((esperadoFresco - esperado).abs() > 0.01) {
        mostrarSnack(context,
            'El pendiente cambió: era ${fmtMonto(esperado)} '
            '$_moneda y ahora es ${fmtMonto(esperadoFresco)} '
            '$_moneda. Revisa la cifra y confirma de nuevo.',
            significado: SignificadoChip.alerta);
        await _cargar();
        return;
      }
      final opIds = await _idsPendiente();
      final resumen = resumenLiquidacionTexto(
        nombre: widget.nombre,
        fecha: ahoraHabana(),
        moneda: _moneda,
        esperado: esperado,
        entregado: entregado,
        opIds: opIds,
        nota: null,
      );
      final liqId = await _crearLiquidacion(
        montoEsperado: esperado,
        montoEntregado: entregado,
        opIds: opIds,
        nota: 'Liquidación de arqueo (Mostrador)',
      );
      if (!mounted) return;
      Navigator.of(context).pop<ResultadoHojaArqueo>((
        modo: ModoHojaArqueo.cierre,
        liquidacion: (
          liqId: liqId,
          moneda: _moneda,
          esperado: esperado,
          entregado: entregado,
          opIds: opIds,
          resumen: resumen,
        ),
        entregaUuid: null,
        entregado: entregado,
        moneda: _moneda,
      ));
    } catch (e) {
      if (mounted) {
        mostrarSnack(context,
            '$e'.contains('en cola de sincronización')
                ? '$e'.replaceFirst('Exception: ', '')
                : 'No se pudo liquidar: $e',
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _liquidando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contado = _contadoNum;
    final diferencia =
        contado == null ? null : _esperado - contado;
    final esC1 = _modo == ModoHojaArqueo.entregaC1;
    final monedaVista = esC1 ? 'CUP' : _moneda;
    final valido = !_cargando &&
        contado != null &&
        (esC1 ? contado > 0 : contado >= 0) &&
        _esperado > 0 &&
        contado - _esperado <= 0.01;
    return HojaAccion(
      titulo: 'Liquidar Arqueo · ${widget.nombre}',
      icono: Icons.account_balance_wallet_rounded,
      cuerpo: _cargando
          ? const Padding(
              padding: EdgeInsets.all(AppEspacio.lg),
              child: Center(child: CircularProgressIndicator()),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Selector de MODO de la puerta única: cada
                // modo ejecuta su operación, sin fundirlas.
                SegmentedButton<ModoHojaArqueo>(
                  segments: const [
                    ButtonSegment(
                      value: ModoHojaArqueo.cierre,
                      label: Text('Liquidación de cierre'),
                    ),
                    ButtonSegment(
                      value: ModoHojaArqueo.entregaC1,
                      label: Text('Entrega anticipada'),
                    ),
                  ],
                  selected: {_modo},
                  onSelectionChanged: (s) => _cambiarModo(s.first),
                ),
                const SizedBox(height: AppEspacio.md),
                if (!esC1 && _usd > 0)
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: AppEspacio.sm),
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'CUP', label: Text('CUP')),
                        ButtonSegment(value: 'USD', label: Text('USD')),
                      ],
                      selected: {_moneda},
                      onSelectionChanged: (s) {
                        setState(() {
                          _moneda = s.first;
                          _contado =
                              _esperado > 0 ? _fmt(_esperado) : '';
                        });
                      },
                    ),
                  ),
                if (esC1) ...[
                  Text(
                    'Pendiente en el libro de entregas: '
                    '${fmtMonto(_esperado)} CUP',
                    style: AppTexto.cuerpo
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    'Es el efectivo que el entrenador ya te '
                    'entregó en mano según el libro de entregas. '
                    'Registrarlo NO crea la liquidación de '
                    'cierre: lo que no entregues sigue pendiente '
                    'en el libro.',
                    style: AppTexto.metadato.copyWith(
                        color: AppColores.textoSecundario(context)),
                  ),
                ] else ...[
                  Text(
                    'Pendiente confirmado: ${fmtMonto(_esperado)} '
                    '$monedaVista',
                    style: AppTexto.cuerpo
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    'Calculado solo sobre datos confirmados por el '
                    'servidor, con adelantos y arrastres ya neteados '
                    '(la misma cifra del Arqueo).',
                    style: AppTexto.metadato.copyWith(
                        color: AppColores.textoSecundario(context)),
                  ),
                ],
                const SizedBox(height: AppEspacio.md),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _contado.isEmpty
                            ? '— $monedaVista'
                            : '$_contado $monedaVista',
                        style: AppTexto.conTabulares(AppTexto.displayPequeno),
                      ),
                    ),
                    TextButton(
                      onPressed: _esperado > 0
                          ? () =>
                              setState(() => _contado = _fmt(_esperado))
                          : null,
                      child: const Text('Todo'),
                    ),
                  ],
                ),
                if (diferencia != null && diferencia > 0.01)
                  Text(
                    esC1
                        ? 'Quedan ${fmtMonto(diferencia)} CUP '
                            'pendientes en el libro tras esta entrega.'
                        : 'Diferencia: ${fmtMonto(diferencia)} '
                            '$monedaVista — se abre el expediente de '
                            'diferencia del Arqueo.',
                    style: AppTexto.metadato.copyWith(
                        color: esC1
                            ? AppColores.textoSecundario(context)
                            : AppColores.alerta),
                  ),
                if (diferencia != null && diferencia < -0.01)
                  Text(
                    esC1
                        ? 'Lo entregado supera el pendiente del '
                            'libro: ajusta la cifra.'
                        : 'Lo contado supera lo esperado: ajusta '
                            'la cifra.',
                    style: AppTexto.metadato
                        .copyWith(color: AppColores.error),
                  ),
                const SizedBox(height: AppEspacio.sm),
                PadNumerico(
                  valor: _contado,
                  onCambia: (v) => setState(() => _contado = v),
                ),
              ],
            ),
      pie: _cargando
          ? null
          : DeslizarConfirmar(
              texto: esC1
                  ? 'Desliza para registrar la entrega →'
                  : 'Desliza para liquidar →',
              habilitado: valido && !_liquidando,
              onConfirmar: () =>
                  esC1 ? _registrarEntregaC1() : _liquidar(),
            ),
    );
  }
}
