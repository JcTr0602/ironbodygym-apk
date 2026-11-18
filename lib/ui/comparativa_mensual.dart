// lib/ui/comparativa_mensual.dart
// v1.3.9 Sprint 3 (#7): comparativa mes actual vs anterior.
// MTD: compara día 1-N actual vs día 1-N anterior.
import 'package:flutter/material.dart';
import '../auth.dart';
import '../negocio.dart';
import '../localdb.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'diseno.dart';
import 'componentes.dart';

class ComparativaMensual extends StatefulWidget {
  const ComparativaMensual({super.key});

  @override
  State<ComparativaMensual> createState() =>
      _ComparativaMensualState();
}

class _Metrica {
  final String titulo;
  final double actual;
  final double anteriorMTD; // mismo corte de días
  final double anteriorTotal; // mes completo
  final IconData icono;
  // 1.25 T118 (F2-15): si la métrica es dinero se dice en el
  // dato, no comparando el título — que además mentía:
  // «Clientes activos» contaba clientes CON PAGO en el rango.
  final bool esMoneda;

  _Metrica({
    required this.titulo,
    required this.actual,
    required this.anteriorMTD,
    required this.anteriorTotal,
    required this.icono,
    this.esMoneda = true,
  });

  /// (1.36 H-A2 136-735) sin base no hay porcentaje: con el
  /// período anterior en 0 el delta es null y la tarjeta pinta
  /// «Sin base» — antes un mes que arrancaba de cero enseñaba
  /// «+100 %» inventado.
  double? get deltaPct {
    if (anteriorMTD == 0) return null;
    return ((actual - anteriorMTD) / anteriorMTD) * 100;
  }
}

class _ComparativaMensualState
    extends State<ComparativaMensual> {
  bool _cargando = true;
  List<_Metrica> _metricas = [];
  String _mesActual = '';
  String _mesAnterior = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<double> _sumarPagos(
      String desde, String hasta) async {
    // Yunque R4-M4-1: las mismas exclusiones que la vía
    // canónica (pagosDelPeriodo): la Cuenta a la Casa nunca
    // es ingreso y un pago cuya anulación sigue en cola ya
    // no es dinero — sin ellas, esta comparativa enseñaba
    // una cifra de «Mensualidades» que ninguna otra
    // superficie de la app muestra.
    final casas = await LocalDb.instance.idsCuentasCasa();
    final anuladosCola =
        await LocalDb.instance.pagosAnuladosEnCola();
    double total = 0;
    for (final p in await LocalDb.instance
        .mirrorPorFecha('pagos', 'fecha', desde, hasta)) {
      // P2#4: las cortesías no son ingreso.
      if ((p['metodo'] as String?) == 'cortesia') continue;
      if (p['casa'] == 1 || p['casa'] == true) continue;
      final cid = p['cliente_id'];
      final cidInt = cid is num
          ? cid.toInt()
          : (cid is String ? int.tryParse(cid) : null);
      if (cidInt != null && casas.contains(cidInt)) continue;
      if (esPagoAnulado(p, anuladosCola)) continue;
      total +=
          (p['monto'] as num?)?.toDouble() ?? 0;
    }
    return total;
  }

  Future<double> _sumarSuplementos(
      String desde, String hasta) async {
    // P2#4: ventasSuplementosCup() ya filtra CUP; se filtra por
    // rango en Dart y se usa precio*cant si falta el total. El
    // filtro de fiados lo añade otro agente en esa función, así
    // que se usa tal cual (sin duplicarlo aquí). Son métricas
    // separadas: no se inventa un total general.
    double total = 0;
    for (final v in await ventasSuplementosCup()) {
      // Yunque R4-M4-3: día de negocio Habana, no el
      // substring crudo del timestamp.
      final dia = fechaNegocioHabana(v['fecha']);
      if (dia.isEmpty) continue;
      if (dia.compareTo(desde) < 0 || dia.compareTo(hasta) > 0) {
        continue;
      }
      total += (v['total'] as num?)?.toDouble() ??
          ((v['precio'] as num?)?.toDouble() ?? 0) *
              ((v['cantidad'] as num?)?.toInt() ?? 0);
    }
    return total;
  }

  Future<int> _contarActivos(
      String desde, String hasta) async {
    // Clientes con pago en el rango.
    // (136-735) con las exclusiones canónicas de pagos, las
    // mismas de _sumarPagos/pagosDelPeriodo: cortesía, Casa
    // (fila o cuenta) y anulados (espejo o anulación en cola)
    // no hacen «activo» a nadie.
    final casas = await LocalDb.instance.idsCuentasCasa();
    final anuladosCola =
        await LocalDb.instance.pagosAnuladosEnCola();
    final vistos = <String>{};
    for (final p in await LocalDb.instance
        .mirrorPorFecha('pagos', 'fecha', desde, hasta)) {
      if ((p['metodo'] as String?) == 'cortesia') continue;
      if (p['casa'] == 1 || p['casa'] == true) continue;
      final cidCrudo = p['cliente_id'];
      final cidInt = cidCrudo is num
          ? cidCrudo.toInt()
          : (cidCrudo is String ? int.tryParse(cidCrudo) : null);
      if (cidInt != null && casas.contains(cidInt)) continue;
      if (esPagoAnulado(p, anuladosCola)) continue;
      final cid = '${p['cliente_id'] ?? ''}';
      if (cid.isNotEmpty) vistos.add(cid);
    }
    return vistos.length;
  }

  Future<int> _contarNuevos(
      String desde, String hasta) async {
    int count = 0;
    for (final c in await LocalDb.instance
        .allMirror('clientes')) {
      if (esClienteEliminado(c)) continue; // v1.8.0: no es persona
      // Yunque R4-M4-3: created_at puede venir con hora y
      // zona: el día que cuenta es el de negocio Habana
      // (con el substring crudo, un alta de madrugada caía
      // en el mes equivocado de «Nuevos ingresos»).
      final dia =
          fechaNegocioHabana(c['created_at'] ?? c['fecha_ingreso']);
      if (dia.isNotEmpty &&
          dia.compareTo(desde) >= 0 &&
          dia.compareTo(hasta) <= 0) {
        count++;
      }
    }
    return count;
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final hoy = ahoraHabana();
      final diaN = hoy.day;

      // Rangos
      final inicioMesActual =
          DateTime(hoy.year, hoy.month, 1);
      final finMesActualMTD = hoy; // hasta hoy

      final mesAnt = hoy.month == 1
          ? DateTime(hoy.year - 1, 12, 1)
          : DateTime(hoy.year, hoy.month - 1, 1);
      final finMesAntMTD = DateTime(
          mesAnt.year, mesAnt.month, diaN);
      // Ajustar si el mes anterior tiene menos días
      final ultimoDiaMesAnt = DateTime(
              mesAnt.year, mesAnt.month + 1, 1)
          .subtract(const Duration(days: 1));
      final finMTD = finMesAntMTD.isAfter(ultimoDiaMesAnt)
          ? ultimoDiaMesAnt
          : finMesAntMTD;
      final finMesAntTotal = ultimoDiaMesAnt;

      final desdeActual = _iso(inicioMesActual);
      final hastaActual = _iso(finMesActualMTD);
      final desdeAnt = _iso(mesAnt);
      final hastaAntMTD = _iso(finMTD);
      final hastaAntTotal = _iso(finMesAntTotal);

      const meses = [
        '',
        'ene',
        'feb',
        'mar',
        'abr',
        'may',
        'jun',
        'jul',
        'ago',
        'sep',
        'oct',
        'nov',
        'dic'
      ];

      final mensualActual =
          await _sumarPagos(desdeActual, hastaActual);
      final mensualAntMTD =
          await _sumarPagos(desdeAnt, hastaAntMTD);
      final mensualAntTotal =
          await _sumarPagos(desdeAnt, hastaAntTotal);

      final suplActual = await _sumarSuplementos(
          desdeActual, hastaActual);
      final suplAntMTD = await _sumarSuplementos(
          desdeAnt, hastaAntMTD);
      final suplAntTotal = await _sumarSuplementos(
          desdeAnt, hastaAntTotal);

      final cliActual = await _contarActivos(
          desdeActual, hastaActual);
      final cliAntMTD = await _contarActivos(
          desdeAnt, hastaAntMTD);
      // Para clientes, el "total" del mes anterior es el MTD
      // (no tiene sentido sumar dos veces)

      final nuevosActual = await _contarNuevos(
          desdeActual, hastaActual);
      final nuevosAntMTD =
          await _contarNuevos(desdeAnt, hastaAntMTD);
      final nuevosAntTotal = await _contarNuevos(
          desdeAnt, hastaAntTotal);

      if (mounted) {
        setState(() {
          _mesActual = meses[hoy.month];
          _mesAnterior = meses[mesAnt.month];
          _metricas = [
            _Metrica(
              titulo: 'Mensualidades',
              actual: mensualActual,
              anteriorMTD: mensualAntMTD,
              anteriorTotal: mensualAntTotal,
              icono: Icons.payments_rounded,
            ),
            _Metrica(
              titulo: 'Suplementos',
              actual: suplActual,
              anteriorMTD: suplAntMTD,
              anteriorTotal: suplAntTotal,
              icono: Icons.fitness_center_rounded,
            ),
            _Metrica(
              titulo: 'Clientes que pagaron',
              actual: cliActual.toDouble(),
              anteriorMTD: cliAntMTD.toDouble(),
              anteriorTotal: cliAntMTD.toDouble(),
              icono: Icons.people_rounded,
              esMoneda: false,
            ),
            _Metrica(
              titulo: 'Nuevos ingresos',
              actual: nuevosActual.toDouble(),
              anteriorMTD: nuevosAntMTD.toDouble(),
              anteriorTotal: nuevosAntTotal.toDouble(),
              icono: Icons.person_add_rounded,
              esMoneda: false,
            ),
          ];
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cargando = false);
        mostrarSnack(context, 'Error: $e', significado: SignificadoChip.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // P2#4: sin guarda de dueño, un entrenador veía cifras de caja.
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Comparativa Mensual'),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: appBarIron(
        context,
        'Comparativa Mensual',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          // F2-20: carga del sistema, como las hermanas del frente.
          ? const EstadoCargando(texto: 'Cargando comparativa…')
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppEspacio.lg),
                  child: Text(
                    '$_mesActual (al día ${ahoraHabana().day}) vs $_mesAnterior',
                    style: AppTexto.cuerpo.copyWith(color: AppColores.textoSecundario(context)),
                  ),
                ),
                Expanded(
                  // F2-15: antes una rejilla 2×2 con
                  // childAspectRatio fijo (1.1): con el texto
                  // del sistema grande las tarjetas
                  // desbordaban. Ahora tarjetas a ancho
                  // completo con altura por contenido.
                  child: ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(
                            horizontal: AppEspacio.lg),
                    itemCount: _metricas.length,
                    itemBuilder: (ctx, i) => Padding(
                      padding: const EdgeInsets.only(
                          bottom: AppEspacio.md),
                      child: _buildTarjeta(_metricas[i]),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildTarjeta(_Metrica m) {
    final delta = m.deltaPct;
    final esPositivo = (delta ?? 0) >= 0;
    // F2-15: dinero con fmtMonto + «CUP» (antes '$' a mano
    // sin moneda, fuera del formato único de la casa).
    String fmt(double v) => m.esMoneda
        ? '${fmtMonto(v)} CUP'
        : '${v.toInt()}';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.md),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          mainAxisAlignment:
              MainAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(m.icono,
                    size: 18,
                    color: AppColores.textoSecundario(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    m.titulo,
                    style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                    maxLines: 1,
                    overflow:
                        TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.xs),
            Text(
              fmt(m.actual),
              style: AppTexto.metrica.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppEspacio.xs),
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2),
                  decoration: BoxDecoration(
                    color: delta == null
                        ? AppColores.textoSecundario(context)
                            .withValues(alpha: 0.12)
                        : esPositivo
                            ? AppColores.exito.withValues(alpha: 0.12)
                            : AppColores.error.withValues(alpha: 0.12),
                    borderRadius:
                        BorderRadius.circular(AppRadio.sm),
                  ),
                  child: Text(
                    // (136-735) sin base: rótulo, no porcentaje.
                    delta == null
                        ? 'Sin base'
                        : '${esPositivo ? '+' : ''}${delta.toStringAsFixed(1)}%',
                    style: AppTexto.metadato.copyWith(color: delta == null
                          ? AppColores.textoSecundario(context)
                          : esPositivo
                              ? AppColores.exitoOscuro
                              : AppColores.errorOscuro, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            // 1.25 T24: la cifra «Ant» es la del MISMO
            // corte que el % (antes era el mes anterior
            // COMPLETO junto a un % calculado al corte: se
            // veía «+32 %» con un «anterior» mayor que el
            // actual). El mes completo queda como dato
            // secundario, rotulado como tal.
            Text(
              'Ant. al mismo corte: ${fmt(m.anteriorMTD)}',
              style: AppTexto.minuscula.copyWith(color: AppColores.textoSecundario(context)),
            ),
            if (m.anteriorTotal != m.anteriorMTD)
              Text(
                'Mes anterior completo: ${fmt(m.anteriorTotal)}',
                style: AppTexto.minuscula.copyWith(color: AppColores.textoSecundario(context)),
              ),
          ],
        ),
      ),
    );
  }
}
