/// LOTE 1.35 · SL-9 (Admin y ajustes) — fichas del Panel del
/// dueño (admin.dart): G09-3, G09-4, G09-5 y A1.
///
/// - G09-3: un pago base inválido («12x») NO cierra el diálogo
///   en silencio: se valida dentro, con aviso, sin cerrar.
/// - G09-4: el fallo al registrar una recogida se avisa en
///   lenguaje amable (mensajeErrorAmable), nunca con la
///   excepción cruda («Exception: …») en pantalla.
/// - G09-5: la sync se dice UNA vez (la cabecera de la app);
///   el Panel pierde banda, chip y sello, y la tarjeta de
///   «Estado de sync» deja de anunciar el estado (dice la
///   acción). Ajustes y Papelera pierden su banda repetida.
/// - A1: antes de aplicar un CAMBIO DE PRECIO (tipo de pago)
///   se muestra la DIFERENCIA (viejo → nuevo) y se confirma;
///   cancelar deja el precio intacto y no encola nada.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/perfil.dart';
import 'package:ironbody_gym/ui/admin.dart';
import 'package:ironbody_gym/ui/ajustes.dart';
import 'package:ironbody_gym/ui/papelera.dart';
import 'package:ironbody_gym/ui/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, {int? telegramId}) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {
      if (telegramId != null) 'telegram_id': telegramId,
      'provider': 'email',
    },
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(WidgetTester tester, {int? telegramId}) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', telegramId: telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
      'aud': 'authenticated',
      'email': 'jc@ironbody.local',
      'app_metadata': {
        if (telegramId != null) 'telegram_id': telegramId,
        'provider': 'email',
      },
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
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

Future<void> _abrirModulo(
    WidgetTester tester, String tituloModulo) async {
  expect(await _esperarHasta(tester, find.text('ESTACIÓN DIARIA')),
      isTrue,
      reason: 'el Panel no terminó de cargar');
  await tester.scrollUntilVisible(find.text(tituloModulo), 300,
      maxScrolls: 80);
  await tester.pump();
  await tester.tap(find.text(tituloModulo));
  await _ciclos(tester);
}

void _mockAppLinks() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          const EventChannel('com.llfbandit.app_links/events'),
          MockStreamHandler.inline(onListen: (args, events) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/messages'),
          (call) async => null);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    _mockAppLinks();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  group('G09-5 · la sync se dice una vez', () {
    testWidgets('Panel sin banda, sin chip y sin sello; la '
        'tarjeta de Estado de sync dice la acción', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
        // Sello de última pull (para que la base pinte el
        // «Actualizado …») y una op pendiente (chip «1 por
        // subir» y tarjeta «1 ops por subir» en la base).
        await LocalDb.instance
            .setMeta('last_pull_ok', '2026-11-16T10:00:00');
        await LocalDb.instance.queueOp(
          opUuid: 'op-sl9-g09-5',
          tipo: 'ajuste',
          payload: {'clave': 'x', 'valor': 1},
        );
      });
      await _fijarSesion(tester, telegramId: 735772141);
      expect(AuthService().isOwner, isTrue);
      await tester.pumpWidget(const MaterialApp(home: AdminScreen()));
      expect(await _esperarHasta(tester, find.text('ESTACIÓN DIARIA')),
          isTrue,
          reason: 'el Panel no terminó de cargar');
      await _ciclos(tester, 4);
      // Banda fuera.
      expect(find.byType(SyncBanner), findsNothing,
          reason: 'la banda de sync sale del Panel');
      // Chip de la cabecera fuera («1 por subir»).
      expect(find.text('1 por subir'), findsNothing,
          reason: 'el chip de sync de la cabecera sale del Panel');
      // Sello fuera («Actualizado 16/11 10:00»).
      expect(find.textContaining('Actualizado 16/11'), findsNothing,
          reason: 'el sello «Actualizado …» sale del Panel');
      // Tarjeta de estado: dice la acción, no el estado.
      await _abrirModulo(tester, 'Control y sistema');
      await tester.scrollUntilVisible(find.text('Estado de sync'), 300,
          maxScrolls: 60);
      await tester.pump();
      expect(find.text('Estado de sync'), findsOneWidget);
      expect(find.text('1 ops por subir'), findsNothing,
          reason: 'la tarjeta no debe anunciar el estado de sync');
      expect(find.text('Diagnóstico y salud de la sincronización'),
          findsOneWidget,
          reason: 'la tarjeta debe decir qué abre el toque');
    });

    testWidgets('Ajustes y Papelera sin banda de sync repetida',
        (tester) async {
      await tester.runAsync(_bdVacia);
      await _fijarSesion(tester, telegramId: 735772141);
      await tester.pumpWidget(const MaterialApp(home: AjustesScreen()));
      await _ciclos(tester);
      expect(find.byType(SyncBanner), findsNothing,
          reason: 'la banda sale de Ajustes');
      await tester.pumpWidget(const MaterialApp(home: PapeleraScreen()));
      await _ciclos(tester);
      expect(find.byType(SyncBanner), findsNothing,
          reason: 'la banda sale de Papelera');
    });
  });

  group('G09-3 · pago base a entrenadores', () {
    testWidgets('«12x» no cierra el diálogo: avisa dentro y '
        'sin guardar', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(_bdVacia);
      await _fijarSesion(tester, telegramId: 735772141);
      await tester.pumpWidget(const MaterialApp(home: AdminScreen()));
      await _abrirModulo(tester, 'Configuración y datos');
      await tester.scrollUntilVisible(
          find.text('Pago base a entrenadores'), 300,
          maxScrolls: 60);
      await tester.pump();
      await tester.tap(find.text('Pago base a entrenadores'));
      expect(
          await _esperarHasta(tester, find.text('Pago a entrenadores')),
          isTrue,
          reason: 'el diálogo de pago base no abrió');
      final campo = find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField));
      // Estado ANTES del intento inválido (corrección del
      // coordinador sobre el endurecimiento F02-HF): la
      // primera versión de esta comprobación exigía la
      // config a null «porque la BD nació vacía», pero el
      // propio recorrido (abrir el módulo y el diálogo) ya
      // había asentado el valor vigente en la config al
      // llegar aquí — lo que «sin guardar» debe probar es
      // que el intento inválido no MUEVE nada respecto a
      // este antes, no un vacío supuesto.
      final antesInvalido = await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        final opsCfg = await db.query('ops_queue',
            where: "tipo = 'actualizar_config_gym'");
        final cfg = await LocalDb.instance
            .getConfigNegocio('pago_entrenador_por_cliente');
        return (opsCfg: opsCfg.length, cfg: cfg);
      });
      await tester.enterText(campo, '12x');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Guardar'));
      await _ciclos(tester);
      // Sigue abierto, con el aviso dentro.
      expect(find.text('Pago a entrenadores'), findsOneWidget,
          reason: 'con un pago inválido el diálogo no debe '
              'cerrarse en silencio');
      expect(
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('Pago inválido')),
          findsOneWidget,
          reason: 'el aviso debe salir dentro del diálogo');
      expect(find.text('12x'), findsOneWidget,
          reason: 'lo tecleado se conserva');
      // F02-HF (z25_sl9_1-1): «sin guardar» se comprueba
      // contra el estado real, no solo contra el aviso:
      // ni la config de negocio, ni la cola de ops, ni la
      // lectura vigente del pago pueden haberse movido
      // (el valor que rige sigue siendo el de por defecto,
      // 150, porque la BD nació vacía).
      final trasInvalido = await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        final opsCfg = await db.query('ops_queue',
            where: "tipo = 'actualizar_config_gym'");
        final cfg = await LocalDb.instance
            .getConfigNegocio('pago_entrenador_por_cliente');
        final pago = await PerfilService.instance.getPagoEntrenador();
        return (opsCfg: opsCfg.length, cfg: cfg, pago: pago);
      });
      expect(trasInvalido!.opsCfg, antesInvalido!.opsCfg,
          reason: 'un pago inválido no debe encolar la op '
              'de configuración');
      expect(trasInvalido.cfg, antesInvalido.cfg,
          reason: 'un pago inválido no debe escribir la '
              'config de negocio (queda como estaba antes '
              'del intento)');
      expect(trasInvalido.pago, 150,
          reason: 'el pago vigente sigue como estaba tras '
              'el intento inválido');
    });
  });

  group('A1 · diff antes de cambiar un precio', () {
    testWidgets('editar el monto de un tipo muestra viejo → '
        'nuevo y cancelar no encola nada', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.setAjustes({
          'tipos_pago': [
            {
              'id': 'mensual',
              'nombre': 'Mensualidad',
              'monto': 2000.0,
              'dias': 30,
              'activo': true,
            },
          ],
        });
      });
      await _fijarSesion(tester, telegramId: 735772141);
      await tester.pumpWidget(const MaterialApp(home: AdminScreen()));
      await _abrirModulo(tester, 'Configuración y datos');
      await tester.scrollUntilVisible(find.text('Tipos de pago'), 300,
          maxScrolls: 60);
      await tester.pump();
      await tester.tap(find.text('Tipos de pago'));
      expect(
          await _esperarHasta(tester, find.text('Mensualidad'),
              intentos: 40),
          isTrue,
          reason: 'la pantalla de tipos no cargó la Mensualidad');
      await tester.tap(find.byIcon(Icons.edit_rounded).first);
      expect(
          await _esperarHasta(
              tester, find.text('Editar Mensualidad')),
          isTrue,
          reason: 'el diálogo de edición del tipo no abrió');
      final campoMonto = find.byWidgetPredicate((w) =>
          w is TextField && w.decoration?.labelText == 'Monto (CUP)');
      await tester.enterText(campoMonto, '2500');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Guardar'));
      // La confirmación muestra la DIFERENCIA.
      expect(
          await _esperarHasta(
              tester, find.text('Confirmar cambio de precio')),
          isTrue,
          reason: 'antes de aplicar debe pedirse confirmación '
              'con el diff');
      expect(find.textContaining('→'), findsWidgets,
          reason: 'el diff dice viejo → nuevo');
      expect(find.textContaining('2500'), findsWidgets);
      // F02-HF (z25_sl9_1-2): el diff «2000 → 2500» debe
      // vivir DENTRO de un mismo widget del diálogo de
      // confirmación — no vale la unión de dos diálogos
      // montados (el «2500» tecleado en el diálogo de
      // edición aún en animación no prueba el diff).
      final dialogoConf = find.ancestor(
          of: find.text('Confirmar cambio de precio'),
          matching: find.byType(AlertDialog));
      expect(dialogoConf, findsOneWidget,
          reason: 'la confirmación es un AlertDialog propio');
      final textosConf = tester
          .widgetList<Text>(find.descendant(
              of: dialogoConf, matching: find.byType(Text)))
          .map((t) => t.data ?? '')
          .toList();
      expect(
          textosConf.any((t) =>
              t.contains('2000') &&
              t.contains('→') &&
              t.contains('2500') &&
              t.indexOf('2000') < t.indexOf('2500')),
          isTrue,
          reason: 'un mismo texto de la confirmación debe '
              'contener el diff completo y en orden: '
              '2000 → 2500 (textos del diálogo: $textosConf)');
      // Cancelar: precio intacto y cero ops.
      await tester.tap(find.widgetWithText(TextButton, 'Cancelar'));
      await _ciclos(tester);
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: "tipo = 'guardar_tipos_pago'");
      expect(ops, isEmpty,
          reason: 'cancelar el cambio de precio no encola nada');
      final aj = await LocalDb.instance.getAjustes();
      final tipos = aj['tipos_pago'] as List;
      expect((tipos.single as Map)['monto'], 2000.0,
          reason: 'el precio queda intacto tras cancelar');
    });
  });

  group('G09-4 · recogida con fallo', () {
    testWidgets('el aviso no pinta la excepción cruda',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
        // Un pago en efectivo pendiente del entrenador 111:
        // la fila de «Pendiente a entregar» lo ofrece.
        final db = await LocalDb.instance.db;
        await db.insert('pagos', {
          'id': 1,
          'data': jsonEncode({
            'id': 1,
            'telegram_user_id': 111,
            'registrado_por': 'Gabriel',
            'metodo': 'efectivo',
            'monto': 500.0,
            'fecha': '2026-11-16',
          }),
          'sync_seq': 1,
        });
      });
      // Sesión de dueño SIN telegram_id: registrarEntregaEfectivo
      // rechaza en local (autor 0) — el fallo forzado del test.
      await _fijarSesion(tester);
      expect(AuthService().isOwner, isTrue);
      expect(AuthService().telegramId, isNull);
      await tester.pumpWidget(const MaterialApp(home: AdminScreen()));
      await _abrirModulo(tester, 'Caja y dinero');
      await tester.scrollUntilVisible(find.text('Cierre de caja'), 300,
          maxScrolls: 60);
      await tester.pump();
      await tester.tap(find.text('Cierre de caja'));
      expect(await _esperarHasta(tester, find.text('Recogida')),
          isTrue,
          reason: 'la sección de cobros no pintó la recogida');
      await tester.tap(find.text('Recogida'));
      expect(
          await _esperarHasta(tester, find.text('Registrar recogida')),
          isTrue,
          reason: 'el diálogo de recogida no abrió');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Registrar'));
      expect(
          await _esperarHasta(
              tester, find.textContaining('No se pudo registrar')),
          isTrue,
          reason: 'el fallo debe avisarse');
      expect(find.textContaining('Exception'), findsNothing,
          reason: 'la excepción cruda nunca llega a pantalla: '
              'mensaje amable y excepción al log');
    });
  });
}
