/// Lote 1.35 · SL-1 · Fichas del DETALLE del invitado:
/// - A-22 (g06 nº22): «Ajustar acceso (clave)» sin guarda
///   offline — era la única acción destructiva del detalle
///   que no consultaba `_offlineCache`.
/// - G12-7 [CORR]: el traductor de acciones del equipo
///   devolvía la clave cruda (`resetear_pin`, claves nuevas)
///   en su rama por defecto.
/// - G12-3 [VIS]: WhatsApp y Convertir vivían en TRES
///   superficies (barra inferior, tarjeta de acciones y
///   tarjeta de conversión); queda una por acción.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/invitados.dart' as ui_inv;
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('${p.join(dir, 'ironbody.db')}$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _drenar(WidgetTester tester,
    {int vueltas = 12, int ms = 110}) async {
  for (var i = 0; i < vueltas; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration(milliseconds: ms));
    });
    await tester.pump(const Duration(milliseconds: 50));
  }
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

Future<void> _fijarSesion(WidgetTester tester, String email) async {
  final sesion = jsonEncode({
    'access_token': _jwtDeMentira(email),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000aa',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth
        .setInitialSession(sesion);
  });
}

Map<String, dynamic> _detalleJson({
  List<dynamic> staff = const [],
}) =>
    {
      'invitado': {
        'id': 'inv-1',
        'nombre': 'Invitado Uno',
        'telefono': '58112233',
        'estado': 'activo',
        'creado_en': '2026-11-01T10:00:00',
        'caduca_en': '2027-01-01T10:00:00',
      },
      'staff_acciones': staff,
    };

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    final docs = await Directory.systemTemp.createTemp('sl1_det_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (_, __) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
  });

  setUp(() async {
    await _bdVacia();
    ui_inv.servicioInvitadosParaTest = null;
    ui_inv.conteoReportesPlusParaTest = () async => 0;
  });

  tearDown(() {
    ui_inv.servicioInvitadosParaTest = null;
    ui_inv.conteoReportesPlusParaTest = null;
  });

  testWidgets(
      'A-22: con el detalle en caché offline, «Ajustar acceso '
      '(clave)» NO ejecuta la revocación y avisa', (tester) async {
    await _fijarSesion(tester, 'jctr0602@ironbody.gym');
    // Detalle sembrado en caché; la RPC de detalle cuelga:
    // la ficha queda en solo lectura offline (_offlineCache).
    await tester.runAsync(() async {
      await LocalDb.instance.guardarDetalleCacheInvitado(
          'inv-1', jsonEncode(_detalleJson()));
    });
    final llamadas = <String>[];
    final colgada = Completer<dynamic>();
    ui_inv.servicioInvitadosParaTest = InvitadosService(
      rpc: (nombre, params) async {
        llamadas.add(nombre);
        if (nombre == 'invitado_detalle') return colgada.future;
        return <String, dynamic>{};
      },
    );
    await tester.pumpWidget(const MaterialApp(
        home: ui_inv.InvitadoDetalleScreen(invitadoId: 'inv-1')));
    await _drenar(tester);
    expect(find.textContaining('solo lectura'), findsWidgets,
        reason: 'la ficha debe estar en modo caché offline');

    final boton = find.widgetWithText(
        OutlinedButton, 'Ajustar acceso (clave)');
    await tester.scrollUntilVisible(boton, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(boton);
    await _drenar(tester, vueltas: 6);

    // Camino de la base: se abre el diálogo anti-fuga; si se
    // completa, la RPC de ajuste se ejecuta. Se completa para
    // demostrar el alcance real del hueco.
    if (find
        .text('Ajustar acceso del invitado')
        .evaluate()
        .isNotEmpty) {
      await tester.tap(find.text(
          'La persona confirmó su nombre y su fecha de registro'));
      await tester.pump();
      await tester.enterText(
          find.byType(TextField).last, 'claveNueva1');
      await tester.pump();
      await tester.tap(find.widgetWithText(
          ElevatedButton, 'Ajustar clave'));
      await _drenar(tester, vueltas: 6);
    }

    expect(llamadas.where((n) => n == 'invitado_ajustar_clave'),
        isEmpty,
        reason: 'offline no debe llamarse a la RPC de ajuste');
    expect(
        find.text('Sin conexión: el detalle está en solo lectura.'),
        findsOneWidget,
        reason: 'debe salir el aviso estándar de solo lectura');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  });

  testWidgets(
      'G12-7: las acciones del equipo se leen en lenguaje '
      'llano, nunca en clave cruda', (tester) async {
    await _fijarSesion(tester, 'jctr0602@ironbody.gym');
    ui_inv.servicioInvitadosParaTest = InvitadosService(
      rpc: (nombre, params) async {
        if (nombre == 'invitado_detalle') {
          return _detalleJson(staff: [
            {
              'accion': 'resetear_pin',
              'actor': 'jc',
              'fecha': '2026-11-10T10:00:00',
              'detalle': <String, dynamic>{},
            },
            {
              'accion': 'accion_inventada_xyz',
              'actor': 'jc',
              'fecha': '2026-11-11T10:00:00',
              'detalle': <String, dynamic>{},
            },
          ]);
        }
        return <String, dynamic>{};
      },
    );
    await tester.pumpWidget(const MaterialApp(
        home: ui_inv.InvitadoDetalleScreen(invitadoId: 'inv-1')));
    await _drenar(tester);
    await tester.scrollUntilVisible(
        find.text('Acciones del equipo'), 300,
        scrollable: find.byType(Scrollable).first);
    await _drenar(tester, vueltas: 4);

    expect(find.textContaining('resetear_pin'), findsNothing,
        reason: 'la clave cruda no va a pantalla');
    expect(find.textContaining('accion_inventada_xyz'),
        findsNothing,
        reason: 'una clave desconocida tampoco se pinta cruda');
    expect(find.textContaining('PIN'), findsWidgets,
        reason: 'resetear_pin se traduce a lenguaje llano');
    expect(find.textContaining('Acción registrada'), findsWidgets,
        reason: 'la rama por defecto es «Acción registrada»');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  });

  testWidgets(
      'G12-3: la ficha tiene UNA superficie para Convertir y '
      'UNA para WhatsApp', (tester) async {
    await _fijarSesion(tester, 'jctr0602@ironbody.gym');
    ui_inv.servicioInvitadosParaTest = InvitadosService(
      rpc: (nombre, params) async {
        if (nombre == 'invitado_detalle') return _detalleJson();
        return <String, dynamic>{};
      },
    );
    await tester.pumpWidget(const MaterialApp(
        home: ui_inv.InvitadoDetalleScreen(invitadoId: 'inv-1')));
    await _drenar(tester);
    // Se recorre TODA la ficha para que cada tarjeta exista.
    await tester.scrollUntilVisible(
        find.text('Ajustar acceso (clave)'), 300,
        scrollable: find.byType(Scrollable).first);
    await _drenar(tester, vueltas: 4);

    int botones(String fragmento) {
      var n = 0;
      for (final tipo in [
        FilledButton,
        OutlinedButton,
        ElevatedButton,
        TextButton,
        BotonPrimario,
      ]) {
        n += find
            .widgetWithText(tipo, fragmento, skipOffstage: false)
            .evaluate()
            .length;
      }
      return n;
    }

    // Convertir: solo el botón de la tarjeta de conversión.
    expect(botones('Convertir en cliente'), 1,
        reason: 'un solo botón «Convertir en cliente»');
    // WhatsApp: solo un acceso (la tarjeta de acciones).
    var whats = 0;
    for (final tipo in [
      FilledButton,
      OutlinedButton,
      ElevatedButton,
      TextButton,
      BotonPrimario,
    ]) {
      whats += find
          .byWidgetPredicate(
              (w) => w.runtimeType == tipo, skipOffstage: false)
          .evaluate()
          .where((e) {
            var tiene = false;
            void busca(Element hijo) {
              if (hijo.widget is Text &&
                  ((hijo.widget as Text).data ?? '')
                      .contains('WhatsApp')) {
                tiene = true;
              }
              hijo.visitChildren(busca);
            }

            e.visitChildren(busca);
            return tiene;
          })
          .length;
    }
    expect(whats, 1, reason: 'un solo acceso de WhatsApp');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
  });
}
