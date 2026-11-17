/// Lote 1.35 · SL-10 — Bandeja WhatsApp, Campañas,
/// Plantillas y Mis avisos.
///
/// G04-5: los controles de la Bandeja van PLEGADOS tras
/// un botón que resume su estado; la lista manda.
/// G04-6: el snack de guardar plantillas de campaña no
/// repite «(se sincronizarán)».
/// G04-7: borrar una plantilla compartida pide la
/// confirmación de la casa antes de borrar.
/// G04-8: si setMeta falla, el interruptor de Avisos no
/// queda cambiado en pantalla: revierte y avisa.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/plantilla_mensaje.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/avisos.dart';
import 'package:ironbody_gym/ui/bandeja_whatsapp.dart';
import 'package:ironbody_gym/ui/campana_wa.dart';
import 'package:ironbody_gym/ui/plantillas_mensaje.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _dbNombre = 'test_lote135_sl10_bandeja.db';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, _dbNombre)).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

String _jwtDeMentira(String email) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000aa',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtDeMentira('jctr0602@ironbody.gym'),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000aa',
      'aud': 'authenticated',
      'email': 'jctr0602@ironbody.gym',
      'app_metadata': {'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _asentarHasta(
    WidgetTester tester, bool Function() condicion) async {
  for (var i = 0; i < 60 && !condicion(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocalDb.nombreArchivoDbForzado = _dbNombre;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  testWidgets('G04-5 · la Bandeja nace con los controles '
      'plegados tras su botón resumen', (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
      final hoy = ahoraHabana();
      final ayer =
          isoHabana(hoy.subtract(const Duration(days: 1)))
              .substring(0, 10);
      await LocalDb.instance.upsertMirror('clientes', 31, {
        'id': 31,
        'nombre': 'Vencido Uno',
        'estado': 'activo',
        'pagado_hasta': ayer,
        'telefono': '58112233',
        'carnet': '900520',
        'sexo': 'M',
      }, 1);
    });
    await _fijarSesionDueno(tester);
    await tester.pumpWidget(
        const MaterialApp(home: BandejaWhatsappScreen()));
    await _asentarHasta(
        tester, () => find.text('Vencido Uno').evaluate().isNotEmpty);

    // Plegados: ni el buscador ni el chip ni el lote
    // ocupan espacio permanente.
    expect(find.widgetWithText(FilterChip, 'Con teléfono'),
        findsNothing);
    expect(find.textContaining('Enviar en lote'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    // El botón resumen sí, y resume el progreso.
    final resumen = find.textContaining('Controles');
    expect(resumen, findsOneWidget);
    expect(find.textContaining('0 de 1 contactados'), findsWidgets);

    // Desplegando, los controles están.
    await tester.tap(resumen);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.widgetWithText(FilterChip, 'Con teléfono'),
        findsOneWidget);
    expect(find.textContaining('Enviar en lote'), findsOneWidget);
    // F02-HF (z27_sl10_1-4): al desplegar también vuelve el
    // BUSCADOR, presente y funcional: acepta texto y el
    // filtro sigue aplicándose a la lista.
    expect(find.byType(TextField), findsOneWidget,
        reason: 'desplegando, el buscador vuelve junto a '
            'los demás controles');
    await tester.enterText(find.byType(TextField), 'Vencido');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Vencido Uno'), findsOneWidget,
        reason: 'el buscador acepta texto y el contacto '
            'que coincide sigue visible');
    await tester.enterText(
        find.byType(TextField), 'NombreQueNoExiste135');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Vencido Uno'), findsNothing,
        reason: 'el filtro del buscador sigue aplicado '
            'tras desplegar: lo que no coincide se oculta');
  });

  testWidgets('G04-6 · guardar plantillas de campaña no '
      'repite el sufijo de sync', (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
      final aj = await LocalDb.instance.getAjustes();
      aj['plantillas_wa'] = [
        {'nombre': 'Saludo', 'texto': 'Hola {nombre}'},
      ];
      await LocalDb.instance.setAjustes(aj);
    });
    await _fijarSesionDueno(tester);
    await tester
        .pumpWidget(const MaterialApp(home: CampanaWaScreen()));
    await _asentarHasta(
        tester, () => find.text('Plantillas').evaluate().isNotEmpty);
    await tester.tap(find.text('Plantillas'));
    await _asentarHasta(tester,
        () => find.text('Plantillas de WhatsApp').evaluate().isNotEmpty);
    // La hoja inferior también entra con animación.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byIcon(Icons.delete_outline_rounded));
    await _asentarHasta(
        tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
    expect(find.text('Plantillas guardadas'), findsOneWidget);
    expect(find.textContaining('se sincronizarán'), findsNothing);
    expect(find.textContaining('se aplicará al sincronizar'),
        findsNothing);
  });

  testWidgets('G04-7 · borrar una plantilla pide '
      'confirmación antes de borrar', (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
      await crearPlantilla('Saludo SL10', 'Hola {nombre}');
    });
    await _fijarSesionDueno(tester);
    await tester
        .pumpWidget(const MaterialApp(home: PlantillasScreen()));
    await _asentarHasta(
        tester, () => find.text('Saludo SL10').evaluate().isNotEmpty);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await _asentarHasta(
        tester, () => find.text('Eliminar').evaluate().isNotEmpty);
    // La animación de apertura del menú deja un
    // IgnorePointer unos instantes: se deja asentar del
    // todo antes de tocar el ítem.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Eliminar'));
    await _asentarHasta(
        tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    // Un toque NO borra: abre la confirmación y la
    // plantilla sigue en la lista.
    expect(find.text('Saludo SL10'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('¿Eliminar'), findsWidgets);
    // Cancelando, sigue ahí.
    await tester.tap(find.text('Cancelar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Saludo SL10'), findsOneWidget);
    final quedan = await tester
        .runAsync(() => listarPlantillas());
    expect(quedan!.length, 1);
    // F02-HF (z27_sl10_1-2): también se ejercita la
    // CONFIRMACIÓN — un botón de confirmar no-op debe
    // hacer fallar este test. Se repite el camino entero
    // y esta vez se confirma: la plantilla desaparece de
    // la pantalla y del registro.
    await tester.tap(find.byType(PopupMenuButton<String>));
    await _asentarHasta(
        tester, () => find.text('Eliminar').evaluate().isNotEmpty);
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Eliminar'));
    await _asentarHasta(
        tester, () => find.byType(AlertDialog).evaluate().isNotEmpty);
    expect(find.text('Saludo SL10'), findsOneWidget,
        reason: 'antes de confirmar, la plantilla sigue ahí');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Eliminar'));
    await _asentarHasta(tester,
        () => find.text('Saludo SL10').evaluate().isEmpty);
    expect(find.text('Saludo SL10'), findsNothing,
        reason: 'tras confirmar, la plantilla desaparece '
            'de la lista');
    final trasConfirmar = await tester
        .runAsync(() => listarPlantillas());
    expect(trasConfirmar!.length, 0,
        reason: 'tras confirmar, el borrado ocurrió en el '
            'registro, no solo en pantalla');
  });

  testWidgets('G04-8 · si setMeta falla, el interruptor de '
      'Avisos revierte y avisa', (tester) async {
    await tester.runAsync(() async {
      await _bdVacia();
      await LocalDb.instance.setMeta('aviso_vencimientos', '1');
    });
    await tester.pumpWidget(const MaterialApp(home: AvisosScreen()));
    await _asentarHasta(tester,
        () => find.text('Vencimientos').evaluate().isNotEmpty);
    SwitchListTile tile() => tester.widget<SwitchListTile>(
        find.widgetWithText(SwitchListTile, 'Vencimientos'));
    expect(tile().value, isTrue);
    // El guardado deja de funcionar (la tabla meta cae).
    await tester.runAsync(() async {
      final d = await LocalDb.instance.db;
      await d.execute('DROP TABLE meta');
    });
    await tester.tap(find.widgetWithText(SwitchListTile, 'Vencimientos'));
    await _asentarHasta(
        tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
    // Revertido y avisado: no queda «activado» sin estarlo.
    expect(tile().value, isTrue);
    expect(find.textContaining('No se pudo guardar'), findsWidgets);
  });
}
