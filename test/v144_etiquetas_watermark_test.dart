/// v1.4.4: (1) la etiqueta de la op 'ajuste' sale de la CLAVE del
/// payload (antes toda ajuste decía «Cambio de precio»); (2) el
/// mínimo de watermarks del cartel de novedades excluye 'borrados'
/// (su cursor solo llega hasta la última tumba y dejaba el cartel
/// «Hay cambios nuevos» encendido para siempre).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tipos_operacion.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('etiquetas de ajuste por clave', () {
    test('horario_turnos ya no dice «Cambio de precio»', () {
      expect(
          describirTipoOpConPayload(
              'ajuste', {'clave': 'horario_turnos', 'valor': '{}'}),
          'Ajuste: horario de turnos');
    });

    test('las claves de precio se distinguen entre sí', () {
      expect(describirTipoOpConPayload('ajuste', {'clave': 'mensualidad'}),
          contains('mensualidad'));
      expect(
          describirTipoOpConPayload('ajuste', {'clave': 'tarjeta_bandec'}),
          contains('BANDEC'));
      expect(describirTipoOpConPayload('ajuste', {'clave': 'tasa_usd'}),
          contains('USD'));
    });

    test('clave desconocida o ausente cae a «Ajuste» genérico', () {
      expect(describirTipoOpConPayload('ajuste', {'clave': 'otra'}), 'Ajuste');
      expect(describirTipoOpConPayload('ajuste', null), 'Ajuste');
      expect(describirTipoOpConPayload('ajuste', const {}), 'Ajuste');
    });

    test('otros tipos ignoran el payload', () {
      expect(
          describirTipoOpConPayload('pago_mensual', {'clave': 'mensualidad'}),
          'Pago mensual');
    });
  });

  test('watermark mínimo: excluir borrados desatasca el cartel',
      () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    final dbPath = p.join(dir, 'ironbody.db');
    try {
      await File(dbPath).delete();
    } catch (_) {}
    await LocalDb.resetParaTest();
    final db = LocalDb.instance;
    await db.db;
    // Todas las tablas al día en 100; borrados rezagado en 40 (su
    // cursor solo avanza hasta la última tumba bajada).
    // 1.24.2: borrados ya NO está en tablasConWatermark (cursor
    // propio; con su tabla vacía en el servidor clavaba el
    // mínimo en 0 para siempre — campo 2026-11-05), así que ni
    // el mínimo clásico ni el de las novedades lo arrastran.
    for (final t in LocalDb.tablasConWatermark) {
      await db.setMeta('wm_$t', '100');
    }
    await db.setMeta('wm_borrados', '40');
    expect(LocalDb.tablasConWatermark.contains('borrados'), isFalse,
        reason: 'borrados salió de la lista en la 1.24.2');
    expect(await db.getWatermarkMinimo(), 100,
        reason: 'el mínimo refleja el contenido, sin borrados');
    expect(await db.getWatermarkMinimo(excluir: {'borrados'}), 100,
        reason: 'la exclusión explícita sigue siendo válida');
  });
}
