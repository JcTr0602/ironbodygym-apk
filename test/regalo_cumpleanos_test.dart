/// Pruebas del regalo de mensualidad por cumpleaños (v1.3.3, Argón).
///
/// Cubre:
/// - Argón spec 1: el regalo (metodo='cortesia') no cuenta en
///   conteoPagosDia (no infla pagos_count del cierre ni genera comisión).
/// - Argón spec 3: normalización de teléfonos cubanos para wa.me.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('normalizarTelefonoWaMe (Argón spec 3)', () {
    test('8 dígitos con prefijo 5/6 → antepone 53', () {
      expect(normalizarTelefonoWaMe('58123456'), '5358123456');
      expect(normalizarTelefonoWaMe('61234567'), '5361234567');
    });

    test('10 dígitos empezando con 535/536 → tal cual', () {
      expect(normalizarTelefonoWaMe('5358123456'), '5358123456');
      expect(normalizarTelefonoWaMe('5361234567'), '5361234567');
    });

    test('10 dígitos con 53 pero tercer dígito inválido → vacío', () {
      // Fijo de La Habana (537) o número mal escrito (531).
      expect(normalizarTelefonoWaMe('5371234567'), '');
      expect(normalizarTelefonoWaMe('5312345678'), '');
    });

    test('quita todo lo no numérico', () {
      expect(normalizarTelefonoWaMe('+53 5812-3456'), '5358123456');
      expect(normalizarTelefonoWaMe('(5812) 3456'), '5358123456');
    });

    test('inválidos → cadena vacía', () {
      // 8 dígitos sin prefijo móvil válido (p. ej. carnet parcial).
      expect(normalizarTelefonoWaMe('12345678'), '');
      // Carnet de 11 dígitos.
      expect(normalizarTelefonoWaMe('95010112345'), '');
      // Vacío / basura.
      expect(normalizarTelefonoWaMe(''), '');
      expect(normalizarTelefonoWaMe('abc'), '');
      // 10 dígitos sin 53 inicial.
      expect(normalizarTelefonoWaMe('5512345678'), '');
    });
  });

  group('conteoPagosDia excluye regalos (Argón spec 1)', () {
    test('pago cortesia no suma al conteo', () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      // Hermético: borrar el archivo para no heredar el esquema de otro
      // test (algunos fixtures crean BDs mínimas sin la tabla pagos).
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'ironbody.db')).delete();
      } catch (_) {}
      await LocalDb.resetParaTest();

      final db = await LocalDb.instance.db;
      final hoy = DateTime.now().toIso8601String().substring(0, 10);
      const tid = 777001;

      // Inserta directo en el espejo: un pago real y un regalo.
      await db.insert('pagos', {
        'id': 9001,
        'data': '{"id":9001,"cliente_id":1,"fecha":"$hoy",'
            '"monto":2000,"metodo":"efectivo","telegram_user_id":$tid}',
        'sync_seq': 1,
      });
      await db.insert('pagos', {
        'id': 9002,
        'data': '{"id":9002,"cliente_id":2,"fecha":"$hoy",'
            '"monto":0,"metodo":"cortesia","telegram_user_id":$tid}',
        'sync_seq': 1,
      });

      final n = await conteoPagosDia(tid, fecha: hoy);
      // Solo el pago real cuenta; el regalo queda excluido.
      expect(n, 1);

      await db.close();
    });
  });
}
