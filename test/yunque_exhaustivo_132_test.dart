/// 1.32 · YUNQUE EXHAUSTIVO — filas nuevas destapadas por la
/// auditoría sobre el candidato final `37aa6c0`:
///
/// - Y-1 (MEDIA): la celda «Al día» del Pulso de Home enseñaba
///   el TOTAL de activos (`activosCount()`, vía `_activosMes`)
///   bajo la etiqueta «Al día», mientras su destino abre el
///   Directorio con el filtro `aldia` (dias > 7, la Casa
///   cuenta) cuyo chip cuenta OTRO conjunto. La corrección
///   de la 1.32: la celda enseña el conteo de
///   `conteosDeBuscar` sobre la misma base del Directorio —
///   la cifra y el destino por fin significan lo mismo.
///   RE-APUNTE 1.36 (bloque J-3, adjudicación de Jc
///   2026-11-17 «re-apuntar, no jubilar»): la 1.35 (M-2)
///   jubiló la fila «Vencidos / Al día» del Mostrador — la
///   celda ancla ya no existe en Home. La casilla que la
///   sustituyó en la composición vigente es el propio chip
///   «Al día (N)» del Directorio (`lib/ui/buscar.dart`,
///   filtro `aldia`): el test se re-apunta a esa casilla y
///   conserva la vigilancia — la cifra «al día» que se
///   enseña es el conjunto de su filtro (dias > 7 + Casa),
///   no el total de activos — verificada ahora EN el
///   destino: el chip dice 3, «Todos» dice 5 y al tocar el
///   chip la lista enseña exactamente esos 3. DIFERENCIA
///   DECLARADA: ya no se vigila una celda de Home contra
///   su destino (Home ya no promete ninguna cifra «al
///   día»: esa mitad de la vigilancia quedó sin objeto),
///   se vigila la coherencia cifra↔lista dentro del
///   Directorio mismo.
/// - Y-2 (BAJA, residuo D-5): el selector de cliente del
///   envío de plantillas pintaba el `telefono` CRUDO como
///   subtítulo; en un migrado ese campo trae el carnet y el
///   mensaje sale a otro número (el efectivo). La corrección:
///   el subtítulo es `telefonoEfectivoLocal` (8 dígitos del
///   efectivo o «—»).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/plantilla_mensaje.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/plantillas_mensaje.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés (la pauta de las compuertas: JWT falso de dueño,
// Roboto real, viewport de teléfono, drenaje realista) ──

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

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 16, int ms = 120}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _cerrarCascara(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _cargarRobotoReal() async {
  const dir =
      '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf'
  ]) {
    final bytes = await File('$dir/$f').readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void _telefono(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

String _enDias(int n) {
  final hoy = DateTime.parse(hoyHabanaIso());
  return hoy.add(Duration(days: n)).toIso8601String().substring(0, 10);
}

Future<void> _sembrarCliente(int id, Map<String, dynamic> datos) async {
  await LocalDb.instance.upsertMirror('clientes', id, {
    'id': id,
    'estado': 'activo',
    'fecha_inscripcion': _enDias(-120),
    ...datos,
  }, id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    await _cargarRobotoReal();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    final docs = await Directory.systemTemp.createTemp('yunq132_docs');
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
    for (final sufijo in ['', '-wal', '-shm']) {
      try {
        await File('${p.join(dir, 'ironbody.db')}$sufijo').delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    // Como en el arnés de las compuertas: la BD se ABRE aquí,
    // en la zona real del setUp — la primera apertura dentro
    // de la zona falsa de un testWidgets no completa nunca
    // (los futuros ffi NoIsolate necesitan giros reales).
    await LocalDb.instance.db;
  });

  testWidgets(
      'Y-1 (re-apuntado 1.36 J-3): el chip «Al día» del '
      'Directorio cuenta el conjunto de su filtro (dias>7 + '
      'Casa), no el total de activos',
      (tester) async {
    _telefono(tester);
    // Padrón de 5 activos: 2 al día estrictos (dias > 7),
    // 1 por vencer (3 días), 1 vencido y 1 Casa con la fecha
    // vieja. «Al día» del Directorio = 3; activos = 5.
    await _sembrarCliente(501, {
      'nombre': 'AlDia Uno',
      'telefono': '58110001',
      'pagado_hasta': _enDias(30),
    });
    await _sembrarCliente(502, {
      'nombre': 'AlDia Dos',
      'telefono': '58110002',
      'pagado_hasta': _enDias(10),
    });
    await _sembrarCliente(503, {
      'nombre': 'PorVencer Tres',
      'telefono': '58110003',
      'pagado_hasta': _enDias(3),
    });
    await _sembrarCliente(504, {
      'nombre': 'Vencido Cuatro',
      'telefono': '58110004',
      'pagado_hasta': _enDias(-5),
    });
    await _sembrarCliente(505, {
      'nombre': 'Casa Cinco',
      'telefono': '58110005',
      'pagado_hasta': _enDias(-40),
      'cuenta_casa': 1,
    });
    await _sesionDueno(tester);
    // RE-APUNTE: la celda del Pulso fue jubilada por M-2
    // (1.35); la casilla sucesora es el chip del Directorio
    // (ver la nota Y-1 de la cabecera del archivo). Las
    // afirmaciones de CAMPO-16 que este test arrastraba
    // (puerta única `marco-actividad`, sin enlaces «Ver
    // actividad reciente») NO se pierden: viven en su
    // propio test (campo16_actividad_cabecera_test.dart).
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const BuscarScreen()));
    await _drenar(tester, vueltas: 10);
    // La cifra «al día» enseñada es 3 (el conjunto del
    // filtro: +30 ✓, +10 ✓ y la Casa ✓) y el total de
    // activos, 5, vive en su propio chip: no se confunden.
    expect(find.text('Al día (3)'), findsOneWidget,
        reason: 'el chip «Al día» del Directorio debe contar '
            'el conjunto de su filtro (3), no el total de '
            'activos (5)');
    expect(find.text('Todos (5)'), findsOneWidget,
        reason: 'el total de activos (5) es la cifra de '
            '«Todos», no la de «Al día»');
    // Y la cifra promete la lista: al tocar el chip, la
    // lista enseña exactamente esos 3 y ninguno más.
    await tester.tap(find.text('Al día (3)'));
    await _drenar(tester, vueltas: 6);
    expect(find.text('AlDia Uno'), findsOneWidget);
    expect(find.text('AlDia Dos'), findsOneWidget);
    expect(find.text('Casa Cinco'), findsOneWidget);
    expect(find.text('PorVencer Tres'), findsNothing,
        reason: 'por vencer (3 días) no es «al día»');
    expect(find.text('Vencido Cuatro'), findsNothing,
        reason: 'vencido no es «al día»');
    await _cerrarCascara(tester);
  });

  testWidgets(
      'Y-2: el selector de cliente de Plantillas enseña el '
      'teléfono EFECTIVO, no el campo crudo (carnet del migrado)',
      (tester) async {
    _telefono(tester);
    await crearPlantilla('Saludo Yunque', 'Hola {{nombre}}');
    // Migrado: `telefono` trae el carnet (11 dígitos) y el
    // móvil real vive en `movil`. El envío sale al móvil.
    await _sembrarCliente(601, {
      'nombre': 'Migrado Seiscientos',
      'telefono': '95062012345',
      'movil': '58191577',
      'pagado_hasta': _enDias(30),
    });
    await _sesionDueno(tester);
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const PlantillasScreen()));
    await _drenar(tester, vueltas: 8);
    expect(find.text('Saludo Yunque'), findsOneWidget);
    await tester.tap(find.text('Saludo Yunque'));
    await _drenar(tester, vueltas: 6);
    expect(find.text('Enviar a un cliente'), findsOneWidget);
    await tester.tap(find.text('Enviar a un cliente'));
    await _drenar(tester, vueltas: 8);
    expect(find.text('Migrado Seiscientos'), findsOneWidget,
        reason: 'el selector debe listar al cliente sembrado');
    expect(find.text('58191577'), findsOneWidget,
        reason: 'el subtítulo debe ser el teléfono efectivo '
            '(el móvil), que es al que saldrá el mensaje');
    expect(find.text('95062012345'), findsNothing,
        reason: 'el carnet que vive en `telefono` NO debe '
            'enseñarse como si fuera el teléfono');
    await _cerrarCascara(tester);
  });
}
