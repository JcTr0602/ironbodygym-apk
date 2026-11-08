import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../auth.dart';
import '../estadisticas_servicios.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto, fmtFecha;
import '../servicios.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'reporte_margenes.dart';
import 'servicios_admin.dart';
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
  String _periodo = 'mes'; // 'mes' | 'todo' | 'rango' (M3-B3)
  // 1.28 (M3-B3): el rango a medida del período (ISO
  // 'yyyy-mm-dd', ambos extremos incluidos). Nace en los
  // últimos 30 días al elegir «Rango» por primera vez.
  String? _desdeRango;
  String? _hastaRango;
  String _tab = 'servicios'; // H6: 'servicios' | 'suplementos'
  // 1.28 (M3-B3): los cortes del período (por vendedor y por
  // pomo) y sus nombres ya resueltos.
  List<({int? tid, int dosis, int unidades, double ingresos, double comision})>
      _corteVendedor = const [];
  List<({int? pomoId, int dosis, double ingresos, double comision, double margen})>
      _cortePomo = const [];
  Map<int, String> _nombreVendedor = const {};
  Map<int, String> _nombrePomo = const {};
  // 1.28 (M3-C1): las cifras de cabecera del período y las
  // del período anterior equivalente (null = sin base
  // comparable: «Todo» no tiene anterior). El neto anterior
  // solo se calcula en modo mes (la inversión de 1B se acota
  // por mes; en rango quedaría mezclada y el delta mentiría).
  ({double ingresos, int dosis, double margen, double? neto})? _kpis;
  ({double ingresos, int dosis, double margen, double? neto})? _kpisAnt;
  // 1.28 (M3-B4): ventas del período aún en la cola de este
  // teléfono (las estadísticas leen SOLO el espejo).
  int _ventasColaPeriodo = 0;
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
  // 12/25: listas ya cargadas por _cargar, que el simulador
  // reutiliza sin releer los espejos en cada apertura.
  List<Map<String, dynamic>> _botes = const [];
  Map<int, String> _nombreSup = const {};
  double _costoAgua = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  bool _enPeriodo(String? fecha) {
    if (_periodo == 'todo') return true;
    if (fecha == null || fecha.length < 7) return false;
    // 1.28 (M3-B3): el rango a medida compara el DÍA (con
    // fecha válida: una imposible no entra en ningún rango).
    if (_periodo == 'rango' &&
        _desdeRango != null &&
        _hastaRango != null) {
      if (fecha.length < 10) return false;
      final dia = fecha.substring(0, 10);
      if (!esFechaIsoValida(dia)) return false;
      return dia.compareTo(_desdeRango!) >= 0 &&
          dia.compareTo(_hastaRango!) <= 0;
    }
    return fecha.substring(0, 7) == hoyHabanaIso().substring(0, 7);
  }

  /// Los extremos ISO del período visible (para el sello de
  /// frescura y el período anterior): 'todo' no acota.
  ({String? desde, String? hasta}) _extremosPeriodo() {
    final hoy = hoyHabanaIso();
    return switch (_periodo) {
      'todo' => (desde: null, hasta: null),
      'rango' => (desde: _desdeRango, hasta: _hastaRango),
      _ => (desde: '${hoy.substring(0, 7)}-01', hasta: hoy),
    };
  }

  // Argón Estadísticas #3: espejos crudos cacheados en el
  // State. Antes, cada apertura y cada cambio del selector
  // «Este mes/Todo» releía las 7 tablas completas de SQLite
  // solo para refiltrar en memoria. Ahora la BD se lee en
  // initState y con el botón de refrescar; cambiar el
  // período recalcula sobre lo ya cargado (releer: false).
  List<Map<String, dynamic>>? _eVentas;
  List<Map<String, dynamic>>? _eSalidas;
  List<Map<String, dynamic>>? _eBotes;
  List<Map<String, dynamic>>? _eLotes;
  List<Map<String, dynamic>>? _eMovsAgua;
  List<Map<String, dynamic>>? _eSuplementos;
  List<Map<String, dynamic>>? _ePomos;

  Future<void> _cargar({bool releer = true}) async {
    if (releer || _eVentas == null) {
      _eVentas = await LocalDb.instance.allMirror('servicio_ventas');
      _eSalidas =
          await LocalDb.instance.allMirror('servicio_salidas');
      _eBotes = await LocalDb.instance.allMirror('servicio_botes');
      _eLotes = await LocalDb.instance.allMirror('servicio_lotes');
      _eMovsAgua = await LocalDb.instance
          .allMirror('servicio_agua_movimientos');
      _eSuplementos =
          await LocalDb.instance.allMirror('suplementos');
      _ePomos = await LocalDb.instance.allMirror('servicio_pomos');
    }
    final ventas = _eVentas!;
    final salidas = _eSalidas!;
    final botes = _eBotes!;
    final lotes = _eLotes!;
    final movsAgua = _eMovsAgua!;
    final suplementos = _eSuplementos!;
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
    // Argón pasada 1 #1: desde v1.15 las ventas/salidas llevan
    // pomo_id, no lote_id. Pomo -> suplemento (activos para el
    // saldo + espejo completo para pomos históricos/inactivos);
    // suplemento -> bote: el abierto, y si hay varios, el más
    // reciente (id mayor). Sin pomo_id o sin bote resoluble por
    // pomo, se cae a lote_id (ventas viejas).
    final pomosEspejo = _ePomos!;
    final pomosActivos = await pomosActivosLocal();
    final suplementoDePomo = <int, int>{
      for (final p in pomosEspejo)
        if ((p['id'] as num?) != null &&
            (p['suplemento_id'] as num?) != null)
          (p['id'] as num).toInt():
              (p['suplemento_id'] as num).toInt(),
    };
    for (final p in pomosActivos) {
      final id = (p['id'] as num?)?.toInt();
      final sup = (p['suplemento_id'] as num?)?.toInt();
      if (id != null && sup != null) suplementoDePomo[id] = sup;
    }
    final botePorSuplemento = <int, int>{};
    final abiertoPorSuplemento = <int, bool>{};
    for (final b in botes) {
      final id = (b['id'] as num?)?.toInt();
      final sup = (b['suplemento_id'] as num?)?.toInt();
      if (id == null || sup == null) continue;
      final abierto = '${b['estado']}' == 'abierto';
      final actual = botePorSuplemento[sup];
      if (actual == null ||
          (abierto && !(abiertoPorSuplemento[sup] ?? false)) ||
          (abierto == (abiertoPorSuplemento[sup] ?? false) &&
              id > actual)) {
        botePorSuplemento[sup] = id;
        abiertoPorSuplemento[sup] = abierto;
      }
    }
    final boteDePomo = <int, int>{
      for (final e in suplementoDePomo.entries)
        if (botePorSuplemento.containsKey(e.value))
          e.key: botePorSuplemento[e.value]!,
    };
    // Argón Estadísticas #2: la resolución por pomo pasa por
    // la VENTANA del bote (mismo criterio que calcular1B): el
    // mapa estático boteDePomo queda solo como respaldo para
    // filas sin fecha o botes sin abierto_en utilizable.
    final botesPorSuplemento = <int, List<Map<String, dynamic>>>{};
    for (final b in botes) {
      final sup = (b['suplemento_id'] as num?)?.toInt();
      if (sup == null) continue;
      (botesPorSuplemento[sup] ??= []).add(b);
    }

    int? boteDe(Map<String, dynamic> r) {
      final pomoId = (r['pomo_id'] as num?)?.toInt();
      if (pomoId != null) {
        final sup = suplementoDePomo[pomoId];
        if (sup != null) {
          final porVentana = botePorVentana(
            botesPorSuplemento[sup] ?? const [],
            r['fecha'] as String?,
            respaldo: boteDePomo[pomoId],
          );
          if (porVentana != null) return porVentana;
        }
        final porPomo = boteDePomo[pomoId];
        if (porPomo != null) return porPomo;
      }
      return boteDeLote[(r['lote_id'] as num?)?.toInt()];
    }

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
      final boteId = boteDe(v);
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
      final boteId = boteDe(s);
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
    // Argón Estadísticas #1/#2: en modo 'mes' la inversión se
    // acota al mes (mesInversion) y el bote de cada venta se
    // resuelve por ventana (suplementoDePomo), no por el bote
    // abierto actual.
    final agg1B = calcular1B(
      ventas: ventasP,
      salidas: salidasP,
      botes: botes,
      boteDeLote: boteDeLote,
      boteDePomo: boteDePomo,
      suplementoDePomo: suplementoDePomo,
      mesInversion:
          _periodo == 'mes' ? hoyHabanaIso().substring(0, 7) : null,
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
    // Argón Estadísticas #6 (segunda parte): la «primera venta»
    // es la primera DOSIS COMERCIAL — un consumo de la Casa o
    // un agua suelta no abren el contador (el numerador nDosis
    // ya los excluía; el denominador no).
    final ventasComerciales = ventasP
        .where((v) =>
            '${v['tipo']}'.startsWith('dosis') &&
            (v['casa'] as num?)?.toInt() != 1)
        .toList();
    final dias = _periodo == 'mes'
        ? ahoraHabana().day
        : diasDesdePrimeraVenta(ventasComerciales, ahoraHabana());
    // Argón pasada 1 #1: el stock vivo son pomos (v1.15), no
    // lotes: saldoTotal suma saldo_local de pomosActivosLocal().
    var saldoTotal = 0;
    for (final p in pomosActivos) {
      saldoTotal += (p['saldo_local'] as num?)?.toInt() ?? 0;
    }
    final dosisDia = dias > 0 ? nDosis / dias : 0.0;
    final autonomia =
        dosisDia > 0 ? (saldoTotal / dosisDia).floor() : null;
    // Argón Estadísticas #6: autonomía del pomo que ANTES se
    // agota. La global mezcla pomos lentos y rápidos (85 dosis
    // a ritmo global pueden esconder un pomo que se acaba
    // mañana). Por pomo: ritmo = sus dosis comerciales del
    // período / días; autonomía = su saldo / su ritmo. Solo
    // pomos con ritmo > 0 (sin ventas no hay señal).
    int? autonomiaPomoMin;
    String? autonomiaPomoNombre;
    if (dias > 0) {
      final dosisPorPomo = <int, int>{};
      for (final v in ventasComerciales) {
        final pomoId = (v['pomo_id'] as num?)?.toInt();
        if (pomoId == null) continue;
        dosisPorPomo[pomoId] = (dosisPorPomo[pomoId] ?? 0) +
            ((v['cantidad'] as num?)?.toInt() ?? 0);
      }
      for (final p in pomosActivos) {
        final pomoId = (p['id'] as num?)?.toInt();
        final vendidas = pomoId == null ? 0 : (dosisPorPomo[pomoId] ?? 0);
        if (pomoId == null || vendidas <= 0) continue;
        final ritmo = vendidas / dias;
        final saldo = (p['saldo_local'] as num?)?.toInt() ?? 0;
        final aut = (saldo / ritmo).floor();
        if (autonomiaPomoMin == null || aut < autonomiaPomoMin) {
          autonomiaPomoMin = aut;
          final sup = (p['suplemento_id'] as num?)?.toInt();
          autonomiaPomoNombre = nombreSup[sup] ?? 'Pomo #$pomoId';
        }
      }
    }

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

    // ---- 1.28 (M3-B3/C1/B4): cortes, KPIs con delta y sello ----
    final corteVendedor = agruparPorVendedor(ventasP);
    final cortePomo = agruparPorPomo(ventasP);
    final nombreVendedor = <int, String>{
      for (final v in ventas)
        if ((v['registrado_por'] as num?) != null &&
            '${v['registrado_por_nombre'] ?? ''}'.trim().isNotEmpty)
          (v['registrado_por'] as num).toInt():
              '${v['registrado_por_nombre']}'.trim(),
    };
    final miTidEst = AuthService().telegramId;
    if (miTidEst != null) {
      nombreVendedor.putIfAbsent(miTidEst, () => 'Yo (dueño)');
    }
    final nombrePomo = <int, String>{
      for (final p in pomosEspejo)
        if ((p['id'] as num?) != null)
          (p['id'] as num).toInt(): (nombreSup[
                      suplementoDePomo[(p['id'] as num).toInt()]] ??
                  'Pomo #${(p['id'] as num).toInt()}'),
    };
    final kpisAct = (
      ingresos: (agg1B.b['ingresos'] as num?)?.toDouble() ?? 0,
      dosis: nDosis,
      margen: (agg1B.b['margen'] as num?)?.toDouble() ?? 0,
      neto: (agg1B.b['neto_dueno'] as num?)?.toDouble(),
    );
    // El período anterior equivalente: el mes calendario
    // anterior en modo mes; el rango de igual longitud justo
    // antes en modo rango; en «Todo» no hay anterior.
    ({double ingresos, int dosis, double margen, double? neto})?
        kpisAnt;
    final hoyD = ahoraHabana();
    String? antDesde;
    String? antHasta;
    String? antMesInversion;
    if (_periodo == 'mes') {
      final pd = DateTime.utc(hoyD.year, hoyD.month - 1, 1);
      final ph = DateTime.utc(hoyD.year, hoyD.month, 0);
      String iso(DateTime x) =>
          '${x.year.toString().padLeft(4, '0')}-'
          '${x.month.toString().padLeft(2, '0')}-'
          '${x.day.toString().padLeft(2, '0')}';
      antDesde = iso(pd);
      antHasta = iso(ph);
      antMesInversion = antDesde.substring(0, 7);
    } else if (_periodo == 'rango' &&
        _desdeRango != null &&
        _hastaRango != null) {
      final r = rangoPeriodoAnterior(_desdeRango!, _hastaRango!);
      antDesde = r?.desde;
      antHasta = r?.hasta;
    }
    if (antDesde != null && antHasta != null) {
      final ventasAnt = ventasEnRango(ventasSinReversos,
          desde: antDesde, hasta: antHasta);
      final salidasAnt = ventasEnRango(salidas,
          desde: antDesde, hasta: antHasta);
      final aggAnt = calcular1B(
        ventas: ventasAnt,
        salidas: salidasAnt,
        botes: botes,
        boteDeLote: boteDeLote,
        boteDePomo: boteDePomo,
        suplementoDePomo: suplementoDePomo,
        mesInversion: antMesInversion,
        movsAgua: movsAgua,
      );
      kpisAnt = (
        ingresos: (aggAnt.b['ingresos'] as num?)?.toDouble() ?? 0,
        dosis: aggAnt.nDosis,
        margen: (aggAnt.b['margen'] as num?)?.toDouble() ?? 0,
        // El neto anterior solo es comparable en modo mes
        // (con la inversión acotada a SU mes).
        neto: antMesInversion == null
            ? null
            : (aggAnt.b['neto_dueno'] as num?)?.toDouble(),
      );
    }
    // El sello de frescura: las estadísticas leen solo el
    // espejo; las ventas del período aún en la cola de este
    // teléfono NO están en estas cifras y se dice cuántas.
    final extremos = _extremosPeriodo();
    final opsEst = await opsPendientesServicios();
    final ventasColaPeriodo = contarOpsServiciosEnCola(opsEst,
            desde: extremos.desde, hasta: extremos.hasta)
        .ventas;

    // Argón Servicios #11: el simulador valora el agua al CPP
    // vigente (el mismo de las ventas reales y la tarjeta 1B),
    // no al costo de la última compra.
    final costoAguaCpp = (await stockAguaLocal()).cpp;
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
        'autonomia_pomo_min': autonomiaPomoMin,
        'autonomia_pomo_nombre': autonomiaPomoNombre,
      };
      // 12/25: el simulador reutiliza estas listas.
      _botes = botes;
      _nombreSup = nombreSup;
      _costoAgua = costoAguaCpp;
      // 1.28 (M3-B3/C1/B4).
      _corteVendedor = corteVendedor;
      _cortePomo = cortePomo;
      _nombreVendedor = nombreVendedor;
      _nombrePomo = nombrePomo;
      _kpis = kpisAct;
      _kpisAnt = kpisAnt;
      _ventasColaPeriodo = ventasColaPeriodo;
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Servicios · Estadísticas'),
        body: const Center(
            child: Text('Solo el dueño ve las estadísticas.')),
      );
    }
    return Scaffold(
      appBar: appBarIron(
        context,
        'Servicios · Estadísticas',
        acciones: [
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando estadísticas…')
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
                      RutaIron(
                          builder: (_) =>
                              const ReporteMargenesScreen()),
                    ),
                    icon: const Icon(Icons.bar_chart_rounded, size: 20),
                    label: const Text(
                        'Abrir reporte de márgenes de suplementos'),
                  ),
                ] else ...[
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                          value: 'mes', label: Text('Este mes')),
                      ButtonSegment(
                          value: 'rango', label: Text('Rango')),
                      ButtonSegment(
                          value: 'todo', label: Text('Todo')),
                    ],
                    selected: {_periodo},
                    onSelectionChanged: (s) {
                      setState(() {
                        _periodo = s.first;
                        // 1.28 (M3-B3): el rango nace en los
                        // últimos 30 días la primera vez.
                        if (_periodo == 'rango' &&
                            (_desdeRango == null || _hastaRango == null)) {
                          final h = ahoraHabana();
                          final dU = DateTime.utc(
                              h.year, h.month, h.day - 29);
                          String iso(DateTime x) =>
                              '${x.year.toString().padLeft(4, '0')}-'
                              '${x.month.toString().padLeft(2, '0')}-'
                              '${x.day.toString().padLeft(2, '0')}';
                          _desdeRango = iso(dU);
                          _hastaRango = hoyHabanaIso();
                        }
                        _cargando = true;
                      });
                      // Argón Estadísticas #3: cambiar el
                      // período NO relee la BD; recalcula
                      // sobre los espejos cacheados.
                      _cargar(releer: false);
                    },
                  ),
                  // 1.28 (M3-B3): el selector de fechas del
                  // rango a medida.
                  if (_periodo == 'rango') ...[
                    const SizedBox(height: AppEspacio.sm),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _desdeRango == null
                                ? 'Sin fechas elegidas'
                                : 'Del ${fmtFecha(_desdeRango)} '
                                    'al ${fmtFecha(_hastaRango)}',
                            style: AppTexto.cuerpo,
                          ),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(
                              Icons.date_range_rounded, size: 18),
                          label: const Text('Elegir fechas'),
                          onPressed: _elegirRango,
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: AppEspacio.md),
                  _tarjetaKpis(),
                  // 1.28 (M3-B4): el sello de frescura de las
                  // estadísticas — estas cifras salen SOLO
                  // del espejo; lo que sigue en la cola de
                  // este teléfono no está dentro y se dice.
                  if (_ventasColaPeriodo > 0) ...[
                    const SizedBox(height: AppEspacio.sm),
                    ChipEstado.semantico(
                      texto: 'No incluye $_ventasColaPeriodo '
                          'venta${_ventasColaPeriodo == 1 ? '' : 's'} '
                          'por sincronizar: aún '
                          '${_ventasColaPeriodo == 1 ? 'está' : 'están'} '
                          'en este teléfono',
                      significado: SignificadoChip.alerta,
                      icono: Icons.sync_rounded,
                    ),
                  ],
                  const SizedBox(height: AppEspacio.md),
                  _tarjetaRendimiento(),
                  const SizedBox(height: AppEspacio.md),
                  _tarjetaInversion(),
                  const SizedBox(height: AppEspacio.md),
                  _tarjetaAgrupaciones(),
                  const SizedBox(height: AppEspacio.md),
                  _tarjetaCortes(),
                  const SizedBox(height: AppEspacio.md),
                  _tarjetaSemana(),
                  const SizedBox(height: AppEspacio.md),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _abrirSimulador,
                          icon: const Icon(Icons.calculate_rounded, size: 20),
                          label: const Text('Simulador de precios'),
                        ),
                      ),
                      const SizedBox(width: AppEspacio.sm),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _exportarCsv,
                          icon: const Icon(Icons.download_rounded, size: 20),
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
    // 12/25: reutiliza las listas que _cargar ya trajo (el botón
    // solo existe tras la carga: el cuerpo muestra spinner antes).
    // Antes releía botes, suplementos y movimientos de agua en
    // cada apertura aunque _cargar acabara de traerlos.
    final botes = _botes;
    final nombreSup = _nombreSup;
    final costoAgua = _costoAgua;
    // Argón #9 (MEDIO): los botes abiertos tienen estado 'abierto';
    // 'activo' es el estado de los LOTES. Con 'activo' la lista
    // salía siempre vacía y el simulador era inutilizable.
    final abiertos = botes
        .where((b) => '${b['estado']}' == 'abierto')
        .toList();
    if (abiertos.isEmpty) {
      mostrarSnack(context, 'No hay un bote abierto para simular.', significado: SignificadoChip.alerta);
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
            padding: const EdgeInsets.all(AppEspacio.lg),
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
          // Argón Estadísticas #7: celdas numéricas LIMPIAS
          // (sin « %» ni « dosis» pegados) para que Excel las
          // sume; la unidad va en la cabecera.
          ind == null || ind.pendiente
              ? 'Pendiente de primeras ventas'
              : '${ind.margenPct?.toStringAsFixed(1)}',
          ind == null || ind.pendiente || ind.puntoEquilibrioDosis == null
              ? 'Pendiente de primeras ventas'
              : '${ind.puntoEquilibrioDosis!.toStringAsFixed(0)}',
        ]);
      }
      final csv = csvEstadisticas(
        ['Bote', 'Dosis servidas', 'Mermas', 'Margen %',
         'Punto de equilibrio (dosis)'],
        filas,
      );
      final dir = await getTemporaryDirectory();
      // Argón Estadísticas #7: el nombre lleva el período —
      // un CSV de «Todo» y uno de «Este mes» ya no se
      // confunden en la carpeta de descargas.
      final f = await File(
              '${dir.path}/estadisticas_servicios_${_periodo}_${hoyHabanaIso()}.csv')
          .writeAsString(csv);
      await Share.shareXFiles([XFile(f.path)],
          text: 'Estadísticas de Servicios Iron Body Gym');
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo exportar: $e', significado: SignificadoChip.error);
      }
    }
  }

  /// 1.25 T94: una barra horizontal proporcional con
  /// su etiqueta y su valor. El patrón se VE; el texto
  /// exacto queda a la derecha.
  Widget _barra(String etiqueta, double fraccion, String valor,
      {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(etiqueta,
                style: AppTexto.cuerpo, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadio.sm),
              child: LinearProgressIndicator(
                value: fraccion,
                minHeight: 10,
                color: color ?? AppColores.naranja,
                backgroundColor:
                    AppColores.naranja.withValues(alpha: 0.12),
              ),
            ),
          ),
          const SizedBox(width: AppEspacio.sm),
          Text(valor, style: AppTexto.cuerpo),
        ],
      ),
    );
  }

  Color _colorNivelAutonomia(String nivel) => switch (nivel) {
        'holgada' => AppColores.exito,
        'justa' => AppColores.alertaOscuro,
        'critica' => AppColores.error,
        _ => Colors.grey,
      };

  Widget _tarjetaAgrupaciones() {
    // 1.25 T94: las agrupaciones se dibujan como barras
    // (antes, listas de texto idénticas: el patrón no se
    // veía). Con el período «Este mes», estas barras SON
    // los ingresos del mes por día de semana.
    final maxDia = _porDia.values
        .fold<int>(0, (m, g) => g.dosis > m ? g.dosis : m);
    final maxFranja = _porFranja.values
        .fold<int>(0, (m, v) => v > m ? v : m);
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Por día de semana (Habana)',
              style: AppTexto.titulo),
          const SizedBox(height: 4),
          for (var d = 1; d <= 7; d++)
            _barra(
              kNombresDiaSemana[d] ?? 'Día $d',
              fraccionBarra(_porDia[d]?.dosis ?? 0, maxDia),
              '${_porDia[d]?.dosis ?? 0} dosis · '
              '${fmtMonto(_porDia[d]?.ingresos ?? 0)} CUP',
            ),
          const Divider(height: 20),
          Text('Por franja horaria (Habana)',
              style: AppTexto.titulo),
          const SizedBox(height: 4),
          for (final e in kNombresFranja.entries)
            _barra(
              e.value,
              fraccionBarra(_porFranja[e.key] ?? 0, maxFranja),
              '${_porFranja[e.key] ?? 0} dosis',
            ),
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
              style: AppTexto.titulo),
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
                mostrarSnack(context, 'Resumen copiado');
              }
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
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

  /// 1.28 (M3-B3): el selector de fechas del rango a medida.
  Future<void> _elegirRango() async {
    final ahora = ahoraHabana();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024, 1, 1),
      lastDate: DateTime(ahora.year, ahora.month, ahora.day),
      initialDateRange: _desdeRango != null && _hastaRango != null
          ? DateTimeRange(
              start: DateTime.parse(_desdeRango!),
              end: DateTime.parse(_hastaRango!),
            )
          : null,
    );
    if (r == null || !mounted) return;
    String iso(DateTime x) =>
        '${x.year.toString().padLeft(4, '0')}-'
        '${x.month.toString().padLeft(2, '0')}-'
        '${x.day.toString().padLeft(2, '0')}';
    setState(() {
      _desdeRango = iso(r.start);
      _hastaRango = iso(r.end);
      _cargando = true;
    });
    _cargar(releer: false);
  }

  /// 1.28 (M3-C1): las cifras de cabecera como tarjetas KPI
  /// con su delta contra el período anterior equivalente.
  /// Sin base comparable (anterior en cero o «Todo») la
  /// tarjeta enseña «sin base» en vez de un porcentaje
  /// inventado. Las barras por día/franja ya viven en
  /// _tarjetaAgrupaciones con el patrón de barras de la casa
  /// (T94, _barra).
  Widget _tarjetaKpis() {
    final k = _kpis;
    if (k == null) return const SizedBox.shrink();
    final ant = _kpisAnt;
    final etiquetaAnt = switch (_periodo) {
      'mes' => 'vs mes anterior',
      'rango' => 'vs rango anterior',
      _ => '',
    };
    Widget kpi(String titulo, String valor, double? delta) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(AppEspacio.md),
          decoration: BoxDecoration(
            color: AppColores.superficie(context),
            borderRadius: BorderRadius.circular(AppRadio.md),
            border: Border.all(color: AppColores.borde(context)),
            // 1.29 D-18: valor exacto de la sombra de tarjeta
            // de la clase deprecada, escrito en el sitio.
            boxShadow: [
              BoxShadow(
                color: (Theme.of(context).brightness == Brightness.dark
                        ? Colors.black
                        : Colors.grey)
                    .withValues(
                        alpha: Theme.of(context).brightness ==
                                Brightness.dark
                            ? 0.4
                            : 0.12),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(titulo, style: AppTexto.metadato),
              const SizedBox(height: 4),
              Text(valor, style: AppTexto.titulo),
              const SizedBox(height: 4),
              if (delta == null)
                Text(
                    ant == null ? 'Sin período anterior' : 'Sin base',
                    style: AppTexto.metadato)
              else
                Text(
                  '${delta >= 0 ? '▲' : '▼'} '
                  '${delta.abs().toStringAsFixed(0)} % $etiquetaAnt',
                  style: AppTexto.metadato.copyWith(
                    color: delta >= 0
                        ? AppColores.exito
                        : AppColores.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            kpi('Ingresos', '${fmtMonto(k.ingresos)} CUP',
                ant == null ? null : deltaPct(k.ingresos, ant.ingresos)),
            const SizedBox(width: AppEspacio.sm),
            kpi('Dosis vendidas', '${k.dosis}',
                ant == null
                    ? null
                    : deltaPct(k.dosis.toDouble(), ant.dosis.toDouble())),
          ],
        ),
        const SizedBox(height: AppEspacio.sm),
        Row(
          children: [
            kpi('Margen', '${fmtMonto(k.margen)} CUP',
                ant == null ? null : deltaPct(k.margen, ant.margen)),
            const SizedBox(width: AppEspacio.sm),
            kpi(
                'Neto del dueño',
                k.neto == null ? '—' : '${fmtMonto(k.neto!)} CUP',
                (ant == null || ant.neto == null || k.neto == null)
                    ? null
                    : deltaPct(k.neto!, ant.neto!)),
          ],
        ),
      ],
    );
  }

  /// 1.28 (M3-B3): los cortes del período — por vendedor y
  /// por pomo/producto, con las mismas ventas ya filtradas
  /// de la pantalla (sin reversos, en período). El margen
  /// por pomo sale de los costos congelados en cada venta
  /// (ver agruparPorPomo): es el margen al venderse, no el
  /// revaluado de 1B.
  Widget _tarjetaCortes() {
    if (_corteVendedor.isEmpty && _cortePomo.isEmpty) {
      return const SizedBox.shrink();
    }
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Cortes del período', style: AppTexto.titulo),
          const SizedBox(height: 6),
          Text('Por vendedor', style: AppTexto.subtitulo),
          if (_corteVendedor.isEmpty)
            const Text('Sin ventas comerciales en el período.',
                style: AppTexto.secundario)
          else
            for (final c in _corteVendedor)
              _fila(
                c.tid == null
                    ? 'Sin vendedor identificado'
                    : (_nombreVendedor[c.tid] ?? 'Entrenador'),
                '${c.dosis} dosis · ${fmtMonto(c.ingresos)} CUP'
                '${c.comision > 0 ? ' · comisión ${fmtMonto(c.comision)}' : ''}',
              ),
          const Divider(height: 20),
          Text('Por pomo / producto', style: AppTexto.subtitulo),
          if (_cortePomo.isEmpty)
            const Text('Sin ventas comerciales en el período.',
                style: AppTexto.secundario)
          else
            for (final c in _cortePomo)
              _fila(
                c.pomoId == null
                    ? 'Agua común (sin pomo)'
                    : (_nombrePomo[c.pomoId] ?? 'Pomo'),
                '${c.dosis} dosis · ${fmtMonto(c.ingresos)} CUP'
                ' · margen ${fmtMonto(c.margen)}',
              ),
          const Text(
            'El margen por pomo usa el costo congelado en cada '
            'venta (el margen al venderse); el de 1B revalúa '
            'al costo actual del bote.',
            style: AppTexto.metadato,
          ),
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
              style: AppTexto.titulo),
          if (porBote.isEmpty)
            // 1.28 (M3-C6): el vacío con salida — abrir el
            // primer bote sin salir a buscar la pantalla.
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Sin botes todavía.',
                    style: AppTexto.cuerpo.copyWith(
                        color: AppColores.textoSecundario(context))),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.science_rounded, size: 18),
                  label: const Text('Abrir un bote'),
                  onPressed: () => Navigator.push(
                    context,
                    RutaIron(
                        builder: (_) => const ServiciosAdminScreen()),
                  ).then((_) => _cargar()),
                ),
              ],
            )
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
              style: AppTexto.titulo),
          const Divider(height: 20),
          // Argón Estadísticas #1: en «Este mes» la inversión
          // ya es SOLO del mes (calcular1B filtra por
          // abierto_en/fecha); la etiqueta lo dice tal cual.
          // En «Todo» sigue siendo la acumulada histórica.
          _fila(
              _periodo == 'mes'
                  ? 'Inversión en botes (este mes)'
                  : 'Inversión en botes (acumulada)',
              cup('inversion_botes')),
          _fila(
              _periodo == 'mes'
                  ? 'Inversión en agua (este mes)'
                  : 'Inversión en agua (acumulada)',
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
          // Argón Estadísticas #6: la autonomía global puede
          // esconder el pomo que se agota primero; si se pudo
          // calcular su ritmo, se muestra aparte.
          if (b['autonomia_pomo_min'] != null)
            _fila(
                'Pomo que antes se agota',
                '${b['autonomia_pomo_nombre']}: '
                '${b['autonomia_pomo_min']} días'),
          // 1.25 T94: la autonomía como MEDIDOR con
          // color (tope visual: 30 días). Verde >= 14,
          // ámbar 7-13, rojo < 7.
          if (b['autonomia_pomo_min'] != null)
            _barra(
              'Autonomía',
              fraccionAutonomiaPomo(
                  (b['autonomia_pomo_min'] as num?)?.toInt()),
              '${b['autonomia_pomo_min']} días',
              color: _colorNivelAutonomia(nivelAutonomiaPomo(
                  (b['autonomia_pomo_min'] as num?)?.toInt())),
            ),
        ],
      ),
    );
  }
}
