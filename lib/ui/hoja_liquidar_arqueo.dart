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
/// Nota de alcance: la entrega C1 «anticipada»
/// (registrarEntregaEfectivo, op liquidar_entrega_efectivo)
/// es una operación DISTINTA — registrar efectivo en mano
/// antes de que los pagos sincronicen — y no se funde aquí:
/// fundir las dos ops es decisión de dinero, no de oleada 1
/// (queda anotado en el informe del Escalón 3).
library;

import 'package:flutter/material.dart';

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
Future<ResultadoLiquidacion?> mostrarHojaLiquidarArqueo(
  BuildContext context, {
  required int telegramId,
  required String nombre,
}) {
  return showModalBottomSheet<ResultadoLiquidacion>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    builder: (_) =>
        HojaLiquidarArqueo(telegramId: telegramId, nombre: nombre),
  );
}

class HojaLiquidarArqueo extends StatefulWidget {
  final int telegramId;
  final String nombre;

  const HojaLiquidarArqueo(
      {super.key, required this.telegramId, required this.nombre});

  @override
  State<HojaLiquidarArqueo> createState() => _HojaLiquidarArqueoState();
}

class _HojaLiquidarArqueoState extends State<HojaLiquidarArqueo> {
  bool _cargando = true;
  bool _liquidando = false;
  double _cup = 0;
  double _usd = 0;
  String _moneda = 'CUP';
  String _contado = '';

  double get _esperado => _moneda == 'USD' ? _usd : _cup;
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
      final pend = await pendienteArqueo(widget.telegramId);
      if (!mounted) return;
      setState(() {
        _cup = pend.cup;
        _usd = pend.usd;
        if (_moneda == 'CUP' && _cup <= 0 && _usd > 0) _moneda = 'USD';
        if (_moneda == 'USD' && _usd <= 0) _moneda = 'CUP';
        _contado = _esperado > 0 ? _fmt(_esperado) : '';
        _cargando = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
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
      final fresco = await pendienteArqueo(widget.telegramId);
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
      final opIds =
          await idsPendienteArqueo(widget.telegramId, moneda: _moneda);
      final resumen = resumenLiquidacionTexto(
        nombre: widget.nombre,
        fecha: ahoraHabana(),
        moneda: _moneda,
        esperado: esperado,
        entregado: entregado,
        opIds: opIds,
        nota: null,
      );
      final liqId = await crearLiquidacion(
        entrenadorTelegramId: widget.telegramId,
        entrenadorNombre: widget.nombre,
        montoEsperado: esperado,
        montoEntregado: entregado,
        opIds: opIds,
        moneda: _moneda,
        nota: 'Liquidación de arqueo (Mostrador)',
      );
      if (!mounted) return;
      Navigator.of(context).pop((
        liqId: liqId,
        moneda: _moneda,
        esperado: esperado,
        entregado: entregado,
        opIds: opIds,
        resumen: resumen,
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
    final valido = !_cargando &&
        contado != null &&
        contado >= 0 &&
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
                if (_usd > 0)
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
                Text(
                  'Pendiente confirmado: ${fmtMonto(_esperado)} $_moneda',
                  style:
                      AppTexto.cuerpo.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  'Calculado solo sobre datos confirmados por el '
                  'servidor, con adelantos y arrastres ya neteados '
                  '(la misma cifra del Arqueo).',
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context)),
                ),
                const SizedBox(height: AppEspacio.md),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _contado.isEmpty ? '— $_moneda' : '$_contado $_moneda',
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
                    'Diferencia: ${fmtMonto(diferencia)} $_moneda — '
                    'se abre el expediente de diferencia del Arqueo.',
                    style: AppTexto.metadato
                        .copyWith(color: AppColores.alerta),
                  ),
                if (diferencia != null && diferencia < -0.01)
                  Text(
                    'Lo contado supera lo esperado: ajusta la cifra.',
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
              texto: 'Desliza para liquidar →',
              habilitado: valido && !_liquidando,
              onConfirmar: _liquidar,
            ),
    );
  }
}
