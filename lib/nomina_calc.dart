import 'localdb.dart';
import 'tiempo.dart';

/// Cálculo de nómina compartido entre la pantalla de Nómina, la tarjeta
/// de Estadísticas Rápidas del home y el pre-cálculo automático.
///
/// Regla de negocio (Jc): la base es el número de clientes ÚNICOS que
/// pagaron en el mes (calendario Habana). Cada entrenador cobra
/// base × tarifa + bonos aplicables + comisión por dosis, menos
/// adelantos del mes y deuda arrastrada, con suelo 0
/// ([totalVivo]). La tarifa la define Jc
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
///
/// 1.19 (#2, #6 Argón nómina): el libro de adelantos suma los bonos
/// a la capacidad de cada mes (sin esto, un adelanto cubierto por
/// un bono generaba deuda fantasma); la llave de entrenador es
/// ÚNICA ([claveEntrenador]) en libro, comisiones y bonos, para
/// que ningún entrenador quede medio dentro y medio fuera.
class NominaCalc {
  /// Llave canónica de entrenador ('duany'/'gabriel') desde un
  /// nombre o username, o null si no es un entrenador conocido.
  /// #6 (Argón nómina): antes el libro filtraba username estricto
  /// y las comisiones se cubeteaban por nombre (contains): un
  /// username con apellido quedaba fuera del libro pero dentro de
  /// las comisiones. Una sola regla (contains, minúsculas) en los
  /// dos lados.
  static String? claveEntrenador(String? nombre) {
    final n = (nombre ?? '').toLowerCase();
    if (n.contains('duany')) return 'duany';
    if (n.contains('gabriel')) return 'gabriel';
    return null;
  }

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
      // Excepción del mes (ver la nota de la clase): se excluye
      // al cliente cuyo pagado_hasta cae en [pref]. 1.15 (M4c-01):
      // aplica a CUALQUIER mes, no solo al mes en curso: antes,
      // la base de un mes cerrado cambiaba al cruzar la medianoche
      // (la excepción dejaba de aplicarse y clientes excluidos
      // volvían a entrar, descuadrando la nómina ya liquidada).
      // Cliente sin fila en el espejo o sin fecha interpretable:
      // SE CONSERVA en el conteo (fallback ante sync incompleta;
      // panel 2026-10-21). Un error de lectura del espejo cae en
      // el catch y devuelve null, como cualquier otro error de
      // lectura.
      if (vistos.isNotEmpty) {
        final filas = await LocalDb.instance
            .mirrorPorIds('clientes', vistos.toList());
        // 1.15 (N1 + n7): el snapshot del pago manda sobre el espejo
        // actual; el espejo solo es fallback para pagos antiguos sin
        // snapshot. El id de la fila se parsea tolerante (n7): una
        // fila con id no interpretable se ignora sin abortar el
        // conjunto (antes un cast directo devolvía null para todo).
        final hastaPorId = hastaSnapshotPorCliente(mensuales, {
          for (final f in filas)
            if (idTolerante(f['id']) != null)
              idTolerante(f['id'])!: _fechaCalendario(f['pagado_hasta']),
        });
        excluirVencidosDentroDelMes(vistos, pref, hastaPorId);
      }
      return vistos;
    } catch (_) {
      return null;
    }
  }

  /// Parseo numérico tolerante (1.15, N3/N5): un número llegado
  /// como String por JSON ('2000', '2000.5') también vale; lo no
  /// interpretable es null, nunca una excepción.
  static double? montoTolerante(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  /// Parseo entero tolerante (1.15, n7/N5): num (10.0 → 10) o String
  /// ('10', '10.0'); lo no interpretable es null.
  static int? idTolerante(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) {
      final t = v.trim();
      final i = int.tryParse(t);
      if (i != null) return i;
      return double.tryParse(t)?.toInt();
    }
    return null;
  }

  /// PURO (testeable sin BD): ¿este pago del espejo `pagos`
  /// genera comisión de nómina? Fase A 2026-10-25 (A3, regla
  /// cerrada por Jc): SOLO las mensualidades.
  ///
  /// - `periodo == 'mensual'` → sí (mensual, menores y especiales
  ///   mensuales; el tipo_id no importa).
  /// - Sin `periodo` o `periodo == ''` → sí: el resto del código
  ///   usa 'mensual' como default del campo (1.15, N3: '' se
  ///   normaliza a mensual).
  /// - `personalizado` o `tipo:<id>` (ofertas) → solo si cubre
  ///   un mes o más (`dias >= 30`): una Oferta 50% a 30 días ES
  ///   una mensualidad; una personalizada de 15 días es una
  ///   quincena y NO genera. Sin `dias` interpretable → no (no
  ///   se puede probar cobertura mensual; el filtro debe ser
  ///   explícito, no por defecto).
  /// - `semanal`, `quincenal` y cualquier otro → no.
  ///
  /// 1.15 (N3): el filtro de promo y monto positivo se valida
  /// ANTES de ramificar, en TODAS las ramas (antes vivía solo en
  /// la mensual): una promo no genera comisión (mes gratis por
  /// la compra) y un cobro de 0 CUP tampoco (regalo, ajuste),
  /// tampoco en personalizados ni ofertas. El monto se parsea
  /// tolerante (num o String numérico).
  static bool esPagoMensualidad(Map<String, dynamic> p) {
    var periodo = '${p['periodo'] ?? 'mensual'}';
    if (periodo.isEmpty) periodo = 'mensual';
    if (p['metodo'] == 'promo') return false;
    final monto = montoTolerante(p['monto']);
    if (monto == null || monto <= 0) return false;
    if (periodo == 'mensual') return true;
    if (periodo == 'semanal' || periodo == 'quincenal') return false;
    if (periodo == 'personalizado' || periodo.startsWith('tipo:')) {
      final dias = idTolerante(p['dias']);
      return dias != null && dias >= 30;
    }
    return false;
  }

  /// PURO (1.15, N1): `pagado_hasta` de elegibilidad por cliente
  /// para el mes que se está contando.
  ///
  /// CONGELAMIENTO: el snapshot lo da el propio pago del mes
  /// (`pagado_hasta` que el cobro dejó calculado: el diálogo de
  /// pago lo incluye en el payload). Si un cliente tiene varios
  /// pagos mensuales en el mes, manda el snapshot MÁXIMO (la
  /// cobertura al cierre del mes, no la de un pago intermedio).
  /// Un pago posterior en otro mes NO entra en esta lista, así
  /// que no puede cambiar la base de un mes ya cerrado.
  ///
  /// FALLBACK EXPLÍCITO: pagos antiguos sin snapshot en su fila
  /// usan el `pagado_hasta` actual del espejo (comportamiento
  /// anterior). Límite documentado: para esos pagos viejos el
  /// congelamiento total exige que el servidor refleje el
  /// `pagado_hasta` del cobro en la fila del espejo `pagos` (o
  /// una columna snapshot local futura); mientras tanto, el
  /// fallback conserva la regla histórica y los tests vigentes.
  static Map<int, String?> hastaSnapshotPorCliente(
      List<Map<String, dynamic>> pagosDelMes,
      Map<int, String?> hastaEspejo) {
    final out = Map<int, String?>.from(hastaEspejo);
    final porCliente = <int, String>{};
    for (final p in pagosDelMes) {
      final id = idTolerante(p['cliente_id']);
      if (id == null) continue;
      final snap = _fechaCalendario(p['pagado_hasta']);
      if (snap == null) continue;
      final previo = porCliente[id];
      if (previo == null || snap.compareTo(previo) > 0) {
        porCliente[id] = snap;
      }
    }
    out.addAll(porCliente);
    return out;
  }

  /// PURO (testeable sin BD): ids únicos de cliente presentes en
  /// [pagos]. Numérico tolerante: un 10.0 llegado por JSON también
  /// es el cliente 10 (auditoría del código, DeepSeek); un id no
  /// interpretable se ignora.
  static Set<int> idsDesdePagos(List<Map<String, dynamic>> pagos) {
    final vistos = <int>{};
    for (final p in pagos) {
      final id = idTolerante(p['cliente_id']);
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
  /// mes — quita a quien tenga `pagado_hasta` dentro de [pref],
  /// según [hastaPorId] (id → fecha calendario 'YYYY-MM-DD'
  /// ya normalizada, o null si no es interpretable: ese se
  /// CONSERVA). 1.15 (M4c-01): vale para cualquier mes, no solo
  /// el mes en curso, para que la base de un mes cerrado no
  /// cambie al cruzar la medianoche.
  static void excluirVencidosDentroDelMes(
      Set<int> ids, String pref, Map<int, String?> hastaPorId) {
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
    // Panel Grupo B: igual que normalizarFechaCobro — tryParse
    // normaliza fechas imposibles; validar la parte fecha con
    // round-trip ANTES de convertir. Ojo: NO comparar con la fecha
    // convertida, que legítimamente puede diferir un día por offset.
    final parte = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v);
    if (parte == null) return null;
    final y = int.parse(parte.group(1)!);
    final mo = int.parse(parte.group(2)!);
    final d = int.parse(parte.group(3)!);
    final chk = DateTime.utc(y, mo, d);
    if (chk.year != y || chk.month != mo || chk.day != d) return null;
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
        // 1.15 (N5): monto tolerante (String numérico también vale).
        total += montoTolerante(b['monto']) ?? 0;
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
        // 1.15 (N5): monto tolerante (String numérico también vale).
        total += montoTolerante(b['monto']) ?? 0;
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

  /// Total VIVO de la fila de nómina (1.14, M5.1): base + bonos +
  /// comisión por dosis, menos adelantos del mes y deuda
  /// arrastrada; nunca negativo (el exceso queda como deuda en
  /// el libro, no como neto negativo). Es la fórmula que la
  /// pantalla de Nómina mostraba incrustada en el build.
  static double totalVivo({
    required double base,
    required double bono,
    required double comision,
    required double adelantos,
    required double deudaEntrante,
  }) {
    final total = base + bono + comision - adelantos - deudaEntrante;
    return total < 0 ? 0 : total;
  }

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
      // 1.15 (N4): mes en hora Habana, no substring crudo: un
      // ISO con hora en UTC puede pertenecer a otro día/mes en
      // Habana. Fecha no interpretable → se ignora la fila.
      final fechaCal = _fechaCalendario(v['fecha']);
      if (fechaCal == null || fechaCal.substring(0, 7) != pref) continue;
      // 1.15 (M4c-02): casa tolerante (1, true o '1'): un bool
      // llegado por JSON revienta el cast a num.
      final casa = v['casa'];
      if (casa == 1 || casa == true || casa == '1') continue;
      // 1.15 (N5): parseo tolerante en cantidad y comisiones.
      final cant = idTolerante(v['cantidad']) ?? 0;
      final com = montoTolerante(v['comision_unitaria']) ?? 0;
      // 1.15 (M4c-02): el monto snapshot manda: si es 0, no hay
      // comisión aunque la unitaria sea > 0 (antes la dosis se
      // contaba por la unitaria y el total por el monto, y podían
      // discrepar).
      // 1.15 (N5, reverso): cantidad negativa con snapshot
      // positivo → se RESTA el monto; si el snapshot ya es
      // negativo, se conserva ese signo. Sin snapshot, la
      // fórmula unitaria × cantidad ya da negativo sola.
      final snap = montoTolerante(v['comision_monto']);
      var montoCom = snap ?? com * cant;
      if (snap != null && cant < 0 && montoCom > 0) {
        montoCom = -montoCom;
      }
      if (montoCom != 0) dosis += cant;
      total += montoCom;
    }
    return (dosis: dosis, total: total);
  }

  /// Comisiones por dosis MES A MES (fix Argón post-1.15, MEDIO):
  /// el libro de adelantos arrastra deuda mes a mes, así que
  /// necesita la comisión de CADA mes, no solo la del mes en
  /// curso. Con solo el mes en curso, un mes anterior con
  /// adelantos por encima de su base pero cubiertos por sus
  /// dosis generaba una deuda entrante falsa en el mes actual.
  /// Puro sobre el espejo de ventas (misma función que el mes
  /// en curso). El avance de mes es local para no importar el
  /// libro de adelantos (DateTime normaliza dic→ene solo).
  static Map<String, double> comisionesPorMesDesdeVentas(
    List<Map<String, dynamic>> ventas,
    int telegramId,
    String primero,
    String hastaMes,
  ) {
    final out = <String, double>{};
    var mes = primero;
    while (mes.compareTo(hastaMes) <= 0) {
      out[mes] = comisionDosisDesdeVentas(ventas, telegramId, mes).total;
      mes = mesSiguiente(mes);
    }
    return out;
  }

  /// Nómina del dueño (fix 1.15, PURO): entrenadores a evaluar para
  /// la comisión = unión de quienes REGISTRARON ventas de servicios
  /// y quienes GANARON comisión (comision_entrenador_id). Sin la
  /// segunda pata, una venta registrada por el dueño a nombre de un
  /// entrenador nunca entraba en la iteración de la pantalla y su
  /// comisión no se calculaba (caso real 2026-10-27: 4 dosis de
  /// Duany registradas por Jc, 0 filas con registrado_por=Duany).
  /// Devuelve tid → nombre: de registrado_por_nombre, o de
  /// usuarios_apk cuando el tid solo ganó comisión (o el nombre
  /// registrado venía vacío); '' si no se conoce el nombre (el
  /// tid igual se itera: el cálculo por tid no depende del nombre,
  /// solo el mapeo a la cubeta duany/gabriel de la pantalla).
  static Map<int, String> tidsConComisionServicio(
      List<Map<String, dynamic>> ventasServ,
      List<Map<String, dynamic>> usuariosApk) {
    final nombres = <int, String>{};
    for (final v in ventasServ) {
      final tid = LocalDb.normalizarTelegramId(v['registrado_por']);
      if (tid != null) {
        nombres.putIfAbsent(
            tid, () => '${v['registrado_por_nombre'] ?? ''}');
      }
      final earn =
          LocalDb.normalizarTelegramId(v['comision_entrenador_id']);
      if (earn != null) nombres.putIfAbsent(earn, () => '');
    }
    for (final u in usuariosApk) {
      final tid = LocalDb.normalizarTelegramId(u['telegram_id']);
      if (tid != null &&
          nombres.containsKey(tid) &&
          nombres[tid]!.isEmpty) {
        final nombre = '${u['nombre'] ?? u['username'] ?? ''}';
        if (nombre.isNotEmpty) nombres[tid] = nombre;
      }
    }
    return nombres;
  }
}
