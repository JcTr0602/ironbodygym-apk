/// 1.32 · YUNQUE EXHAUSTIVO — filas nuevas destapadas por la
/// auditoría sobre el candidato final `37aa6c0`:
///
/// - Y-1 (MEDIA): la celda «Al día» del Pulso de Home enseñaba
///   el TOTAL de activos (`activosCount()`, vía `_activosMes`)
///   bajo la etiqueta «Al día», mientras su destino abre el
///   Directorio con el filtro `aldia` (dias > 7, la Casa
///   cuenta) cuyo chip cuenta OTRO conjunto. La corrección:
///   la celda enseña el conteo de `conteosDeBuscar` sobre la
///   misma base del Directorio — la cifra y el destino por
///   fin significan lo mismo. (La 1.35 jubiló la celda
///   entera con M-2; el test guarda desde Campo 1.35 que
///   ninguna celda «al día» resucite en el Mostrador.)
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
import 'package:ironbody_gym/ui/home.dart';
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

Future<void> _descartarDialogos(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    final hay = find.byType(AlertDialog).evaluate().isNotEmpty ||
        find.byType(Dialog).evaluate().isNotEmpty;
    if (!hay) break;
    Navigator.of(tester.element(find.byType(Navigator).first))
        .popUntil((r) => r.isFirst);
    await tester.pump(const Duration(milliseconds: 400));
  }
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

  // ACTUALIZADO (Campo 1.35, 2026-11-17): la celda «Al día»
  // del Pulso que este test nació vigilando se jubiló en la
  // PROPIA 1.35 (M-2 retiró la fila «Vencidos / Al día» del
  // Mostrador; la consulta res[22] se trae sin guardar su
  // valor) — el test quedó caducado y ya fallaba sobre el
  // árbol entregado (contraste de base en la carpeta de la
  // pieza). El invariante Y-1 sigue vivo y es el que se
  // guarda ahora: NINGUNA celda del Mostrador etiqueta el
  // total de activos como «Al día» (la celda no existe).
  testWidgets(
      'Y-1: ninguna celda «Al día» queda en el Mostrador — el '
      'total de activos no se disfraza de «al día»',
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
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const HomeScreen()));
    await _drenar(tester, vueltas: 10);
    await _descartarDialogos(tester);
    await _drenar(tester, vueltas: 6);
    // Las secciones bajas nacen perezosas (ListView): hay
    // que rodar la lista hasta que existan. El ancla
    // histórica era el enlace «Ver actividad reciente →»
    // al pie de las tarjetas; CAMPO-16 (segunda parte,
    // orden de Jc) lo retiró: la ÚNICA puerta a Actividad
    // es el botón de cabecera `marco-actividad`, junto a
    // la lupa — se verifica esa puerta única aquí mismo.
    // El scroll se ancla en la Zona 3 del dueño
    // (`hoy-informe`), la última sección del Mostrador:
    // rodar hasta ella construye todo lo que va por
    // encima. (La cabecera plegable `hoy-informe-cabecera`
    // se jubiló con la composición de Campo 1.35: la
    // Zona 3 va abierta.)
    expect(find.text('Ver actividad reciente →'), findsNothing,
        reason: 'CAMPO-16 2ª parte: ningún enlace de Actividad '
            'queda en las tarjetas del Mostrador');
    expect(find.byKey(const ValueKey('marco-actividad')),
        findsOneWidget,
        reason: 'la única puerta a Actividad es el botón de '
            'cabecera junto a la lupa');
    await tester.scrollUntilVisible(
        find.byKey(const ValueKey('hoy-informe')), 200,
        scrollable: find
            .descendant(
                of: find.byType(HomeScreen),
                matching: find.byType(Scrollable))
            .first);
    await tester.pump(const Duration(milliseconds: 300));
    // Compuerta Y-1 actualizada: NO debe existir ninguna
    // celda con forma (número, «Al día») en el Mostrador —
    // la del Pulso se jubiló (M-2) y el total de activos
    // (5) no puede reaparecer disfrazado de «al día» (su
    // conjunto real sería 3: +30 ✓, +10 ✓ y la Casa ✓).
    final valores = <String>[];
    for (final e in find
        .ancestor(
            of: find.text('Al día'), matching: find.byType(InkWell))
        .evaluate()) {
      for (final c in find
          .descendant(
              of: find.byWidget(e.widget),
              matching: find.byType(Column))
          .evaluate()) {
        final textos = find
            .descendant(
                of: find.byWidget(c.widget),
                matching: find.byType(Text))
            .evaluate()
            .map((t) => (t.widget as Text).data ?? '')
            .toList();
        if (textos.length == 2 &&
            textos[1] == 'Al día' &&
            int.tryParse(textos[0]) != null) {
          valores.add(textos[0]);
        }
      }
    }
    expect(valores, isEmpty,
        reason: 'ninguna celda (número, «Al día») puede '
            'existir en el Mostrador: la del Pulso se '
            'jubiló en la 1.35 (M-2) y ni el 3 de su '
            'conjunto ni el 5 de activos tienen celda '
            '«al día» aquí; candidatas: $valores');
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
