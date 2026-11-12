/// Oleada 2 Fase 2 · Carril Sync (1.32): las compuertas
/// del sello falso (Pieza 4), el detalle desde el diario
/// (M1/M3), el clasificador de sesión muerta (4d), la
/// vigilancia M4 y la costura del Centro a 420×800.
///
/// El motor completo no corre aquí (sin harness de sesión
/// Supabase, como en el resto del banco): las compuertas se
/// prueban en sus costuras reales — la función pura del
/// juicio de completitud tal como run() la compone, el
/// invariante troncal vía su costura de test contra la BD
/// real, y detalle() contra el diario sembrado.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/diario_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/centro_sync.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:ironbody_gym/vigilancia_sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_o2f2s_sync.db';
  try {
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_o2f2s_sync.db$suf')).delete();
    } catch (_) {}
  }
  await LocalDb.instance.db;
}

int get _ahoraEpoch =>
    DateTime.now().millisecondsSinceEpoch ~/ 1000;

void main() {
  group('Pieza 4a ADJUDICADA (F-1): el sello exige el '
      'server_seq confirmado EN ESTA CORRIDA', () {
    // Contrato de la forma adjudicada por Argón: el juicio
    // ya no consulta la meta — recibe el valor que
    // _download devolvió fuera de su catch. El caso Duany:
    // la lectura de sync_estado nunca ocurrió (sesión
    // muerta) ⇒ null ⇒ sin sello, aunque watermark y meta
    // valieran 0 y el juicio viejo comparara 0 >= 0.
    test('sync_estado sin leer en la corrida (null): no '
        'hay sello', () {
      expect(
          SyncEngine.cicloCompleto(
              serverSeqConfirmado: null,
              watermarkMinimo: 0,
              clientesLegibles: false,
              incidenciasOk: true),
          isFalse,
          reason: 'sin la lectura confirmada en la corrida, '
              'el juicio viejo sellaba «al día» con la app '
              'vacía y la sesión muerta');
    });
    test('sync_estado falló (500/timeout): la corrida NO '
        'es completa aunque la meta vieja alcanzara', () {
      // La meta podría decir 900 y el watermark 900, pero si
      // ESTA corrida no confirmó el seq, llega null.
      expect(
          SyncEngine.cicloCompleto(
              serverSeqConfirmado: null,
              watermarkMinimo: 900,
              clientesLegibles: true,
              incidenciasOk: true),
          isFalse);
    });
    test('confirmado en la corrida y watermark al día: '
        'sello', () {
      expect(
          SyncEngine.cicloCompleto(
              serverSeqConfirmado: 900,
              watermarkMinimo: 900,
              clientesLegibles: true,
              incidenciasOk: true),
          isTrue);
    });
    test('confirmado pero el watermark quedó corto: no '
        'hay sello', () {
      expect(
          SyncEngine.cicloCompleto(
              serverSeqConfirmado: 900,
              watermarkMinimo: 850,
              clientesLegibles: true,
              incidenciasOk: true),
          isFalse);
    });
  });

  group('Pieza 4b ADJUDICADA (F-2): condición POSITIVA de '
      'sello — clientes legibles (BD real)', () {
    // La pata «clientesLegibles» de run() sale de
    // conteoMirrorLegible('clientes') sobre la BD real: la
    // forma negativa original («meta server_seq>0 ⇒
    // prohibido») nunca se disparaba en el teléfono de
    // Duany porque su meta jamás se escribió.
    test('0 legibles + seq confirmado 870 + watermark al '
        'día: sello PROHIBIDO', () async {
      await _init();
      final db = LocalDb.instance;
      final legibles =
          (await db.conteoMirrorLegible('clientes')).legibles;
      expect(legibles, 0);
      expect(
          SyncEngine.cicloCompleto(
              serverSeqConfirmado: 870,
              watermarkMinimo: 870,
              clientesLegibles: legibles > 0,
              incidenciasOk: true),
          isFalse);
    });
    test('primer pull correcto (ya hay legibles): sello '
        'permitido', () async {
      await _init();
      final db = LocalDb.instance;
      final d = await db.db;
      await d.insert('clientes', {
        'id': 1,
        'data': jsonEncode({'id': 1, 'nombre': 'Prueba'}),
        'sync_seq': 10,
      });
      final legibles =
          (await db.conteoMirrorLegible('clientes')).legibles;
      expect(legibles, 1);
      expect(
          SyncEngine.cicloCompleto(
              serverSeqConfirmado: 870,
              watermarkMinimo: 870,
              clientesLegibles: legibles > 0,
              incidenciasOk: true),
          isTrue);
    });
    test('instalación virgen (seq confirmado 0): «sin '
        'confirmar», nunca sello', () {
      expect(
          SyncEngine.cicloCompleto(
              serverSeqConfirmado: 0,
              watermarkMinimo: 0,
              clientesLegibles: false,
              incidenciasOk: true),
          isFalse);
    });
  });

  group('Pieza 4e + M3: detalle() lee el diario', () {
    test('el error de una corrida fallida posterior al '
        'último OK se ve (no «Todo al día» por defecto)',
        () async {
      await _init();
      final db = LocalDb.instance;
      final d = DiarioSync.instance;
      // Último OK sellado hace 2 horas; la meta de error,
      // vacía (como la dejaba el sello falso).
      await db.setMeta('last_sync_ok',
          isoHabana(ahoraHabana().subtract(const Duration(hours: 2))));
      await db.setMeta('last_sync_error', '');
      final id = await d.abrirCorrida(
          tipo: 'completa',
          origen: 'automatica',
          ahoraEpoch: _ahoraEpoch - 60);
      await d.cerrarCorrida(id,
          estado: 'fallida',
          duracionMs: 900,
          errorDetalle: SyncEngine.mensajeSesionInvalida,
          ahoraEpoch: _ahoraEpoch - 59);
      final det = await SyncEngine.instance.detalle();
      expect(det.error, SyncEngine.mensajeSesionInvalida,
          reason: 'el héroe de la Cola lee detalle().error: '
              'con la corrida fallida más nueva que el OK, el '
              'error manda y no se pinta «al día»');
    });
    test('un OK posterior a la corrida fallida apaga el '
        'error del diario', () async {
      await _init();
      final db = LocalDb.instance;
      final d = DiarioSync.instance;
      final id = await d.abrirCorrida(
          tipo: 'completa',
          origen: 'automatica',
          ahoraEpoch: _ahoraEpoch - 3600);
      await d.cerrarCorrida(id,
          estado: 'fallida',
          duracionMs: 900,
          errorDetalle: 'fallo viejo',
          ahoraEpoch: _ahoraEpoch - 3599);
      await db.setMeta(
          'last_sync_ok', isoHabana(ahoraHabana()));
      await db.setMeta('last_sync_error', '');
      final det = await SyncEngine.instance.detalle();
      expect(det.error, isNot('fallo viejo'));
    });
    test('los conteos «último» salen de las corridas del '
        'diario, no de las metas jubiladas', () async {
      await _init();
      final db = LocalDb.instance;
      await db.setMeta('last_uploaded', '99');
      await db.setMeta('last_downloaded', '99');
      final d = DiarioSync.instance;
      final id = await d.abrirCorrida(
          tipo: 'completa',
          origen: 'manual',
          ahoraEpoch: _ahoraEpoch - 10);
      await d.volcarOps(id, const [
        CorridaOpSync(
            opUuid: 'u1', tipo: 'pago_mensual', resultado: 'aplicada'),
        CorridaOpSync(
            opUuid: 'u2', tipo: 'pago_mensual', resultado: 'aplicada'),
      ]);
      await d.volcarTablas(id, {
        'clientes': AcumTablaDiario()
          ..fusionarIntento(
              recibidas: 7, aplicadas: 7, paginas: 1, estado: 'ok'),
      });
      await d.cerrarCorrida(id,
          estado: 'completa',
          duracionMs: 100,
          subidos: 2,
          bajados: 7,
          ahoraEpoch: _ahoraEpoch - 9);
      final det = await SyncEngine.instance.detalle();
      expect(det.subidosUltimo, 2);
      expect(det.bajadosUltimo, 7);
    });
  });

  group('Pieza 4d ADJUDICADA (F-5): clasificador del '
      'refresco', () {
    test('AuthApiException 400/401/403 = rechazo del '
        'servidor', () {
      for (final sc in ['400', '401', '403']) {
        expect(
            AuthService.esRechazoDeAuth(AuthApiException(
                'invalid refresh token', statusCode: sc)),
            isTrue,
            reason: 'statusCode $sc');
      }
    });
    test('AuthApiException 5xx NO expulsa (el servidor de '
        'auth falló, no rechazó)', () {
      expect(
          AuthService.esRechazoDeAuth(const AuthApiException(
              'internal', statusCode: '500')),
          isFalse);
    });
    test('AuthApiException sin statusCode NO expulsa', () {
      expect(
          AuthService.esRechazoDeAuth(
              const AuthApiException('sin código')),
          isFalse);
    });
    test('AuthRetryableFetchException = red, no rechazo',
        () {
      expect(
          AuthService.esRechazoDeAuth(
              AuthRetryableFetchException(message: 'sin conexión')),
          isFalse);
    });
    test('un error cualquiera no mata la sesión', () {
      expect(AuthService.esRechazoDeAuth(Exception('otro')),
          isFalse);
    });
  });

  group('M4 vigilancia: reglas puras', () {
    test('A3: fallida en sus 3 últimas apariciones', () {
      final r = tablasFallidasTresCorridas([
        (tabla: 'clientes', fallida: true),
        (tabla: 'pagos', fallida: true),
        (tabla: 'clientes', fallida: true),
        (tabla: 'clientes', fallida: true),
        (tabla: 'pagos', fallida: false),
      ]);
      expect(r, contains('clientes'));
      expect(r, isNot(contains('pagos')));
    });
    test('A2-diario: fallida en 2 corridas basta', () {
      final r = tablasFallidasDosCorridas([
        (tabla: 'pagos', fallida: true),
        (tabla: 'pagos', fallida: false),
        (tabla: 'pagos', fallida: true),
      ]);
      expect(r, contains('pagos'));
    });
    test('A1: instalación cortada sin completa posterior', () {
      final corridas = [
        CorridaSync(
            id: '2',
            tipo: 'solo_pull',
            origen: 'automatica',
            inicioEpoch: 200,
            estado: 'parcial'),
        CorridaSync(
            id: '1',
            tipo: 'completa',
            origen: 'instalacion',
            inicioEpoch: 100,
            estado: 'cortada'),
      ];
      expect(primeraBajadaIncompleta(corridas), isTrue);
    });
    test('A1: una completa posterior la cura', () {
      final corridas = [
        CorridaSync(
            id: '2',
            tipo: 'completa',
            origen: 'automatica',
            inicioEpoch: 200,
            estado: 'completa'),
        CorridaSync(
            id: '1',
            tipo: 'completa',
            origen: 'instalacion',
            inicioEpoch: 100,
            estado: 'cortada'),
      ];
      expect(primeraBajadaIncompleta(corridas), isFalse);
    });
  });

  group('M4 vigilancia: evaluación integrada (BD real)', () {
    test('A7: wm_sinverificar activo avisa de inmediato',
        () async {
      await _init();
      await LocalDb.instance
          .setMeta('wm_sinverificar_clientes', 'seq=10 filas=2');
      final avisos = await evaluarVigilanciaSync();
      expect(avisos.where((a) => a.regla == 'A7'), hasLength(1));
      expect(avisos.firstWhere((a) => a.regla == 'A7').tabla,
          'clientes');
    });
    test('A8: reloj desfasado más de 15 min avisa', () async {
      await _init();
      await LocalDb.instance.setMeta('reloj_desfasado_min', '25');
      final avisos = await evaluarVigilanciaSync();
      final a8 = avisos.where((a) => a.regla == 'A8');
      expect(a8, hasLength(1));
      expect(a8.first.titulo, contains('25'));
    });
    test('A8: 10 min de desfase no avisa', () async {
      await _init();
      await LocalDb.instance.setMeta('reloj_desfasado_min', '10');
      final avisos = await evaluarVigilanciaSync();
      expect(avisos.where((a) => a.regla == 'A8'), isEmpty);
    });
    test('A5: rechazada de más de un día avisa; la de hoy no',
        () async {
      await _init();
      final d = await LocalDb.instance.db;
      await d.insert('ops_queue', {
        'op_uuid': 'vieja-1',
        'tipo': 'pago_mensual',
        'payload': '{}',
        'estado': 'rechazada',
        'creada_ts': isoHabana(
            ahoraHabana().subtract(const Duration(hours: 49))),
      });
      await d.insert('ops_queue', {
        'op_uuid': 'nueva-1',
        'tipo': 'pago_mensual',
        'payload': '{}',
        'estado': 'rechazada',
        'creada_ts': isoHabana(ahoraHabana()),
      });
      final avisos = await evaluarVigilanciaSync();
      final a5 = avisos.where((a) => a.regla == 'A5');
      expect(a5, hasLength(1));
      expect(a5.first.titulo, contains('1 operación'));
    });
    test('A3 integrada: clientes fallida en 3 corridas con '
        'error vigente', () async {
      await _init();
      final db = LocalDb.instance;
      final d = DiarioSync.instance;
      await db.setMeta('wm_err_clientes', 'HTTP 500');
      for (var i = 0; i < 3; i++) {
        final base = _ahoraEpoch - (3 - i) * 600;
        final id = await d.abrirCorrida(
            tipo: 'completa',
            origen: 'automatica',
            ahoraEpoch: base);
        await d.volcarTablas(id, {
          'clientes': AcumTablaDiario()
            ..fusionarIntento(
                recibidas: 3,
                fallidas: 3,
                paginas: 1,
                estado: 'fallida',
                error: 'HTTP 500'),
        });
        await d.cerrarCorrida(id,
            estado: 'parcial',
            duracionMs: 10,
            bajados: 1,
            ahoraEpoch: base + 1);
      }
      final avisos = await evaluarVigilanciaSync();
      expect(
          avisos.where(
              (a) => a.regla == 'A3' && a.tabla == 'clientes'),
          hasLength(1));
    });
    test('A1 suprime los A2/A3 hijos (M4-R3)', () async {
      await _init();
      final db = LocalDb.instance;
      final d = DiarioSync.instance;
      await db.setMeta('wm_err_clientes', 'HTTP 500');
      // Instalación cortada…
      final id0 = await d.abrirCorrida(
          tipo: 'completa',
          origen: 'instalacion',
          ahoraEpoch: _ahoraEpoch - 7200);
      await d.cerrarCorrida(id0,
          estado: 'cortada',
          duracionMs: 10,
          ahoraEpoch: _ahoraEpoch - 7199);
      // …y dos corridas posteriores con clientes fallida:
      // sin la supresión, A2-diario saltaría.
      for (var i = 0; i < 2; i++) {
        final base = _ahoraEpoch - (2 - i) * 600;
        final id = await d.abrirCorrida(
            tipo: 'completa',
            origen: 'automatica',
            ahoraEpoch: base);
        await d.volcarTablas(id, {
          'clientes': AcumTablaDiario()
            ..fusionarIntento(
                recibidas: 3,
                fallidas: 3,
                paginas: 1,
                estado: 'fallida',
                error: 'HTTP 500'),
        });
        await d.cerrarCorrida(id,
            estado: 'parcial',
            duracionMs: 10,
            bajados: 1,
            ahoraEpoch: base + 1);
      }
      final avisos = await evaluarVigilanciaSync();
      expect(avisos.where((a) => a.regla == 'A1'), hasLength(1));
      expect(
          avisos.where((a) =>
              (a.regla == 'A2' || a.regla == 'A3') &&
              a.tabla == 'clientes'),
          isEmpty,
          reason: 'con A1 activo, los avisos hijos de la '
              'primera bajada no se duplican');
    });
  });

  group('Pieza 2: costura del Centro a 420×800', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      try {
        // ignore: deprecated_member_use
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', publishableKey: 'dummy');
      } catch (_) {}
    });

    // Bajo FakeAsync las lecturas FFI no resuelven (límite
    // documentado del banco de widgets): se afirma la
    // ESTRUCTURA y la navegación, no el contenido cargado.
    // Se avanza el tiempo falso en pasos de 11 s para que
    // los temporizadores internos de sqflite (10 s) expiren
    // antes del cierre, como hace el banco.
    Future<void> avanzar(WidgetTester tester, [int pasos = 4]) async {
      for (var i = 0; i < pasos; i++) {
        await tester.pump(const Duration(seconds: 11));
      }
    }

    testWidgets('el Centro monta a 420×800 sin errores',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: CentroSyncScreen()));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Centro de sincronización'),
          findsOneWidget);
      await avanzar(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('la puerta de la Cola abre el Centro',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester
          .pumpWidget(const MaterialApp(home: ColaScreen()));
      await avanzar(tester, 2);
      await tester.scrollUntilVisible(
          find.text('Centro de sincronización'), 200);
      expect(find.text('Centro de sincronización'),
          findsOneWidget);
      await tester.tap(find.text('Centro de sincronización'));
      await avanzar(tester, 2);
      expect(find.byType(CentroSyncScreen), findsOneWidget);
      await avanzar(tester);
      expect(tester.takeException(), isNull);
    });
  });
}
