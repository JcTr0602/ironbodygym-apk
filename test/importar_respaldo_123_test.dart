/// 1.23 — Cierre F-7: importar respaldo según la regla de Jc
/// (decisión 2026-11-04).
///
/// - Compuertas: IMPORTAR ya no depende de ser dueño (basta
///   sesión staff: dueño y entrenadores); EXPORTAR sigue
///   siendo solo del dueño.
/// - Salvaguarda nueva: si hay material sin subir (ops vivas
///   de la cola, comprobantes pendiente/error, fotos de la
///   cola no completadas), importar exige la advertencia
///   fuerte con los conteos; sin material confirmado, no.
/// - Un subconteo que falla marca indeterminado y la
///   advertencia sale igual (genérica), nunca «sin pérdida»
///   (mismo criterio que el aviso de cierre de sesión, M1).
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/importar_respaldo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('compuertas de respaldo (regla de Jc 2026-11-04)', () {
    test('importar NO depende de ser dueño: basta sesión staff', () {
      expect(puedeImportarRespaldo(haySesionStaff: true), isTrue);
      expect(puedeImportarRespaldo(haySesionStaff: false), isFalse);
    });

    test('exportar SIGUE siendo solo del dueño', () {
      expect(puedeExportarRespaldo(esDueno: true), isTrue);
      expect(puedeExportarRespaldo(esDueno: false), isFalse);
    });
  });

  group('decisión de advertencia (lógica pura)', () {
    test('sin material y conteo sano → no advierte', () {
      const c = (ops: 0, comprobantes: 0, fotos: 0, indeterminado: false);
      expect(requiereAdvertenciaImportacion(c), isFalse);
      expect(textoAdvertenciaImportacion(c), isNull);
    });

    test('con material → advierte y el texto trae los conteos', () {
      const c = (ops: 2, comprobantes: 1, fotos: 3, indeterminado: false);
      expect(requiereAdvertenciaImportacion(c), isTrue);
      final t = textoAdvertenciaImportacion(c)!;
      expect(t, contains('2 operaciones en cola sin subir'));
      expect(t, contains('1 comprobante sin subir'));
      expect(t, contains('3 fotos en cola sin subir'));
      expect(t, contains('se PERDERÁ'));
    });

    test('singulares correctos con 1 de cada', () {
      const c = (ops: 1, comprobantes: 0, fotos: 1, indeterminado: false);
      final t = textoAdvertenciaImportacion(c)!;
      expect(t, contains('1 operación en cola sin subir'));
      expect(t, contains('1 foto en cola sin subir'));
      expect(t, isNot(contains('comprobante')));
    });

    test('indeterminado sin conteos → advertencia genérica', () {
      const c = (ops: 0, comprobantes: 0, fotos: 0, indeterminado: true);
      expect(requiereAdvertenciaImportacion(c), isTrue);
      expect(textoAdvertenciaImportacion(c), avisoImportacionIndeterminado);
    });

    test('indeterminado con conteos → conteos + aviso de que '
        'puede haber más', () {
      const c = (ops: 1, comprobantes: 0, fotos: 0, indeterminado: true);
      final t = textoAdvertenciaImportacion(c)!;
      expect(t, contains('1 operación en cola sin subir'));
      expect(t, contains('podría haber más datos sin sincronizar'));
    });
  });

  group('recogida de conteos', () {
    test('un subconteo que falla marca indeterminado, no cero falso',
        () async {
      final c = await conteoSinSubirParaImportar(
        contarOps: () async => 4,
        contarComprobantes: () async => throw StateError('sin tabla'),
        contarFotos: () async => 0,
      );
      expect(c.ops, 4);
      expect(c.comprobantes, 0);
      expect(c.fotos, 0);
      expect(c.indeterminado, isTrue);
      // Y con ese resultado la advertencia es obligatoria.
      expect(requiereAdvertenciaImportacion(c), isTrue);
      expect(textoAdvertenciaImportacion(c), isNotNull);
    });

    test('conteos inyectados sanos pasan tal cual', () async {
      final c = await conteoSinSubirParaImportar(
        contarOps: () async => 0,
        contarComprobantes: () async => 0,
        contarFotos: () async => 0,
      );
      expect(c.indeterminado, isFalse);
      expect(textoAdvertenciaImportacion(c), isNull);
    });
  });

  group('contra la BD local', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    });

    setUp(() async {
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
    });

    test('BD vacía → cero confirmado, sin advertencia', () async {
      final c = await conteoSinSubirParaImportar();
      expect(c.indeterminado, isFalse);
      expect(c.ops + c.comprobantes + c.fotos, 0);
      expect(requiereAdvertenciaImportacion(c), isFalse);
      expect(textoAdvertenciaImportacion(c), isNull);
    });

    test('material pendiente real → conteos exactos y advertencia',
        () async {
      final db = await LocalDb.instance.db;
      // Ops: 1 viva cuenta; 1 aplicada NO (ya está en el servidor).
      await db.insert('ops_queue', {
        'op_uuid': 'op-viva',
        'tipo': 'pago_mensual',
        'payload': jsonEncode({}),
        'estado': 'pendiente',
        'creada_ts': '2026-11-04T08:00:00.000-04:00',
      });
      await db.insert('ops_queue', {
        'op_uuid': 'op-aplicada',
        'tipo': 'pago_mensual',
        'payload': jsonEncode({}),
        'estado': 'aplicada',
        'creada_ts': '2026-11-04T08:00:00.000-04:00',
      });
      // Comprobantes: pendiente + error reactivable cuentan;
      // subido NO.
      for (final (uuid, estado) in [
        ('c-pen', 'pendiente'),
        ('c-err', 'error'),
        ('c-sub', 'subido'),
      ]) {
        await db.insert('comprobantes_pago', {
          'comprobante_uuid': uuid,
          'ruta_local': '/tmp/$uuid.jpg',
          'estado': estado,
          'creado_en': '2026-11-04T08:00:00.000-04:00',
        });
      }
      // Fotos: pendiente y error cuentan; completada NO.
      for (final (uuid, estado) in [
        ('f-pen', 'pendiente'),
        ('f-err', 'error'),
        ('f-ok', 'completada'),
      ]) {
        await db.insert('fotos_cola', {
          'op_uuid': uuid,
          'tipo': 'display',
          'ruta_local': '/tmp/$uuid.jpg',
          'estado': estado,
          'creado_en': '2026-11-04T08:00:00.000-04:00',
          'actualizado_en': '2026-11-04T08:00:00.000-04:00',
        });
      }

      final c = await conteoSinSubirParaImportar();
      expect(c.indeterminado, isFalse);
      expect(c.ops, 1);
      expect(c.comprobantes, 2);
      expect(c.fotos, 2);
      expect(requiereAdvertenciaImportacion(c), isTrue);
      final t = textoAdvertenciaImportacion(c)!;
      expect(t, contains('1 operación en cola sin subir'));
      expect(t, contains('2 comprobantes sin subir'));
      expect(t, contains('2 fotos en cola sin subir'));
    });

    test('tabla ausente → indeterminado y advertencia genérica posible',
        () async {
      final db = await LocalDb.instance.db;
      await db.execute('DROP TABLE comprobantes_pago');
      final c = await conteoSinSubirParaImportar();
      expect(c.indeterminado, isTrue);
      expect(requiereAdvertenciaImportacion(c), isTrue);
      expect(textoAdvertenciaImportacion(c), isNotNull);
    });
  });
}
