/// (M2-BC B6) «Liquidar con arrastre» sin salir de Pendiente:
/// la misma liquidación del Arqueo (esperado canónico de
/// [pendienteArqueo], ids frescos de [idsPendienteArqueo] y
/// [crearLiquidacion] con todas sus guardas, incluida la de
/// M2-A A1) en una hoja sobre la tarjeta del entrenador. El
/// Arqueo sigue existiendo para el detalle, el historial y
/// los expedientes; esto solo le mueve la puerta al gesto.
///
/// (M2-BC B2) La hoja devuelve también el aviso compartido
/// [mostrarAvisoLiquidacionConDeshacer]: tras liquidar, la
/// barra de éxito lleva «Deshacer» mientras la op siga en el
/// teléfono (la ventana visual de la casa, 8 s; la de negocio
/// es «mientras la op no haya sincronizado»).
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'hoja_accion.dart';

/// Lo que la hoja devuelve al liquidar con éxito: lo que
/// Pendiente necesita para su actualización optimista, su
/// aviso con Deshacer y el resumen de WhatsApp (B1).
typedef ResultadoLiquidacion = ({
  String liqId,
  String moneda,
  double esperado,
  double entregado,
  Map<String, List<int>> opIds,
  String resumen,
});

/// (M2-BC B2) Aviso de liquidación registrada con acción
/// «Deshacer»: pasa por el mecanismo central de avisos (P2,
/// protegida) con la duración visual de la casa. Deshacer
/// borra la op SOLO si sigue en cola ([deshacerLiquidacion]);
/// si ya sincronizó, el aviso lo dice y no se toca nada.
void mostrarAvisoLiquidacionConDeshacer(
  ScaffoldMessengerState messenger, {
  required String mensaje,
  required String liqId,
  required Future<void> Function() alDeshacer,
}) {
  mostrarSnackControladoEnMessenger(
    messenger,
    mensaje,
    significado: SignificadoChip.exito,
    duracion: kDuracionVisualDeshacer,
    accion: 'Deshacer',
    alAccion: () async {
      final ok = await deshacerLiquidacion(liqId);
      if (ok) {
        mostrarSnackEnMessenger(messenger, 'Liquidación deshecha');
        await alDeshacer();
      } else {
        mostrarSnackEnMessenger(
          messenger,
          'Ya no se puede deshacer: la liquidación ya sincronizó.',
          significado: SignificadoChip.error,
        );
      }
    },
  );
}

class HojaLiquidar extends StatefulWidget {
  final int telegramId;
  final String nombre;

  const HojaLiquidar(
      {super.key, required this.telegramId, required this.nombre});

  @override
  State<HojaLiquidar> createState() => _HojaLiquidarState();
}

class _HojaLiquidarState extends State<HojaLiquidar> {
  bool _cargando = true;
  bool _liquidando = false;
  double _cup = 0;
  double _usd = 0;
  String _moneda = 'CUP';
  final _entregadoCtrl = TextEditingController();
  final _notaCtrl = TextEditingController();

  double get _esperado => _moneda == 'USD' ? _usd : _cup;

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

  Future<void> _cargar() async {
    try {
      final pend = await pendienteArqueo(widget.telegramId);
      if (!mounted) return;
      setState(() {
        _cup = pend.cup;
        _usd = pend.usd;
        if (_moneda == 'CUP' && _cup <= 0 && _usd > 0) {
          _moneda = 'USD';
        }
        if (_moneda == 'USD' && _usd <= 0) _moneda = 'CUP';
        _entregadoCtrl.text = _esperado > 0
            ? _esperado.toStringAsFixed(
                _esperado == _esperado.roundToDouble() ? 0 : 2)
            : '';
        _cargando = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _liquidar() async {
    if (_liquidando) return;
    final entregado =
        double.tryParse(_entregadoCtrl.text.replaceAll(',', '.'));
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
      // Reverificación (patrón Arqueo, D2-04): la foto de la
      // hoja puede estar vieja si entró un sync con la hoja
      // abierta; si el pendiente cambió, no se encola sobre
      // la foto vieja.
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
      final nota = _notaCtrl.text.trim();
      // (M2-BC B1) el resumen se compone con la MISMA foto
      // que viaja en la op, antes de encolarla.
      final resumen = resumenLiquidacionTexto(
        nombre: widget.nombre,
        fecha: ahoraHabana(),
        moneda: _moneda,
        esperado: esperado,
        entregado: entregado,
        opIds: opIds,
        nota: nota.isEmpty ? null : nota,
      );
      final liqId = await crearLiquidacion(
        entrenadorTelegramId: widget.telegramId,
        entrenadorNombre: widget.nombre,
        montoEsperado: esperado,
        montoEntregado: entregado,
        opIds: opIds,
        moneda: _moneda,
        nota: nota.isEmpty
            ? 'Liquidación con arrastre (Pendiente a recoger)'
            : nota,
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
    final parcial = !_cargando &&
        (double.tryParse(_entregadoCtrl.text.replaceAll(',', '.')) ??
                _esperado) <
            _esperado - 0.01;
    // 1.30 (D3, UI130-15): la hoja compone HojaAccion (asa,
    // cabecera y pie fijo de la casa); la superficie y el
    // radio los da el bottomSheetTheme. El monto pasa por
    // CampoMoneda y la nota por CampoTexto; el parseo y las
    // validaciones de _liquidar no cambian.
    return HojaAccion(
      titulo: 'Liquidar con arrastre · ${widget.nombre}',
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
                      },
                    ),
                  ),
                Text(
                  'Pendiente confirmado: ${fmtMonto(_esperado)} $_moneda',
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
                const SizedBox(height: AppEspacio.sm),
                CampoMoneda(
                  controller: _entregadoCtrl,
                  etiqueta: 'Monto entregado ($_moneda)',
                  moneda: _moneda,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: AppEspacio.sm),
                CampoTexto(
                  controller: _notaCtrl,
                  etiqueta: 'Nota (opcional)',
                ),
                if (parcial) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    'Liquidación parcial: el resto queda como '
                    'saldo de arrastre.',
                    style: AppTexto.metadato
                        .copyWith(color: AppColores.alerta),
                  ),
                ],
              ],
            ),
      pie: _cargando
          ? null
          : BotonPrimario(
              texto: 'Liquidar',
              icono: Icons.point_of_sale_rounded,
              cargando: _liquidando,
              onPressed: _liquidando ? null : _liquidar,
            ),
    );
  }
}
