import 'package:flutter/material.dart';
import '../auth.dart';
import '../localdb.dart';
import 'diseno.dart';

/// Margen en USD de un suplemento del espejo (Argón #9 BLOQUEANTE).
/// El espejo `suplementos` es JSON (data), sin columnas: el precio vivo
/// es `precio_oficial` en la moneda del suplemento y el costo siempre
/// en USD. Si la moneda es CUP y hay tasa válida (> 1.0), el precio se
/// convierte a USD; si es CUP sin tasa válida, no hay margen en USD
/// que mostrar (null) en vez de un número falso mezclando CUP con USD.
/// Si el precio convertible es <= 0, tampoco hay margen. PURO.
({double precioUsd, double? margenUnitario, double? margenPotencial, double? pct}) margenSuplementoUsd({
  required Map<String, dynamic> s,
  double? tasaUsd,
}) {
  final precioOficial = (s['precio_oficial'] as num?)?.toDouble() ?? 0;
  final costo = (s['costo'] as num?)?.toDouble() ?? 0;
  final stock = (s['stock'] as num?)?.toInt() ?? 0;
  final moneda = LocalDb.monedaDe(s);
  double? precioUsd;
  if (moneda == 'USD') {
    precioUsd = precioOficial;
  } else if (tasaUsd != null && tasaUsd > 1.0) {
    precioUsd = precioOficial / tasaUsd;
  }
  if (precioUsd == null || precioUsd <= 0) {
    return (
      precioUsd: precioUsd ?? 0,
      margenUnitario: null,
      margenPotencial: null,
      pct: null,
    );
  }
  final margen = precioUsd - costo;
  return (
    precioUsd: precioUsd,
    margenUnitario: margen,
    margenPotencial: margen * stock,
    pct: margen / precioUsd * 100,
  );
}

/// v1.2.9+47: reporte de márgenes de suplementos (solo dueño).
/// Decisión Jc: margen SOLO en reportes, nunca en tarjetas.
/// Revisado por Gemini 2026-10-13.
class ReporteMargenesScreen extends StatefulWidget {
  const ReporteMargenesScreen({super.key});

  @override
  State<ReporteMargenesScreen> createState() =>
      _ReporteMargenesScreenState();
}

class _ReporteMargenesScreenState
    extends State<ReporteMargenesScreen> {
  List<Map<String, dynamic>> _datos = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // Argón #9 (BLOQUEANTE): la tabla espejo suplementos es JSON
    // (id, data, sync_seq, ultimo_precio, moneda): NO existen las
    // columnas nombre/costo/precio/stock/activo y el rawQuery viejo
    // reventaba con «no such column» al abrir la pantalla. Se lee
    // del espejo decodificado y el margen se calcula en Dart, con
    // conversión CUP→USD por tasa (nunca mezclando monedas).
    final espejo = await LocalDb.instance.allMirror('suplementos');
    final aj = await LocalDb.instance.getAjustes();
    final tasa = (aj['tasa_usd'] as num?)?.toDouble();
    final datos = <Map<String, dynamic>>[];
    for (final s in espejo) {
      final activo = s['activo'];
      if (!(activo == 1 || activo == true)) continue;
      final moneda = LocalDb.monedaDe(s);
      final m = margenSuplementoUsd(s: s, tasaUsd: tasa);
      datos.add({
        'nombre': '${s['nombre'] ?? ''}',
        'costo': (s['costo'] as num?)?.toDouble() ?? 0.0,
        'precio': (s['precio_oficial'] as num?)?.toDouble() ?? 0.0,
        'precio_usd': m.precioUsd,
        'moneda': moneda,
        'sin_tasa': m.margenUnitario == null &&
            moneda == 'CUP' &&
            (tasa == null || tasa <= 1.0),
        'stock': (s['stock'] as num?)?.toInt() ?? 0,
        'margen_unitario': m.margenUnitario,
        'margen_potencial': m.margenPotencial,
        'pct': m.pct,
      });
    }
    datos.sort((a, b) {
      final ma = a['margen_unitario'] as double?;
      final mb = b['margen_unitario'] as double?;
      if (ma == null && mb == null) return 0;
      if (ma == null) return 1;
      if (mb == null) return -1;
      return mb.compareTo(ma);
    });
    if (mounted) {
      setState(() {
        _datos = datos;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Argón stats MEDIO: el docstring dice solo dueño, pero no había
    // gate (un entrenador por ruta veía costos USD y márgenes).
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(
              title: const Text('Márgenes de Suplementos')),
          body: const Center(
              child: Text('Solo el dueño ve este reporte.')));
    }
    double totalMargenInventario = 0;
    for (final r in _datos) {
      totalMargenInventario +=
          (r['margen_potencial'] as num?)?.toDouble() ?? 0.0;
    }

    return Scaffold(
      appBar: AppBar(
          title: const Text('Márgenes de Suplementos')),
      body: _cargando
          ? const Center(
              child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColores.fondo(context),
                    borderRadius:
                        BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceAround,
                    children: [
                      _kpi('Productos',
                          '${_datos.length}'),
                      _kpi('Margen en stock',
                          '\$${totalMargenInventario.toStringAsFixed(2)} USD'),
                    ],
                  ),
                ),
                if (_datos.any((r) => r['sin_tasa'] == true))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Text(
                      '${_datos.where((r) => r['sin_tasa'] == true).length} producto(s) en CUP sin tasa USD: fuera del total.',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey[500]),
                    ),
                  ),
                Expanded(
                  child: ListView.separated(
                    itemCount: _datos.length,
                    separatorBuilder: (_, __) =>
                        const Divider(
                            height: 1,
                            indent: 16,
                            endIndent: 16),
                    itemBuilder: (ctx, i) {
                      final r = _datos[i];
                      final margenUnit =
                          (r['margen_unitario'] as num?)?.toDouble();
                      final pct =
                          (r['pct'] as num?)?.toDouble();
                      final stock =
                          (r['stock'] as num?)?.toInt() ?? 0;
                      final costo =
                          (r['costo'] as num?)?.toDouble() ?? 0.0;
                      final precio =
                          (r['precio'] as num?)?.toDouble() ?? 0.0;
                      final precioUsd =
                          (r['precio_usd'] as num?)?.toDouble();
                      final moneda = '${r['moneda'] ?? 'CUP'}';
                      final sinTasa = r['sin_tasa'] == true;

                      return ListTile(
                        title: Text('${r['nombre']}',
                            style: const TextStyle(
                                fontWeight:
                                    FontWeight.w600)),
                        subtitle: Text(
                          'Costo: \$${costo.toStringAsFixed(2)} USD · '
                          'Precio: \$${precio.toStringAsFixed(2)} $moneda'
                          '${moneda == 'CUP' && precioUsd != null ? ' (≈ \$${precioUsd.toStringAsFixed(2)} USD)' : ''}'
                          '${sinTasa ? ' · sin tasa USD' : ''} '
                          '($stock disp.)',
                          style: TextStyle(
                              fontSize: 12,
                              color:
                                  Colors.grey[400]),
                        ),
                        trailing: Column(
                          mainAxisAlignment:
                              MainAxisAlignment.center,
                          crossAxisAlignment:
                              CrossAxisAlignment.end,
                          children: [
                            Text(
                              margenUnit == null
                                  ? '—'
                                  : margenUnit < 0
                                      ? '-\$${(-margenUnit).toStringAsFixed(2)}'
                                      : '+\$${margenUnit.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontWeight:
                                    FontWeight.bold,
                                color: margenUnit == null
                                    ? Colors.grey
                                    : margenUnit > 0
                                        ? Colors.greenAccent
                                        : Colors.redAccent,
                              ),
                            ),
                            Text(
                                pct == null
                                    ? '—'
                                    : '${pct.toStringAsFixed(1)}%',
                                style: const TextStyle(
                                    fontSize: 12)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  Widget _kpi(String label, String valor) {
    return Column(
      children: [
        Text(valor,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: TextStyle(
                fontSize: 12,
                color: Colors.grey[500])),
      ],
    );
  }
}
