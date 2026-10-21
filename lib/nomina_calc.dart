import 'localdb.dart';
import 'tiempo.dart';

/// Cálculo de nómina compartido entre la pantalla de Nómina, la tarjeta
/// de Estadísticas Rápidas del home y el pre-cálculo automático.
///
/// Regla de negocio (Jc): la base es el número de clientes ÚNICOS que
/// pagaron en el mes (calendario Habana). Cada entrenador cobra
/// base × tarifa + bonos aplicables. La tarifa la define Jc
/// (PerfilService.getPagoEntrenador; 150 CUP por defecto).
///
/// Excepción del MES EN CURSO (Jc, 2026-10-21): un cliente cuyo
/// `pagado_hasta` cae DENTRO del propio mes en curso NO entra en la
/// base de ese mes (ese pago todavía no corresponde a la nómina del
/// mes; p. ej. un semanal pagado el 13 que vence el 20). La excepción
/// NO se aplica a meses pasados: el `pagado_hasta` actual no
/// reconstruye la cobertura que el cliente tenía al cierre de un mes
/// anterior, así que los meses cerrados conservan la regla histórica
/// (panel de revisión 2026-10-21).
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
  static Future<int> clientesQuePagaronElMes(String pref) async =>
      (await _contar(pref)) ?? 0;

  /// Igual que [clientesQuePagaronElMes] pero distingue el "0 real"
  /// (nadie pagó) de un error de lectura (null). La usa el
  /// pre-cálculo para NO persistir un 0 nacido de un error como si
  /// fuera una caché fresca (auditoría del código, DeepSeek).
  static Future<int?> clientesQuePagaronElMesSeguro(String pref) =>
      _contar(pref);

  static Future<int?> _contar(String pref) async {
    try {
      final pagos = await LocalDb.instance.pagosDelMes(pref);
      final vistos = <int>{};
      for (final p in pagos) {
        final cid = p['cliente_id'];
        // Numérico tolerante: un 10.0 llegado por JSON también es el
        // cliente 10 (auditoría del código, DeepSeek).
        final id = cid is num ? cid.toInt() : int.tryParse('$cid');
        if (id != null) vistos.add(id);
      }
      // Excepción del mes en curso (ver la nota de la clase): se
      // excluye al cliente cuyo pagado_hasta cae en
      // [inicioMes, inicioMesSiguiente). Cliente sin fila en el
      // espejo o sin fecha interpretable: SE CONSERVA en el conteo
      // (fallback ante sync incompleta; panel 2026-10-21). Un error
      // de lectura del espejo cae en el catch y devuelve null, como
      // cualquier otro error de lectura.
      if (vistos.isNotEmpty && pref == prefMesActual()) {
        final filas = await LocalDb.instance
            .mirrorPorIds('clientes', vistos.toList());
        final hastaPorId = <int, String?>{
          for (final f in filas)
            (f['id'] as num).toInt(): _fechaCalendario(f['pagado_hasta']),
        };
        final inicio = '$pref-01';
        final siguiente = _inicioMesSiguiente(pref);
        vistos.removeWhere((id) {
          final h = hastaPorId[id];
          if (h == null) return false;
          return h.compareTo(inicio) >= 0 && h.compareTo(siguiente) < 0;
        });
      }
      return vistos.length;
    } catch (_) {
      return null;
    }
  }

  /// Primer día del mes siguiente a [pref] ('YYYY-MM') como
  /// 'YYYY-MM-DD'.
  static String _inicioMesSiguiente(String pref) {
    final y = int.parse(pref.substring(0, 4));
    final m = int.parse(pref.substring(5, 7));
    final ny = m == 12 ? y + 1 : y;
    final nm = m == 12 ? 1 : m + 1;
    return '${ny.toString().padLeft(4, '0')}-${nm.toString().padLeft(2, '0')}-01';
  }

  /// Fecha calendario 'YYYY-MM-DD' de un `pagado_hasta` del espejo.
  /// El dato verificado en producción es texto 'YYYY-MM-DD'; si
  /// llegara con hora (ISO), la fecha se toma en hora de Habana.
  /// Devuelve null si no se puede interpretar.
  static String? _fechaCalendario(dynamic v) {
    if (v is! String || v.isEmpty) return null;
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v);
    if (m != null) {
      // La fecha debe EXISTIR (ronda 2, Terra): el formato solo
      // no basta — '2026-02-30' pasaría el regex y caería dentro
      // del intervalo del mes, excluyendo a un cliente que la
      // regla manda conservar ante datos no interpretables.
      // DateTime normaliza el desborde (30 feb → 2 mar); si no
      // reproduce año/mes/día exactos, no es interpretable.
      final y = int.parse(m.group(1)!);
      final mo = int.parse(m.group(2)!);
      final d = int.parse(m.group(3)!);
      final dt = DateTime.utc(y, mo, d);
      if (dt.year != y || dt.month != mo || dt.day != d) return null;
      return v;
    }
    final dt = DateTime.tryParse(v);
    if (dt == null) return null;
    return isoHabana(aHabana(dt)).substring(0, 10);
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
