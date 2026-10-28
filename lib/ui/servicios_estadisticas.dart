import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../auth.dart';
import '../estadisticas_servicios.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../servicios.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'reporte_margenes.dart';
import 'widgets.dart';

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
  String _tab = 'servicios'; // H6: 'servicios' | 'suplementos'
  Map<String, dynamic> _a = const {}; // 1A rendimiento
  Map<String, dynamic> _b = const {}; // 1B inversión
  // v1.13.0 (Bloque 4): agrupaciones Habana, indicadores por bote
  // (con guarda NaN) y resumen semanal I3.
  Map<int, ({int dosis, double ingresos})> _porDia = const {};
  Map<String, int> _porFranja = const {};
  Map<int, ({bool pendiente, double? margenPct, double? puntoEquilibrioDosis})>
      _indBote = const {};
  String _semanaTexto = '';
  String _semanaRango = '';

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
    // Argón #9 (ALTO parcial): estadísticas sin reversos ni ventas
    // reversadas (ver ventasServicioSinReversos). El reverso lleva
    // cantidad negativa y la misma ventana netea sola, pero el
    // reverso cae en su propio día (fecha = hoy), no en el de la
    // venta original: en periodo/semana/día, la ventana de la
    // original quedaba sobreestimada (y la del reverso, en negativo
    // sola). Para estadísticas, reversada es como si no hubiera
    // ocurrido. El CSV exporta estos mismos agregados.
    final ventasSinReversos = ventasServicioSinReversos(ventas);
    final ventasP = ventasSinReversos.where(enP).toList();
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
        'casa': 0,
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
        // Argón stats MEDIO 2 (1A): la Casa no es venta comercial:
        // va a su propia fila, no a servidas (1B ya la separa).
        if ((v['casa'] as num?)?.toInt() == 1) {
          fila['casa'] =
              (fila['casa'] as int) + ((v['cantidad'] as num?)?.toInt() ?? 0);
        } else {
          fila['servidas'] = (fila['servidas'] as int) +
              ((v['cantidad'] as num?)?.toInt() ?? 0);
        }
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

    // ---- 1B: inversión y margen (puro, testeable: calcular1B) ----
    final agg1B = calcular1B(
      ventas: ventasP,
      salidas: salidasP,
      botes: botes,
      boteDeLote: boteDeLote,
      movsAgua: movsAgua,
    );
    final ingBote = agg1B.ingBote;
    final dosisBote = agg1B.dosisBote;
    final costoBoteV = agg1B.costoBoteV;
    final nDosis = agg1B.nDosis;
    // Indicadores (Argón E5).
    // Argón stats MEDIO 2 (autonomía): en modo 'todo', días desde la
    // primera venta, no 30 fijos (con 30 fijos, dosisDia se infla y
    // la autonomía se subestima desde el segundo mes).
    final dias = _periodo == 'mes'
        ? ahoraHabana().day
        : diasDesdePrimeraVenta(ventasP, ahoraHabana());
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

    // v1.13.0 (Bloque 4, ajuste 6): indicadores por bote con guarda
    // NaN (bote nuevo o solo Casa/mermas → «Pendiente de primeras
    // ventas»), agrupaciones por día de semana y franja (fechas
    // truncadas explícitamente en Habana, agua en POMOS).
    final indBote = <int, ({bool pendiente, double? margenPct, double? puntoEquilibrioDosis})>{};
    for (final b in botes) {
      final id = (b['id'] as num?)?.toInt();
      if (id == null) continue;
      indBote[id] = indicadoresBote(
        costoBote: (b['costo_bote'] as num?)?.toDouble() ?? 0,
        rendimiento: (b['dosis_rendimiento'] as num?)?.toInt() ?? 0,
        ingresosComerciales: ingBote[id] ?? 0,
        dosisComerciales: dosisBote[id] ?? 0,
        costosComerciales: costoBoteV[id] ?? 0,
      );
    }
    final porDia = agruparPorDiaSemana(ventasP);
    final porFranja = agruparPorFranja(ventasP);

    // v1.13.0 (I3): resumen de la semana CERRADA Habana (lunes a
    // domingo ya terminada). Se genera al abrir Estadísticas y se
    // copia con J1; jamás se envía solo. J4 PDF está ELIMINADO.
    final hoyH = ahoraHabana();
    final lunesEstaSemana =
        hoyH.subtract(Duration(days: hoyH.weekday - 1));
    final lunesCerrada = lunesEstaSemana.subtract(const Duration(days: 7));
    final domingoCerrada = lunesCerrada.add(const Duration(days: 6));
    String fDia(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final lunesTxt = fDia(lunesCerrada);
    final domingoTxt = fDia(domingoCerrada);
    var semDosis = 0, semPomos = 0;
    var semIng = 0.0, semCom = 0.0;
    for (final v in ventasSinReversos) {
      final f = '${v['fecha'] ?? ''}';
      if (f.length < 10) continue;
      final dia = f.substring(0, 10);
      if (dia.compareTo(lunesTxt) < 0 || dia.compareTo(domingoTxt) > 0) {
        continue;
      }
      final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
      final precio = (v['precio_unitario'] as num?)?.toDouble() ?? 0;
      final tipo = '${v['tipo']}';
      if (tipo == 'agua_suelta') {
        semPomos += cant;
        semIng += precio * cant;
      } else if (tipo.startsWith('dosis') &&
          (v['casa'] as num?)?.toInt() != 1) {
        semDosis += cant;
        semIng += precio * cant;
        semCom +=
            ((v['comision_unitaria'] as num?)?.toDouble() ?? 0) * cant;
      }
    }
    final semanaTexto = textoResumenSemanal(
      lunes: lunesTxt,
      domingo: domingoTxt,
      dosis: semDosis,
      pomosSueltos: semPomos,
      ingresos: semIng,
      comisiones: semCom,
    );

    if (!mounted) return;
    setState(() {
      _a = {'porBote': porBote};
      _porDia = porDia;
      _porFranja = porFranja;
      _indBote = indBote;
      _semanaTexto = semanaTexto;
      _semanaRango = '$lunesTxt al $domingoTxt';
      _b = {
        ...agg1B.b,
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
                // Argón stats MEDIO 2: sin banner, el dueño veía
                // números viejos sin advertencia de sync pendiente.
                // Al tocarlo se sincroniza; el refresh recarga.
                const SyncBanner(),
                // v1.13.0 (H6): pestañas Servicios / Suplementos.
                // Suplementos reutiliza el reporte de márgenes
                // existente (no se crea otra pantalla de stats).
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                        value: 'servicios',
                        label: Text('Servicios')),
                    ButtonSegment(
                        value: 'suplementos',
                        label: Text('Suplementos')),
                  ],
                  selected: {_tab},
                  onSelectionChanged: (s) =>
                      setState(() => _tab = s.first),
                ),
                const SizedBox(height: AppEspacio.md),
                if (_tab == 'suplementos') ...[
                  const Text(
                    'Márgenes de suplementos: el reporte existente '
                    '(mismo cálculo, sin duplicar).',
                    style: AppTexto.secundario,
                  ),
                  const SizedBox(height: AppEspacio.md),
                  FilledButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              const ReporteMargenesScreen()),
                    ),
                    icon: const Icon(Icons.bar_chart, size: 20),
                    label: const Text(
                        'Abrir reporte de márgenes de suplementos'),
                  ),
                ] else ...[
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
                  const SizedBox(height: AppEspacio.md),
                  _tarjetaAgrupaciones(),
                  const SizedBox(height: AppEspacio.md),
                  _tarjetaSemana(),
                  const SizedBox(height: AppEspacio.md),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _abrirSimulador,
                          icon: const Icon(Icons.calculate, size: 20),
                          label: const Text('Simulador de precios'),
                        ),
                      ),
                      const SizedBox(width: AppEspacio.sm),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _exportarCsv,
                          icon: const Icon(Icons.download, size: 20),
                          label: const Text('Exportar CSV'),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }

  /// v1.13.0 (B6): hoja calculadora EFÍMERA en memoria (2
  /// deslizadores sobre el costo del bote actual). No escribe BD.
  Future<void> _abrirSimulador() async {
    final botes = await LocalDb.instance.allMirror('servicio_botes');
    // Argón stats MENOR: el desplegable mostraba solo 'Bote #id'.
    final suplementos =
        await LocalDb.instance.allMirror('suplementos');
    final nombreSup = <int, String>{
      for (final s in suplementos)
        if ((s['id'] as num?) != null)
          (s['id'] as num).toInt(): '${s['nombre'] ?? ''}',
    };
    // Costo del pomo para el margen con agua: última entrada de agua
    // (por fecha e id, no por orden del espejo: ver
    // ultimaEntradaAguaCosto).
    final costoAgua = ultimaEntradaAguaCosto(await LocalDb.instance
        .allMirror('servicio_agua_movimientos'));
    // Argón #9 (MEDIO): los botes abiertos tienen estado 'abierto';
    // 'activo' es el estado de los LOTES. Con 'activo' la lista
    // salía siempre vacía y el simulador era inutilizable.
    final abiertos = botes
        .where((b) => '${b['estado']}' == 'abierto')
        .toList();
    if (!mounted) return;
    if (abiertos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No hay un bote abierto para simular.')));
      return;
    }
    var bote = abiertos.first;
    var precioSin = 600.0;
    var precioCon = 900.0;
    // Etiquetas del desplegable (nombre + id, para no confundir dos
    // botes abiertos del mismo suplemento).
    final etiquetasBote = <String>[];
    for (final b in abiertos) {
      final nom = nombreSup[(b['suplemento_id'] as num?)?.toInt()];
      etiquetasBote.add(nom == null || nom.isEmpty
          ? 'Bote #${b['id']}'
          : '$nom · Bote #${b['id']}');
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          final costo =
              (bote['costo_bote'] as num?)?.toDouble() ?? 0;
          final rend =
              (bote['dosis_rendimiento'] as num?)?.toInt() ?? 0;
          final sim = simularPrecios(
            costoBote: costo,
            rendimiento: rend,
            precioSinAgua: precioSin,
            precioConAgua: precioCon,
            costoAgua: costoAgua,
          );
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Simulador de precios (solo cálculo, '
                    'no guarda nada)',
                    style: AppTexto.titulo),
                const SizedBox(height: 8),
                DropdownButton<Map<String, dynamic>>(
                  value: bote,
                  items: [
                    for (var i = 0; i < abiertos.length; i++)
                      DropdownMenuItem(
                          value: abiertos[i],
                          child: Text(etiquetasBote[i])),
                  ],
                  onChanged: (v) =>
                      setD(() => bote = v ?? bote),
                ),
                Text(
                  'Costo del bote: ${fmtMonto(costo)} CUP · '
                  'Rendimiento: $rend dosis · '
                  'Costo por dosis: ${fmtMonto(sim.costoPorDosis)} CUP · '
                  'Pomo de agua: ${fmtMonto(costoAgua)} CUP',
                  style: AppTexto.cuerpo,
                ),
                const SizedBox(height: 8),
                Text(
                    'Precio sin agua: ${fmtMonto(precioSin)} CUP '
                    '(margen ${fmtMonto(sim.margenSinAgua)} CUP/dosis)'),
                Slider(
                  value: precioSin,
                  min: 0,
                  max: 2000,
                  divisions: 40,
                  label: fmtMonto(precioSin),
                  onChanged: (v) => setD(() => precioSin = v),
                ),
                Text(
                    'Precio con agua: ${fmtMonto(precioCon)} CUP '
                    '(margen ${fmtMonto(sim.margenConAgua)} CUP/dosis)'),
                Slider(
                  value: precioCon,
                  min: 0,
                  max: 2000,
                  divisions: 40,
                  label: fmtMonto(precioCon),
                  onChanged: (v) => setD(() => precioCon = v),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// v1.13.0 (J2/J3): exportar las estadísticas a CSV y compartir.
  Future<void> _exportarCsv() async {
    try {
      final porBote =
          (_a['porBote'] as Map<int, Map<String, dynamic>>?) ?? const {};
      final filas = <List<String>>[];
      for (final e in porBote.entries) {
        final ind = _indBote[e.key];
        filas.add([
          '${e.value['nombre']}',
          '${e.value['servidas']}',
          '${e.value['merma']}',
          ind == null || ind.pendiente
              ? 'Pendiente de primeras ventas'
              : '${ind.margenPct?.toStringAsFixed(1)} %',
          ind == null || ind.pendiente || ind.puntoEquilibrioDosis == null
              ? 'Pendiente de primeras ventas'
              : '${ind.puntoEquilibrioDosis!.toStringAsFixed(0)} dosis',
        ]);
      }
      final csv = csvEstadisticas(
        ['Bote', 'Dosis servidas', 'Mermas', 'Margen %',
         'Punto de equilibrio'],
        filas,
      );
      final dir = await getTemporaryDirectory();
      final f = await File(
              '${dir.path}/estadisticas_servicios_${hoyHabanaIso()}.csv')
          .writeAsString(csv);
      await Share.shareXFiles([XFile(f.path)],
          text: 'Estadísticas de Servicios Iron Body Gym');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo exportar: $e')));
      }
    }
  }

  Widget _tarjetaAgrupaciones() {
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Por día de semana (Habana)',
              style: AppTexto.titulo.copyWith(fontSize: 16)),
          const SizedBox(height: 4),
          for (var d = 1; d <= 7; d++)
            _fila(
              kNombresDiaSemana[d] ?? 'Día $d',
              '${_porDia[d]?.dosis ?? 0} dosis · '
              '${fmtMonto(_porDia[d]?.ingresos ?? 0)} CUP',
            ),
          const Divider(height: 20),
          Text('Por franja horaria (Habana)',
              style: AppTexto.titulo.copyWith(fontSize: 16)),
          const SizedBox(height: 4),
          for (final e in kNombresFranja.entries)
            _fila(e.value, '${_porFranja[e.key] ?? 0} dosis'),
          const Text(
            'Las ventas sin hora (anteriores a la 1.13.0) caen en '
            '«Sin hora registrada»: no se inventa su franja.',
            style: AppTexto.secundario,
          ),
        ],
      ),
    );
  }

  /// v1.13.0 (I3 + J1): tarjeta de la semana cerrada Habana con
  /// botón copiar. Jamás se envía sola.
  Widget _tarjetaSemana() {
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Resumen semanal (semana cerrada)',
              style: AppTexto.titulo.copyWith(fontSize: 16)),
          const SizedBox(height: 4),
          Text(_semanaRango, style: AppTexto.secundario),
          const SizedBox(height: 8),
          Text(_semanaTexto, style: AppTexto.cuerpo),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              await Clipboard.setData(
                  ClipboardData(text: _semanaTexto));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Resumen copiado')));
              }
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copiar resumen'),
          ),
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
              _fila('Casa', '${e.value['casa']}'),
              _fila('Mermas', '${e.value['merma']}'),
              _fila('Cortesías', '${e.value['cortesia']}'),
              _fila('Consumo del staff', '${e.value['staff']}'),
              // v1.13.0 (ajuste 6): punto de equilibrio y margen %
              // con guarda NaN: bote nuevo o solo Casa/mermas →
              // «Pendiente de primeras ventas», nunca división
              // entre cero.
              Builder(builder: (_) {
                final ind = _indBote[e.key];
                if (ind == null || ind.pendiente) {
                  return Column(
                    children: [
                      _fila('Punto de equilibrio',
                          'Pendiente de primeras ventas'),
                      _fila('Margen %',
                          'Pendiente de primeras ventas'),
                    ],
                  );
                }
                return Column(
                  children: [
                    _fila(
                        'Punto de equilibrio',
                        ind.puntoEquilibrioDosis == null
                            ? 'Sin equilibrio a estos precios'
                            : '${ind.puntoEquilibrioDosis!.toStringAsFixed(0)} dosis'),
                    _fila('Margen %',
                        '${ind.margenPct?.toStringAsFixed(1)} %'),
                  ],
                );
              }),
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
          _fila('Inversión en botes (acumulada)',
              cup('inversion_botes')),
          _fila('Inversión en agua (acumulada)',
              cup('inversion_agua')),
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
