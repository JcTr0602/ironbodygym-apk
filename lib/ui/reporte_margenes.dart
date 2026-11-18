import 'package:flutter/material.dart';
import '../auth.dart';
import '../localdb.dart';
import '../tipos_pago.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import '../app_log.dart';

/// Margen en USD de un suplemento del espejo (Argón #9 BLOQUEANTE).
/// El espejo `suplementos` es JSON (data), sin columnas: el precio vivo
/// es `precio_oficial` en la moneda del suplemento y el costo siempre
/// en USD. Si la moneda es CUP y hay tasa válida (> 1.0), el precio se
/// convierte a USD; si es CUP sin tasa válida, no hay margen en USD
/// que mostrar (null) en vez de un número falso mezclando CUP con USD.
/// Si el precio convertible es <= 0, tampoco hay margen. PURO.
///
/// G05-2 (definición de Jc, 2026-11-17): el % de margen se calcula
/// SOBRE EL PRECIO DE VENTA — (precio − costo) / precio × 100; p. ej.
/// costo 1000 y precio 1500 → 33,3 %, no 50 %. Y SIN costo válido
/// (null o <= 0) no hay margen que enseñar ni sumar: antes un costo
/// de 0 se leía como «todo es margen» (100 %) y se sumaba al total.
/// Esta es la ÚNICA función de margen de suplementos: la usan el
/// reporte y el detalle del suplemento.
({double precioUsd, double? margenUnitario, double? margenPotencial, double? pct}) margenSuplementoUsd({
  required Map<String, dynamic> s,
  double? tasaUsd,
}) {
  final precioOficial = (s['precio_oficial'] as num?)?.toDouble() ?? 0;
  final costo = (s['costo'] as num?)?.toDouble();
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
  // G05-2: sin costo válido no se inventa margen (ni se suma).
  if (costo == null || costo <= 0 || !costo.isFinite) {
    return (
      precioUsd: precioUsd,
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
  // 1.36 H-B3 (136-763): el fallo de carga se pinta con
  // reintento, no como «Sin productos».
  String? _errorCarga;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
      if (mounted) setState(() => _errorCarga = null);
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
      if (mounted) setState(() => _errorCarga = '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    // Argón #9 (BLOQUEANTE): la tabla espejo suplementos es JSON
    // (id, data, sync_seq, ultimo_precio, moneda): NO existen las
    // columnas nombre/costo/precio/stock/activo y el rawQuery viejo
    // reventaba con «no such column» al abrir la pantalla. Se lee
    // del espejo decodificado y el margen se calcula en Dart, con
    // conversión CUP→USD por tasa (nunca mezclando monedas).
    final espejo = await LocalDb.instance.allMirror('suplementos');
    final aj = await LocalDb.instance.getAjustes();
    // Yunque 3 (K6-3, clase completa): lector tolerante — con
    // la tasa en texto el cast duro la dejaba en null y el
    // reporte perdía la conversión a USD en silencio.
    final tasa = montoAjusteTolerante(aj['tasa_usd']);
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
          appBar: appBarIron(context, 'Márgenes de Suplementos'),
          body: const Center(
              child: Text('Solo el dueño ve este reporte.')));
    }
    double totalMargenInventario = 0;
    for (final r in _datos) {
      totalMargenInventario +=
          (r['margen_potencial'] as num?)?.toDouble() ?? 0.0;
    }

    return Scaffold(
      appBar: appBarIron(
        context,
        'Márgenes de Suplementos',
        acciones: [
          // 1.36 H-B3 (136-763): recalcular sin salir — si la
          // tasa USD cambió en Admin, el reporte se relee aquí.
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Recalcular',
            onPressed: _cargando
                ? null
                : () {
                    setState(() => _cargando = true);
                    _cargar();
                  },
          ),
        ],
      ),
      body: _cargando
          // 1.36 H-B3 (136-763): EstadoCargando de la casa,
          // no el spinner crudo.
          ? const EstadoCargando(texto: 'Calculando márgenes…')
          : _errorCarga != null && _datos.isEmpty
              ? EstadoError(
                  titulo: 'No se pudo cargar el reporte',
                  detalle: _errorCarga,
                  onReintentar: () {
                    setState(() {
                      _errorCarga = null;
                      _cargando = true;
                    });
                    _cargar();
                  },
                )
          // F4-16: sin productos activos la pantalla quedaba
          // en blanco como si estuviera rota.
          : _datos.isEmpty
              ? const EstadoVacio(
                  icono: Icons.trending_up_rounded,
                  titulo: 'Sin productos para calcular',
                  subtitulo:
                      'No hay suplementos activos con costo en '
                      'este teléfono todavía.',
                )
          : Column(
              children: [
                Container(
                  margin: const EdgeInsets.all(AppEspacio.lg),
                  padding: const EdgeInsets.all(AppEspacio.lg),
                  decoration: BoxDecoration(
                    // 1.36 H-B3 (136-763): la tarjeta KPI va
                    // sobre una superficie DISTINGUIBLE del
                    // fondo, con borde (antes fondo sobre
                    // fondo: casi invisible).
                    color: AppColores.superficie(context),
                    border:
                        Border.all(color: AppColores.borde(context)),
                    borderRadius:
                        BorderRadius.circular(AppRadio.md),
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
                      style: AppTexto.metadato.copyWith(
                          color: AppColores.textoSecundario(context)),
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
                      // 1.25 T120 (F4-16): el margen potencial
                      // (unitario × stock) se calculaba y solo
                      // alimentaba el KPI total: ahora cada fila
                      // enseña cuánto margen hay dormido en ESE
                      // producto, que es el dato para reponer.
                      final margenPot =
                          (r['margen_potencial'] as num?)
                              ?.toDouble();
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
                          '($stock disp.)'
                          '${margenPot != null ? '\nMargen en stock: \$${margenPot.toStringAsFixed(2)} USD' : ''}',
                          style: AppTexto.metadato.copyWith(
                              color: AppColores.textoSecundario(ctx)),
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
                                // 1.36 H-B3 (136-763): tokens
                                // de éxito/error de la casa, no
                                // los acentos crudos de Material.
                                color: margenUnit == null
                                    ? AppColores.textoSecundario(ctx)
                                    : margenUnit > 0
                                        ? AppColores.exito
                                        : AppColores.errorTexto(ctx),
                              ),
                            ),
                            Text(
                                pct == null
                                    ? '—'
                                    : '${pct.toStringAsFixed(1)}%',
                                style: AppTexto.metadato),
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
            style: AppTexto.titulo),
        const SizedBox(height: 2),
        Text(label,
            style: AppTexto.metadato.copyWith(
                color: AppColores.textoSecundario(context))),
      ],
    );
  }
}
