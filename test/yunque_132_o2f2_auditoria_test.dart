/// 1.32 (Oleada 2, Fase 2 · G-80): la Auditoría adopta la
/// cabecera de día de la plantilla del Día de Servicios — el
/// día a la izquierda y los TOTALES del grupo visible a la
/// derecha («N operaciones · M alertas») — conservando los
/// filtros (Otros y alertas / Todo / Solo mías, Hoy, por
/// entrenador) y el detalle por fila intactos.
///
/// Contrato que se fija:
/// 1. El puro resumenDiaAuditoria cuenta las visibles y las
///    alertas con la MISMA definición de siempre (esOpAlerta:
///    tipo sensible o estado de fallo); el texto usa el
///    singular cuando toca y omite las alertas si no hay.
/// 2. Costura a 420×800: con el filtro inicial («Otros y
///    alertas») la cabecera de hoy cuenta solo lo visible;
///    al pasar a «Todo», la MISMA cabecera recounta con la
///    op rutinaria propia incluida.
/// 3. El detalle por fila sigue abriendo su diálogo con
///    actor, fecha y estado.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/actividad_cliente.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/auditoria.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, int telegramId) {
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
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion({
  required String email,
  required int telegramId,
}) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await Supabase.instance.client.auth.setInitialSession(sesion);
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
  final db = await LocalDb.instance.db;
  await db.delete('ops_queue');
  await db.delete('meta');
}

Future<bool> _esperarTexto(WidgetTester tester, String fragmento) async {
  for (var i = 0; i < 90; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 100));
    if (find.textContaining(fragmento).evaluate().isNotEmpty) {
      return true;
    }
  }
  return false;
}

/// Instante de pared habanero (hoy/ayer a una hora dada) en
/// el formato ISO con offset que la cola guarda.
String _tsHabana(DateTime dia, int hora) => isoHabana(DateTime(
    dia.year, dia.month, dia.day, hora, 15));

Future<void> _op(String uuid, String tipo, String estado, String ts,
    Map<String, dynamic> payload) async {
  final db = await LocalDb.instance.db;
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': estado,
    'creada_ts': ts,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  group('resumenDiaAuditoria (puro)', () {
    test('cuenta visibles y alertas con la definición de siempre', () {
      final r = resumenDiaAuditoria([
        {'tipo': 'pago_mensual', 'estado': 'aplicada', 'payload': '{}'},
        {'tipo': 'inscribir', 'estado': 'pendiente', 'payload': '{}'},
        {'tipo': 'foto', 'estado': 'rechazada', 'payload': '{}'},
      ]);
      expect(r.operaciones, 3);
      // pago_mensual es sensible; la foto rechazada es alerta
      // por estado; la inscripción rutinaria no.
      expect(r.alertas, 2);
      expect(textoTotalesDiaAuditoria(r), '3 operaciones · 2 alertas');
    });

    test('singular y sin alertas: el texto no inventa', () {
      expect(
          textoTotalesDiaAuditoria(
              resumenDiaAuditoria([
            {'tipo': 'inscribir', 'estado': 'aplicada', 'payload': '{}'},
          ])),
          '1 operación');
      expect(
          textoTotalesDiaAuditoria(
              resumenDiaAuditoria([
            {'tipo': 'gasto', 'estado': 'aplicada', 'payload': '{}'},
          ])),
          '1 operación · 1 alerta');
    });
  });

  group('AuditoriaScreen (costura 420×800)', () {
    testWidgets(
        'cabecera con totales del grupo visible; filtros y detalle '
        'conservados', (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final hoy = ahoraHabana();
      final ayer = sumarDiasCalendario(hoy, -1);
      await tester.runAsync(() async {
        await _bdVacia();
        await _fijarSesion(
            email: 'jctr0602@ironbody.gym', telegramId: 735772141);
        await _op('op-hoy-pago', 'pago_mensual', 'aplicada',
            _tsHabana(hoy, 9), {
          'cliente_id': 5,
          'monto': 2000,
          'metodo': 'efectivo',
        });
        await _op('op-hoy-insc', 'inscribir', 'pendiente',
            _tsHabana(hoy, 10), {'nombre': 'Ana Prueba'});
        await _op('op-ayer-gasto', 'gasto', 'aplicada',
            _tsHabana(ayer, 18), {'concepto': 'Luz del local', 'monto': 500});
      });
      await tester.pumpWidget(MaterialApp(
        home: AuditoriaScreen(
          servicioActividad:
              ActividadClienteService(rpcParaTest: (_) async => []),
        ),
      ));
      // Filtro inicial del dueño: «Otros y alertas» — la
      // inscripción rutinaria propia queda fuera y la
      // cabecera de hoy cuenta SOLO lo visible.
      expect(await _esperarTexto(tester, '1 operación · 1 alerta'),
          isTrue,
          reason: 'hoy: solo el pago (alerta) es visible al abrir');
      // 1.34 (C-48 · G-01): los filtros van PLEGADOS — «Hoy»
      // solo aparece ya como cabecera del día (el chip de
      // filtro rápido vive en la hoja, tras el botón).
      expect(find.text('Hoy'), findsOneWidget);
      // A «Todo» (desde la hoja de filtros, tras el botón
      // «Filtrar · Otros y alertas»): la misma cabecera
      // recounta incluyendo la inscripción (los totales son
      // del grupo VISIBLE).
      await tester.tap(find.text('Filtrar · Otros y alertas'));
      expect(await _esperarTexto(tester, 'Alcance'), isTrue,
          reason: 'la hoja de filtros abre tras el botón');
      // Se toca la FILA del radio (no su texto) y con la hoja
      // ya asentada: durante la animación de entrada el toque
      // al texto falla el hit-test y el radio no cambia.
      final filaTodo = find.descendant(
          of: find.byType(BottomSheet),
          matching:
              find.widgetWithText(RadioListTile<FiltroAuditoria>, 'Todo'));
      await tester.ensureVisible(filaTodo);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(filaTodo);
      await tester.pump(const Duration(milliseconds: 300));
      // Con la fuente del entorno de test la hoja es más alta
      // que la ventana: «Aplicar» nace bajo el pliegue y hay
      // que traerlo a la vista antes de tocarlo.
      await tester.scrollUntilVisible(find.text('Aplicar'), 100,
          scrollable: find.descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable)));
      await tester.tap(find.text('Aplicar'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(await _esperarTexto(tester, '2 operaciones · 1 alerta'),
          isTrue,
          reason: 'en Todo, hoy suma la inscripción rutinaria');

      // Ayer, con su gasto: puede quedar bajo el pliegue.
      await tester.scrollUntilVisible(find.text('Ayer'), 200,
          scrollable: find.descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable)));
      expect(find.text('Ayer'), findsOneWidget);

      // El detalle por fila se conserva: el gasto (sin
      // cliente) abre su diálogo con actor y estado.
      await tester.scrollUntilVisible(
          find.textContaining('Luz del local'), 200,
          scrollable: find.descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable)));
      // Tras el scroll la lista aún va con inercia y el
      // primer toque la frena en vez de abrir: se asienta y
      // se toca el centro de la fila.
      final fila = find.ancestor(
          of: find.textContaining('Luz del local'),
          matching: find.byType(ListTile));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tapAt(tester.getCenter(fila));
      expect(await _esperarTexto(tester, 'Sincronizada'), isTrue,
          reason: 'el diálogo de detalle enseña el estado de la op');
      expect(find.textContaining('Actor:'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
