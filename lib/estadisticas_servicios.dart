/// v1.13.0 (Bloque 4, Estadísticas): cálculos PUROS de la vista de
/// Estadísticas de Servicios.
///
/// Reglas de Argón (ajuste 6):
/// - NUNCA dividir entre cero: con bote nuevo (0 vendidas) o solo
///   salidas Casa/mermas, punto de equilibrio y margen % devuelven
///   «pendiente» y la UI muestra «Pendiente de primeras ventas».
/// - Las agrupaciones truncan fechas explícitamente en America/Havana:
///   las ventas ya nacen con fecha Habana (hoyHabanaIso), así que el
///   día de semana se deriva de la fecha sin conversión de zona del
///   dispositivo (DateTime.utc evita el desplazamiento local).
/// - El agua se expresa en POMOS, nunca en litros.
/// - La franja horaria sale de la 'hora' HH:MM Habana que la venta
///   lleva en su payload desde la 1.13.0; las ventas viejas sin hora
///   caen en «Sin hora registrada», nunca se inventa una franja.
library;

/// Indicadores de un bote. [pendiente] = true cuando no hay ventas
/// comerciales todavía (0 vendidas, o solo Casa/mermas): la UI debe
/// mostrar «Pendiente de primeras ventas» en punto de equilibrio y
/// margen %, nunca NaN ni Infinity.
({bool pendiente, double? margenPct, double? puntoEquilibrioDosis})
    indicadoresBote({
  required double costoBote,
  required int rendimiento,
  required double ingresosComerciales,
  required int dosisComerciales,
  required double costosComerciales,
}) {
  if (dosisComerciales <= 0 || ingresosComerciales <= 0) {
    return (pendiente: true, margenPct: null, puntoEquilibrioDosis: null);
  }
  final margenPct =
      (ingresosComerciales - costosComerciales) / ingresosComerciales * 100;
  // Argón stats MEDIO 1 (equilibrio): el costo unitario efectivo es el
  // costo real por dosis (costos/dosis, que ya incluye el agua de los
  // combos tras el fix de costoBoteV). Usar solo costoBote/rendimiento
  // (polvo) dejaba el agua fuera y subestimaba el punto de equilibrio.
  // Sin costos registrados, se cae al costo del bote.
  final costoPorDosis = dosisComerciales > 0 && costosComerciales > 0
      ? costosComerciales / dosisComerciales
      : (rendimiento > 0 ? costoBote / rendimiento : 0.0);
  final precioMedio = ingresosComerciales / dosisComerciales;
  final denominador = precioMedio - costoPorDosis;
  final puntoEquilibrio =
      denominador > 0 ? costoBote / denominador : null;
  return (
    pendiente: false,
    margenPct: margenPct,
    puntoEquilibrioDosis: puntoEquilibrio,
  );
}

/// Día de semana (1 = lunes … 7 = domingo) de una fecha Habana
/// 'YYYY-MM-DD'. null si la fecha no parsea. PURO y determinista:
/// DateTime.utc no aplica la zona del dispositivo.
int? diaSemanaHabana(String? fecha) {
  if (fecha == null || fecha.length < 10) return null;
  final y = int.tryParse(fecha.substring(0, 4));
  final m = int.tryParse(fecha.substring(5, 7));
  final d = int.tryParse(fecha.substring(8, 10));
  if (y == null || m == null || d == null) return null;
  try {
    return DateTime.utc(y, m, d).weekday;
  } catch (_) {
    return null;
  }
}

const Map<int, String> kNombresDiaSemana = {
  1: 'Lunes',
  2: 'Martes',
  3: 'Miércoles',
  4: 'Jueves',
  5: 'Viernes',
  6: 'Sábado',
  7: 'Domingo',
};

/// Ventas agrupadas por día de semana: dosis e ingresos por día.
/// Solo ventas de dosis (no agua suelta) y sin Casa (precio 0).
/// Las filas sin fecha válida se ignoran (no se inventa un día).
Map<int, ({int dosis, double ingresos})> agruparPorDiaSemana(
    List<Map<String, dynamic>> ventas) {
  final out = <int, ({int dosis, double ingresos})>{};
  for (final v in ventas) {
    final tipo = '${v['tipo']}';
    if (!tipo.startsWith('dosis')) continue;
    if ((v['casa'] as num?)?.toInt() == 1) continue;
    final dia = diaSemanaHabana('${v['fecha'] ?? ''}');
    if (dia == null) continue;
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    final ing =
        ((v['precio_unitario'] as num?)?.toDouble() ?? 0) * cant;
    final prev = out[dia] ?? (dosis: 0, ingresos: 0.0);
    out[dia] = (dosis: prev.dosis + cant, ingresos: prev.ingresos + ing);
  }
  return out;
}

/// Franjas horarias Habana: madrugada 00–06, mañana 06–12,
/// tarde 12–18, noche 18–24. La hora sale de la 'hora' HH:MM Habana
/// del payload (1.13.0); sin ella, «sin_hora».
String franjaDeHora(String? hora) {
  // Corrección panel 1.13 (BAJO): validar el rango completo
  // HH:MM; antes «99:99» caía en «noche» y contaminaba las
  // estadísticas con filas espejadas o datos viejos inválidos.
  if (hora == null || hora.length < 5) return 'sin_hora';
  final h = int.tryParse(hora.substring(0, 2));
  final m = int.tryParse(hora.substring(3, 5));
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
    return 'sin_hora';
  }
  if (h < 6) return 'madrugada';
  if (h < 12) return 'manana';
  if (h < 18) return 'tarde';
  return 'noche';
}

const Map<String, String> kNombresFranja = {
  'madrugada': 'Madrugada (00–06)',
  'manana': 'Mañana (06–12)',
  'tarde': 'Tarde (12–18)',
  'noche': 'Noche (18–24)',
  'sin_hora': 'Sin hora registrada',
};

/// Ventas agrupadas por franja: dosis por franja (dosis comerciales,
/// sin Casa; el agua suelta no es dosis y no entra).
Map<String, int> agruparPorFranja(List<Map<String, dynamic>> ventas) {
  final out = <String, int>{};
  for (final v in ventas) {
    final tipo = '${v['tipo']}';
    if (!tipo.startsWith('dosis')) continue;
    if ((v['casa'] as num?)?.toInt() == 1) continue;
    final franja = franjaDeHora('${v['hora'] ?? ''}');
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    out[franja] = (out[franja] ?? 0) + cant;
  }
  return out;
}

/// Texto del resumen semanal I3 (semana cerrada Habana, lunes a
/// domingo). SOLO se genera al abrir Estadísticas y se copia con
/// J1; jamás se envía solo. PURO.
String textoResumenSemanal({
  required String lunes,
  required String domingo,
  required int dosis,
  required int pomosSueltos,
  required double ingresos,
  required double comisiones,
}) {
  String cup(double v) =>
      v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 2);
  return 'Iron Body Gym — Semana $lunes al $domingo\n'
      'Dosis vendidas: $dosis\n'
      'Pomos sueltos: $pomosSueltos\n'
      'Ingresos: ${cup(ingresos)} CUP\n'
      'Comisiones: ${cup(comisiones)} CUP';
}

/// Simulador B6 (hoja calculadora efímera, SOLO memoria): a partir
/// del costo del bote actual y dos precios deslizables, devuelve
/// costo por dosis y margen por dosis en cada variante. No toca BD.
({double costoPorDosis, double margenSinAgua, double margenConAgua})
    simularPrecios({
  required double costoBote,
  required int rendimiento,
  required double precioSinAgua,
  required double precioConAgua,
  // Argón stats MENOR: el margen con agua debe restar el pomo (~220);
  // sin esto el simulador decía 553 en vez de 333 por dosis.
  required double costoAgua,
}) {
  final costoPorDosis = rendimiento > 0 ? costoBote / rendimiento : 0.0;
  return (
    costoPorDosis: costoPorDosis,
    margenSinAgua: precioSinAgua - costoPorDosis,
    margenConAgua: precioConAgua - costoPorDosis - costoAgua,
  );
}

/// 1B Inversión y margen (PURO, testeable): agregados de la tarjeta
/// 1B de Estadísticas de Servicios a partir de los espejos.
///
/// Lote Stats (reporte de Jc 2026-10-28: la pantalla mostraba
/// inversión en botes 0, margen -2913 y neto -3311 con 8 dosis
/// vendidas a 600):
/// - Inversión en botes = Σ costo_bote de los botes. Antes leía
///   compras con claves tipo/costo que NO existen (la tabla trae
///   insumo/costo_unitario) y daba 0 aunque el bote costó 20800.
/// - Costo de dosis = dosis COMERCIALES × costo ACTUAL del bote
///   (costo_bote/rendimiento). Antes sumaba los snapshots de la
///   venta: las 2 primeras dosis llevaban 800 (de cuando el bote
///   figuraba a 48000) y mezclaban dos bases; y la Casa entraba
///   aquí y también en su línea propia (doble conteo).
/// - Costo de agua = solo comercial (la Casa va en casaCosto).
/// - Mermas = solo motivo 'merma'. Antes cualquier salida (incluso
///   agua del staff) se valorizaba como dosis.
/// - Margen medio y % con agua: solo dosis comerciales (la Casa no
///   es venta y distorsionaba ambos).
/// - Los agregados por bote (ingBote/dosisBote/costoBoteV) usan la
///   MISMA base que el costo, para que Margen % (indicadoresBote)
///   y Margen coincidan (antes el % excluía agua y mermas y el
///   Margen los incluía: 23.3 % frente a un margen negativo).
/// - nDosis: solo comerciales (alimenta la autonomía).
/// Devuelve el mapa 1B (sin autonomía/saldo, que son asíncronos y
/// los pone la pantalla) más los agregados por bote y nDosis.
({
  Map<String, dynamic> b,
  Map<int, double> ingBote,
  Map<int, int> dosisBote,
  Map<int, double> costoBoteV,
  int nDosis,
}) calcular1B({
  required List<Map<String, dynamic>> ventas,
  required List<Map<String, dynamic>> salidas,
  required List<Map<String, dynamic>> botes,
  required Map<int, int> boteDeLote,
  required List<Map<String, dynamic>> movsAgua,
}) {
  final costoDosisPorBote = <int, double>{};
  var inversionBotes = 0.0;
  for (final b in botes) {
    final id = (b['id'] as num?)?.toInt();
    if (id == null) continue;
    final rend = (b['dosis_rendimiento'] as num?)?.toInt() ?? 0;
    final costo = (b['costo_bote'] as num?)?.toDouble() ?? 0;
    costoDosisPorBote[id] = rend > 0 ? costo / rend : 0;
    inversionBotes += costo;
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
  // Argón stats MEDIO 1 (margen_medio): costo del agua SOLO de los
  // combos (no del agua suelta), para restarlo del margen por dosis.
  var costoAguaCombos = 0.0;
  var nDosis = 0, nConAgua = 0;
  final ingBote = <int, double>{};
  final dosisBote = <int, int>{};
  final costoBoteV = <int, double>{};
  for (final v in ventas) {
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    final precio = (v['precio_unitario'] as num?)?.toDouble() ?? 0;
    final esCasa = (v['casa'] as num?)?.toInt() == 1;
    final tipo = '${v['tipo']}';
    switch (tipo) {
      case 'dosis_sin_agua':
        // Terra stats MEDIO: la Casa sumaba en ingSin/ingCon (y por
        // tanto en ingresos y margen) si su precio era > 0, aunque
        // costo y dosis ya la excluían. Casa no es venta comercial:
        // fuera del ingreso también (solo casa_n/casa_costo).
        if (!esCasa) ingSin += precio * cant;
        if (!esCasa) nDosis += cant;
      case 'dosis_con_agua':
        if (!esCasa) ingCon += precio * cant;
        if (!esCasa) {
          nDosis += cant;
          nConAgua += cant;
        }
      case 'agua_suelta':
        // Sin variante Casa: el agua suelta siempre es comercial.
        ingAgua += precio * cant;
    }
    if (!esCasa && tipo.startsWith('dosis')) {
      final boteId = boteDeLote[(v['lote_id'] as num?)?.toInt()];
      // Panel Luna P2a: la Casa ya usaba el snapshot como respaldo;
      // la comercial huérfana (sin bote) quedaba a costo 0. Mismo
      // respaldo aquí: sin bote no hay costo actual que usar.
      final unit = costoDosisPorBote[boteId] ??
          ((v['costo_dosis_snapshot'] as num?)?.toDouble() ?? 0);
      costoDosis += unit * cant;
      // Argón stats MEDIO 1: el ingreso del combo (900) incluye el
      // pomo de agua; el costo del bote debe incluirlo también, o el
      // Margen % del bote trata el agua como ganancia pura del polvo.
      final aguaSnap = tipo == 'dosis_con_agua'
          ? ((v['costo_agua_snapshot'] as num?)?.toDouble() ?? 0)
          : 0.0;
      if (tipo == 'dosis_con_agua') costoAguaCombos += aguaSnap * cant;
      if (boteId != null) {
        ingBote[boteId] = (ingBote[boteId] ?? 0) + precio * cant;
        dosisBote[boteId] = (dosisBote[boteId] ?? 0) + cant;
        costoBoteV[boteId] =
            (costoBoteV[boteId] ?? 0) + (unit + aguaSnap) * cant;
      }
    }
    if (!esCasa) {
      costoAguaVendida +=
          ((v['costo_agua_snapshot'] as num?)?.toDouble() ?? 0) * cant;
      comision +=
          ((v['comision_unitaria'] as num?)?.toDouble() ?? 0) * cant;
    }
  }
  var mermasCosto = 0.0;
  for (final s in salidas) {
    if ('${s['motivo']}' != 'merma') continue;
    final boteId = boteDeLote[(s['lote_id'] as num?)?.toInt()];
    mermasCosto += ((s['dosis'] as num?)?.toDouble() ?? 0) *
        (costoDosisPorBote[boteId] ?? 0);
  }
  var casaCosto = 0.0, casaN = 0;
  for (final v in ventas) {
    if ((v['casa'] as num?)?.toInt() != 1) continue;
    final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
    casaN += cant;
    final boteId = boteDeLote[(v['lote_id'] as num?)?.toInt()];
    final unit = costoDosisPorBote[boteId] ??
        ((v['costo_dosis_snapshot'] as num?)?.toDouble() ?? 0);
    casaCosto += unit * cant +
        ((v['costo_agua_snapshot'] as num?)?.toDouble() ?? 0) * cant;
  }
  final ingresos = ingSin + ingCon + ingAgua;
  final costos = costoDosis + costoAguaVendida + mermasCosto;
  final margen = ingresos - costos;
  return (
    b: {
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
          ? (ingSin + ingCon - costoDosis - costoAguaCombos) / nDosis
          : 0.0,
      'pct_con_agua': nDosis > 0 ? (nConAgua * 100 / nDosis) : 0.0,
    },
    ingBote: ingBote,
    dosisBote: dosisBote,
    costoBoteV: costoBoteV,
    nDosis: nDosis,
  );
}

/// Días de operación desde la primera venta (modo 'todo' de
/// Estadísticas): el denominador de autonomía no puede ser 30 fijos
/// cuando hay más de un mes de historia (Argón stats MEDIO 2: con 30
/// fijos, dosisDia se infla y la autonomía se subestima).
/// PURO. Fechas ISO (YYYY-MM-DD o datetime); [hoy] en hora Habana.
int diasDesdePrimeraVenta(
    List<Map<String, dynamic>> ventas, DateTime hoy) {
  DateTime? primera;
  for (final v in ventas) {
    final f = DateTime.tryParse('${v['fecha'] ?? ''}');
    if (f != null && (primera == null || f.isBefore(primera))) {
      primera = f;
    }
  }
  if (primera == null) return 30;
  // Terra stats MEDIO: difference() mide periodos de 24 h, no días
  // calendario (una primera venta a las 23:00 contaba un día menos).
  // Se truncan ambas fechas a día calendario antes de restar.
  final inicio = DateTime(primera.year, primera.month, primera.day);
  final fin = DateTime(hoy.year, hoy.month, hoy.day);
  final dias = fin.difference(inicio).inDays + 1;
  return dias > 0 ? dias : 1;
}

/// Costo de la entrada de agua más reciente (simulador): el espejo
/// no garantiza orden, así que se elige por fecha y, ante empate,
/// por id. PURO. Terra stats MENOR: el bucle anterior tomaba la
/// última fila recibida, que no era necesariamente la más reciente.
/// Sin entradas devuelve 0.
double ultimaEntradaAguaCosto(List<Map<String, dynamic>> movs) {
  Map<String, dynamic>? mejor;
  for (final m in movs) {
    if ('${m['tipo']}' != 'entrada') continue;
    if (mejor == null) {
      mejor = m;
      continue;
    }
    final f = '${m['fecha'] ?? ''}';
    final mf = '${mejor['fecha'] ?? ''}';
    final id = (m['id'] as num?)?.toInt() ?? 0;
    final mid = (mejor['id'] as num?)?.toInt() ?? 0;
    if (f.compareTo(mf) > 0 || (f == mf && id > mid)) mejor = m;
  }
  return (mejor?['costo_unitario'] as num?)?.toDouble() ?? 0;
}

/// CSV para J2/J3 (exportar a CSV/Excel): escapado mínimo con
/// comillas cuando hace falta. PURO.
String csvEstadisticas(
    List<String> cabecera, List<List<String>> filas) {
  String esc(String s) {
    if (s.contains(',') || s.contains('"') || s.contains('\n')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  final sb = StringBuffer();
  sb.writeln(cabecera.map(esc).join(','));
  for (final f in filas) {
    sb.writeln(f.map(esc).join(','));
  }
  return sb.toString();
}
