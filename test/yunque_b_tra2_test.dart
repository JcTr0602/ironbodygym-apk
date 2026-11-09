// Yunque B · lente TRANSVERSAL — regresión de TRA-03, TRA-06,
// TRA-08 y TRA-10 (Gestión 1.31).
//
// TRA-03: la copia en frío con destino directo no deja
// copia intermedia en copias_manuales.
// TRA-06: el permiso de notificaciones en tres estados
// (denegado ya no se funde con canal roto).
// TRA-08: una op de payload ilegible en las sumas de caja
// se CUENTA (noCalculadasCaja), no se traga en silencio.
// TRA-10: la marca de espejo sin verificar tras importar
// se publica en el servicio del candado y se levanta al
// quitarla de la meta.
//
// (TRA-02 —copia atómica al importar— y TRA-04/09 —timeouts—
// y TRA-05 —marca del aviso de pendientes— viven en flujos
// de UI/canal sin costura en este arnés: verificados por
// lectura y analyze en el informe de la oleada.)
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_bloqueo.dart';
import 'package:ironbody_gym/copia_seguridad.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/notificaciones_recordatorios.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_yunque_b_tra2.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  LocalDb.nombreArchivoDbForzado = 'test_yunque_b_tra2.db';
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('yb_tra2_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  group('YB-TRA-03 exportarCopiaFria con destino directo', () {
    test('escribe en el destino y no deja copia en manuales',
        () async {
      await _abrirDbVacia();
      final manuales = Directory(p.join(docs.path, 'copias_manuales'));
      final antes = await manuales.exists()
          ? await manuales.list().length
          : 0;
      final destino =
          File(p.join(docs.path, 'copias_auto', 'auto-directa.db'));
      final f = await exportarCopiaFria(destinoDirecto: destino);
      expect(f.path, destino.path);
      expect(await destino.exists(), isTrue);
      final cabecera = await destino.openRead(0, 15).first;
      expect(String.fromCharCodes(cabecera), 'SQLite format 3');
      final despues = await manuales.exists()
          ? await manuales.list().length
          : 0;
      expect(despues, antes,
          reason: 'la vía automática no deja copia intermedia');
    });
  });

  group('YB-TRA-06 estadoPermiso triestado', () {
    const canal = MethodChannel('ironbody/recordatorios');
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(canal, null);
    });

    test('canal mudo: desconocido, sin alarmar', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(canal, null);
      expect(await AvisosRecordatorios.estadoPermiso(),
          'desconocido');
      expect(await AvisosRecordatorios.tienePermiso(), isTrue);
    });

    test('denegado: se distingue y tienePermiso cae', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(canal, (call) async {
        if (call.method == 'tienePermisoNotificacion') return false;
        return null;
      });
      expect(await AvisosRecordatorios.estadoPermiso(), 'denegado');
      expect(await AvisosRecordatorios.tienePermiso(), isFalse);
    });

    test('concedido', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(canal, (call) async {
        if (call.method == 'tienePermisoNotificacion') return true;
        return null;
      });
      expect(await AvisosRecordatorios.estadoPermiso(),
          'concedido');
      expect(await AvisosRecordatorios.tienePermiso(), isTrue);
    });
  });

  group('YB-TRA-08 sumas de caja con op ilegible', () {
    test('miTurnoHoy cuenta la op no calculada', () async {
      await _abrirDbVacia();
      final db = await LocalDb.instance.db;
      const tid = 999001;
      await db.insert('ops_queue', {
        'op_uuid': 'yb-tra8-corrupta',
        'tipo': 'registrar_pago',
        'payload': '###esto-no-es-json',
        'estado': 'pendiente',
        'creada_ts': isoHabana(ahoraHabana()),
        'telegram_id': tid,
      });
      final t = await miTurnoHoy(tid);
      expect(t.$1, 0.0);
      expect(noCalculadasCaja, 1,
          reason: 'la op ilegible se cuenta, no se traga');
      // Y una corrida limpia lo vuelve a cero.
      await db.delete('ops_queue');
      await miTurnoHoy(tid);
      expect(noCalculadasCaja, 0);
    });
  });

  group('YB-TRA-10 espejo del candado sin verificar', () {
    test('la marca se publica y se levanta con la meta',
        () async {
      await _abrirDbVacia();
      final svc = AccesoBloqueoService.instance;
      await LocalDb.instance
          .setMeta(kMetaCandadoTrasImportar, '1');
      await svc.reevaluar();
      expect(svc.espejoSinVerificar.value, isTrue);
      await LocalDb.instance.setMeta(kMetaCandadoTrasImportar, '');
      await svc.reevaluar();
      expect(svc.espejoSinVerificar.value, isFalse);
    });
  });
}
