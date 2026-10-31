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
    return 'v5|$pagosParte|${await _huellaPagosNegocio()}|${await _huellaClientes()}';
  }

  /// Componente de huella sobre el espejo `pagos`: hash canónico
  /// determinista por pago (1.15, N6) con los campos de negocio
  /// que usa [NominaCalc.esPagoMensualidad] (cliente, período,
  /// método, monto, días, pagado_hasta) además de la fecha. Editar
  /// cualquiera de ellos invalida la caché; cambiar otros campos
  /// (p. ej. registrado_por) no la toca.
  Future<String> _huellaPagosNegocio() async {
    final d = await LocalDb.instance.db;
    final rows = await d.query('pagos', columns: ['id', 'data']);
    final partes = <String>[];
    for (final r in rows) {
      String estado;
      try {
        final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        final cliente = NominaCalc.idTolerante(data['cliente_id']) ?? 0;
        var periodo = '${data['periodo'] ?? 'mensual'}';
        if (periodo.isEmpty) periodo = 'mensual';
        final metodo = '${data['metodo'] ?? ''}';
        final monto = NominaCalc.montoTolerante(data['monto']);
        final montoStr = monto == null
            ? '<null>'
            : (monto == monto.roundToDouble()
                ? '${monto.toInt()}'
                : '$monto');
        final dias = NominaCalc.idTolerante(data['dias']);
        final fecha = data['fecha'] == null ? '<null>' : '${data['fecha']}';
        // #4 (Argón nómina): pagado_hasta entra en la huella (la
        // regla del mes en curso depende de él).
        final pagadoHasta = data['pagado_hasta'] == null
            ? '<null>'
            : '${data['pagado_hasta']}';
        estado =
            '$cliente|$periodo|$metodo|$montoStr|${dias ?? '<null>'}|$fecha|$pagadoHasta';
      } catch (_) {
        estado = '<ilegible>';
      }
      partes.add('${r['id']}:$estado');
    }
    partes.sort();
    return 'p${partes.length}:${_fnv1a64(partes.join('|'))}';
  }

  /// Componente de huella sobre el espejo `clientes`: detecta altas,
  /// bajas y cualquier cambio de `pagado_hasta` (la regla del mes en
  /// curso depende de ese campo). Se calcula en Dart leyendo el JSON
  /// de `data` (sin depender de funciones JSON de SQLite, ausentes
  /// en Android viejos); con ~190 clientes es despreciable.
  ///
  /// Representación CANÓNICA por cliente, ordenada por id, hasheada
  /// con FNV-1a de 64 bits (ronda 2, Terra, ALTA): la primera
  /// versión resumía con sumas (nº de filas, suma de ids, suma de
  /// días) y dos estados distintos con la misma suma —p. ej.
  /// vencimientos (30 sep, 10 nov) frente a (10 oct, 31 oct)—
  /// producían la MISMA huella con exclusiones opuestas: la caché
  /// vieja se servía como fresca y la nómina salía mal sin ruido.
  Future<String> _huellaClientes() async {
    final d = await LocalDb.instance.db;
    final rows = await d.query('clientes', columns: ['id', 'data']);
    final partes = <String>[];
    for (final r in rows) {
      final id = (r['id'] as num?)?.toInt() ?? 0;
      String estado;
      try {
        final data = jsonDecode(r['data'] as String) as Map<String, dynamic>;
        final h = data['pagado_hasta'];
        // 1.15 (N2): cuenta_casa normalizado (1/true/'1' → 1;
        // resto → 0, mismo punto único de verdad que el resto del
        // código). Un cambio de Casa invalida la caché.
        final casa = LocalDb.cuentaCasaDe(data) ? 1 : 0;
        estado = '${h == null ? '<null>' : '$h'}:$casa';
      } catch (_) {
        estado = '<ilegible>';
      }
      partes.add('$id:$estado');
    }
    partes.sort();
    return 'c${partes.length}:${_fnv1a64(partes.join('|'))}';
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
