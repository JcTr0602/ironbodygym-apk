/// Gestión 1.30 · Oleada 2 · Adelantos: cadena `op_uuid`
/// (plan §3, con el ajuste MEDIA-02 de Argón).
///
/// Contrato que se fija:
/// 1. PURO: entran los TRES estados vivos de la cola
///    ('pendiente', 'enviada', 'error') como 'por_enviar';
///    'aplicada' y otros tipos no entran.
/// 2. PURO: deduplicación EXACTA — si el espejo trae una fila
///    con el mismo op_uuid que la op (cualquier estado de la
///    fila), la op no se pinta dos veces.
/// 3. PURO: fallback MEDIA-02 — fila espejo SIN op_uuid + op
///    en 'enviada' + misma identidad (entrenador, monto,
///    motivo normalizado) + creada_ts dentro de ±5 min del
///    creado_en del espejo ⇒ se tapa y deja diagnóstico.
///    Fuera de la ventana, en 'pendiente', o con identidad
///    distinta, NO tapa (podría ser un duplicado real).
/// 4. normalizarMotivoAdelanto: trim + minúsculas + un solo
///    espacio («Almuerzo » == «almuerzo»).
/// 5. SERVICIO con BD: pedir() encola el payload del contrato
///    y mias() lo ve 'por_enviar' en los tres estados; al
///    aterrizar el espejo con el mismo op_uuid, la solicitud
///    se ve UNA vez; tieneVivaIgual caza la viva idéntica
///    (normalizando) e ignora las resueltas.
/// 6. WIDGET (pantalla real): con una viva idéntica, el primer
///    toque en «Enviar solicitud» enseña «Ya tienes una
///    solicitud igual sin resolver» y NO encola; «Pedir
///    igual» encola la segunda.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque3.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/ui/mi_nomina.dart';
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
  for (final t in ['ops_queue', 'solicitudes_adelanto']) {
    try {
      await db.delete(t);
    } catch (_) {}
  }
  await db.delete('meta');
}

Future<void> _espejo(
    String tabla, Object id, Map<String, dynamic> data) async {
  final d = await LocalDb.instance.db;
  await d.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': 1,
  });
}

/// Sondeo intercalado runAsync+pump (patrón de la casa para
/// pantallas con lecturas FFI bajo FakeAsync).
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

Future<void> _ciclos(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _tidGab = 222222;
const _t0 = '2026-11-08T10:00:00-04:00';

SolicitudAdelanto _esp({
  String id = 's1',
  String estado = 'pendiente',
  double monto = 500,
  String motivo = 'almuerzo',
  String? opUuid,
  String creadoEn = _t0,
  int? tid = _tidGab,
}) =>
    SolicitudAdelanto(
      id: id,
      monto: monto,
      motivo: motivo,
      estado: estado,
      opUuid: opUuid,
      creadoEn: creadoEn,
      entrenadorTelegramId: tid,
    );

Map<String, dynamic> _op({
  required String uuid,
  required String estado,
  double monto = 500,
  String motivo = 'almuerzo',
  String creadaTs = _t0,
  int? tid = _tidGab,
}) =>
    {
      'op_uuid': uuid,
      'tipo': 'solicitar_adelanto',
      'estado': estado,
      'creada_ts': creadaTs,
      if (tid != null) 'telegram_id': tid,
      'payload': jsonEncode({'monto': monto, 'motivo': motivo}),
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('Oleada 2 · puro: estados y deduplicación exacta', () {
    test('entran los tres estados vivos; aplicada no', () {
      final out = solicitudesConPendientes(
        espejo: [],
        opsPendientes: [
          _op(uuid: 'u1', estado: 'pendiente'),
          _op(uuid: 'u2', estado: 'enviada'),
          _op(uuid: 'u3', estado: 'error'),
          _op(uuid: 'u4', estado: 'aplicada'),
        ],
      );
      expect(out.length, 3);
      expect(out.every((s) => s.estado == 'por_enviar'), isTrue);
      expect(out.map((s) => s.id),
          containsAll(['op:u1', 'op:u2', 'op:u3']));
    });

    test('la exacta: el espejo con el mismo op_uuid tapa la op '
        'en cualquier estado de la fila', () {
      for (final estadoFila in ['pendiente', 'aprobado', 'rechazado']) {
        final out = solicitudesConPendientes(
          espejo: [_esp(estado: estadoFila, opUuid: 'u1')],
          opsPendientes: [_op(uuid: 'u1', estado: 'enviada')],
        );
        expect(out.length, 1, reason: 'fila $estadoFila');
        expect(out.single.id, 's1');
      }
    });

    test('op_uuid distinto no tapa: la op se enseña', () {
      final out = solicitudesConPendientes(
        espejo: [_esp(opUuid: 'otra')],
        opsPendientes: [_op(uuid: 'u1', estado: 'enviada')],
      );
      expect(out.length, 2);
    });
  });

  group('Oleada 2 · puro: fallback MEDIA-02', () {
    test('dentro de la ventana y con identidad: tapa y '
        'diagnostica (el motivo se compara normalizado)', () {
      final diagnosticos = <String>[];
      final out = solicitudesConPendientes(
        espejo: [_esp(motivo: 'almuerzo')],
        opsPendientes: [
          _op(
              uuid: 'u9',
              estado: 'enviada',
              motivo: '  ALMUERZO ',
              creadaTs: '2026-11-08T10:04:00-04:00'),
        ],
        registrarDiagnostico: diagnosticos.add,
      );
      expect(out.length, 1);
      expect(out.single.id, 's1');
      expect(diagnosticos.length, 1);
      expect(diagnosticos.single,
          contains('op_uuid ausente en espejo de adelanto'));
    });

    test('fuera de la ventana (±5 min) no tapa', () {
      final diagnosticos = <String>[];
      final out = solicitudesConPendientes(
        espejo: [_esp()],
        opsPendientes: [
          _op(
              uuid: 'u9',
              estado: 'enviada',
              creadaTs: '2026-11-08T10:06:00-04:00'),
        ],
        registrarDiagnostico: diagnosticos.add,
      );
      expect(out.length, 2);
      expect(diagnosticos, isEmpty);
    });

    test('en pendiente nunca tapa (aún no pudo aterrizar)', () {
      final out = solicitudesConPendientes(
        espejo: [_esp()],
        opsPendientes: [_op(uuid: 'u9', estado: 'pendiente')],
      );
      expect(out.length, 2);
    });

    test('identidad distinta no tapa (monto, motivo u otro '
        'entrenador)', () {
      for (final op in [
        _op(uuid: 'u9', estado: 'enviada', monto: 600),
        _op(uuid: 'u9', estado: 'enviada', motivo: 'transporte'),
        _op(uuid: 'u9', estado: 'enviada', tid: 999999),
      ]) {
        final out = solicitudesConPendientes(
          espejo: [_esp()],
          opsPendientes: [op],
        );
        expect(out.length, 2, reason: '$op');
      }
    });
  });

  group('Oleada 2 · normalización del motivo', () {
    test('trim + minúsculas + colapso de espacios', () {
      expect(normalizarMotivoAdelanto('  Almuerzo   De   Hoy '),
          'almuerzo de hoy');
      expect(normalizarMotivoAdelanto('Almuerzo '),
          normalizarMotivoAdelanto('almuerzo'));
      expect(normalizarMotivoAdelanto('   '), '');
    });
  });

  group('Oleada 2 · servicio con BD', () {
    test('pedir encola el payload del contrato y mias lo ve '
        'en los tres estados', () async {
      await _bdVacia();
      await _fijarSesion(email: 'gabriel@ironbody.gym', telegramId: _tidGab);
      await SolicitudesAdelantoService.instance
          .pedir(monto: 500, motivo: 'almuerzo');
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: 'tipo = ?', whereArgs: ['solicitar_adelanto']);
      expect(ops.length, 1);
      final payload =
          jsonDecode(ops.single['payload'] as String) as Map;
      expect(payload, {'monto': 500, 'motivo': 'almuerzo'});
      var mias = await SolicitudesAdelantoService.instance.mias();
      expect(mias.length, 1);
      expect(mias.single.estado, 'por_enviar');
      // En vuelo y en error la petición sigue viva en «mías».
      for (final estado in ['enviada', 'error']) {
        await db.update('ops_queue', {'estado': estado},
            where: 'tipo = ?', whereArgs: ['solicitar_adelanto']);
        mias = await SolicitudesAdelantoService.instance.mias();
        expect(mias.length, 1, reason: 'estado $estado');
        expect(mias.single.estado, 'por_enviar');
      }
    });

    test('ciclo completo: al aterrizar el espejo con el mismo '
        'op_uuid, la solicitud se ve UNA vez', () async {
      await _bdVacia();
      await _fijarSesion(email: 'gabriel@ironbody.gym', telegramId: _tidGab);
      await SolicitudesAdelantoService.instance
          .pedir(monto: 500, motivo: 'almuerzo');
      final db = await LocalDb.instance.db;
      final ops = await db.query('ops_queue',
          where: 'tipo = ?', whereArgs: ['solicitar_adelanto']);
      final uuidOp = ops.single['op_uuid'] as String;
      await db.update('ops_queue', {'estado': 'enviada'},
          where: 'tipo = ?', whereArgs: ['solicitar_adelanto']);
      await _espejo('solicitudes_adelanto', 'sol-1', {
        'id': 'sol-1',
        'entrenador_telegram_id': _tidGab,
        'entrenador_nombre': 'Gabriel',
        'monto': 500,
        'motivo': 'almuerzo',
        'estado': 'pendiente',
        'creado_en': ops.single['creada_ts'],
        'op_uuid': uuidOp,
      });
      final mias = await SolicitudesAdelantoService.instance.mias();
      expect(mias.length, 1);
      expect(mias.single.id, 'sol-1');
      expect(mias.single.estado, 'pendiente');
      expect(mias.single.opUuid, uuidOp);
    });

    test('tieneVivaIgual: caza la idéntica normalizando e '
        'ignora las resueltas', () async {
      await _bdVacia();
      await _fijarSesion(email: 'gabriel@ironbody.gym', telegramId: _tidGab);
      final svc = SolicitudesAdelantoService.instance;
      expect(
          await svc.tieneVivaIgual(monto: 500, motivo: 'almuerzo'),
          isFalse);
      await svc.pedir(monto: 500, motivo: 'Almuerzo ');
      expect(await svc.tieneVivaIgual(monto: 500, motivo: 'almuerzo'),
          isTrue);
      expect(await svc.tieneVivaIgual(monto: 500, motivo: 'ALMUERZO'),
          isTrue);
      expect(
          await svc.tieneVivaIgual(monto: 600, motivo: 'almuerzo'),
          isFalse);
      expect(
          await svc.tieneVivaIgual(monto: 500, motivo: 'transporte'),
          isFalse);
      // Una resuelta en el espejo NO es viva: no dispara la
      // puerta.
      await _bdVacia();
      await _fijarSesion(email: 'gabriel@ironbody.gym', telegramId: _tidGab);
      await _espejo('solicitudes_adelanto', 'sol-r', {
        'id': 'sol-r',
        'entrenador_telegram_id': _tidGab,
        'monto': 500,
        'motivo': 'almuerzo',
        'estado': 'aprobado',
        'creado_en': _t0,
      });
      expect(
          await svc.tieneVivaIgual(monto: 500, motivo: 'almuerzo'),
          isFalse);
      // Una pendiente en el espejo SÍ es viva.
      await _espejo('solicitudes_adelanto', 'sol-p', {
        'id': 'sol-p',
        'entrenador_telegram_id': _tidGab,
        'monto': 700,
        'motivo': 'Transporte ',
        'estado': 'pendiente',
        'creado_en': _t0,
      });
      expect(
          await svc.tieneVivaIgual(monto: 700, motivo: 'transporte'),
          isTrue);
    });
  });

  group('Oleada 2 · widget: la puerta del diálogo', () {
    testWidgets(
        'con viva idéntica, el primer toque avisa y no encola; '
        '«Pedir igual» encola', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // La aserción de tinta de ListTile del framework es un
      // patrón visual preexistente de la app (ver batería
      // FB-09): se filtra SOLO esa; el resto falla el test.
      final onErrorPrevio = FlutterError.onError;
      FlutterError.onError = (details) {
        if ('${details.exception}'
            .contains('ListTile background color')) {
          return;
        }
        onErrorPrevio?.call(details);
      };
      addTearDown(() => FlutterError.onError = onErrorPrevio);

      // La siembra va en runAsync: bajo la zona FakeAsync de
      // testWidgets los await de BD no entregan sin ciclos
      // reales (patrón de la casa, m3bc — batería FB-09).
      await tester.runAsync(() async {
        await _bdVacia();
        await _fijarSesion(
            email: 'gabriel@ironbody.gym', telegramId: _tidGab);
        // La pantalla exige can_view_payroll (fail-closed):
        // se siembra la foto de permisos del entrenador en su
        // caché por usuario (patrón de ajustes_127_test).
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('cache_permisos_entrenador_json@gabriel',
            jsonEncode({'can_view_payroll': true}));
        await prefs.setBool('cache_entrenador_activo@gabriel', true);
        await prefs.setBool(
            'cache_entrenador_habilitado@gabriel', true);
        PermisosEntrenador().limpiar();
        await PermisosEntrenador().cargar();
        // La viva idéntica preexiste: op en cola del
        // entrenador sembrada con queueOp directo (patrón
        // FB-09). NO se usa pedir() aquí a propósito: pedir
        // dispara el empujón y en el entorno de test el
        // motor habla con el Supabase real (URL constante)
        // con el JWT de mentira: el 4xx marcaría la op
        // «rechazada» y dejaría de contar como viva antes
        // de que el diálogo consulte. El empujón de pedir()
        // lo cubren los tests de servicio de arriba.
        await LocalDb.instance.queueOp(
          opUuid: 'op-viva-widget',
          tipo: 'solicitar_adelanto',
          payload: {'monto': 500, 'motivo': 'almuerzo'},
        );
      });

      await tester.pumpWidget(
          const MaterialApp(home: MiNominaScreen()));
      expect(await _esperarTexto(tester, 'Pedir adelanto'), isTrue,
          reason: 'la pantalla monta y ofrece pedir');
      await tester.scrollUntilVisible(
        find.text('Pedir adelanto'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await _ciclos(tester, 3);
      await tester.tap(find.text('Pedir adelanto'));
      expect(await _esperarTexto(tester, 'Enviar solicitud'), isTrue,
          reason: 'el diálogo abre');

      final campos = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField));
      await tester.enterText(campos.at(0), '500');
      await tester.enterText(campos.at(1), '  ALMUERZO ');
      await tester.tap(find.text('Enviar solicitud'));
      expect(
          await _esperarTexto(
              tester, 'Ya tienes una solicitud igual sin resolver'),
          isTrue,
          reason: 'el primer toque solo avisa');
      expect(find.text('Pedir igual'), findsOneWidget);
      var nOps = await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        final ops = await db.query('ops_queue',
            where: 'tipo = ?', whereArgs: ['solicitar_adelanto']);
        return ops.length;
      });
      expect(nOps, 1, reason: 'el aviso no encoló nada');

      await tester.tap(find.text('Pedir igual'));
      await _ciclos(tester, 20);
      nOps = await tester.runAsync(() async {
        final db = await LocalDb.instance.db;
        final ops = await db.query('ops_queue',
            where: 'tipo = ?', whereArgs: ['solicitar_adelanto']);
        return ops.length;
      });
      expect(nOps, 2, reason: '«Pedir igual» sí encola');
      expect(tester.takeException(), isNull);
      // Cierre §17 (×30): el push que dispara «Pedir igual»
      // corre en segundo plano y su ciclo, al fallar sin red
      // en el arnés, deja armados los temporizadores del
      // motor (el respiro de 2 s del catch de _doPull y el
      // sondeo de red de 5 s de _hayInternet al emitir la
      // foto de estado) — en esta VM el test cerraba antes
      // de que vencieran y el binding los marcaba como
      // pendientes. Se dejan vencer en bucle; no cambia
      // ninguna aserción del test.
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pump();
    });
  });
}
