/// Gestión 1.29 · Oleada 4 · FB-10 (WhatsApp desde el
/// recordatorio) + FB-13 (hora elegible de los avisos).
///
/// Contrato que se fija:
/// FB-13 (puros): instanteAvisoHabanaHora(fecha, 20) cae a
/// las 20:00 de pared Habana del día pedido, también en los
/// bordes DST de Cuba (8-mar y 1-nov de 2026);
/// instanteAvisoDebido con la hora pasada devuelve +5 min.
/// La hora se persiste en su meta (default 08:00) y
/// fijarHoraAvisos limpia las marcas de programación para
/// que la alarma se reprograme con la hora nueva.
/// FB-10 (puros): el mensaje de vencimiento sale de la
/// fuente única según el estado del cliente; el de
/// cumpleaños es el de la bandeja con la línea automática;
/// la URL es wa.me/<10 dígitos con 53>?text=<codificado>.
/// FB-10 (widget): la tarjeta del debido (vencimiento y
/// cumpleaños) ofrece «WhatsApp» junto a «Disparar», abre
/// wa.me con el teléfono efectivo y el mensaje — y VOLVER
/// no marca el recordatorio: sigue pendiente, sin disparo
/// asentado.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/notificaciones_recordatorios.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/recordatorios.dart';
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

Future<void> _fijarSesionDueno() async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jctr0602@ironbody.gym', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
      'aud': 'authenticated',
      'email': 'jctr0602@ironbody.gym',
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
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
  await db.delete('clientes');
  await db.delete('meta');
  try {
    await db.delete('recordatorio_config');
  } catch (_) {}
  try {
    await db.delete('recordatorio_disparos_log');
  } catch (_) {}
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('FB-13 · hora elegible de los avisos', () {
    test('instanteAvisoHabanaHora: las 20:00 de pared Habana',
        () {
      for (final fecha in [
        '2026-11-07', // día normal (CST, -5)
        '2026-06-15', // verano (CDT, -4)
        '2026-03-08', // borde DST: primavera
        '2026-11-01', // borde DST: otoño
      ]) {
        final inst = instanteAvisoHabanaHora(fecha, 20);
        final pared = aHabana(inst);
        expect(
            '${pared.year}-${pared.month}-${pared.day} ${pared.hour}',
            '${fecha.substring(0, 4)}-'
            '${int.parse(fecha.substring(5, 7))}-'
            '${int.parse(fecha.substring(8, 10))} 20',
            reason: 'fecha $fecha');
      }
      // La forma histórica delega en la general (08:00).
      expect(instanteAvisoHabana('2026-11-07'),
          instanteAvisoHabanaHora('2026-11-07', 8));
    });

    test('instanteAvisoDebido con hora 20: futuro → la hora; '
        'pasada → +5 min', () {
      final antes = DateTime.utc(2026, 11, 7, 12); // 07:00 Habana
      final inst = instanteAvisoDebido(
          fecha: '2026-11-07', ahoraUtc: antes, hora: 20);
      expect(inst, instanteAvisoHabanaHora('2026-11-07', 20));
      final despues = DateTime.utc(2026, 11, 8, 3); // 22:00 Habana
      final tarde = instanteAvisoDebido(
          fecha: '2026-11-07', ahoraUtc: despues, hora: 20);
      expect(tarde, despues.add(const Duration(minutes: 5)));
    });

    test('la hora persiste en su meta; default 08:00; '
        'fijarla limpia las marcas de programación', () async {
      await _bdVacia();
      expect(await AvisosRecordatorios.horaAvisos(), 8);
      await LocalDb.instance
          .setMeta(kMetaHoraAvisosRecordatorios, 'basura');
      expect(await AvisosRecordatorios.horaAvisos(), 8,
          reason: 'basura en la meta no rompe el default');
      await LocalDb.instance.setMeta('notif_prog_x_hoy', '12345');
      await AvisosRecordatorios.fijarHoraAvisos(20);
      expect(await AvisosRecordatorios.horaAvisos(), 20);
      expect(await LocalDb.instance.getMeta('notif_prog_x_hoy'),
          '',
          reason: 'la marca se limpia: se reprograma a las 20');
    });
  });

  group('FB-10 · mensaje y URL (puros)', () {
    test('vencimiento: sale de la fuente única según estado',
        () {
      final hoy = hoyHabanaIso();
      final cliente = {
        'nombre': 'Ana Pérez',
        'pagado_hasta': hoy,
        'telefono': '58191577',
      };
      expect(
        mensajeWaRecordatorio(
            tipo: 'vencimiento', cliente: cliente, nombre: 'Ana'),
        mensajeWaVenceHoy('Ana Pérez'),
      );
      final vencido = {
        'nombre': 'Ana Pérez',
        'pagado_hasta': '2020-01-01',
      };
      expect(
        mensajeWaRecordatorio(
            tipo: 'vencimiento', cliente: vencido, nombre: 'Ana'),
        mensajeWaVencido('Ana Pérez'),
      );
    });

    test('cumpleaños: el texto de la bandeja con la línea '
        'automática', () {
      final m = mensajeWaRecordatorio(
          tipo: 'cumpleanos', cliente: null, nombre: 'Luis');
      expect(m, contains('¡Feliz cumpleaños, Luis!'));
      expect(m, contains(lineaMensajeAutomatico.trim()));
    });

    test('la URL lleva el teléfono efectivo (53 + 8 dígitos) '
        'y el mensaje codificado', () {
      final url = urlWaRecordatorio(
          '5358191577', mensajeWaVenceHoy('Ana Pérez'));
      final uri = Uri.parse(url);
      expect(uri.host, 'wa.me');
      expect(uri.path, '/5358191577');
      expect(uri.queryParameters['text'],
          mensajeWaVenceHoy('Ana Pérez'));
    });
  });

  group('FB-10 · la tarjeta del debido', () {
    testWidgets(
        'vencimiento y cumpleaños ofrecen WhatsApp; abrirlo '
        'NO asienta el recordatorio', (tester) async {
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

      final hoy = hoyHabanaIso();
      final mm = hoy.substring(5, 7);
      final dd = hoy.substring(8, 10);
      await tester.runAsync(() async {
        await _bdVacia();
        await _fijarSesionDueno();
        final db = await LocalDb.instance.db;
        await db.insert('clientes', {
          'id': 5,
          'data': jsonEncode({
            'id': 5,
            'nombre': 'Ana Pérez',
            'telefono': '58191577',
            'pagado_hasta': hoy,
            'estado': 'activo',
          }),
          'sync_seq': 1,
        });
        await db.insert('clientes', {
          'id': 6,
          'data': jsonEncode({
            'id': 6,
            'nombre': 'Luis Díaz',
            'telefono': '52001122',
            'carnet': '90$mm$dd',
            'nacimiento': '1990-$mm-$dd',
            'pagado_hasta': '2027-06-01',
            'estado': 'activo',
          }),
          'sync_seq': 1,
        });
        await LocalDb.instance.guardarRecordatorio({
          'id': 'cfg-venc',
          'tipo': 'vencimiento',
          'titulo': 'Vencimiento de hoy',
          'alcance': 'todos',
          'activa': 1,
          'dias_anticipacion': 3,
          'creado_por': 735772141,
          'creada_ts': '2026-11-07T00:00:00',
          'actualizada_ts': '2026-11-07T00:00:00',
        });
        await LocalDb.instance.guardarRecordatorio({
          'id': 'cfg-cumple',
          'tipo': 'cumpleanos',
          'titulo': 'Cumpleaños de hoy',
          'alcance': 'todos',
          'activa': 1,
          'creado_por': 735772141,
          'creada_ts': '2026-11-07T00:00:00',
          'actualizada_ts': '2026-11-07T00:00:00',
        });
      });

      await tester.pumpWidget(
          const MaterialApp(home: RecordatoriosScreen()));
      expect(await _esperarTexto(tester, 'Vencimiento de hoy'),
          isTrue);
      expect(find.text('WhatsApp'), findsNWidgets(2),
          reason: 'ambas tarjetas ofrecen avisar por WhatsApp');
      expect(find.text('Disparar'), findsNWidgets(2));

      // La de vencimiento es la primera tarjeta.
      await tester.tap(find.text('WhatsApp').first);
      for (var i = 0; i < 20 && lanzadas.isEmpty; i++) {
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 80));
      }
      expect(lanzadas.length, 1);
      final uri = Uri.parse(lanzadas.single);
      expect(uri.path, '/5358191577',
          reason: 'el teléfono efectivo con su 53');
      expect(uri.queryParameters['text'],
          mensajeWaVenceHoy('Ana Pérez'));

      // Volver de WhatsApp NO marca nada: el debido sigue
      // pendiente y no hay disparo asentado.
      expect(find.text('Disparar'), findsNWidgets(2));
      expect(find.textContaining('ya disparado hoy'), findsNothing);
      final disparos = (await tester.runAsync(() =>
          LocalDb.instance.disparosRecordatoriosDelDia(hoy)))!;
      expect(disparos, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('Barrido · el diálogo de crear recordatorio', () {
    // El patrón D-B1-08: el formulario vive en un
    // StatefulWidget dueño de su controlador. Abrir,
    // teclear, cancelar y confirmar NO puede terminar en
    // «used after being disposed» durante la animación de
    // salida, y confirmar crea el recordatorio.
    testWidgets('abrir, teclear, cancelar y crear: sin '
        'excepciones y con el recordatorio creado',
        (tester) async {
      // Pantalla larga: viewport alto (patrón de la casa).
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
        await _fijarSesionDueno();
      });
      await tester.pumpWidget(
          const MaterialApp(home: RecordatoriosScreen()));
      // Con la BD vacía la pantalla pinta su estado vacío
      // («Sin recordatorios»), no los encabezados de lista.
      expect(await _esperarTexto(tester, 'Sin recordatorios'),
          isTrue);

      // Cancelar tras teclear: la salida no revienta.
      await tester.tap(find.byIcon(Icons.add_rounded));
      expect(await _esperarTexto(tester, 'Nuevo recordatorio'),
          isTrue);
      await tester.enterText(
          find.byType(TextField).first, 'Aviso que se cancela');
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.text('Nuevo recordatorio'), findsNothing);
      expect(tester.takeException(), isNull);

      // Crear de verdad: el recordatorio queda guardado.
      await tester.tap(find.byIcon(Icons.add_rounded));
      expect(await _esperarTexto(tester, 'Nuevo recordatorio'),
          isTrue);
      await tester.enterText(
          find.byType(TextField).first, 'Aviso de prueba O4');
      await tester.tap(find.text('Crear'));
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 80));
        if (find.text('Aviso de prueba O4').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.text('Aviso de prueba O4'), findsOneWidget);
      final configs = (await tester.runAsync(
          () => LocalDb.instance.listarRecordatorios()))!;
      expect(
          configs.any((c) => c['titulo'] == 'Aviso de prueba O4'),
          isTrue);
      // Crear dispara el push del motor: su ciclo mezcla red
      // real (avanza en runAsync) y temporizadores de la zona
      // falsa (avanzan con pump). Se entrelaza hasta que el
      // ciclo muere y su latido se cancela (si no, el
      // desmontaje acusa un Timer vivo). La BD de este
      // archivo usa la factoría FFI sin isolate: con la de
      // isolate, las consultas del ciclo desde la zona falsa
      // se quedan sin respuesta y el ciclo nunca termina.
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() =>
            Future<void>.delayed(const Duration(milliseconds: 300)));
        await tester.pump(const Duration(seconds: 1));
      }
      expect(tester.takeException(), isNull);
    });
  });
}
