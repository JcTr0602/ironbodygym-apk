import 'adelantos.dart';
import 'nomina_calc.dart';
import 'nomina_foto.dart';
import 'nomina_precalc.dart';

/// Total neto a pagar a los entrenadores (post-1.15, fix principal).
///
/// ANTES la principal mostraba `pagaron × 300` (150 por entrenador × 2):
/// el BRUTO, sin descontar adelantos ni sumar comisiones por dosis.
/// Eso no es «lo que hay que pagarles»: el neto real es la suma de
/// las filas de la pantalla de Nómina, y esta es la ÚNICA fuente
/// para esa cifra en la principal.
///
/// La función pura [totalNetoNomina] replica EXACTAMENTE la fórmula
/// de las filas de Nómina ([NominaCalc.totalVivo] por entrenador):
/// base + bono + comisión por dosis − adelantos del mes − deuda
/// arrastrada, con suelo 0 por entrenador. Los bonos usan
/// [NominaCalc.bonosPara] ('ambos' cuenta para los dos). Si un
/// entrenador no tiene fila en [libroMes], sus adelantos y su deuda
/// son 0, igual que en la pantalla.
///
/// El wrapper [totalNetoNominaMes] (1.28, M3-A4) ya no
/// ensambla insumos propios: delega en la foto compartida de
/// nomina_foto.dart ([fotoNominaMes] + [netoTotalDueno]), la
/// misma que consumen la pantalla de Nómina y el Panel, y
/// devuelve null si la foto está incompleta: la llamadora
/// conserva entonces el valor anterior en vez de mostrar un
/// neto inventado. La función pura [totalNetoNomina] se
/// conserva como réplica testeable de la fórmula por
/// entrenador (sin la exclusión de liquidados, que vive en
/// netoTotalDueno).
double totalNetoNomina({
  required double base,
  required List<Map<String, dynamic>> bonos,
  required Map<String, ({int dosis, double total})> comisionDosis,
  required Map<String, MesLibroAdelantos> libroMes,
}) {
  var total = 0.0;
  for (final ent in const ['duany', 'gabriel']) {
    final libro = libroMes[ent];
    total += NominaCalc.totalVivo(
      base: base,
      bono: NominaCalc.bonosPara(bonos, ent),
      comision: comisionDosis[ent]?.total ?? 0,
      adelantos: libro?.adelantos ?? 0,
      deudaEntrante: libro?.deudaEntrante ?? 0,
    );
  }
  return total;
}

/// 1.28 (M3-A4): el «a pagar» de Home y Dashboard sale de la
/// MISMA foto que usan la pantalla de Nómina y el Panel
/// ([fotoNominaMes] + [netoTotalDueno]). Antes esta función
/// ensamblaba sus propios insumos en paralelo a la foto, con
/// DOS divergencias reales: no excluía a los entrenadores ya
/// LIQUIDADOS (Home/Dashboard decían «a pagar» un dinero ya
/// pagado, mientras el Panel —que sí usa la foto— decía otra
/// cifra) y llamaba a NominaCalc.clientesQuePagaronElMes
/// directamente tras asegurar() el precálculo, DESCARTANDO el
/// conteo asegurado que la pantalla sí usa. Ahora hay una
/// sola definición: foto compartida (con su guardia de
/// huella), conteo del precálculo y bonos por el camino con
/// migración — exactamente lo que compone el Panel.
/// Devuelve null si la foto está incompleta: la llamadora
/// conserva el valor anterior, nunca muestra un neto
/// inventado (misma regla que ya tenía el Panel).
Future<double?> totalNetoNominaMes(String pref) async {
  try {
    final foto = await fotoNominaMes(pref);
    final pagaron = await NominaPrecalc.instance.asegurar(pref);
    final bonos = await leerBonosMesConMigracion(pref);
    return netoTotalDueno(foto, clientesPagados: pagaron, bonos: bonos);
  } catch (_) {
    return null;
  }
}
