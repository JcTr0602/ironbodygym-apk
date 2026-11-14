/// Yunque 3 · Gestión 1.34 · Carril C — correcciones del
/// clúster K5 (Clientes y operación diaria).
///
/// - K5-1: «Mis vencimientos» de Mi Turno excluía ni Casa ni
///   protegidos (lista propia sin los predicados centrales).
/// - K5-2: Reportes Plus desbloqueaba la tarjeta con la
///   decisión en «enviada» (gemelo no propagado de D-B2-02).
/// - K5-3: la medición recién registrada desaparecía de la
///   lista local mientras su op estaba «enviada».
/// - K5-5: «Cambiar teléfono del acceso» truncaba el pegado
///   internacional con maxLength: 8 antes de sanitizar (D-6).
/// - K5-8: filtro/contador «Sin foto» de Buscar ignoraban
///   `foto_local`.
/// - K5-6: el recibo desde la cola decía «Cobrado por: <id
///   numérico de Telegram>».
/// - K5-7: el recibo de una inscripción nueva nunca entraba
///   en la bandeja por la vía de cola (exigía un cliente_id
///   que el payload de inscripción no trae).
/// - K5-4: Listas marcaba «avisado» al ABRIR WhatsApp, sin
///   confirmar el envío (ver el grupo propio al final).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/mediciones_cliente.dart';
import 'package:ironbody_gym/plus_reportes.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/mi_turno.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_yunque3_k5_fix_c.db';
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'test_yunque3_k5_fix_c.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('K5-1 · Mis vencimientos sin Casa ni protegidos', () {
    const hoy = '2026-11-14';
    const limite = '2026-11-21';

    Map<String, dynamic> cli(int id, String nombre, String ph,
            {int? casa, int? protegido}) =>
        {
          'id': id,
          'nombre': nombre,
          'estado': 'activo',
          'pagado_hasta': ph,
          if (casa != null) 'cuenta_casa': casa,
          if (protegido != null) 'protegido': protegido,
        };

    test('la Casa con pagado_hasta pasada atribuida NO aparece; '
        'el cliente normal vencido atribuido SÍ', () {
      final clientes = [
        // Casa: no vence nunca, aunque su fecha guardada pasó.
        cli(198, 'Casa Vencida', '2026-11-01', casa: 1),
        // Protegido: el entrenador no ve sus fechas.
        cli(55, 'Protegida Vencida', '2026-11-02', protegido: 1),
        // Normal vencido atribuido: debe aparecer.
        cli(60, 'Normal Vencido', '2026-11-10'),
        // Normal por vencer dentro de la ventana: aparece.
        cli(61, 'Normal Por Vencer', '2026-11-20'),
        // Fuera de ventana y no atribuido: no aparecen.
        cli(62, 'Normal Lejano', '2026-12-30'),
        cli(63, 'No Atribuido', '2026-11-05'),
      ];
      final out = filtrarMisVencimientos(
        clientes,
        {198, 55, 60, 61, 62},
        hoy: hoy,
        limite: limite,
        esDueno: false,
      );
      final ids = out.map((m) => m['id']).toList();
      expect(ids, contains(60),
          reason: 'el cliente normal vencido atribuido aparece');
      expect(ids, contains(61));
      expect(ids, isNot(contains(198)),
          reason: 'la Cuenta a la Casa no vence: no se lista '
              'como vencida en el teléfono del entrenador');
      expect(ids, isNot(contains(55)),
          reason: 'un protegido no enseña su vencimiento al '
              'entrenador');
      expect(ids, isNot(contains(62)));
      expect(ids, isNot(contains(63)));
      final normal = out.firstWhere((m) => m['id'] == 60);
      expect(normal['vencido'], isTrue);
    });

    test('el dueño SÍ ve al protegido en su lista (la vista '
        'protegida solo bloquea al no-dueño)', () {
      final out = filtrarMisVencimientos(
        [cli(55, 'Protegida Vencida', '2026-11-02', protegido: 1)],
        {55},
        hoy: hoy,
        limite: limite,
        esDueno: true,
      );
      expect(out.map((m) => m['id']), contains(55));
    });
  });

  group('K5-2 · Reportes Plus: la decisión «enviada» sigue '
      'bloqueando la tarjeta', () {
    test('op de decisión en «enviada»: bloquea vía '
        'pendingOpsLectura y la pantalla la lee así', () async {
      final d = await _abrirDbVacia();
      await d.insert('ops_queue', {
        'op_uuid': 'op-plus-enviada',
        'tipo': kTipoOpConfirmarPlus,
        'payload': jsonEncode(
            {'reporte_id': 42, 'monto_cup': 1000, 'invitado_id': 'inv-42'}),
        'estado': 'enviada',
        'creada_ts': '2026-11-14T08:00:00.000-05:00',
        'telegram_id': 111111,
      });
      final delPush = await LocalDb.instance.pendingOps();
      expect(delPush.any((o) => o['op_uuid'] == 'op-plus-enviada'),
          isFalse,
          reason: 'pendingOps es la lectura del push: la op '
              'enviada ya no está para él');
      final deLectura = await LocalDb.instance.pendingOpsLectura();
      expect(
          deLectura.any((o) => o['op_uuid'] == 'op-plus-enviada'),
          isTrue);
      expect(reportesPlusConOpPendiente(deLectura), contains('42'),
          reason: 'con la lectura amplia, la tarjeta del reporte '
              '42 queda bloqueada hasta que el espejo baje y no '
              'admite la decisión contraria');
      expect(reportesPlusConOpPendiente(delPush),
          isNot(contains('42')));
      // La pantalla (_cargar) debe componer con la lectura
      // amplia, como Reservas desde D-B2-02.
      final fuente =
          File('lib/ui/reportes_plus.dart').readAsStringSync();
      final i = fuente.indexOf('Future<void> _cargar()');
      final j = fuente.indexOf('Future<void> _decidir(', i);
      expect(i, greaterThan(0));
      expect(fuente.substring(i, j), contains('pendingOpsLectura()'),
          reason: '_cargar de Reportes Plus debe leer '
              'pendingOpsLectura() (K5-2)');
      expect(fuente.substring(i, j),
          isNot(contains('pendingOps()')));
    });
  });

  group('K5-3 · la medición con su op «enviada» no desaparece '
      'de la lista local', () {
    test('op registrar_medicion_cliente en «enviada» sin fila '
        'en espejo: la lista la incluye una sola vez; con la '
        'fila espejada, tampoco se duplica', () async {
      final d = await _abrirDbVacia();
      const medicionId = 'med-k5-3-0001';
      await d.insert('ops_queue', {
        'op_uuid': 'op-med-enviada',
        'tipo': 'registrar_medicion_cliente',
        'payload': jsonEncode({
          'medicion_id': medicionId,
          'cliente_id': 55,
          'fecha_medicion': '2026-11-14',
          'medidas': {'peso_kg': 90.0},
          'registrado_por': 111,
        }),
        'estado': 'enviada',
        'creada_ts': '2026-11-14T08:00:00.000-05:00',
        'telegram_id': 111,
      });
      var lista = await medicionesClienteLocal(55);
      expect(lista, hasLength(1),
          reason: 'la medición recién registrada no puede '
              'desaparecer mientras su op está «enviada» y el '
              'espejo aún no la trae');
      expect(lista.single['medicion_id'], medicionId);
      expect(lista.single['espejado'], isFalse);

      // Cuando el espejo ya trae la fila, manda ella y la op
      // no duplica (dedupe por medicion_id: la tabla espejo
      // usa id TEXT = el UUID de la medición).
      await d.insert('cliente_mediciones', {
        'id': medicionId,
        'data': jsonEncode({
          'id': medicionId,
          'cliente_id': 55,
          'fecha_medicion': '2026-11-14',
          'peso_kg': 90.0,
        }),
        'sync_seq': 1,
      });
      lista = await medicionesClienteLocal(55);
      expect(lista, hasLength(1));
      expect(lista.single['espejado'], isTrue);
    });
  });
}
