// 1.35 (CAMPO-9 + SP-04/SP-05/SP-06/SP-07/SP-08/SP-09):
// el panel de fotos habla de FOTOS, no de variantes.
//
//  - SP-05: los conteos son por foto (op_uuid) con estado
//    conjunto; una foto atascada en 3 variantes suma 1.
//  - CAMPO-9: la lista agrupa por foto y la fila se
//    identifica por el nombre de su cliente; las variantes
//    viven en el detalle expandible.
//  - SP-04: con 0 operaciones y fotos pendientes, el
//    resumen en sencillo NO declara vacío total.
//  - SP-06: la pastilla de Fotos cuenta también los
//    errores.
//  - SP-07: descartar y reintentar actúan sobre la foto
//    entera (todas sus variantes).
//  - SP-08: el error de la fila se traduce por clase; el
//    crudo jamás se pinta.
//  - SP-09: la original en espera QoS dice la verdad de
//    su espera, no «Esperando buena conexión».
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés (la pauta de gestion129_oleada6_test.dart) ────

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _sesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e6',
      'aud': 'authenticated',
      'email': 'jc@ironbody.local',
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<Database> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

Future<void> _pumps(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// La tarjeta de Fotos nace bajo el pliegue de la lista
/// perezosa: se arrastra hasta que el buscado exista
/// (la pauta de la oleada 6).
Future<void> _arrastrarHasta(WidgetTester tester, Finder buscado) async {
  for (var i = 0; i < 12 && buscado.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
    await _pumps(tester);
  }
}

Future<void> _insertarFoto(
  Database db, {
  required String uuid,
  required String tipo,
  int? clienteId,
  String estado = 'pendiente',
  String? ultimoError,
  int forzarQos = 0,
}) async {
  final ahora = isoHabana(ahoraHabana());
  await db.insert('fotos_cola', {
    'op_uuid': uuid,
    'tipo': tipo,
    'cliente_id': clienteId,
    'ruta_local': '/tmp/$uuid-$tipo.jpg',
    'estado': estado,
    'intentos': 0,
    'ultimo_error': ultimoError,
    'forzar_qos': forzarQos,
    'creado_en': ahora,
    'actualizado_en': ahora,
  });
}

Map<String, dynamic> _filaFoto({
  required String uuid,
  required String tipo,
  String estado = 'pendiente',
  String? ultimoError,
  int forzarQos = 0,
  int? clienteId,
}) =>
    {
      'op_uuid': uuid,
      'tipo': tipo,
      'estado': estado,
      'ultimo_error': ultimoError,
      'forzar_qos': forzarQos,
      'cliente_id': clienteId,
      'creado_en': '2026-11-15T10:00:00.000-05:00',
      'ruta_local': '/tmp/x.jpg',
      'intentos': 0,
    };

void main() {
  late Directory docsDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
    docsDir = await Directory.systemTemp.createTemp('panel_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docsDir.path);
  });

  group('SP-05/CAMPO-9 · agrupar y contar por foto (puro)', () {
    test('tres variantes de una foto = un grupo, estado conjunto', () {
      final filas = [
        _filaFoto(uuid: 'f1', tipo: 'original'),
        _filaFoto(uuid: 'f1', tipo: 'thumb'),
        _filaFoto(uuid: 'f1', tipo: 'display', estado: 'subiendo'),
        _filaFoto(uuid: 'f2', tipo: 'display'),
      ];
      final grupos = agruparFotosCola(filas);
      expect(grupos.length, 2);
      final f1 = grupos.firstWhere((g) => g.opUuid == 'f1');
      expect(f1.variantes.map((v) => v['tipo']).toList(),
          ['thumb', 'display', 'original'],
          reason: 'las variantes se ordenan para el detalle');
      expect(f1.estadoConjunto, 'subiendo');
    });

    test('los conteos son por foto: la de error suma 1, no 3', () {
      final filas = [
        _filaFoto(uuid: 'fa', tipo: 'thumb'),
        _filaFoto(uuid: 'fa', tipo: 'display'),
        _filaFoto(uuid: 'fa', tipo: 'original', estado: 'error'),
        _filaFoto(uuid: 'fb', tipo: 'display', estado: 'subiendo'),
        _filaFoto(uuid: 'fc', tipo: 'original'),
      ];
      final c = conteosFotosPorFoto(filas);
      expect(c.error, 1);
      expect(c.subiendo, 1);
      expect(c.pendientes, 1);
    });
  });

  group('SP-08 · fraseErrorFoto (pura)', () {
    test('traduce por clase y nunca devuelve el crudo', () {
      expect(
          fraseErrorFoto('La vinculación de la foto no pudo '
              'completarse: DatabaseException(...)'),
          'Llegó al servidor pero no pudo enlazarse');
      // E3 (C2-03): el texto REAL que SP-01 escribe a las
      // 24 h sin espejo (fotos_cola.dart) también es de la
      // clase vinculación — en la base caía al genérico
      // «No pudo subirse», falso (los bytes sí subieron).
      expect(
          fraseErrorFoto('La foto no pudo enlazarse: el '
              'cliente no aparece en este teléfono'),
          'Llegó al servidor pero no pudo enlazarse');
      expect(fraseErrorFoto('El archivo no existe en disco'),
          'El archivo ya no está en este teléfono');
      expect(
          fraseErrorFoto('ClientException: SocketException: '
              'Connection failed'),
          'La conexión falló al subirla');
      expect(fraseErrorFoto('StateError: algo raro interno'),
          'No pudo subirse');
      expect(fraseErrorFoto(null), 'No pudo subirse');
      expect(fraseErrorFoto(''), 'No pudo subirse');
    });
  });

  group('SP-07 · descarte y reintento por foto (BD)', () {
    test('descartar borra TODAS las variantes de la foto', () async {
      final db = await _bdVacia();
      await _insertarFoto(db, uuid: 'f1', tipo: 'thumb', clienteId: 7);
      await _insertarFoto(db, uuid: 'f1', tipo: 'display', clienteId: 7);
      await _insertarFoto(db, uuid: 'f1', tipo: 'original', clienteId: 7);
      await _insertarFoto(db, uuid: 'f2', tipo: 'display', clienteId: 8);
      final n = await descartarFotoGrupoCola(db, 'f1',
          esDueno: true, miTelegramId: 735772141);
      expect(n, 3);
      final quedan = await db.query('fotos_cola');
      expect(quedan.length, 1);
      expect(quedan.single['op_uuid'], 'f2');
    });

    // Hy4 G#25 (1.35): el contrato cambió — el descarte
    // re-verifica DENTRO de la transacción y si alguna
    // variante está subiendo no descarta NADA (-1). El
    // contrato anterior (borrar las demás y dejar la
    // subiendo) partía el grupo y el snack decía
    // «Foto descartada» mientras una variante seguía
    // subiendo sola: eso es lo que G#25 corrige.
    test('descartar con una variante subiendo no parte '
        'el grupo', () async {
      final db = await _bdVacia();
      await _insertarFoto(db, uuid: 'f1', tipo: 'thumb', clienteId: 7);
      await _insertarFoto(db,
          uuid: 'f1', tipo: 'display', clienteId: 7, estado: 'subiendo');
      final n = await descartarFotoGrupoCola(db, 'f1',
          esDueno: true, miTelegramId: 735772141);
      expect(n, -1,
          reason: 'con una variante subiendo no se descarta nada');
      final quedan = await db.query('fotos_cola');
      expect(quedan, hasLength(2),
          reason: 'el grupo queda entero, nunca partido');
    });

    test('reintentar resetea todas las variantes y fuerza QoS',
        () async {
      final db = await _bdVacia();
      await _insertarFoto(db,
          uuid: 'f1', tipo: 'display', clienteId: 7, estado: 'error');
      await _insertarFoto(db, uuid: 'f1', tipo: 'original', clienteId: 7);
      final n = await reintentarFotoGrupoCola(db, 'f1',
          esDueno: true, miTelegramId: 735772141);
      expect(n, 2);
      final filas = await db.query('fotos_cola',
          where: 'op_uuid = ?', whereArgs: ['f1']);
      for (final f in filas) {
        expect(f['estado'], 'pendiente');
        expect(f['forzar_qos'], 1,
            reason: 'el reintento manual salta la espera QoS');
        expect(f['ultimo_error'], isNull);
      }
    });
  });

  group('Panel en pantalla (dueño)', () {
    testWidgets(
        'SP-04+SP-05+SP-06+CAMPO-9: 0 ops y una foto con 2 '
        'variantes — el sencillo nombra 1 foto, la pastilla '
        'cuenta 1 y la fila es la foto de su cliente',
        (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await db.insert('clientes', {
          'id': 7,
          'data': jsonEncode({'nombre': 'Claudia Prueba'}),
          'sync_seq': 1,
        });
        await _insertarFoto(db, uuid: 'f1', tipo: 'display', clienteId: 7);
        await _insertarFoto(db, uuid: 'f1', tipo: 'original', clienteId: 7);
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(home: ColaScreen()));
      await _pumps(tester);
      // SP-04: el resumen no declara vacío total.
      expect(find.textContaining('foto(s) por subir'), findsOneWidget);
      expect(find.textContaining('Además, 1 foto(s) por subir'),
          findsOneWidget,
          reason: 'una foto con dos variantes cuenta UNA');
      // SP-06/SP-05: la pastilla de Fotos cuenta 1 pendiente.
      await _arrastrarHasta(tester, find.text('1 pendientes · 0 subiendo'));
      expect(find.text('1 pendientes · 0 subiendo'), findsOneWidget);
      // CAMPO-9: expandir Fotos enseña UNA fila, la foto
      // identificada por su cliente.
      await tester.tap(find.text('Fotos'));
      await _pumps(tester);
      expect(find.text('Foto de Claudia Prueba'), findsOneWidget);
      expect(find.textContaining('2 versiones'), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
    });

    testWidgets(
        'SP-06+SP-08+SP-09: la foto en error sale en la '
        'pastilla, su fila traduce el error y la original '
        'en espera QoS dice su verdad', (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await db.insert('clientes', {
          'id': 9,
          'data': jsonEncode({'nombre': 'Error Prueba'}),
          'sync_seq': 1,
        });
        await _insertarFoto(db,
            uuid: 'fe',
            tipo: 'display',
            clienteId: 9,
            estado: 'error',
            ultimoError: 'ClientException: SocketException: '
                'Connection reset by peer, uri=https://x');
        await _insertarFoto(db, uuid: 'fq', tipo: 'original', clienteId: 9);
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(home: ColaScreen()));
      await _pumps(tester);
      // SP-06: la pastilla cuenta el error sin expandir.
      await _arrastrarHasta(tester, find.textContaining('1 con error'));
      expect(find.textContaining('1 con error'), findsOneWidget);
      // La línea plegada también (por foto).
      expect(find.textContaining('1 foto falló'), findsOneWidget);
      await tester.tap(find.text('Fotos'));
      await _pumps(tester);
      // SP-08: la fila traduce; el crudo no aparece.
      expect(find.text('La conexión falló al subirla'), findsOneWidget);
      expect(find.textContaining('SocketException'), findsNothing);
      // SP-09: la original sola en espera QoS dice su verdad.
      expect(find.text('En espera'), findsOneWidget);
      expect(
          find.textContaining('espera a que la cola esté tranquila'),
          findsWidgets);
      expect(find.text('Esperando buena conexión'), findsNothing);
      await tester.pump(const Duration(seconds: 31));
    });
  });
}
