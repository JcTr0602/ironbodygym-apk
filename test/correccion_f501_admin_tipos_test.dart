/// Corrección PROPIA-F5-01 (1.35, decisión de Jc 2026-11-17) —
/// el editor de tipos de pago de Admin debe hacer WRITE-THROUGH
/// local a las claves planas de precio, como hace el servidor
/// en `set_tipos_pago` (db/core.py) al aplicar la op.
///
/// El defecto (foto 1241e9d): `_persistirTiposImpl` actualizaba
/// en local SOLO el blob `tipos_pago` y `_guardarTiposImpl` ni
/// el blob — solo encolaba la op. El diálogo de cobro lee el
/// blob (precio nuevo) pero `preciosVigentes()` —lo que usan la
/// renovación rápida de ficha, cuentas por cobrar y atrasados—
/// lee las claves planas (precio viejo), mientras el servidor,
/// al aplicar la op, ya asienta con el nuevo: recibo de 2000
/// contra asiento de 2200 (patrón de la divergencia B del
/// lote 141, en la pantalla que aquella corrección no cubrió).
///
/// Discriminante: guardar un precio nuevo desde el editor y,
/// SIN sincronizar, las claves planas y `preciosVigentes()`
/// deben valer ya lo nuevo. En la base, la clave plana queda
/// en el precio viejo en AMBAS vías: ROJO.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tipos_pago.dart';
import 'package:ironbody_gym/ui/admin.dart';
import 'package:ironbody_gym/ui/admin_secciones.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': 'jc@ironbody.local',
    'role': 'authenticated',
    'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
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

List<Map<String, dynamic>> _blob(double mensual) => [
      {
        'id': 'mensual',
        'nombre': 'Mensualidad',
        'monto': mensual,
        'dias': 30,
        'activo': true,
      },
      {
        'id': 'menores',
        'nombre': 'Mensualidad menores',
        'monto': 1500.0,
        'dias': 30,
        'activo': true,
        'solo_menores': true,
      },
      {
        'id': 'semanal',
        'nombre': 'Semana',
        'monto': 600.0,
        'dias': 7,
        'activo': true,
      },
      {
        'id': 'quincenal',
        'nombre': 'Quincena',
        'monto': 1200.0,
        'dias': 15,
        'activo': true,
      },
    ];

Future<void> _bdConPrecios() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
  await LocalDb.instance.setAjustes({
    'mensualidad': 2000.0,
    'mensualidad_menores': 1500.0,
    'pago_semanal': 600.0,
    'pago_quincenal': 1200.0,
    'tipos_pago': _blob(2000.0),
  });
}

Future<bool> _esperarHasta(WidgetTester tester, Finder f,
    {int intentos = 60}) async {
  for (var i = 0; i < intentos; i++) {
    if (f.evaluate().isNotEmpty) return true;
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  return f.evaluate().isNotEmpty;
}

Future<void> _ciclos(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Avance de tiempo (receta de compuertas_132_matriz): deja
/// TERMINAR lo que la cáscara deja en vuelo — el ciclo de
/// sync y la cola de fotos laten con Timer.periodic de
/// 60/30 s que solo se cancelan en el finally de su
/// operación; las zancadas de tiempo falso + giros reales
/// los llevan a ese finally.
Future<void> _avanzarTiempo(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump(const Duration(seconds: 65));
  }
}

/// Cierre de cáscara (receta de compuertas_132_matriz):
/// desmontar el árbol y dar giros REALES de E/S. Sin este
/// cierre, el invariante del arnés («Timer is still
/// pending») marca en rojo tests cuyas aserciones pasaron.
Future<void> _cerrarCascara(WidgetTester tester) async {
  await _avanzarTiempo(tester);
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _abrirTipos(WidgetTester tester) async {
  expect(await _esperarHasta(tester, find.text('ESTACIÓN DIARIA')),
      isTrue,
      reason: 'el Panel no terminó de cargar');
  await tester.scrollUntilVisible(find.text('Configuración y datos'), 300,
      maxScrolls: 80);
  await tester.pump();
  await tester.tap(find.text('Configuración y datos'));
  await _ciclos(tester);
  await tester.scrollUntilVisible(find.text('Tipos de pago'), 300,
      maxScrolls: 60);
  await tester.pump();
  await tester.tap(find.text('Tipos de pago'));
  expect(
      await _esperarHasta(tester, find.text('Mensualidad'), intentos: 40),
      isTrue,
      reason: 'la pantalla de tipos no cargó la Mensualidad');
}

Future<Map<String, dynamic>> _fotoDinero() async {
  final aj = await LocalDb.instance.getAjustes();
  final precios = await preciosVigentes();
  // La cola se lee DIRECTA, sin filtro de estado: el push()
  // del guardado intenta subir la op y puede dejarla en
  // 'enviada', fuera del filtro de pendingOps — lo que se
  // comprueba es el payload encolado, no su estado.
  final db = await LocalDb.instance.db;
  final deTipos = await db.query('ops_queue',
      where: "tipo = 'guardar_tipos_pago'", orderBy: 'creada_ts ASC');
  Map<String, dynamic>? payloadTipos;
  if (deTipos.isNotEmpty) {
    final crudo = deTipos.last['payload'];
    payloadTipos = crudo is String
        ? jsonDecode(crudo) as Map<String, dynamic>
        : Map<String, dynamic>.from(crudo as Map);
  }
  double? montoEn(List<dynamic>? lista, String id) {
    if (lista == null) return null;
    for (final t in lista) {
      if (t is Map && '${t['id']}' == id) {
        return (t['monto'] as num?)?.toDouble();
      }
    }
    return null;
  }

  return {
    'claveMensual': (aj['mensualidad'] as num?)?.toDouble(),
    'claveSemanal': (aj['pago_semanal'] as num?)?.toDouble(),
    'claveMenores': (aj['mensualidad_menores'] as num?)?.toDouble(),
    'blobMensual': montoEn(aj['tipos_pago'] as List?, 'mensual'),
    'vigenteMensual': precios['mensual'],
    'opMensual': payloadTipos == null
        ? null
        : montoEn(payloadTipos['tipos'] as List?, 'mensual'),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  testWidgets('F5-01 · editar el tipo en Admin (vía persistir): '
      'sin sincronizar, la clave plana y preciosVigentes ya '
      'valen el precio nuevo', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(_bdConPrecios);
    await _fijarSesion(tester);
    expect(AuthService().isOwner, isTrue);
    await tester.pumpWidget(const MaterialApp(home: AdminScreen()));
    await _abrirTipos(tester);
    // Editar la Mensualidad: 2000 → 2200 (primer botón de
    // edición de la lista = primer tipo del blob).
    await tester.tap(find.byIcon(Icons.edit_rounded).first);
    expect(
        await _esperarHasta(tester, find.text('Editar Mensualidad')),
        isTrue,
        reason: 'el diálogo de edición del tipo no abrió');
    final campoMonto = find.byWidgetPredicate((w) =>
        w is TextField && w.decoration?.labelText == 'Monto (CUP)');
    await tester.enterText(campoMonto, '2200');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Guardar'));
    expect(
        await _esperarHasta(
            tester, find.text('Confirmar cambio de precio')),
        isTrue,
        reason: 'la confirmación con diff no apareció');
    await tester
        .tap(find.widgetWithText(ElevatedButton, 'Aplicar cambio'));
    await _ciclos(tester);
    final foto = await tester.runAsync(_fotoDinero);
    // La op y el blob ya valían en la base; lo que discrimina
    // es la CLAVE PLANA (y su lector, preciosVigentes).
    expect(foto!['opMensual'], 2200.0,
        reason: 'la op guardar_tipos_pago lleva el precio nuevo');
    expect(foto['blobMensual'], 2200.0,
        reason: 'el blob local lleva el precio nuevo');
    expect(foto['claveMensual'], 2200.0,
        reason: 'F5-01: la clave plana «mensualidad» debe '
            'moverse con el blob al guardar en el editor '
            '(write-through local, espejo del servidor)');
    expect(foto['vigenteMensual'], 2200.0,
        reason: 'F5-01: preciosVigentes() —la renovación '
            'rápida de ficha— debe cotizar ya 2200 sin esperar '
            'a la sincronización');
    // Los precios no tocados no se mueven.
    expect(foto['claveSemanal'], 600.0);
    expect(foto['claveMenores'], 1500.0);
    await _cerrarCascara(tester);
  });

  testWidgets('F5-01 · «Guardar tipos de pago» (vía guardar): '
      'sin sincronizar, blob y clave plana quedan en lo '
      'guardado, no en lo que hubiera en ajustes', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(_bdConPrecios);
    await _fijarSesion(tester);
    expect(AuthService().isOwner, isTrue);
    await tester.pumpWidget(const MaterialApp(home: AdminScreen()));
    await _abrirTipos(tester);
    // Divergencia previa: mientras el dueño está en el Panel,
    // una bajada deja en ajustes OTRO precio (2500) — el
    // estado en memoria del editor sigue en 2000. Al pulsar
    // «Guardar tipos de pago» manda lo del editor (2000) y el
    // guardado local debe reflejarlo ENTERO (op + blob +
    // claves), no dejar ajustes en 2500.
    await tester.runAsync(() async {
      final aj = await LocalDb.instance.getAjustes();
      aj['tipos_pago'] = _blob(2500.0);
      aj['mensualidad'] = 2500.0;
      await LocalDb.instance.setAjustes(aj);
    });
    // El botón se busca DENTRO de la pantalla de ajustes de
    // encima: el módulo de debajo reutiliza la misma pantalla
    // (embebida) y su botón gemelo quedaría en el árbol.
    final botonGuardar = find.descendant(
        of: find.byType(SeccionAjustesScreen).last,
        matching:
            find.widgetWithText(BotonPrimario, 'Guardar tipos de pago'));
    // El scrollable se pasa explícito: con la pantalla de
    // ajustes empujada sobre el módulo hay más de un
    // Scrollable en el árbol y scrollUntilVisible exige uno
    // solo si no se le dice cuál.
    final scrollable = find
        .descendant(
            of: find.byType(SeccionAjustesScreen).last,
            matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(botonGuardar, 300,
        maxScrolls: 40, scrollable: scrollable);
    await tester.pump();
    await tester.tap(botonGuardar);
    // El diálogo de confirmación es un AlertDialog con el
    // título «Guardar tipos de pago»; se confirma.
    final dialogo = find.ancestor(
        of: find.text('Guardar tipos de pago'),
        matching: find.byType(AlertDialog));
    expect(
        await _esperarHasta(tester, dialogo, intentos: 40), isTrue,
        reason: 'la confirmación de guardar tipos no apareció');
    await tester.tap(find.descendant(
        of: dialogo,
        matching: find.widgetWithText(ElevatedButton, 'Confirmar')));
    await _ciclos(tester);
    final foto = await tester.runAsync(_fotoDinero);
    expect(foto!['opMensual'], 2000.0,
        reason: 'la op guardar_tipos_pago lleva lo del editor');
    expect(foto['blobMensual'], 2000.0,
        reason: 'F5-01: tras «Guardar tipos», el blob local '
            'debe quedar en lo guardado (en la base ni el blob '
            'se movía: quedaba el 2500 de ajustes)');
    expect(foto['claveMensual'], 2000.0,
        reason: 'F5-01: la clave plana debe quedar en lo '
            'guardado, en el mismo acto que la op');
    expect(foto['vigenteMensual'], 2000.0,
        reason: 'preciosVigentes() debe cotizar lo guardado '
            'sin esperar a la sincronización');
    await _cerrarCascara(tester);
  });

  group('F5-01 · ajustesTrasGuardarTipos (puro)', () {
    test('los tipos fijos presentes mueven su clave plana y '
        'el blob queda fijado', () {
      final aj = <String, dynamic>{
        'mensualidad': 2000.0,
        'mensualidad_menores': 1500.0,
        'pago_semanal': 600.0,
        'pago_quincenal': 1200.0,
        'transferencia': 2500.0,
        'tipos_pago': _blob(2000.0),
      };
      final nuevos = ajustesTrasGuardarTipos(aj, [
        {'id': 'mensual', 'monto': 2200.0},
        {'id': 'semanal', 'monto': 700.0},
      ]);
      expect(nuevos['mensualidad'], 2200.0);
      expect(nuevos['pago_semanal'], 700.0);
      // Fijos ausentes de la lista: su clave no se toca
      // (igual que set_tipos_pago en el servidor).
      expect(nuevos['mensualidad_menores'], 1500.0);
      expect(nuevos['pago_quincenal'], 1200.0);
      // Claves sin tipo en el blob: intactas.
      expect(nuevos['transferencia'], 2500.0);
      expect((nuevos['tipos_pago'] as List).length, 2);
      // El mapa de entrada no se muta.
      expect(aj['mensualidad'], 2000.0);
    });

    test('un tipo personalizado no toca ninguna clave', () {
      final aj = <String, dynamic>{'mensualidad': 2000.0};
      final nuevos = ajustesTrasGuardarTipos(aj, [
        {'id': 'trimestre', 'monto': 5500.0},
      ]);
      expect(nuevos['mensualidad'], 2000.0);
      expect(nuevos.containsKey('pago_semanal'), isFalse);
    });

    test('el monto como texto también mueve la clave '
        '(lector tolerante, como el blob editable por bot/SQL)',
        () {
      final aj = <String, dynamic>{'mensualidad': 2000.0};
      final nuevos = ajustesTrasGuardarTipos(aj, [
        {'id': 'mensual', 'monto': '2200'},
      ]);
      expect(nuevos['mensualidad'], 2200.0);
    });
  });
}
