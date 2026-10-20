import 'package:sqflite/sqflite.dart';

import 'localdb.dart';
import 'nomina_calc.dart';
import 'tiempo.dart';

/// Pre-cálculo automático de la base de nómina (v1.4.0).
///
/// Lo único caro de la nómina es contar los clientes únicos que
/// pagaron el mes (escaneo del espejo `pagos`). Ese conteo se cachea
/// en la tabla local `nomina_precalc` junto con una HUELLA de los
/// insumos. Los bonos y la tarifa NO se cachean: viven en preferencias
/// y se leen siempre en vivo al componer el total, así un bono recién
/// guardado se refleja al instante.
///
/// Frescura: la huella se recalcula al leer; si no coincide con la
/// guardada, la caché se considera vieja y se recalcula. La huella
/// cubre cambios locales (ops sin subir) y remotos (pull), porque se
/// deriva del estado real de la tabla `pagos`, no de eventos.
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
    return '${r['c']}|${r['ss']}|${r['sc']}|${r['mi']}|${r['sf']}|${r['cn']}|${r['sn']}';
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
      return (
        clientes: (r['clientes_pagados'] as num).toInt(),
        calculadoEn: '${r['calculado_en']}',
        fresco: r['huella'] == h,
      );
    } catch (_) {
      return null;
    }
  }

  /// Garantiza una caché fresca para [pref] y devuelve el conteo.
  /// Serializado por mes: llamadas simultáneas comparten el cálculo.
  Future<int> asegurar(String pref) async {
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
        final n = await NominaCalc.clientesQuePagaronElMes(pref);
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
                'calculado_en': ahoraHabana().toIso8601String(),
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
