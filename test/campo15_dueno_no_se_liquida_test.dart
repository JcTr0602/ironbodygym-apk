// CAMPO-15 (1.35, decisión de Jc 2026-11-16): el dueño NO
// se liquida a sí mismo. Lo que el dueño recoge en efectivo
// nunca entra en la piscina de «pendiente a entregar»: ni
// se le muestra pendiente, ni aparece en los listados de
// arqueo, ni se puede crear una liquidación o una entrega
// C1 a su nombre — aunque una fila suya nazca con
// entregado=0 (el caso real: pago 221, inscripción en
// efectivo de Claudia Toledo cobrada por el propio Jc el
// 2026-11-15, que la 1.34 enseñaba como «Pendiente
// confirmado: 2000 CUP» en la hoja «Liquidar Arqueo · Jc»).
// El mismo cobro hecho por un entrenador SÍ es pendiente
// y SÍ se liquida: los entrenadores no cambian en nada.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/bloque2_resto.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _tidDueno = 735772141;
const _tidGabriel = 1403501391;

String _jwtDueno() {
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
    'app_metadata': {'telegram_id': _tidDueno, 'provider': 'email'},
  });
  return '$header.$payload.firma';
}

/// La sesión completa que gotrue espera en
/// setInitialSession (el JSON de sesión, no el JWT solo).
String _sesionDueno() => jsonEncode({
      'access_token': _jwtDueno(),
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh-x',
      'user': {
        'id': '00000000-0000-0000-0000-0000000000e6',
        'aud': 'authenticated',
        'email': 'jc@ironbody.local',
        'app_metadata': {'telegram_id': _tidDueno, 'provider': 'email'},
        'user_metadata': <String, dynamic>{},
        'created_at': '2024-01-01T00:00:00.000Z',
      },
    });

/// La foto del caso real: el pago 221 del dueño (efectivo,
/// entregado=0) y los mismos cobros hechos por Gabriel.
Future<void> _semillaBase() async {
  final db = LocalDb.instance;
  await db.upsertMirror('pagos', 221, {
    'cliente_id': 240,
    'cliente_nombre': 'Claudia Toledo Jimenez',
    'monto': 2000,
    'metodo': 'efectivo',
    'entregado': 0,
    'telegram_user_id': _tidDueno,
    'registrado_por': 'Jc',
    'fecha': '2026-11-15',
    'tipo': 'mensual',
  }, 900);
  await db.upsertMirror('pagos', 900, {
    'cliente_id': 50,
    'cliente_nombre': 'Cliente De Gabriel',
    'monto': 2000,
    'metodo': 'efectivo',
    'entregado': 0,
    'telegram_user_id': _tidGabriel,
    'registrado_por': 'Gabriel',
    'fecha': '2026-11-15',
    'tipo': 'mensual',
  }, 901);
  await db.upsertMirror('pagos_diarios', 901, {
    'registrado_por': _tidDueno,
    'registrado_por_nombre': 'Jc',
    'total': 200,
    'entregado': 0,
    'fecha': '2026-11-15',
    'turno': 'manana',
    'cantidad': 1,
  }, 902);
  await db.upsertMirror('pagos_diarios', 902, {
    'registrado_por': _tidGabriel,
    'registrado_por_nombre': 'Gabriel',
    'total': 200,
    'entregado': 0,
    'fecha': '2026-11-15',
    'turno': 'manana',
    'cantidad': 1,
  }, 903);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  LocalDb.nombreArchivoDbForzado = 'test_campo15.db';

  setUp(() async {
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_campo15.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
  });

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    await Supabase.instance.client.auth.setInitialSession(_sesionDueno());
  });

  test('la sesión del arnés es la del dueño', () {
    expect(AuthService().isOwner, isTrue);
    expect(AuthService().telegramId, _tidDueno);
  });

  test('pendienteArqueo: el dueño 0 aunque su fila nazca '
      'entregado=0; el entrenador suma lo suyo', () async {
    await _semillaBase();
    final dueno = await pendienteArqueo(_tidDueno);
    expect(dueno.cup, 0, reason: 'el dueño no se debe a sí mismo');
    expect(dueno.usd, 0);
    final gabriel = await pendienteArqueo(_tidGabriel);
    expect(gabriel.cup, 2200,
        reason: '2000 del pago + 200 del diario, como siempre');
  });

  test('pendienteEntrega y pendienteEntregaUsd: el dueño 0',
      () async {
    await _semillaBase();
    expect(await pendienteEntrega(_tidDueno), 0);
    expect(await pendienteEntregaUsd(_tidDueno), 0);
    expect(await pendienteEntrega(_tidGabriel), 2200);
  });

  test('pendientePorEntrenador: sin fila del dueño; la de '
      'Gabriel intacta', () async {
    await _semillaBase();
    final filas = await pendientePorEntrenador();
    expect(filas.any((e) => e['id'] == _tidDueno), isFalse,
        reason: 'la fila «Jc» no aparece en el pendiente');
    final g = filas.singleWhere((e) => e['id'] == _tidGabriel);
    expect(g['total'], 2200);
  });

  test('entrenadoresConPendiente (la lista de la hoja '
      '«Liquidar Arqueo»): el dueño no se lista', () async {
    await _semillaBase();
    final lista = await entrenadoresConPendiente();
    expect(
        lista.any((e) => e['telegram_id'] == _tidDueno), isFalse);
    final g =
        lista.singleWhere((e) => e['telegram_id'] == _tidGabriel);
    expect(g['cup'], 2200);
  });

  test('idsPendienteArqueo: el dueño no ofrece ids; el '
      'entrenador sí', () async {
    await _semillaBase();
    final delDueno = await idsPendienteArqueo(_tidDueno);
    expect(delDueno.values.every((l) => l.isEmpty), isTrue);
    final deGabriel = await idsPendienteArqueo(_tidGabriel);
    expect(deGabriel['pagos'], [900]);
    expect(deGabriel['pagos_diarios'], [902]);
  });

  test('pagosPendientesDetalle y detalle del dueño: vacíos '
      'para él, vivos para el entrenador', () async {
    await _semillaBase();
    final detalle = await pagosPendientesDetalle();
    expect(
        detalle.any((p) => p['trainer_telegram_id'] == _tidDueno),
        isFalse);
    expect(
        detalle.any((p) => p['trainer_telegram_id'] == _tidGabriel),
        isTrue);
    expect(await detallePendienteEntrenador(_tidDueno), isEmpty);
    expect(await detallePendienteEntrenador(_tidGabriel),
        isNotEmpty);
    final (m, d, s, u) = await detallePendiente(_tidDueno);
    expect(m, isEmpty);
    expect(d, isEmpty);
    expect(s, isEmpty);
    expect(u, isEmpty);
  });

  test('arrastresVivosCup: el arrastre del dueño no crea '
      'entrada; el del entrenador sí', () async {
    final db = LocalDb.instance;
    await db.upsertMirror('liquidaciones_caja', 71, {
      'entrenador_telegram_id': _tidDueno,
      'entrenador_nombre': 'Jc',
      'estado': 'parcial',
      'saldo_arrastre': 500,
      'moneda': 'CUP',
    }, 910);
    await db.upsertMirror('liquidaciones_caja', 72, {
      'entrenador_telegram_id': _tidGabriel,
      'entrenador_nombre': 'Gabriel',
      'estado': 'parcial',
      'saldo_arrastre': 300,
      'moneda': 'CUP',
    }, 911);
    final arrastres = await arrastresVivosCup();
    expect(arrastres.containsKey(_tidDueno), isFalse);
    expect(arrastres[_tidGabriel]?.total, 300);
  });

  test('crearLiquidacion: al dueño se le rechaza; al '
      'entrenador se le encola', () async {
    await _semillaBase();
    await expectLater(
      crearLiquidacion(
        entrenadorTelegramId: _tidDueno,
        entrenadorNombre: 'Jc',
        montoEsperado: 2200,
        montoEntregado: 2200,
        opIds: const {
          'pagos': [221],
          'pagos_diarios': [901],
          'ventas_suplementos': <int>[],
          'servicio_ventas': <int>[],
          'adelantos': <int>[],
        },
      ),
      throwsA(anything),
      reason: 'el dueño no se liquida a sí mismo',
    );
    final liqId = await crearLiquidacion(
      entrenadorTelegramId: _tidGabriel,
      entrenadorNombre: 'Gabriel',
      montoEsperado: 2200,
      montoEntregado: 2200,
      opIds: const {
        'pagos': [900],
        'pagos_diarios': [902],
        'ventas_suplementos': <int>[],
        'servicio_ventas': <int>[],
        'adelantos': <int>[],
      },
    );
    expect(liqId, isNotEmpty);
    final ops = await LocalDb.instance.pendingOps();
    expect(
        ops.any((o) =>
            o['tipo'] == 'liquidar_caja' &&
            '${o['payload']}'.contains('$_tidGabriel')),
        isTrue,
        reason: 'la liquidación del entrenador sí viaja');
  });

  test('registrarEntregaEfectivo (C1): al dueño se le '
      'rechaza también por la vía anticipada', () async {
    await _semillaBase();
    await expectLater(
      registrarEntregaEfectivo(
        entrenadorTelegramId: _tidDueno,
        montoEntregado: 200,
        autorDuenoId: _tidDueno,
        permitirAnticipada: true,
      ),
      throwsA(anything),
      reason: 'ni con anticipada: el dueño no se entrega '
          'efectivo a sí mismo',
    );
  });
}
