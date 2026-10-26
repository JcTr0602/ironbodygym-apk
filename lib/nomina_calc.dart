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
/// Fase A 2026-10-25 (A3, regla cerrada por Jc): SOLO las
/// mensualidades generan los 150 CUP. Semanas, quincenas y diarios
/// NO generan comisión (los diarios ni siquiera viven en `pagos`).
/// El filtro es explícito por tipo de pago ([esPagoMensualidad]),
/// no por `pagado_hasta`: un cliente que solo pagó semanal en un
/// mes cerrado contaba antes y ya no cuenta.
///
/// Excepción del MES EN CURSO (Jc, 2026-10-21): un cliente cuyo
/// `pagado_hasta` cae DENTRO del propio mes en curso NO entra en la
/// base de ese mes (ese pago todavía no corresponde a la nómina del
/// mes; p. ej. un semanal pagado el 13 que vence el 20). La excepción
/// NO se aplica a meses pasados: el `pagado_hasta` actual no
/// reconstruye la cobertura que el cliente tenía al cierre de un mes
/// anterior, así que los meses cerrados conservan la regla histórica
/// (panel de revisión 2026-10-21). La excepción se aplica DESPUÉS
/// del filtro de tipo: nunca se usa como filtro de tipo.
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
    final ids = await _conjunto(pref);
    return ids?.length;
  }

  /// IDs de los clientes que forman la base del mes [pref]:
  /// EXACTAMENTE el mismo conjunto que cuenta
  /// [clientesQuePagaronElMes] (ambos salen de [_conjunto]), para
  /// que el listado «Pagaron este mes» y la cifra de Home nunca
  /// discrepen. Ante un error de lectura devuelve lista vacía, como
  /// el contador devuelve 0.
  static Future<List<int>> idsQuePagaronElMes(String pref) async =>
      (await _conjunto(pref))?.toList() ?? <int>[];

  /// El conjunto de la base del mes [pref], o null si la lectura
  /// falló (para distinguir el "0 real" de un error).
  static Future<Set<int>?> _conjunto(String pref) async {
    try {
      final pagos = await LocalDb.instance.pagosDelMes(pref);
      // Fase A 2026-10-25 (A3): la base solo cuenta mensualidades.
      // El filtro va ANTES de cualquier otra exclusión (Casa, mes
      // en curso): semanas/quincenas/personalizados cortos no
      // generan comisión aunque el cliente no sea Casa ni esté
      // en la excepción del mes en curso.
      final mensuales = [
        for (final p in pagos)
          if (esPagoMensualidad(p)) p,
      ];
      final vistos = idsDesdePagos(mensuales);
      // v1.7.0 (Argón, separación estricta): la contabilidad
      // filtra cuenta_casa=0. Una Cuenta a la Casa no genera los
      // 150 CUP ni entra en «pagaron el mes» aunque tenga un pago
      // suelto registrado (permitido pero inútil, diseño Casa §4).
      if (vistos.isNotEmpty) {
        excluirCuentasCasa(
            vistos, await LocalDb.instance.idsCuentasCasa());
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
        excluirVencidosDentroDelMes(vistos, pref, hastaPorId);
      }
      return vistos;
    } catch (_) {
      return null;
    }
  }

  /// PURO (testeable sin BD): ¿este pago del espejo `pagos`
  /// genera comisión de nómina? Fase A 2026-10-25 (A3, regla
  /// cerrada por Jc): SOLO las mensualidades.
  ///
  /// - `periodo == 'mensual'` → sí (mensual, menores y especiales
  ///   mensuales; el tipo_id no importa).
  /// - Sin `periodo` → sí: el resto del código usa 'mensual'
  ///   como default del campo (etiquetaPeriodo, payloads de cobro).
  /// - `personalizado` o `tipo:<id>` (ofertas) → solo si cubre
  ///   un mes o más (`dias >= 30`): una Oferta 50% a 30 días ES
  ///   una mensualidad; una personalizada de 15 días es una
  ///   quincena y NO genera. Sin `dias` interpretable → no (no
  ///   se puede probar cobertura mensual; el filtro debe ser
  ///   explícito, no por defecto).
  /// - `semanal`, `quincenal` y cualquier otro → no.
  static bool esPagoMensualidad(Map<String, dynamic> p) {
    final periodo = '${p['periodo'] ?? 'mensual'}';
    if (periodo == 'mensual') return true;
    if (periodo == 'semanal' || periodo == 'quincenal') return false;
    if (periodo == 'personalizado' || periodo.startsWith('tipo:')) {
      final dias = (p['dias'] as num?)?.toInt();
      return dias != null && dias >= 30;
    }
    return false;
  }

  /// PURO (testeable sin BD): ids únicos de cliente presentes en
  /// [pagos]. Numérico tolerante: un 10.0 llegado por JSON también
  /// es el cliente 10 (auditoría del código, DeepSeek); un id no
  /// interpretable se ignora.
  static Set<int> idsDesdePagos(List<Map<String, dynamic>> pagos) {
    final vistos = <int>{};
    for (final p in pagos) {
      final cid = p['cliente_id'];
      final id = cid is num ? cid.toInt() : int.tryParse('$cid');
      if (id != null) vistos.add(id);
    }
    return vistos;
  }

  /// PURO (testeable sin BD): quita de [ids] a las Cuentas a la
  /// Casa (v1.7.0). La nómina y «pagaron el mes» comparten este
  /// conjunto, así que la exclusión vale para cifra y listado a
  /// la vez. Un id sin fila Casa en [casaIds] se conserva.
  static void excluirCuentasCasa(Set<int> ids, Set<int> casaIds) {
    if (casaIds.isEmpty) return;
    ids.removeAll(casaIds);
  }

  /// PURO (testeable sin BD): aplica sobre [ids] la excepción del
  /// mes en curso — quita a quien tenga `pagado_hasta` dentro de
  /// [pref], según [hastaPorId] (id → fecha calendario 'YYYY-MM-DD'
  /// ya normalizada, o null si no es interpretable: ese se
  /// CONSERVA). Si [pref] no es el mes en curso, no toca nada.
  static void excluirVencidosDentroDelMes(
      Set<int> ids, String pref, Map<int, String?> hastaPorId) {
    if (pref != prefMesActual()) return;
    final inicio = '$pref-01';
    final siguiente = _inicioMesSiguiente(pref);
    ids.removeWhere((id) {
      final h = hastaPorId[id];
      if (h == null) return false;
      return h.compareTo(inicio) >= 0 && h.compareTo(siguiente) < 0;
    });
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

  /// v1.8.0 (diseño dosis, Argón E-integración): comisión por dosis
  /// de un entrenador en el mes [pref] ('YYYY-MM'), desde el espejo
  /// de ventas de servicios. PURO. La comisión ya viene SNAPSOTEADA
  /// en cada fila (comision_unitaria) y es 0 en agua suelta, en
  /// ventas del dueño y en Casa por construcción; los reversos
  /// llevan cantidad negativa y netan solos. Regla de reverso de
  /// Argón: un reverso POSTERIOR al pago de la nómina resta en el
  /// mes EN CURSO — eso sale gratis de esta función, porque el
  /// reverso se fecha en el mes en que ocurre, no en el de la venta.
  /// Devuelve (dosis netas con comisión, total CUP).
  static ({int dosis, double total}) comisionDosisDesdeVentas(
      List<Map<String, dynamic>> ventas, int telegramId, String pref) {
    var dosis = 0;
    var total = 0.0;
    for (final v in ventas) {
      // Ítem 8: la comisión es de quien la GANÓ (comision_entrenador
      // _id), no de quien registró; sin la columna (filas previas)
      // recae en registrado_por. El monto snapshot manda cuando
      // está (el dueño pudo fijar otra comisión para esa venta);
      // si no, unitaria × cantidad (el reverso netea por su
      // cantidad negativa).
      final duenoComision =
          LocalDb.normalizarTelegramId(v['comision_entrenador_id']) ??
              LocalDb.normalizarTelegramId(v['registrado_por']);
      if (duenoComision != telegramId) {
        continue;
      }
      final f = '${v['fecha'] ?? ''}';
      if (f.length < 7 || f.substring(0, 7) != pref) continue;
      if ((v['casa'] as num?)?.toInt() == 1) continue;
      final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
      final com = (v['comision_unitaria'] as num?)?.toDouble() ?? 0;
      if (com > 0) dosis += cant;
      total += (v['comision_monto'] as num?)?.toDouble() ?? com * cant;
    }
    return (dosis: dosis, total: total);
  }
}
