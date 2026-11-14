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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/listas.dart';
import 'package:ironbody_gym/mediciones_cliente.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/plus_reportes.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/mi_turno.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

int _seq = 3300;

Future<void> _espejo(
    Database db, String tabla, int id, Map<String, dynamic> data) async {
  await db.insert(tabla, {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': _seq++,
  });
}

Future<void> _opCola(Database db,
    {required String uuid,
    required String tipo,
    required Map<String, dynamic> payload,
    int? telegramId,
    String estado = 'pendiente'}) async {
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': estado,
    'creada_ts': isoHabana(ahoraHabana()),
    'telegram_id': telegramId,
  });
}

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

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
  });
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
          // Yunque 4 (L8-4): la fila espejo real trae
          // `fecha`, no `fecha_medicion` (esa es la clave
          // del payload de la op); el lector la expone como
          // fecha_medicion de salida.
          'fecha': '2026-11-14',
          'peso_kg': 90.0,
        }),
        'sync_seq': 1,
      });
      lista = await medicionesClienteLocal(55);
      expect(lista, hasLength(1));
      expect(lista.single['espejado'], isTrue);
      expect(lista.single['fecha_medicion'], '2026-11-14',
          reason: 'la forma real del espejo (fecha) debe '
              'llegar a la lista como fecha_medicion');
    });
  });

  group('K5-5 · «Cambiar teléfono del acceso» no trunca el '
      'pegado internacional', () {
    // El diálogo es privado de acciones_acceso.dart y su flujo
    // público termina en la RPC cambiar_telefono_acceso: un
    // widget test suyo exigiría sesión Supabase y servidor —
    // andamiaje desproporcionado. Contrato por pin de fuente
    // (estilo yunque2_cambiar_estado_test) + la conducta de la
    // sanitización que juzga al guardar.
    test('el TextField del diálogo no lleva maxLength y el '
        'guardado sanitiza el texto devuelto', () {
      final f = File('lib/ui/acciones_acceso.dart').readAsStringSync();
      final i = f.indexOf('class _DialogoCambiarTelefonoAcceso');
      expect(i, greaterThan(0));
      final dialogo = f.substring(i);
      expect(dialogo, isNot(contains('maxLength:')),
          reason: 'con maxLength: 8, pegar «5358191577» se '
              'truncaba a «53581915» ANTES de sanitizar y ese '
              'número equivocado quedaba como teléfono de '
              'acceso (la clase exacta de D-6)');
      final j = f.indexOf('Future<void> _cambiarTelefonoAccesoInterna');
      final k = f.indexOf("rpc(", j);
      expect(f.substring(j, k), contains('sanitizarTelefono(texto)'),
          reason: 'quien juzga es sanitizarTelefono al guardar, '
              'como en el diálogo compartido tras D-6');
    });

    test('sanitizarTelefono acepta el internacional pegado y '
        'el truncado también «valía»: por eso el tope era el '
        'defecto', () {
      expect(sanitizarTelefono('5358191577'), '58191577');
      expect(sanitizarTelefono('+53 5819 1577'), '58191577');
      // El número truncado por el maxLength es en sí mismo
      // «válido» (8 dígitos empezando en 5): ningún paso
      // posterior detectaba el error.
      expect(sanitizarTelefono('53581915'), '53581915');
    });
  });

  group('K5-8 · «Sin foto» de Buscar cuenta también la foto '
      'local', () {
    Map<String, dynamic> cli(
            {String? fotoStorage, String? fotoLocal}) =>
        {
          'id': 1,
          'nombre': 'Fixture',
          'estado': 'activo',
          'pagado_hasta': '2027-01-01',
          'foto_storage': fotoStorage,
          'foto_local': fotoLocal,
        };

    test('conteosDeBuscar: con foto local recién tomada (aún '
        'sin subir) NO cuenta como sin foto; sin ninguna, sí',
        () {
      expect(
          conteosDeBuscar([cli(fotoLocal: 'x.jpg')])['sinfoto'],
          0,
          reason: 'la foto local de este teléfono manda: su '
              'fila la muestra y no puede salir «sin foto»');
      expect(conteosDeBuscar([cli(fotoStorage: 'srv.jpg')])['sinfoto'],
          0);
      expect(conteosDeBuscar([cli()])['sinfoto'], 1,
          reason: 'sin foto en servidor ni local: sin foto de '
              'verdad');
      expect(
          conteosDeBuscar(
              [cli(fotoStorage: '', fotoLocal: '')])['sinfoto'],
          1);
    });

    test('el predicado compartido juzga ambas señales y el '
        'filtro de la pantalla lo usa', () {
      expect(clienteSinFotoBuscar(cli(fotoLocal: 'x.jpg')), isFalse);
      expect(clienteSinFotoBuscar(cli(fotoStorage: 'srv.jpg')),
          isFalse);
      expect(clienteSinFotoBuscar(cli()), isTrue);
      final f = File('lib/ui/buscar.dart').readAsStringSync();
      // Dos usos reales además de la declaración: el filtro
      // «sinfoto» y el contador de conteosDeBuscar.
      expect('clienteSinFotoBuscar('.allMatches(f).length,
          greaterThanOrEqualTo(3),
          reason: 'filtro y contador deben juzgar con el mismo '
              'predicado (K5-8)');
    });
  });

  group('K5-6 · el recibo desde la cola nombra al cobrador, '
      'no su id numérico', () {
    test('pago_mensual en cola: «Cobrado por: <nombre>» desde '
        'usuarios_apk; sin nombre resoluble, la línea se omite',
        () async {
      final db = await _abrirDbVacia();
      final hoy = hoyHabanaIso();
      final futuro = DateTime.parse(hoy)
          .add(const Duration(days: 10))
          .toIso8601String()
          .substring(0, 10);
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {'telegram_id': 222222, 'nombre': 'Gabriel'},
          ]));
      for (final id in [31, 32]) {
        await _espejo(db, 'clientes', id, {
          'id': id,
          'nombre': 'Cliente $id',
          'telefono': '581900$id',
          'estado': 'activo',
          'pagado_hasta': futuro,
        });
        await _opCola(db,
            uuid: 'op-recibo-k56-$id',
            tipo: 'pago_mensual',
            payload: {
              'cliente_id': id,
              'monto': 2000,
              'metodo': 'efectivo',
              'fecha': hoy,
            },
            telegramId: id == 31 ? 222222 : 999999);
      }
      final avisos = await avisosWhatsappHoy();
      final r31 = avisos.singleWhere(
          (a) => a['tipo'] == 'recibo' && a['cliente_id'] == 31);
      expect('${r31['mensaje']}', contains('Cobrado por: Gabriel'),
          reason: 'el recibo que sale al cliente lleva el NOMBRE '
              'del cobrador, como el de la rama del espejo');
      expect('${r31['mensaje']}', isNot(contains('222222')));
      final r32 = avisos.singleWhere(
          (a) => a['tipo'] == 'recibo' && a['cliente_id'] == 32);
      expect('${r32['mensaje']}', isNot(contains('999999')),
          reason: 'sin fuente de nombre, jamás el id crudo');
      expect('${r32['mensaje']}', isNot(contains('Cobrado por')),
          reason: 'sin nombre resoluble la línea se omite');
    });
  });

  group('K5-7 · el recibo de una inscripción nueva entra en la '
      'bandeja por la vía de cola', () {
    test('op inscribir de hoy (mensual estándar): aparece '
        'el recibo con el nombre del payload, y dos '
        'inscripciones no comparten clave de atendido', () async {
      final db = await _abrirDbVacia();
      final hoy = hoyHabanaIso();
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {'telegram_id': 222222, 'nombre': 'Gabriel'},
          ]));
      for (final (uuid, nombre) in [
        ('op-insc-k57-1', 'Nueva Uno'),
        ('op-insc-k57-2', 'Nueva Dos'),
      ]) {
        await _opCola(db,
            uuid: uuid,
            tipo: 'inscribir',
            payload: {
              'nombre': nombre,
              'telefono': '58112233',
              'periodo': 'mensual',
              'meses': 1,
              'metodo_pago': 'efectivo',
              'precio_aplicado': 2000,
              'fecha': hoy,
            },
            telegramId: 222222);
      }
      final avisos = await avisosWhatsappHoy();
      final recibos = avisos
          .where((a) =>
              a['tipo'] == 'recibo' &&
              ['Nueva Uno', 'Nueva Dos'].contains(a['nombre']))
          .toList();
      expect(recibos, hasLength(2),
          reason: 'el recibo de la inscripción no puede esperar '
              'al ciclo completo push→puente→pull');
      for (final r in recibos) {
        expect('${r['mensaje']}', contains('Cliente: ${r['nombre']}'));
        expect('${r['mensaje']}', contains('Cobrado por: Gabriel'));
        // Yunque 4 (L8-3): el importe también se afirma —
        // lo calcula montoCobradoCupOp recomputando la
        // tarifa (mensualidad), NO leyendo precio_aplicado
        // (que el productor sí envía pero ningún consumidor
        // de la bandeja lee).
        expect('${r['mensaje']}',
            contains('Monto: ${fmtMonto(2000)} CUP'));
        expect(r['telefono'], '5358112233');
      }
      final ids =
          recibos.map((r) => r['cliente_id'] as int).toList();
      expect(ids.toSet(), hasLength(2),
          reason: 'la clave de atendido es tipo+cliente_id: dos '
              'inscripciones con el mismo provisional chocarían');
      expect(ids.every((i) => i < 0), isTrue,
          reason: 'el provisional es negativo: no colisiona con '
              'ningún id real del servidor');
    });

    test('L8-3 (Yunque 4) · inscripción con periodo «tipo:» '
        'entra por su `monto` (la clave que el productor '
        'envía en ese periodo); sin `monto` vale 0 y no hay '
        'recibo', () async {
      final db = await _abrirDbVacia();
      final hoy = hoyHabanaIso();
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {'telegram_id': 222222, 'nombre': 'Gabriel'},
          ]));
      await _opCola(db,
          uuid: 'op-insc-tipo-con-monto',
          tipo: 'inscribir',
          payload: {
            'nombre': 'Tipo Con Monto',
            'telefono': '58112233',
            'periodo': 'tipo:oferta',
            'metodo_pago': 'efectivo',
            'monto': 1000,
            'precio_aplicado': 1000,
            'fecha': hoy,
          },
          telegramId: 222222);
      await _opCola(db,
          uuid: 'op-insc-tipo-sin-monto',
          tipo: 'inscribir',
          payload: {
            'nombre': 'Tipo Sin Monto',
            'telefono': '58112233',
            'periodo': 'tipo:oferta',
            'metodo_pago': 'efectivo',
            'precio_aplicado': 1000,
            'fecha': hoy,
          },
          telegramId: 222222);
      final avisos = await avisosWhatsappHoy();
      final conMonto = avisos
          .where((a) =>
              a['tipo'] == 'recibo' && a['nombre'] == 'Tipo Con Monto')
          .toList();
      expect(conMonto, hasLength(1),
          reason: 'con `monto`, la op «tipo:» se valora y el '
              'recibo entra en la bandeja');
      expect('${conMonto.single['mensaje']}',
          contains('Monto: ${fmtMonto(1000)} CUP'));
      final sinMonto = avisos.where((a) =>
          a['tipo'] == 'recibo' && a['nombre'] == 'Tipo Sin Monto');
      expect(sinMonto, isEmpty,
          reason: 'sin `monto` la op «tipo:» vale 0 aunque '
              'traiga precio_aplicado: esa clave no la lee '
              'ningún consumidor de la bandeja');
    });
  });

  group('K5-4 · Listas solo marca «avisado» tras confirmar el '
      'envío por WhatsApp', () {
    Future<bool> esperar(WidgetTester tester, bool Function() ok,
        {int vueltas = 60}) async {
      for (var i = 0; i < vueltas; i++) {
        if (ok()) return true;
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      return ok();
    }

    testWidgets('abrir WhatsApp y responder «No lo envié» NO '
        'marca; responder «Sí, enviado» sí', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final lanzadas = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          if (call.method == 'launch') {
            lanzadas.add('${call.arguments['url']}');
            return true;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/url_launcher'),
              null));

      await tester.runAsync(() async {
        await _abrirDbVacia();
        final hace5 = sumarDiasIso(hoyHabanaIso(), -5);
        await LocalDb.instance.upsertMirror('clientes', 41, {
          'nombre': 'Atrasado Aviso',
          'telefono': '58112233',
          'estado': 'activo',
          'pagado_hasta': hace5,
        }, 1);
      });
      await tester.pumpWidget(
          const MaterialApp(home: ListasScreen(inicial: 2)));
      expect(
          await esperar(
              tester, () => find.text('Atrasado Aviso').evaluate().isNotEmpty),
          isTrue,
          reason: 'la fila del atrasado no se pintó');

      Future<void> avisarPorWhatsApp() async {
        await tester.tap(find.byTooltip('Marcar como avisado').first);
        expect(
            await esperar(tester,
                () => find.text('Avisar por WhatsApp').evaluate().isNotEmpty),
            isTrue,
            reason: 'la hoja de vías de aviso no se abrió');
        // La hoja entra animada y el tap sintético cae fuera
        // (patrón de la oleada 7: se dispara el callback).
        tester
            .widget<ListTile>(
                find.widgetWithText(ListTile, 'Avisar por WhatsApp'))
            .onTap!();
        expect(
            await esperar(tester,
                () => find.text('¿Se envió el aviso?').evaluate().isNotEmpty),
            isTrue,
            reason: 'tras abrir WhatsApp debe preguntarse si el '
                'mensaje se envió (patrón Cumpleaños/Bandeja); '
                'sin pregunta, la marca se ponía al abrir');
      }

      // Vía WhatsApp con confirmación NEGATIVA: sin marca.
      await avisarPorWhatsApp();
      expect(lanzadas, isNotEmpty,
          reason: 'WhatsApp sí se abrió (launchUrl simulado)');
      tester
          .widget<TextButton>(
              find.widgetWithText(TextButton, 'No lo envié'))
          .onPressed!();
      await tester.pump(const Duration(milliseconds: 300));
      final marcados1 = await tester.runAsync(
          () => LocalDb.instance.avisadosVigentesConFecha());
      expect(marcados1!.containsKey(41), isFalse,
          reason: 'abrir WhatsApp no prueba el envío: sin '
              'confirmación el cliente NO puede quedar avisado '
              'para todo su ciclo de vencimiento');
      expect(find.byTooltip('Marcar como avisado'), findsWidgets,
          reason: 'la fila sigue ofreciendo avisar');

      // Vía WhatsApp con confirmación POSITIVA: marca.
      await avisarPorWhatsApp();
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Sí, enviado'))
          .onPressed!();
      var marcados2 = <int, DateTime>{};
      for (var i = 0; i < 40 && !marcados2.containsKey(41); i++) {
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
        marcados2 = await tester.runAsync(
                () => LocalDb.instance.avisadosVigentesConFecha()) ??
            {};
      }
      expect(marcados2.containsKey(41), isTrue,
          reason: 'confirmado el envío, la marca sí se asienta');
      // Drenar el snack de la cadena para no dejar timers.
      await tester.pump(const Duration(seconds: 6));
    });
  });
}
