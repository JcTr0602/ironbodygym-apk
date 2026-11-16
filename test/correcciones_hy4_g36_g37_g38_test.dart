/// Correcciones Hy4 — G#36/G#37/G#38: las tres
/// pantallas de cifras por entrenador (Historial,
/// Comparativa y Detalle) cargaban con awaits y
/// publicaban sin revalidar que el mes/filtro siguiera
/// siendo el elegido: una carga vieja que terminaba
/// tarde dejaba SUS cifras bajo el título nuevo. Las
/// tres llevan ahora guarda de generación.
///
/// NOTA DE ARNÉS (honesta): la carrera exacta (la carga
/// vieja terminando DESPUÉS que la nueva) no se
/// reproduce de forma determinista aquí — sqflite FFI
/// serializa las lecturas en FIFO y la carga vieja,
/// encolada primero, termina primero. Estos tests
/// fijan el comportamiento exigible: cambios rápidos
/// de mes/filtro sin atasco y con el estado final
/// consistente con la ÚLTIMA selección. La guarda se
/// verifica por lectura de código (generación capturada
/// al entrar y revalidada antes de publicar/tocar
/// campos).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/comparativa_entrenadores.dart';
import 'package:ironbody_gym/ui/detalle_entrenador.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/historial_entrenador.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso() {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': 'jc@ironbody.local',
    'role': 'authenticated',
    'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
  });
  return '$header.$payload.firma';
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 12, int ms = 100}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    const dirFuentes =
        '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
    final loader = FontLoader('Roboto');
    for (final f in [
      'Roboto-Regular.ttf',
      'Roboto-Medium.ttf',
      'Roboto-Bold.ttf'
    ]) {
      final bytes = await File('$dirFuentes/$f').readAsBytes();
      loader.addFont(Future.value(ByteData.view(bytes.buffer)));
    }
    await loader.load();
    SharedPreferences.setMockInitialValues({});
    LocalDb.nombreArchivoDbForzado = 'test_hy4g36.db';
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
    final docs = await Directory.systemTemp.createTemp('hy4g36_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_hy4g36.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    // usuarios_apk NO es tabla: es el blob JSON en meta.
    await LocalDb.instance.setMeta(
        'usuarios_apk',
        jsonEncode([
          {
            'id': '00000000-0000-0000-0000-0000000000e7',
            'telegram_id': 1403501391,
            'nombre': 'Gabriel',
            'username': 'gabriel',
          },
          {
            'id': '00000000-0000-0000-0000-0000000000e8',
            'telegram_id': 969869611,
            'nombre': 'Duany',
            'username': 'duany',
          },
        ]));
    await LocalDb.instance.upsertMirror('clientes', 41, {
      'id': 41,
      'nombre': 'Cliente Cifras',
    }, 100);
    // Gabriel: noviembre 2000 · octubre 700. Duany:
    // noviembre 500 · octubre 300 (la Comparativa exige
    // DOS entrenadores con actividad en el mes).
    for (final (id, fecha, monto, tid, nombre) in [
      (61, '2026-11-10', 2000, 1403501391, 'Gabriel'),
      (62, '2026-10-10', 700, 1403501391, 'Gabriel'),
      (63, '2026-11-05', 500, 969869611, 'Duany'),
      (64, '2026-10-05', 300, 969869611, 'Duany'),
    ]) {
      await LocalDb.instance.upsertMirror('pagos', id, {
        'id': id,
        'cliente_id': 41,
        'monto': monto,
        'fecha': fecha,
        'metodo': 'efectivo',
        'entregado': 1,
        'telegram_user_id': tid,
        'registrado_por_nombre': nombre,
      }, 100);
    }
  });

  Future<void> sesionDueno(WidgetTester tester) async {
    final sesion = jsonEncode({
      'access_token': _jwtFalso(),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-x',
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
    tester.view.physicalSize = const Size(420, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('G#36 Historial: cambiar de mes rápido '
      'deja las cifras del mes final', (tester) async {
    await sesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const HistorialEntrenadorScreen(),
    ));
    await _drenar(tester);
    expect(find.textContaining('2000'), findsWidgets,
        reason: 'noviembre arranca con los 2000 de Gabriel');
    // Dos toques seguidos al mes anterior y de vuelta.
    final atras = find.byIcon(Icons.chevron_left_rounded);
    await tester.tap(atras);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(atras);
    await _drenar(tester);
    // Mes final: septiembre — sin pagos de Gabriel.
    expect(find.textContaining('2000'), findsNothing,
        reason: 'las cifras visibles son las del mes '
            'final, no las de un mes intermedio');
    expect(find.textContaining('700'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('G#37 Comparativa: mover el mes rápido '
      'deja las filas del mes final', (tester) async {
    await sesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const ComparativaEntrenadoresScreen(),
    ));
    await _drenar(tester);
    expect(find.textContaining('2000'), findsWidgets);
    final atras = find.byTooltip('Mes anterior');
    await tester.tap(atras);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(atras);
    await _drenar(tester);
    expect(find.textContaining('2000'), findsNothing,
        reason: 'septiembre no tiene los 2000 de '
            'noviembre: la fila visible es del mes final');
    expect(find.textContaining('700'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('G#38 Detalle: cambiar el filtro rápido '
      'deja los totales del filtro final', (tester) async {
    await sesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const DetalleEntrenadorScreen(
          nombre: 'Gabriel', telegramId: 1403501391),
    ));
    await _drenar(tester);
    // Filtro inicial: Mes (noviembre) — el cobro de
    // Gabriel está en la lista de cobros.
    expect(find.textContaining('Cliente Cifras'),
        findsWidgets);
    // Saltos rápidos: 90 días → Semana (final).
    await tester.tap(find.text('90 días'));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.tap(find.text('Semana'));
    await _drenar(tester);
    // Esta semana (desde el lunes 2026-11-16) no tiene
    // cobros de Gabriel: su fila no puede seguir en la
    // lista. (El «2000 → 0» del comparador con el
    // período anterior SÍ es correcto en Semana: el
    // pago del 10 cae en la semana anterior.)
    expect(find.textContaining('Cliente Cifras'),
        findsNothing,
        reason: 'los cobros visibles son los del '
            'filtro final (Semana), no los de Mes/90 días');
    expect(find.textContaining('700'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
    expect(tester.takeException(), isNull);
  });
}
