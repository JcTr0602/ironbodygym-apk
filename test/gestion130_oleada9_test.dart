/// Gestión 1.30 · Oleada 9 — Fotos: el reintento filtra por
/// autor (ítem 11 del inventario, plan §9.3).
///
/// Contrato que se fija, con BD de cola mezclada de dos
/// autores (sellos `fotos_cola.telegram_id` de la v68):
/// · El reintento MASIVO como entrenador toca solo las suyas
///   y la cuenta devuelta cuadra con las filas marcadas.
/// · El masivo como dueño toca todas (su reintento es la
///   operación de rescate).
/// · El masivo sin identidad numérica no toca ninguna
///   (fail-closed, la misma regla de fotoVisibleParaActor).
/// · El reintento INDIVIDUAL sobre una fila ajena (o sin
///   sello: las previas a v68 son del dueño) NO la procesa.
/// · El individual sobre la propia la marca como siempre
///   (con `forzar_qos = 1`), y sobre una 'subiendo' no la
///   toca (cinturón H-01) aunque esté autorizada.
/// · La pantalla delega en estas funciones (test de fuente:
///   que nadie vuelva al UPDATE sin filtro).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _yo = 111; // telegram_id del entrenador de la sesión
const _otro = 222; // telegram_id del otro autor

Future<Database> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

Future<int> _foto(
  Database db, {
  required String uuid,
  required String estado,
  int? telegramId,
  int intentos = 3,
}) async {
  return db.insert('fotos_cola', {
    'op_uuid': uuid,
    'tipo': 'display',
    'ruta_local': '/tmp/$uuid.jpg',
    'estado': estado,
    'intentos': intentos,
    'ultimo_error': 'fallo previo',
    'proximo_intento_en': 1794000000,
    'telegram_id': telegramId,
    'creado_en': '2026-11-08T09:00:00.000-04:00',
    'actualizado_en': '2026-11-08T09:00:00.000-04:00',
  });
}

Future<Map<String, Object?>> _fila(Database db, int id) async =>
    (await db.query('fotos_cola', where: 'id = ?', whereArgs: [id])).single;

/// Siembra la cola mezclada estándar y devuelve los ids por
/// clave: mía pendiente, mía error, ajena pendiente, ajena
/// error, sin sello pendiente y mía subiendo.
Future<Map<String, int>> _colaMezclada(Database db) async => {
      'miaPend': await _foto(db,
          uuid: 'f-mia-pend', estado: 'pendiente', telegramId: _yo),
      'miaErr': await _foto(db,
          uuid: 'f-mia-err', estado: 'error', telegramId: _yo),
      'ajenaPend': await _foto(db,
          uuid: 'f-ajena-pend', estado: 'pendiente', telegramId: _otro),
      'ajenaErr': await _foto(db,
          uuid: 'f-ajena-err', estado: 'error', telegramId: _otro),
      'sinSello': await _foto(db, uuid: 'f-sin-sello', estado: 'pendiente'),
      'miaSub': await _foto(db,
          uuid: 'f-mia-sub', estado: 'subiendo', telegramId: _yo),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reintentarTodasFotosCola (masivo)', () {
    test('entrenador: solo las suyas y la cuenta cuadra', () async {
      final db = await _bdVacia();
      final ids = await _colaMezclada(db);

      final n = await reintentarTodasFotosCola(db,
          esDueno: false, miTelegramId: _yo);

      expect(n, 2, reason: 'solo mía pendiente + mía error');
      // Las mías quedaron marcadas (reseteo completo).
      for (final k in ['miaPend', 'miaErr']) {
        final f = await _fila(db, ids[k]!);
        expect(f['estado'], 'pendiente', reason: k);
        expect(f['intentos'], 0, reason: k);
        expect(f['ultimo_error'], isNull, reason: k);
        expect(f['proximo_intento_en'], isNull, reason: k);
      }
      // Las ajenas y la sin sello, intactas: la ajena
      // pendiente NO se resetea aunque ya esté 'pendiente'.
      for (final k in ['ajenaPend', 'ajenaErr', 'sinSello']) {
        final f = await _fila(db, ids[k]!);
        expect(f['intentos'], 3, reason: '$k no debió tocarse');
        expect(f['ultimo_error'], 'fallo previo', reason: k);
      }
      expect((await _fila(db, ids['ajenaErr']!))['estado'], 'error');
      // La 'subiendo' no entra en el masivo de nadie.
      final sub = await _fila(db, ids['miaSub']!);
      expect(sub['estado'], 'subiendo');
      expect(sub['intentos'], 3);
    });

    test('dueño: toca todas las pendiente/error (rescate)', () async {
      final db = await _bdVacia();
      final ids = await _colaMezclada(db);

      final n = await reintentarTodasFotosCola(db,
          esDueno: true, miTelegramId: null);

      expect(n, 5, reason: 'todas menos la subiendo');
      for (final k in ['miaPend', 'miaErr', 'ajenaPend', 'ajenaErr', 'sinSello']) {
        final f = await _fila(db, ids[k]!);
        expect(f['estado'], 'pendiente', reason: k);
        expect(f['intentos'], 0, reason: k);
      }
      expect((await _fila(db, ids['miaSub']!))['estado'], 'subiendo');
    });

    test('sin identidad numérica: fail-closed, no toca ninguna',
        () async {
      final db = await _bdVacia();
      final ids = await _colaMezclada(db);

      final n = await reintentarTodasFotosCola(db,
          esDueno: false, miTelegramId: null);

      expect(n, 0);
      expect((await _fila(db, ids['miaErr']!))['intentos'], 3);
      expect((await _fila(db, ids['ajenaErr']!))['intentos'], 3);
    });
  });

  group('reintentarFotoCola (individual)', () {
    test('entrenador sobre foto ajena: no autorizada, no la toca',
        () async {
      final db = await _bdVacia();
      final ids = await _colaMezclada(db);

      final r = await reintentarFotoCola(db, ids['ajenaErr']!,
          esDueno: false, miTelegramId: _yo);

      expect(r.autorizada, isFalse);
      expect(r.tocadas, 0);
      final f = await _fila(db, ids['ajenaErr']!);
      expect(f['estado'], 'error');
      expect(f['intentos'], 3);
    });

    test('entrenador sobre foto sin sello: no autorizada (es del dueño)',
        () async {
      final db = await _bdVacia();
      final ids = await _colaMezclada(db);

      final r = await reintentarFotoCola(db, ids['sinSello']!,
          esDueno: false, miTelegramId: _yo);

      expect(r.autorizada, isFalse);
      expect((await _fila(db, ids['sinSello']!))['intentos'], 3);
    });

    test('sin identidad sobre foto sellada ajena a la sesión: no autorizada',
        () async {
      final db = await _bdVacia();
      final ids = await _colaMezclada(db);

      final r = await reintentarFotoCola(db, ids['miaErr']!,
          esDueno: false, miTelegramId: null);

      expect(r.autorizada, isFalse);
      expect((await _fila(db, ids['miaErr']!))['intentos'], 3);
    });

    test('entrenador sobre su foto en error: la marca (forzar_qos = 1)',
        () async {
      final db = await _bdVacia();
      final ids = await _colaMezclada(db);

      final r = await reintentarFotoCola(db, ids['miaErr']!,
          esDueno: false, miTelegramId: _yo);

      expect(r.autorizada, isTrue);
      expect(r.tocadas, 1);
      final f = await _fila(db, ids['miaErr']!);
      expect(f['estado'], 'pendiente');
      expect(f['intentos'], 0);
      expect(f['ultimo_error'], isNull);
      expect(f['forzar_qos'], 1);
    });

    test('dueño sobre foto ajena: la procesa (rescate)', () async {
      final db = await _bdVacia();
      final ids = await _colaMezclada(db);

      final r = await reintentarFotoCola(db, ids['ajenaErr']!,
          esDueno: true, miTelegramId: null);

      expect(r.autorizada, isTrue);
      expect(r.tocadas, 1);
      expect((await _fila(db, ids['ajenaErr']!))['estado'], 'pendiente');
    });

    test('sobre foto subiendo: autorizada pero tocadas 0 (cinturón H-01)',
        () async {
      final db = await _bdVacia();
      final ids = await _colaMezclada(db);

      final r = await reintentarFotoCola(db, ids['miaSub']!,
          esDueno: false, miTelegramId: _yo);

      expect(r.autorizada, isTrue);
      expect(r.tocadas, 0);
      expect((await _fila(db, ids['miaSub']!))['estado'], 'subiendo');
    });
  });

  test('fuente: la pantalla delega en las funciones con filtro', () {
    final src = File('lib/ui/cola.dart').readAsStringSync();
    expect(src, contains('reintentarFotoCola(db, id'));
    expect(src, contains('reintentarTodasFotosCola(db'));
    expect(src, contains("AND telegram_id = ?"));
    // El UPDATE masivo sin filtro no sobrevive en ningún sitio:
    // el único `estado IN ('pendiente', 'error')` a secas es la
    // rama del dueño dentro de la función nueva (ternario).
    expect('reintentarTodasFotosCola'.allMatches(src).length,
        greaterThanOrEqualTo(2));
  });
}
