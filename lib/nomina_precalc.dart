import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'localdb.dart';
import 'nomina_calc.dart';
import 'tiempo.dart';

/// Pre-cálculo automático de la base de nómina (v1.4.0).
///
/// Lo único caro de la nómina es contar los clientes únicos que
/// pagaron el mes (escaneo del espejo `pagos`). Ese conteo se cachea
/// en la tabla local `nomina_precalc` junto con una HUELLA de los
/// insumos. Los bonos y la tarifa NO se cachean: los bonos viven
/// en gym.db sincronizado (Fase A 2026-10-25, A4) y la tarifa en
/// el perfil; se leen siempre en vivo al componer el total, así
/// un bono recién guardado se refleja al instante.
///
/// Frescura: la huella se recalcula al leer; si no coincide con la
/// guardada, la caché se considera vieja y se recalcula. La huella
/// cubre cambios locales (ops sin subir) y remotos (pull), porque se
/// deriva del estado real de las tablas espejo, no de eventos.
///
/// Huella v2 (2026-10-21): además de `pagos`, cubre los
/// `pagado_hasta` de la tabla espejo `clientes`, porque la regla del
/// mes en curso (ver NominaCalc) depende de ellos: un cambio de
/// vencimiento sin ningún pago nuevo también debe invalidar la
/// caché. El prefijo 'v2|' invalida por sí solo toda caché escrita
/// con la huella v1 (panel de revisión 2026-10-21).
///
/// Huella v3 (ronda 2, mismo día): el componente de clientes pasó
/// de sumas agregadas a un hash canónico por cliente (las sumas
/// colisionaban con exclusiones opuestas). El prefijo 'v3|'
/// invalida toda caché v2.
class NominaPrecalc {
  NominaPrecalc._();
  static final NominaPrecalc instance = NominaPrecalc._();

  final _enCurso = <String, Future<int>>{};

  /// Huella de los insumos de nómina sobre la tabla espejo `pagos`.
  /// COUNT + SUM(sync_seq) + SUM(cliente_id) + MAX(id) detectan
  /// altas, bajas, ediciones que llegan por pull (nuevo sync_seq) y
  /// ops locales aplicadas al espejo (nuevo id). SUM(epoch(fecha))
  /// detecta además que un pago se mueva de mes (auditoría del
  /// código, terra: una edición local solo de fecha no tocaba
  /// ninguno de los otros componentes). Las filas con fecha NULL
  /// (camino de fallback de pagosDelMes) quedan cubiertas por su
  /// conteo y la suma de sus ids.
  Future<String> huella() async {
    final d = await LocalDb.instance.db;
    final rows = await d.rawQuery(
        'SELECT COUNT(*) AS c, COALESCE(SUM(sync_seq), 0) AS ss, '
        'COALESCE(SUM(cliente_id), 0) AS sc, COALESCE(MAX(id), 0) AS mi, '
        "COALESCE(SUM(CAST(strftime('%s', fecha) AS INTEGER)), 0) AS sf, "
        '(SELECT COUNT(*) FROM pagos WHERE fecha IS NULL) AS cn, '
        '(SELECT COALESCE(SUM(id), 0) FROM pagos WHERE fecha IS NULL) AS sn '
        'FROM pagos');
    final r = rows.first;
    final pagosParte =
        '${r['c']}|${r['ss']}|${r['sc']}|${r['mi']}|${r['sf']}|${r['cn']}|${r['sn']}';
    // v5 (1.19, #4 Argón nómina): la huella de pagos ahora incluye
    // pagado_hasta: sin él, un cambio de cobertura no invalidaba
    // la caché y la nómina servía el conteo viejo. El prefijo
    // nuevo invalida de una vez toda caché v4.
    // v6 (1.28, M3-A11): los componentes por fila extraen los
    // campos de negocio en SQL (json_extract) en vez de
    // DECODIFICAR el JSON de cada pago/cliente (ver abajo).
    return 'v6|$pagosParte|${await _huellaPagosNegocio()}|${await _huellaClientes()}';
  }

  // ----------------------------------------------------------
  // 1.28 (M3-A11) · Huella por extracción selectiva en SQL.
  //
  // La huella v5 DECODIFICABA en Dart el JSON de cada pago y
  // cada cliente para extraer los campos de negocio, y
  // [huella] se paga varias veces por asegurar() (leer + hasta
  // 3 intentos de _recalcular × 2 componentes): con el
  // historial crecido era el coste dominante del precálculo.
  // Ahora UNA consulta con json_extract trae SOLO los campos
  // de negocio como columnas primitivas — el espejo entero ya
  // no se decodifica — y la tupla canónica se arma en Dart con
  // las mismas reglas v5: (a) solo campos de negocio (un campo
  // ajeno, p. ej. registrado_por, NO invalida); (b)
  // representaciones equivalentes dan la misma huella (1 y
  // «1» cuentan igual; 2000 y «2000» también); (c) la huella
  // por fila sigue siendo canónica y ordenada por id, así que
  // la colisión por sumas que cazó Terra en la ronda 2 no
  // vuelve. El prefijo v6 invalida de una vez las cachés v5
  // (la FORMA de la tupla cambió aunque el contrato no).
  // ----------------------------------------------------------

  /// Canoniza un número tolerante: 2000, 2000.0 y «2000» dan
  /// la misma pieza; lo no numérico pasa como texto.
  static String _canonNum(dynamic v) {
    if (v == null) return '';
    if (v is num) {
      return v == v.roundToDouble()
          ? v.toInt().toString()
          : v.toString();
    }
    final n = num.tryParse('$v'.trim());
    if (n != null) {
      return n == n.roundToDouble()
          ? n.toInt().toString()
          : n.toString();
    }
    return '$v';
  }

  static String _canonInt(dynamic v) =>
      NominaCalc.idTolerante(v)?.toString() ?? (v == null ? '' : '$v');

  static String _canonStr(dynamic v) => v == null ? '' : '$v';

  /// Bandera tolerante 0/1 (cuenta_casa, anulado): 1, true y
  /// «1» son la misma representación.
  static String _canonFlag(dynamic v) =>
      (v == 1 || v == true || v == '1') ? '1' : '0';

  static String _tuplaPago({
    required dynamic id,
    required dynamic clienteId,
    required dynamic fecha,
    required dynamic periodo,
    required dynamic dias,
    required dynamic metodo,
    required dynamic monto,
    required dynamic pagadoHasta,
    required dynamic anulado,
  }) =>
      '${_canonInt(id)}:${_canonInt(clienteId)}:${_canonStr(fecha)}:'
      '${_canonStr(periodo)}:${_canonInt(dias)}:${_canonStr(metodo)}:'
      '${_canonNum(monto)}:${_canonStr(pagadoHasta)}:${_canonFlag(anulado)}';

  static String _tuplaCliente({
    required dynamic id,
    required dynamic estado,
    required dynamic pagadoHasta,
    required dynamic cuentaCasa,
  }) =>
      '${_canonInt(id)}:${_canonStr(estado)}:${_canonStr(pagadoHasta)}:'
      '${_canonFlag(cuentaCasa)}';

  /// Componente de huella sobre el espejo `pagos` (solo los
  /// campos que el conteo de NominaCalc lee).
  Future<String> _huellaPagosNegocio() async {
    final d = await LocalDb.instance.db;
    try {
      final rows = await d.rawQuery('''
        SELECT id,
          json_extract(data, '\$.cliente_id') AS cid,
          json_extract(data, '\$.fecha') AS fecha,
          json_extract(data, '\$.periodo') AS periodo,
          json_extract(data, '\$.dias') AS dias,
          json_extract(data, '\$.metodo') AS metodo,
          json_extract(data, '\$.monto') AS monto,
          json_extract(data, '\$.pagado_hasta') AS ph,
          json_extract(data, '\$.anulado') AS anulado
        FROM pagos ORDER BY id''');
      final partes = <String>[
        for (final r in rows)
          _tuplaPago(
            id: r['id'],
            clienteId: r['cid'],
            fecha: r['fecha'],
            periodo: r['periodo'],
            dias: r['dias'],
            metodo: r['metodo'],
            monto: r['monto'],
            pagadoHasta: r['ph'],
            anulado: r['anulado'],
          ),
      ];
      return 'p${partes.length}:${_fnv1a64(partes.join('|'))}';
    } catch (_) {
      // Sin JSON1 (no esperado: media app lo usa): decodificar
      // y armar LAS MISMAS tuplas — la huella no cambia de
      // forma entre caminos.
      final espejo = await LocalDb.instance.allMirror('pagos');
      final partes = <String>[
        for (final p in espejo)
          _tuplaPago(
            id: p['id'],
            clienteId: p['cliente_id'],
            fecha: p['fecha'],
            periodo: p['periodo'],
            dias: p['dias'],
            metodo: p['metodo'],
            monto: p['monto'],
            pagadoHasta: p['pagado_hasta'],
            anulado: p['anulado'],
          ),
      ];
      partes.sort();
      return 'p${partes.length}:${_fnv1a64(partes.join('|'))}';
    }
  }

  /// Componente de huella sobre el espejo `clientes` (estado,
  /// cobertura y Cuenta a la Casa: lo que el conteo lee).
  Future<String> _huellaClientes() async {
    final d = await LocalDb.instance.db;
    try {
      final rows = await d.rawQuery('''
        SELECT id,
          json_extract(data, '\$.estado') AS estado,
          json_extract(data, '\$.pagado_hasta') AS ph,
          json_extract(data, '\$.cuenta_casa') AS casa
        FROM clientes ORDER BY id''');
      final partes = <String>[
        for (final r in rows)
          _tuplaCliente(
            id: r['id'],
            estado: r['estado'],
            pagadoHasta: r['ph'],
            cuentaCasa: r['casa'],
          ),
      ];
      return 'c${partes.length}:${_fnv1a64(partes.join('|'))}';
    } catch (_) {
      final espejo = await LocalDb.instance.allMirror('clientes');
      final partes = <String>[
        for (final c in espejo)
          _tuplaCliente(
            id: c['id'],
            estado: c['estado'],
            pagadoHasta: c['pagado_hasta'],
            cuentaCasa: c['cuenta_casa'],
          ),
      ];
      partes.sort();
      return 'c${partes.length}:${_fnv1a64(partes.join('|'))}';
    }
  }

  /// FNV-1a de 64 bits sobre UTF-8, en hex. Determinista entre
  /// ejecuciones; la huella solo vive y se compara en el propio
  /// dispositivo (app Android, enteros de 64 bits).
  static String _fnv1a64(String s) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(s)) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toRadixString(16);
  }

  /// Lee la caché del mes [pref] ('YYYY-MM'). Devuelve null si aún no
  /// hay fila. `fresco` dice si la huella guardada sigue vigente.
  Future<({int clientes, String calculadoEn, bool fresco})?> leer(
      String pref) async {
    try {
      final d = await LocalDb.instance.db;
      final rows = await d.query('nomina_precalc',
          where: 'mes = ?', whereArgs: [pref], limit: 1);
      if (rows.isEmpty) return null;
      final r = rows.first;
      final h = await huella();
      // Guarda de transición de mes (ronda 2, Luna, ALTA latente):
      // 1.15 (M4c-01): la excepción de vencimiento vale para
      // cualquier mes, así que un mes cerrado ya NO cambia de
      // regla al cerrar; aun así, por construcción, la caché de
      // un mes ya pasado NUNCA se sirve como fresca — quien la
      // pida recalcula vía asegurar() con la regla vigente.
      // Hoy la única pantalla lectora solo pide el mes actual.
      final esMesActual = pref == NominaCalc.prefMesActual();
      return (
        clientes: (r['clientes_pagados'] as num).toInt(),
        calculadoEn: '${r['calculado_en']}',
        fresco: esMesActual && r['huella'] == h,
      );
    } catch (_) {
      return null;
    }
  }

  /// Garantiza una caché fresca para [pref] y devuelve el conteo.
  /// Serializado por mes: llamadas simultáneas comparten el cálculo.
  Future<int> asegurar(String pref) async {
    // 1.15 (n8): un mes que NO es el actual se calcula directo,
    // sin leer ni escribir caché: su base ya no cambia por
    // definición y una caché vieja no debe servirse ni reescribirse.
    if (pref != NominaCalc.prefMesActual()) {
      return NominaCalc.clientesQuePagaronElMes(pref);
    }
    final cache = await leer(pref);
    if (cache != null && cache.fresco) return cache.clientes;
    final enCurso = _enCurso[pref];
    if (enCurso != null) return enCurso;
    final f = _recalcular(pref).whenComplete(() {
      // Cuerpo con llaves a propósito: si el callback devolviera el
      // valor de remove() (el propio f), whenComplete esperaría a que
      // f terminara para completar f: deadlock.
      _enCurso.remove(pref);
    });
    _enCurso[pref] = f;
    return f;
  }

  Future<int> _recalcular(String pref) async {
    // Nunca lanza: asegurar() se llama también sin await desde el
    // home, y un error de BD aquí no debe convertirse en una
    // excepción asíncrona sin manejar (auditoría del código, terra).
    try {
      // Solo se escribe la caché si la huella no cambió DURANTE el
      // cálculo (si cambió, el conteo podría mezclar dos estados).
      for (var intento = 0; intento < 3; intento++) {
        final h1 = await huella();
        final n = await NominaCalc.clientesQuePagaronElMesSeguro(pref);
        if (n == null) {
          // Error de lectura: NO se cachea nada (un 0 por error
          // quedaría pegado como cifra "fresca" hasta que cambiara
          // la tabla pagos). Se devuelve el cálculo de pantalla.
          return await NominaCalc.clientesQuePagaronElMes(pref);
        }
        final h2 = await huella();
        if (h1 == h2) {
          try {
            final d = await LocalDb.instance.db;
            await d.insert(
              'nomina_precalc',
              {
                'mes': pref,
                'clientes_pagados': n,
                'huella': h2,
                // 1.15 (n8): marca con offset Habana explícito,
                // no el ISO local sin offset del dispositivo.
                'calculado_en': isoHabana(ahoraHabana()),
              },
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          } catch (_) {}
          return n;
        }
      }
    } catch (_) {}
    // Espejo inestable (sync escribiendo sin parar) o error de
    // lectura: no se guarda nada; se devuelve el cálculo vivo para
    // no mostrar una cifra vieja como si fuera fresca.
    return NominaCalc.clientesQuePagaronElMes(pref);
  }
}
