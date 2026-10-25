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
  final costoPorDosis = rendimiento > 0 ? costoBote / rendimiento : 0.0;
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
  if (hora == null || hora.length < 2) return 'sin_hora';
  final h = int.tryParse(hora.substring(0, 2));
  if (h == null) return 'sin_hora';
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
}) {
  final costoPorDosis = rendimiento > 0 ? costoBote / rendimiento : 0.0;
  return (
    costoPorDosis: costoPorDosis,
    margenSinAgua: precioSinAgua - costoPorDosis,
    margenConAgua: precioConAgua - costoPorDosis,
  );
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
