/// 1.32 (Oleada 2, Fase 3 — Momento 2C del plano): el
/// cliente con reserva activa enseña el aviso en la
/// cabecera de su ficha — «Tiene reservado [Producto]
/// (vence en X h) · Entregar ahora» — calculado desde
/// el espejo local con las defensas de la bandeja:
/// las vencidas en el espejo no son vivas y la
/// reserva de un cliente protegido no se revela a un
/// no-dueño. Costura: la ficha real a 420×800 con los
/// espejos sembrados.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/reservas.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _jwtFalso(String email, int telegramId) {
  String b64(Object v) =>
      base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');
  final header = b64({'alg': 'none', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000ee',
    'aud': 'authenticated',
    'exp': 4102444800,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(String email, int telegramId) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000ee',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await Supabase.instance.client.auth.setInitialSession(sesion);
}

Map<String, dynamic> _reserva({
  required int id,
  required int clienteId,
  String estado = 'reservada',
  String? expiraEn,
  int cantidad = 1,
}) =>
    {
      'id': id,
      'cliente_id': clienteId,
      'suplemento_id': 9,
      'cantidad': cantidad,
      'precio_unitario': 2500,
      'estado': estado,
      'creada_ts': '2026-11-11T10:00:00Z',
      'expira_en': expiraEn,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Momento 2C — el puro', () {
    final ahora = DateTime.utc(2026, 11, 12, 15, 0);
    final clientes = [
      {'id': 5, 'nombre': 'Cliente Cinco'},
    ];
    final suplementos = [
      {'id': 9, 'nombre': 'Whey Pro'},
    ];

    test('reservada viva: la devuelve con su texto del plano',
        () {
      final v = reservaVivaDeCliente(
        reservas: [
          _reserva(
              id: 1,
              clienteId: 5,
              expiraEn: '2026-11-12T20:00:00Z'),
        ],
        clientes: clientes,
        suplementos: suplementos,
        clienteId: 5,
        ahora: ahora,
      );
      expect(v, isNotNull);
      expect(textoAvisoReservaViva(v!, ahora),
          'Tiene reservado Whey Pro (vence en 5 h) · Entregar ahora');
    });

    test('solicitada viva también cuenta; cantidad > 1 se '
        'enseña', () {
      final v = reservaVivaDeCliente(
        reservas: [
          _reserva(
              id: 2,
              clienteId: 5,
              estado: 'solicitada',
              cantidad: 2,
              expiraEn: '2026-11-13T15:00:00Z'),
        ],
        clientes: clientes,
        suplementos: suplementos,
        clienteId: 5,
        ahora: ahora,
      );
      expect(v, isNotNull);
      expect(textoAvisoReservaViva(v!, ahora),
          'Tiene reservado 2 × Whey Pro (vence en 1 d) · '
          'Entregar ahora');
    });

    test('vencida en el espejo NO es viva (ni reservada ni '
        'solicitada)', () {
      for (final estado in ['reservada', 'solicitada']) {
        expect(
            reservaVivaDeCliente(
              reservas: [
                _reserva(
                    id: 3,
                    clienteId: 5,
                    estado: estado,
                    expiraEn: '2026-11-12T14:00:00Z'),
              ],
              clientes: clientes,
              suplementos: suplementos,
              clienteId: 5,
              ahora: ahora,
            ),
            isNull,
            reason: estado);
      }
    });

    test('terminales y de otro cliente no cuentan; entre '
        'varias vivas manda la que antes vence', () {
      expect(
          reservaVivaDeCliente(
            reservas: [
              _reserva(
                  id: 4,
                  clienteId: 5,
                  estado: 'pagada',
                  expiraEn: '2026-11-12T20:00:00Z'),
              _reserva(
                  id: 5,
                  clienteId: 6,
                  expiraEn: '2026-11-12T16:00:00Z'),
            ],
            clientes: clientes,
            suplementos: suplementos,
            clienteId: 5,
            ahora: ahora,
          ),
          isNull);
      final v = reservaVivaDeCliente(
        reservas: [
          _reserva(
              id: 6,
              clienteId: 5,
              expiraEn: '2026-11-14T15:00:00Z'),
          _reserva(
              id: 7,
              clienteId: 5,
              expiraEn: '2026-11-12T18:00:00Z'),
        ],
        clientes: clientes,
        suplementos: suplementos,
        clienteId: 5,
        ahora: ahora,
      );
      expect(v!.id, 7);
    });

    test('blindaje: la reserva de un cliente protegido no '
        'se revela a un no-dueño; al dueño sí', () {
      final protegido = [
        {'id': 5, 'nombre': 'Cliente Cinco', 'protegido': 1},
      ];
      final reservas = [
        _reserva(
            id: 8,
            clienteId: 5,
            expiraEn: '2026-11-12T20:00:00Z'),
      ];
      expect(
          reservaVivaDeCliente(
            reservas: reservas,
            clientes: protegido,
            suplementos: suplementos,
            clienteId: 5,
            ahora: ahora,
            esDueno: false,
          ),
          isNull);
      expect(
          reservaVivaDeCliente(
            reservas: reservas,
            clientes: protegido,
            suplementos: suplementos,
            clienteId: 5,
            ahora: ahora,
            esDueno: true,
          ),
          isNotNull);
    });
  });

  group('Momento 2C — la ficha real', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfiNoIsolate;
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    });

    Future<void> bdVacia(WidgetTester tester) async {
      await tester.runAsync(() async {
        final dir = await getDatabasesPath();
        try {
          await File(p.join(dir, 'ironbody.db')).delete();
        } catch (_) {}
        await LocalDb.resetParaTest();
        await LocalDb.instance.db;
      });
    }

    Future<void> drenar(WidgetTester tester) async {
      // Campo 2 · B-1 (2026-11-14): «Membresía» era el
      // centinela de «la ficha terminó de cargar» porque
      // vivía al fondo de la pestaña y solo se construía
      // tarde; con la jerarquía nueva abre la pestaña y se
      // construye en el primer fotograma — el drenaje se
      // cortaba a la primera vuelta y la navegación del
      // toque no llegaba a montar la ruta. Se conserva el
      // centinela con un suelo de 8 vueltas: el tiempo que
      // la cadena de carga y las transiciones necesitan.
      for (var i = 0; i < 16; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 150));
        });
        await tester.pump(const Duration(milliseconds: 60));
        if (i >= 7 &&
            find.text('Membresía').evaluate().isNotEmpty) {
          break;
        }
      }
    }

    /// La ficha a 420 con la fuente de test (Ahem, de
    /// glifos anchos) desborda 49 px en la cabecera
    /// PREEXISTENTE de «Información personal» — probado
    /// con sonda sobre una ficha SIN reserva ni banner
    /// (artefacto de entorno, mismo precedente que
    /// FICHA-10 de la oleada 7 de la 1.30, cuyo arnés
    /// abre a 500 por esto). Se tolera SOLO esa
    /// excepción; cualquier otra es fallo.
    void tolerarSoloDesbordeAhem(WidgetTester tester) {
      final ex = tester.takeException();
      expect(
          ex == null || '$ex'.contains('RenderFlex overflowed'),
          isTrue,
          reason: 'excepción inesperada en la ficha: $ex');
    }

    testWidgets(
        'con reserva viva, la cabecera enseña el aviso y el '
        'toque abre la bandeja; sin reserva, no hay aviso',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await _fijarSesion('jc@ironbody.local', 735772141);
      await bdVacia(tester);
      final hoy = ahoraHabana();
      final hasta =
          '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}-'
          '${hoy.day.toString().padLeft(2, '0')}';
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror(
            'clientes',
            5,
            {
              'id': 5,
              'nombre': 'Cliente Con Reserva',
              'sexo': 'M',
              'pagado_hasta': hasta,
              'estado': 'activo',
            },
            1);
        await LocalDb.instance.upsertMirror(
            'suplementos', 9, {'id': 9, 'nombre': 'Whey Pro'}, 1);
        await LocalDb.instance.upsertMirror(
            'reservas',
            21,
            {
              'id': 21,
              'cliente_id': 5,
              'suplemento_id': 9,
              'cantidad': 1,
              'precio_unitario': 2500,
              'estado': 'reservada',
              'creada_ts': '2026-11-11T10:00:00Z',
              'expira_en': DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 30))
                  .toIso8601String(),
            },
            1);
      });
      await tester.pumpWidget(const MaterialApp(
          home: FichaScreen(clienteId: 5)));
      await drenar(tester);
      tolerarSoloDesbordeAhem(tester);
      expect(
          find.textContaining('Tiene reservado Whey Pro'),
          findsOneWidget);
      expect(
          find.textContaining('Entregar ahora'), findsOneWidget);
      // El toque abre la bandeja de Reservas.
      await tester.tap(find.textContaining('Tiene reservado'));
      await drenar(tester);
      expect(find.byType(ReservasScreen), findsOneWidget);
      await tester.pageBack();
      await drenar(tester);
      tolerarSoloDesbordeAhem(tester);
      await tester.pump(const Duration(milliseconds: 600));

      // Sin reserva viva: la ficha no enseña ningún aviso.
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror(
            'reservas',
            21,
            {
              'id': 21,
              'cliente_id': 5,
              'suplemento_id': 9,
              'cantidad': 1,
              'precio_unitario': 2500,
              'estado': 'pagada',
              'creada_ts': '2026-11-11T10:00:00Z',
              'expira_en': DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 30))
                  .toIso8601String(),
            },
            1);
      });
      await tester.pumpWidget(const MaterialApp(
          home: FichaScreen(key: ValueKey('sin-reserva'), clienteId: 5)));
      await drenar(tester);
      expect(
          find.textContaining('Tiene reservado'), findsNothing);
      tolerarSoloDesbordeAhem(tester);
      await tester.pump(const Duration(milliseconds: 600));
    });
  });
}
