import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../servicios.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

/// v1.8.0: Estadísticas de servicios (SOLO DUEÑO), diseño 🟢 Argón
/// (DISENO_DOSIS_ESTADISTICAS): dos tarjetas separadas —
/// 1A Rendimiento físico (sin dinero) y 1B Inversión y margen
/// (a costo; las mermas y la Casa se valorizan a costo, nunca a
/// precio de venta). Todo se calcula desde los espejos locales.
class ServiciosEstadisticasScreen extends StatefulWidget {
  const ServiciosEstadisticasScreen({super.key});

  @override
  State<ServiciosEstadisticasScreen> createState() =>
      _ServiciosEstadisticasScreenState();
}

class _ServiciosEstadisticasScreenState
    extends State<ServiciosEstadisticasScreen> {
  bool _cargando = true;
  String _periodo = 'mes'; // 'mes' | 'todo'
  Map<String, dynamic> _a = const {}; // 1A rendimiento
  Map<String, dynamic> _b = const {}; // 1B inversión

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  bool _enPeriodo(String? fecha) {
    if (_periodo == 'todo') return true;
    if (fecha == null || fecha.length < 7) return false;
    return fecha.substring(0, 7) == hoyHabanaIso().substring(0, 7);
  }

  Future<void> _cargar() async {
    final ventas =
        await LocalDb.instance.allMirror('servicio_ventas');
    final salidas =
        await LocalDb.instance.allMirror('servicio_salidas');
    final botes = await LocalDb.instance.allMirror('servicio_botes');
    final lotes = await LocalDb.instance.allMirror('servicio_lotes');
    final compras =
        await LocalDb.instance.allMirror('servicio_compras');
    final movsAgua = await LocalDb.instance
        .allMirror('servicio_agua_movimientos');
    final suplementos =
        await LocalDb.instance.allMirror('suplementos');
    final nombreSup = <int, String>{
      for (final s in suplementos)
        if ((s['id'] as num?) != null)
          (s['id'] as num).toInt(): '${s['nombre'] ?? ''}',
    };
    final boteDeLote = <int, int>{
      for (final l in lotes)
        if ((l['id'] as num?) != null)
          (l['id'] as num).toInt(): (l['bote_id'] as num?)?.toInt() ?? -1,
    };

    bool enP(Map<String, dynamic> r) => _enPeriodo(r['fecha'] as String?);
    final ventasP = ventas.where(enP).toList();
    final salidasP = salidas.where(enP).toList();

    // ---- 1A: rendimiento por bote ----
    final porBote = <int, Map<String, dynamic>>{};
    for (final b in botes) {
      final id = (b['id'] as num?)?.toInt();
      if (id == null) continue;
      porBote[id] = {
        'nombre': nombreSup[(b['suplemento_id'] as num?)?.toInt()] ??
            'Bote #$id',
        'rendimiento': (b['dosis_rendimiento'] as num?)?.toInt() ?? 0,
        'servidas': 0,
        'merma': 0,
        'cortesia': 0,
        'staff': 0,
        'ajuste': 0,
        'diferencia_rendimiento': b['diferencia_rendimiento_bote'],
        'estado': '${b['estado']}',
      };
    }
    for (final v in ventasP) {
      final boteId = boteDeLote[(v['lote_id'] as num?)?.toInt()];
      final fila = porBote[boteId];
      if (fila == null) continue;
      final tipo = '${v['tipo']}';
      if (tipo.startsWith('dosis')) {
        fila['servidas'] =
            (fila['servidas'] as int) + ((v['cantidad'] as num?)?.toInt() ?? 0);
      }
    }
    for (final s in salidasP) {
      final boteId = boteDeLote[(s['lote_id'] as num?)?.toInt()];
      final fila = porBote[boteId];
      if (fila == null) continue;
      final dosis = (s['dosis'] as num?)?.toInt() ?? 0;
      switch ('${s['motivo']}') {
        case 'merma':
          fila['merma'] = (fila['merma'] as int) + dosis;
        case 'cortesia':
          fila['cortesia'] = (fila['cortesia'] as int) + dosis;
        case 'consumo_staff':
          fila['staff'] = (fila['staff'] as int) + dosis;
        default:
          fila['ajuste'] = (fila['ajuste'] as int) + dosis;
      }
    }

    // ---- 1B: inversión y margen ----
    var inversionBotes = 0.0;
    for (final c in compras) {
      if ('${c['tipo']}' == 'bote') {
        inversionBotes += (c['costo'] as num?)?.toDouble() ?? 0;
      }
    }
    var inversionAgua = 0.0;
    for (final m in movsAgua) {
      if ('${m['tipo']}' == 'entrada') {
        inversionAgua += ((m['cantidad'] as num?)?.toDouble() ?? 0) *
            ((m['costo_unitario'] as num?)?.toDouble() ?? 0);
      }
    }
    var ingSin = 0.0, ingCon = 0.0, ingAgua = 0.0;
    var costoDosis = 0.0, costoAguaVendida = 0.0, comision = 0.0;
    var nDosis = 0, nConAgua = 0;
    for (final v in ventasP) {
      final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
      final precio = (v['precio_unitario'] as num?)?.toDouble() ?? 0;
      switch ('${v['tipo']}') {
        case 'dosis_sin_agua':
          ingSin += precio * cant;
          nDosis += cant;
        case 'dosis_con_agua':
          ingCon += precio * cant;
          nDosis += cant;
          nConAgua += cant;
        case 'agua_suelta':
          ingAgua += precio * cant;
      }
      costoDosis +=
          ((v['costo_dosis_snapshot'] as num?)?.toDouble() ?? 0) * cant;
      costoAguaVendida +=
          ((v['costo_agua_snapshot'] as num?)?.toDouble() ?? 0) * cant;
      comision +=
          ((v['comision_unitaria'] as num?)?.toDouble() ?? 0) * cant;
    }
    // Mermas a costo: costo unitario del bote (snapshot de la dosis
    // del lote; si el bote no tiene ventas, rendimiento como base).
    var mermasCosto = 0.0;
    final costoDosisPorBote = <int, double>{};
    for (final b in botes) {
      final id = (b['id'] as num?)?.toInt();
      if (id == null) continue;
      final rend = (b['dosis_rendimiento'] as num?)?.toInt() ?? 0;
      final costo = (b['costo_bote'] as num?)?.toDouble() ?? 0;
      costoDosisPorBote[id] = rend > 0 ? costo / rend : 0;
    }
    for (final s in salidasP) {
      final boteId = boteDeLote[(s['lote_id'] as num?)?.toInt()];
      mermasCosto += ((s['dosis'] as num?)?.toDouble() ?? 0) *
          (costoDosisPorBote[boteId] ?? 0);
    }
    // Casa a costo (nunca como pérdida comercial, Argón E3).
    var casaCosto = 0.0, casaN = 0;
    for (final v in ventasP) {
      if ((v['casa'] as num?)?.toInt() != 1) continue;
      final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
      casaN += cant;
      casaCosto +=
          ((v['costo_dosis_snapshot'] as num?)?.toDouble() ?? 0) * cant +
              ((v['costo_agua_snapshot'] as num?)?.toDouble() ?? 0) *
                  cant;
    }
    final ingresos = ingSin + ingCon + ingAgua;
    final costos = costoDosis + costoAguaVendida + mermasCosto;
    final margen = ingresos - costos;
    // Indicadores (Argón E5).
    final dias = _periodo == 'mes' ? ahoraHabana().day : 30;
    var saldoTotal = 0;
    for (final l in lotes) {
      if ('${l['estado']}' == 'activo') {
        saldoTotal +=
            await saldoLoteLocal((l['id'] as num).toInt());
      }
    }
    final dosisDia = dias > 0 ? nDosis / dias : 0.0;
    final autonomia =
        dosisDia > 0 ? (saldoTotal / dosisDia).floor() : null;

    if (!mounted) return;
    setState(() {
      _a = {'porBote': porBote};
      _b = {
        'inversion_botes': inversionBotes,
        'inversion_agua': inversionAgua,
        'ing_sin': ingSin,
        'ing_con': ingCon,
        'ing_agua': ingAgua,
        'ingresos': ingresos,
        'costo_dosis': costoDosis,
        'costo_agua': costoAguaVendida,
        'mermas_costo': mermasCosto,
        'margen': margen,
        'comision': comision,
        'neto_dueno': margen - comision,
        'casa_costo': casaCosto,
        'casa_n': casaN,
        'margen_medio': nDosis > 0
            ? (ingSin + ingCon - costoDosis) / nDosis
            : 0.0,
        'pct_con_agua':
            nDosis > 0 ? (nConAgua * 100 / nDosis) : 0.0,
        'autonomia_dias': autonomia,
        'saldo_total': saldoTotal,
      };
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Servicios · Estadísticas')),
        body: const Center(
            child: Text('Solo el dueño ve las estadísticas.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Servicios · Estadísticas'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'mes', label: Text('Este mes')),
                    ButtonSegment(
                        value: 'todo', label: Text('Todo')),
                  ],
                  selected: {_periodo},
                  onSelectionChanged: (s) {
                    setState(() {
                      _periodo = s.first;
                      _cargando = true;
                    });
                    _cargar();
                  },
                ),
                const SizedBox(height: AppEspacio.md),
                _tarjetaRendimiento(),
                const SizedBox(height: AppEspacio.md),
                _tarjetaInversion(),
              ],
            ),
    );
  }

  Widget _fila(String etiqueta, String valor, {bool negrita = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(etiqueta,
                style: AppTexto.cuerpo.copyWith(
                    fontWeight:
                        negrita ? FontWeight.w600 : FontWeight.normal)),
          ),
          Text(valor,
              style: AppTexto.cuerpo.copyWith(
                  fontWeight:
                      negrita ? FontWeight.bold : FontWeight.normal)),
        ],
      ),
    );
  }

  Widget _tarjetaRendimiento() {
    final porBote =
        (_a['porBote'] as Map<int, Map<String, dynamic>>?) ?? const {};
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('1A · Rendimiento (físico)',
              style: AppTexto.titulo.copyWith(fontSize: 16)),
          if (porBote.isEmpty)
            Text('Sin botes todavía.',
                style: AppTexto.cuerpo.copyWith(
                    color: AppColores.textoSecundario(context)))
          else
            for (final e in porBote.entries) ...[
              const Divider(height: 20),
              Text('${e.value['nombre']}',
                  style: AppTexto.cuerpo
                      .copyWith(fontWeight: FontWeight.w600)),
              _fila('Rendimiento del bote',
                  '${e.value['rendimiento']} dosis'),
              _fila('Dosis servidas', '${e.value['servidas']}'),
              _fila('Mermas', '${e.value['merma']}'),
              _fila('Cortesías', '${e.value['cortesia']}'),
              _fila('Consumo del staff', '${e.value['staff']}'),
              if (e.value['diferencia_rendimiento'] != null)
                _fila('Diferencia de rendimiento (cierre)',
                    '${e.value['diferencia_rendimiento']} dosis',
                    negrita: true),
            ],
        ],
      ),
    );
  }

  Widget _tarjetaInversion() {
    final b = _b;
    String cup(String k) => '${fmtMonto(b[k])} CUP';
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('1B · Inversión y margen',
              style: AppTexto.titulo.copyWith(fontSize: 16)),
          const Divider(height: 20),
          _fila('Inversión en botes', cup('inversion_botes')),
          _fila('Inversión en agua', cup('inversion_agua')),
          const Divider(height: 20),
          _fila('Ingresos dosis sin agua', cup('ing_sin')),
          _fila('Ingresos dosis con agua', cup('ing_con')),
          _fila('Ingresos pomos sueltos', cup('ing_agua')),
          _fila('Ingresos totales', cup('ingresos'), negrita: true),
          const Divider(height: 20),
          _fila('Costo de dosis vendidas', cup('costo_dosis')),
          _fila('Costo del agua vendida', cup('costo_agua')),
          _fila('Mermas (a costo)', cup('mermas_costo')),
          _fila('Margen', cup('margen'), negrita: true),
          _fila('Comisión a entrenadores', cup('comision')),
          _fila('Neto del dueño', cup('neto_dueno'), negrita: true),
          const Divider(height: 20),
          _fila('Casa: ${(b['casa_n'] as int?) ?? 0} consumos (a costo)',
              cup('casa_costo')),
          _fila('Margen medio por dosis', cup('margen_medio')),
          _fila('% de dosis con agua',
              '${((b['pct_con_agua'] as double?) ?? 0).toStringAsFixed(0)} %'),
          _fila(
              'Autonomía del stock',
              b['autonomia_dias'] == null
                  ? '—'
                  : '${b['autonomia_dias']} días (${b['saldo_total']} dosis)'),
        ],
      ),
    );
  }
}
