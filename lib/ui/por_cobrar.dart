/// 1.25 T74: «Por cobrar» — UNA pantalla para todo el
/// dinero que está en la calle: pestañas Vencidos /
/// Fiados y un héroe con el TOTAL combinado arriba.
/// Cada pestaña es la pantalla de siempre incrustada
/// (sus grupos por antigüedad y sus acciones no
/// cambian); el héroe suma lo que cada una reporta.
library;

import 'package:flutter/material.dart';

import '../negocio.dart' show fmtMonto, fmtMontoConMoneda;
import 'app_bar.dart';
import 'componentes.dart';
import 'cuentas_cobrar.dart';
import 'cuentas_por_cobrar.dart';
import 'diseno.dart';
import 'widgets.dart';

class PorCobrarScreen extends StatefulWidget {
  /// Pestaña inicial: 0 = Vencidos, 1 = Fiados.
  final int pestanaInicial;

  const PorCobrarScreen({super.key, this.pestanaInicial = 0});

  @override
  State<PorCobrarScreen> createState() => _PorCobrarScreenState();
}

class _PorCobrarScreenState extends State<PorCobrarScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  double? _totalVencidos;
  double? _fiadosCup;
  double? _fiadosUsd;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
        length: 2, vsync: this, initialIndex: widget.pestanaInicial);
  }

  @override
  void didUpdateWidget(PorCobrarScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 1.36 H-C2 (136-678): un cambio posterior de la
    // pestaña inicial sí mueve la pestaña.
    if (widget.pestanaInicial != oldWidget.pestanaInicial &&
        widget.pestanaInicial >= 0 &&
        widget.pestanaInicial < _tabs.length &&
        _tabs.index != widget.pestanaInicial) {
      _tabs.animateTo(widget.pestanaInicial);
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final combinadoCup =
        (_totalVencidos ?? 0) + (_fiadosCup ?? 0);
    final cargando = _totalVencidos == null || _fiadosCup == null;
    return Scaffold(
      appBar: appBarIron(
        context,
        'Por cobrar',
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: 'Vencidos'),
              Tab(text: 'Fiados'),
            ],
          ),
        ),
      ),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          // El héroe combinado: todo el dinero en la
          // calle, de un vistazo.
          Padding(
            padding: const EdgeInsets.all(AppEspacio.md),
            child: Tarjeta(
              color: AppColores.carbon,
              child: Column(
                children: [
                  Text(
                    'Dinero en la calle',
                    // 1.36 H-C2 (136-678): texto sobre carbón
                    // con el token de la casa, no white70 fijo.
                    style: AppTexto.secundario.copyWith(
                        color: AppColores.textoSobreOscuroSuave),
                  ),
                  // SL-5B G04-12: la cifra se asienta con
                  // MontoAnimado (la pieza de la casa), no
                  // salta de «…» a la cifra en un Text crudo.
                  MontoAnimado(
                    valor: cargando ? 0 : combinadoCup,
                    // 1.36 (136-309/318): cifra y moneda con
                    // espacio duro (fmtMontoConMoneda).
                    // 1.36 H-C2 (136-678): SOLO el CUP se
                    // anima; el USD va en su línea secundaria
                    // fija (antes viajaba dentro del formato
                    // animado y parpadeaba con cada paso).
                    formato: (v) =>
                        cargando ? '…' : fmtMontoConMoneda(v, 'CUP'),
                    style: AppTexto.display
                        .copyWith(color: AppColores.naranja),
                  ),
                  Text(
                    'Vencidos ${_totalVencidos == null ? '…' : '${fmtMonto(_totalVencidos!)} CUP'}'
                    ' · Fiados ${_fiadosCup == null ? '…' : '${fmtMonto(_fiadosCup!)} CUP'}',
                    style: AppTexto.minuscula.copyWith(
                        color: AppColores.textoSobreOscuroSuave),
                  ),
                  if ((_fiadosUsd ?? 0) > 0)
                    Text(
                      'Fiados en USD: ${fmtMonto(_fiadosUsd!)} USD',
                      style: AppTexto.minuscula.copyWith(
                          color: AppColores.textoSobreOscuroSuave),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                CuentasCobrarScreen(
                  incrustada: true,
                  onTotalCup: (t) {
                    if (mounted) {
                      setState(() => _totalVencidos = t);
                    }
                  },
                ),
                CuentasPorCobrarScreen(
                  incrustada: true,
                  onTotales: (t) {
                    if (mounted) {
                      setState(() {
                        _fiadosCup = t.cup;
                        _fiadosUsd = t.usd;
                      });
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
