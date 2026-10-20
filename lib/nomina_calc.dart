import 'localdb.dart';
import 'tiempo.dart';

/// Cálculo de nómina compartido entre la pantalla de Nómina, la tarjeta
/// de Estadísticas Rápidas del home y el pre-cálculo automático.
///
/// Regla de negocio (Jc): la base es el número de clientes ÚNICOS que
/// pagaron en el mes (calendario Habana). Cada entrenador cobra
/// base × tarifa + bonos aplicables. La tarifa la define Jc
/// (PerfilService.getPagoEntrenador; 150 CUP por defecto).
class NominaCalc {
  /// Prefijo del mes Habana en curso: 'YYYY-MM'.
  static String prefMesActual() => hoyHabanaIso().substring(0, 7);

  /// Clientes únicos con al menos un pago registrado en el mes [pref].
  ///
  /// Misma fuente histórica de la pantalla de Nómina: la tabla espejo
  /// `pagos` vía [LocalDb.pagosDelMes], deduplicando por cliente_id
  /// (un cliente que paga dos veces en el mes cuenta UNA vez).
  /// Ante un error de lectura devuelve 0 (la pantalla muestra la base
  /// en 0 en vez de romperse, como hacía el cálculo original).
  static Future<int> clientesQuePagaronElMes(String pref) async {
    try {
      final pagos = await LocalDb.instance.pagosDelMes(pref);
      final vistos = <int>{};
      for (final p in pagos) {
        final cid = p['cliente_id'];
        final id = cid is int ? cid : int.tryParse('$cid');
        if (id != null) vistos.add(id);
      }
      return vistos.length;
    } catch (_) {
      return 0;
    }
  }

  /// Suma de bonos aplicables a [entrenador]: los generales ('ambos')
  /// más los dirigidos a ese entrenador. [bonos] es la lista guardada
  /// en preferencias (clave nomina_bonos_YYYY_M).
  static double bonosPara(
      List<Map<String, dynamic>> bonos, String entrenador) {
    double total = 0;
    for (final b in bonos) {
      final para = '${b['entrenador'] ?? 'ambos'}';
      if (para == 'ambos' || para == entrenador) {
        total += (b['monto'] as num?)?.toDouble() ?? 0;
      }
    }
    return total;
  }

  /// Suma solo los bonos generales ('ambos'), contados una vez.
  /// Respaldo defensivo cuando no se puede identificar al entrenador.
  static double bonoSoloAmbos(List<Map<String, dynamic>> bonos) {
    double total = 0;
    for (final b in bonos) {
      final para = '${b['entrenador'] ?? 'ambos'}';
      if (para == 'ambos') {
        total += (b['monto'] as num?)?.toDouble() ?? 0;
      }
    }
    return total;
  }

  /// Total de nómina de un entrenador: base × tarifa + bonos.
  static double totalEntrenador({
    required int baseClientes,
    required double tarifa,
    required double bonos,
  }) =>
      baseClientes * tarifa + bonos;
}
