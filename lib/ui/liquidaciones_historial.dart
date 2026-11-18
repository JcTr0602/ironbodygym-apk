/// (M2-BC B5) «Últimas liquidaciones»: vista ÚNICA del
/// historial de liquidaciones de caja de todos los
/// entrenadores (antes vivía solo dentro del detalle de
/// cada uno), con búsqueda por entrenador y filtro por mes.
/// Responder «¿cuándo liquidó Gabriel lo de la semana
/// pasada?» deja de exigir entrar entrenador por entrenador.
/// Solo lectura: tocar una fila abre el arqueo de ese
/// entrenador, donde vive el detalle y la acción.
library;

import 'package:flutter/material.dart';

import '../app_log.dart';
import '../auth.dart';
import '../errores_sync.dart';
import '../negocio.dart';
import '../nomina_calc.dart';
import 'app_bar.dart';
import 'arqueo.dart';
import 'componentes.dart';
import 'diseno.dart';

class LiquidacionesHistorialScreen extends StatefulWidget {
  const LiquidacionesHistorialScreen({super.key});

  @override
  State<LiquidacionesHistorialScreen> createState() =>
      _LiquidacionesHistorialScreenState();
}

class _LiquidacionesHistorialScreenState
    extends State<LiquidacionesHistorialScreen> {
  bool _cargando = true;
  // Yunque de App 1.31 (C1-3): el fallo de carga se PINTA
  // como error, no como «sin liquidaciones».
  String? _falloCarga;
  List<Map<String, dynamic>> _todas = [];
  final _busquedaCtrl = TextEditingController();
  String _mes = ''; // '' = todos los meses

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final filas = await todasLasLiquidaciones();
      if (mounted) {
        setState(() {
          _todas = filas;
          _falloCarga = null;
          _cargando = false;
        });
      }
    } catch (e) {
      // Yunque de App 1.31 (C1-3): bitácora + error visible.
      AppLog.error('liquidaciones', 'carga_fallo', d: '$e');
      if (mounted) {
        setState(() {
          // 1.36 H-B3 (136-812): el detalle del EstadoError
          // va amable; el crudo ya quedó en la bitácora.
          _falloCarga = mensajeErrorAmable(e);
          _cargando = false;
        });
      }
    }
  }

  /// Meses presentes en el historial (yyyy-MM, descendente).
  List<String> get _meses {
    final s = <String>{
      for (final h in _todas)
        if ('${h['creada_en'] ?? ''}'.length >= 7)
          '${h['creada_en']}'.substring(0, 7),
    }.toList()
      ..sort((a, b) => b.compareTo(a));
    return s;
  }

  List<Map<String, dynamic>> get _visibles {
    final q = _busquedaCtrl.text.trim().toLowerCase();
    return [
      for (final h in _todas)
        if ((_mes.isEmpty ||
                '${h['creada_en'] ?? ''}'.startsWith(_mes)) &&
            (q.isEmpty ||
                '${h['entrenador_nombre'] ?? ''}'
                    .toLowerCase()
                    .contains(q)))
          h,
    ];
  }

  String _etiquetaMes(String mes) {
    // yyyy-MM → «MM/yyyy» sin depender de intl.
    if (mes.length < 7) return mes;
    return '${mes.substring(5, 7)}/${mes.substring(0, 4)}';
  }

  /// 1.34 (C-48 · G-04): nombre del mes para el botón y la
  /// hoja («Octubre 2026»): la forma que el diseño C-48 usa
  /// en su ejemplo («Mes · Octubre 2026»).
  String _nombreMes(String mes) {
    const nombres = [
      'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
      'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre',
      'Diciembre',
    ];
    if (mes.length < 7) return mes;
    final m = int.tryParse(mes.substring(5, 7)) ?? 0;
    if (m < 1 || m > 12) return _etiquetaMes(mes);
    return '${nombres[m - 1]} ${mes.substring(0, 4)}';
  }

  /// G07-7 (desbloqueo lote 141): el selector de meses es
  /// el SelectorIron de la casa (patrón DIS-05), en la fila
  /// del buscador — fuera el botón propio con su hoja de
  /// radios a mano (C-48). El panel del SelectorIron ya
  /// trae radio, elegida en marca y cierre al tocar; los
  /// meses van en el mismo orden descendente de siempre y
  /// la opción '' se lee «Todos».
  Widget _selectorMes() {
    return SelectorIron<String>(
      valor: _mes,
      etiqueta: 'Mes',
      tituloPanel: 'Mes',
      opciones: [
        const OpcionSelector('', 'Todos'),
        for (final m in _meses) OpcionSelector(m, _nombreMes(m)),
      ],
      alCambiar: (v) => setState(() => _mes = v ?? ''),
    );
  }

  Widget _fila(Map<String, dynamic> h) {
    // 1.36 H-C2 (136-811): importes con el lector
    // tolerante de la casa (texto también vale): un
    // importe serializado como texto pintaba 0.
    final entregado =
        NominaCalc.montoTolerante(h['monto_entregado']) ?? 0;
    final esperado =
        NominaCalc.montoTolerante(h['monto_esperado']) ?? 0;
    final arrastre =
        NominaCalc.montoTolerante(h['saldo_arrastre']) ?? 0;
    final moneda = '${h['moneda'] ?? 'CUP'}';
    final parcial = h['estado'] == 'parcial';
    final tid =
        int.tryParse('${h['entrenador_telegram_id'] ?? ''}');
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        onTap: tid == null
            ? null
            : () async {
                await Navigator.of(context).push(
                  RutaIron(
                    builder: (_) => DetalleArqueoScreen(
                      telegramId: tid,
                      nombre: '${h['entrenador_nombre'] ?? ''}',
                    ),
                  ),
                );
                _cargar();
              },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${h['entrenador_nombre'] ?? 'Entrenador'}',
                    style: AppTexto.subtitulo,
                  ),
                ),
                Text(
                  '${fmtMonto(entregado)} $moneda',
                  // UI136-06: cifras tabulares (tnum).
                  style: AppTexto.conTabulares(
                      const TextStyle(fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: AppEspacio.sm),
                // SL-5 G07-8: chip de estado de la casa
                // (ChipEstado), no un Container a mano.
                ChipEstado.semantico(
                  texto: parcial ? 'Parcial' : 'Liquidado',
                  significado: parcial
                      ? SignificadoChip.alerta
                      : SignificadoChip.exito,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Esperado: ${fmtMonto(esperado)} $moneda'
              '${arrastre > 0 ? ' · Arrastre: ${fmtMonto(arrastre)} $moneda' : ''}',
              // UI136-06: cifras tabulares (tnum).
              style: AppTexto.conTabulares(AppTexto.metadato
                  .copyWith(
                      color: AppColores.textoSecundario(context))),
            ),
            Text(
              '${fmtFecha('${h['creada_en'] ?? ''}')}'
              '${(h['nota'] as String?)?.isNotEmpty == true ? ' · ${h['nota']}' : ''}',
              style: AppTexto.metadato.copyWith(
                  color: AppColores.textoSecundario(context)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Últimas liquidaciones'),
        body: const Center(
            child: Text(
                'Solo el dueño puede ver el historial de liquidaciones.')),
      );
    }
    final visibles = _visibles;
    return Scaffold(
      appBar: appBarIron(context, 'Últimas liquidaciones'),
      body: Column(
        children: [
          // UI136-02: sin SyncBanner propio — el estado de sync
          // se dice una sola vez, en el marco (Regla 6).
          Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.md, AppEspacio.lg, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: TextField(
              controller: _busquedaCtrl,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Buscar por entrenador',
                prefixIcon: Icon(Icons.search_rounded),
                border: OutlineInputBorder(),
              ),
                  ),
                ),
                if (_meses.length > 1) ...[
                  const SizedBox(width: AppEspacio.sm),
                  Flexible(child: _selectorMes()),
                ],
              ],
            ),
          ),
          Expanded(
            child: _cargando
                ? const EstadoCargando(
                    texto: 'Cargando liquidaciones…')
                : _falloCarga != null
                    ? EstadoError(
                        detalle: _falloCarga,
                        onReintentar: _cargar,
                      )
                    : RefrescoIron(
                    onRefresh: _cargar,
                    child: visibles.isEmpty
                        ? ListView(
                            // 1.36 H-B3 (136-812): el vacío
                            // con la primitiva de la casa.
                            children: const [
                              EstadoVacio(
                                icono: Icons.receipt_long_rounded,
                                titulo:
                                    'Sin liquidaciones que mostrar.',
                              ),
                            ],
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(AppEspacio.lg),
                            itemCount: visibles.length,
                            itemBuilder: (_, i) => _fila(visibles[i]),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Yunque 2.34 (F-7): nombre del mes para el BOTÓN de
/// Liquidaciones — si el nombre supera 8 letras se abrevia
/// a 3 («septiembre» → «sep 2026»): con el nombre entero, el
/// año se elidía del botón a 360 dp × 1.3 («Mes ·
/// Septiembre 20…»). La hoja de meses conserva los nombres
/// completos. PURO.
String nombreMesBoton(String mes) {
  const nombres = [
    'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
    'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre',
    'Diciembre',
  ];
  const cortos = [
    'ene', 'feb', 'mar', 'abr', 'may', 'jun',
    'jul', 'ago', 'sep', 'oct', 'nov', 'dic',
  ];
  if (mes.length < 7) return mes;
  final m = int.tryParse(mes.substring(5, 7)) ?? 0;
  // Fuera de rango: la misma salida de _etiquetaMes.
  if (m < 1 || m > 12) {
    return '${mes.substring(5, 7)}/${mes.substring(0, 4)}';
  }
  final nombre = nombres[m - 1];
  final anio = mes.substring(0, 4);
  return nombre.length > 8 ? '${cortos[m - 1]} $anio' : '$nombre $anio';
}
