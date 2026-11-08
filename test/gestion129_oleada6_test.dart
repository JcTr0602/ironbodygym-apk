/// Gestión 1.29 · Oleada 6 (panel-sistema y cola) + v68.
///
/// Contrato que se fija, punto por punto del plan §7:
/// · D-A3 (v68): fotoVisibleParaActor — el dueño ve todo;
///   el no-dueño solo sus fotos selladas; las previas sin
///   sello (NULL) son del dueño (ni lista ni contadores);
///   la de un protegido no la ve ni su autor. En la
///   pantalla: los contadores del entrenador cuentan solo
///   lo visible; los del dueño, el total global.
/// · FA-06: etiquetaOpAjena («de Duany · suben cuando él
///   entre»; firma de texto > firma numérica resuelta por
///   el directorio > «de otra cuenta») y el desglose
///   «N pendientes · M tuyas · K de otros» que suma el
///   total global de la cabecera.
/// · FB-16: el río de Auditoría por bloques con cursor
///   (creada_ts + rowid): 250 ops de hoy sin duplicados
///   entre bloques, contador «viendo N de M de hoy» y la
///   op de la mañana alcanzable y buscable.
/// · D-B3-09 (+H-06): Auditoría por persona — la base y
///   el río se cargan una vez; cambiar de persona no
///   relee (lo sembrado después no aparece); el mes con
///   600 ops sale del río completo, no del tope de 500.
/// · FB-17 + D-B3-04: caso marcado «ya revisado» no
///   reaparece; un hecho nuevo (otro id fuente) sí; un
///   detector que falla NO pinta «Sin anomalías».
/// · D-B3-05: guardarAvisoVerificado — lo que aterrizó
///   tras un timeout no se duplica; lo que no aterrizó
///   se puede reintentar; sin comprobación posible,
///   sinConfirmar.
/// · D-B3-06: dos exportaciones → dos copias con nombre
///   fechado en documentos/copias_manuales.
/// · D-B3-08: csvDeExportacion neutraliza fórmulas.
/// · FB-19: el mensaje del vale aprobado contiene el
///   nuevo vencimiento; el del rechazado, el motivo; la
///   bandeja ofrece «Avisar por WhatsApp» al teléfono
///   del vale.
/// · FB-20: tocar la tarjeta de Comunidad abre la ficha
///   del cliente correcto; los botones no navegan.
/// · D-16: estadoSaludSync en sus tres estados y el
///   AvisoEstado de la pantalla de Salud.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/copia_seguridad.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/auditoria.dart';
import 'package:ironbody_gym/ui/auditoria_persona.dart';
import 'package:ironbody_gym/ui/auditoria_silenciosa.dart';
import 'package:ironbody_gym/ui/cola.dart';
import 'package:ironbody_gym/ui/editor_avisos_clientes.dart';
import 'package:ironbody_gym/ui/exportar_excel.dart';
import 'package:ironbody_gym/ui/panel_comunidad.dart';
import 'package:ironbody_gym/ui/panel_premios.dart';
import 'package:ironbody_gym/ui/salud_sync_screen.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés común (la pauta de las oleadas 4/5) ──────────

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesion(
    WidgetTester tester, String email, int telegramId) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso(email, telegramId),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e6',
      'aud': 'authenticated',
      'email': email,
      'app_metadata': {
        'telegram_id': telegramId,
        'provider': 'email'
      },
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _sesionDueno(WidgetTester t) =>
    _fijarSesion(t, 'jc@ironbody.local', 735772141);
Future<void> _sesionDuany(WidgetTester t) =>
    _fijarSesion(t, 'duany@ironbody.local', 969869611);

Future<Database> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

/// Fecha ISO (AAAA-MM-DD) de un instante ya en hora de
/// La Habana (se formatean sus campos, sin convertir).
String _fechaIso(DateTime f) =>
    '${f.year.toString().padLeft(4, '0')}-'
    '${f.month.toString().padLeft(2, '0')}-'
    '${f.day.toString().padLeft(2, '0')}';

Future<void> _pumps(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// El banner de sync programa un temporizador de un solo
/// disparo (≤30 s) al pintar un resumen reciente: si el
/// test termina con él pendiente, el arnés lo marca como
/// error. Se drena avanzando el reloj falso más allá.
Future<void> _drenarBanner(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 31));
}

Future<void> _insertarOp(
  Database db, {
  required String uuid,
  required String tipo,
  String estado = 'pendiente',
  Map<String, dynamic> payload = const {},
  String? creadaTs,
  int? telegramId,
}) async {
  await db.insert('ops_queue', {
    'op_uuid': uuid,
    'tipo': tipo,
    'payload': jsonEncode(payload),
    'estado': estado,
    'creada_ts': creadaTs ?? '${hoyHabanaIso()}T09:00:00.000-04:00',
    if (telegramId != null) 'telegram_id': telegramId,
  });
}

Future<void> _insertarFoto(
  Database db, {
  required String uuid,
  int? clienteId,
  int? telegramId,
  String estado = 'pendiente',
}) async {
  final ahora = isoHabana(ahoraHabana());
  await db.insert('fotos_cola', {
    'op_uuid': uuid,
    'tipo': 'display',
    'cliente_id': clienteId,
    'ruta_local': '/tmp/$uuid.jpg',
    'estado': estado,
    'intentos': 0,
    'telegram_id': telegramId,
    'creado_en': ahora,
    'actualizado_en': ahora,
  });
}

Future<void> _insertarClienteEspejo(
  Database db,
  int id,
  Map<String, dynamic> data,
) async {
  await db.insert('clientes', {
    'id': id,
    'data': jsonEncode(data),
    'sync_seq': 1,
  });
}

void main() {
  late Directory docsDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
    // path_provider → carpeta propia: la copia en frío
    // (D-B3-06) escribe en <docs>/copias_manuales.
    docsDir = await Directory.systemTemp.createTemp('o6_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docsDir.path);
  });

  // ── D-A3 · la regla de visibilidad de fotos ──────────
  group('D-A3 · fotoVisibleParaActor (pura)', () {
    test('el dueño ve todas (selladas, ajenas y previas)', () {
      expect(
          fotoVisibleParaActor({'telegram_id': 111},
              esDueno: true, miTelegramId: 735772141),
          isTrue);
      expect(
          fotoVisibleParaActor({'telegram_id': null},
              esDueno: true, miTelegramId: 735772141),
          isTrue);
    });

    test('el no-dueño solo ve las suyas selladas', () {
      expect(
          fotoVisibleParaActor({'telegram_id': 969869611},
              esDueno: false, miTelegramId: 969869611),
          isTrue);
      expect(
          fotoVisibleParaActor({'telegram_id': 1403501391},
              esDueno: false, miTelegramId: 969869611),
          isFalse,
          reason: 'la foto de otro entrenador no se le enseña');
      expect(
          fotoVisibleParaActor({'telegram_id': null},
              esDueno: false, miTelegramId: 969869611),
          isFalse,
          reason: 'la previa sin sello es DEL DUEÑO: ningún '
              'no-dueño la ve');
      expect(
          fotoVisibleParaActor({'telegram_id': 969869611},
              esDueno: false, miTelegramId: null),
          isFalse,
          reason: 'sin identidad de sesión no se acredita '
              'ninguna foto como propia (fail-closed)');
    });
  });

  group('D-A3 · la cola en pantalla', () {
    Future<void> sembrarFotos(Database db) async {
      await _insertarClienteEspejo(db, 5, {'nombre': 'Cinco'});
      await _insertarClienteEspejo(
          db, 6, {'nombre': 'Seis', 'protegido': 1});
      // Propia de Duany, cliente normal.
      await _insertarFoto(db,
          uuid: 'f-propia', clienteId: 5, telegramId: 969869611);
      // De Gabriel.
      await _insertarFoto(db,
          uuid: 'f-ajena', clienteId: 5, telegramId: 1403501391);
      // Previa a v68: sin sello = del dueño.
      await _insertarFoto(db, uuid: 'f-previa', clienteId: 5);
      // Propia de Duany pero de un cliente protegido.
      await _insertarFoto(db,
          uuid: 'f-protegida', clienteId: 6, telegramId: 969869611);
    }

    testWidgets('entrenador: contadores solo con lo visible '
        '(autor ∩ no protegido)', (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await sembrarFotos(db);
      });
      await _sesionDuany(tester);
      await tester.pumpWidget(
          const MaterialApp(home: ColaScreen()));
      await _pumps(tester);
      // Solo f-propia cuenta: la ajena es de otro, la
      // previa es del dueño y la protegida no se enseña
      // ni a su autor.
      expect(find.text('1 pendientes · 0 subiendo'),
          findsOneWidget);
      await _drenarBanner(tester);
    });

    testWidgets('dueño: contadores con el total global',
        (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await sembrarFotos(db);
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(
          const MaterialApp(home: ColaScreen()));
      await _pumps(tester);
      expect(find.text('4 pendientes · 0 subiendo'),
          findsOneWidget);
      await _drenarBanner(tester);
    });
  });

  // ── FA-06 · lo ajeno, etiquetado ────────────────────
  group('FA-06 · etiqueta y desglose (puros)', () {
    test('la mía y la sin firma no llevan etiqueta', () {
      expect(
          etiquetaOpAjena(
              {'payload': jsonEncode({'registrado_por': 735772141})},
              miActor: 'Jc',
              miTelegramId: 735772141,
              nombresPorTelegram: const {}),
          isNull);
      expect(
          etiquetaOpAjena({'payload': '{}'},
              miActor: 'Jc',
              miTelegramId: 735772141,
              nombresPorTelegram: const {}),
          isNull,
          reason: 'sin firma = mía (la regla de esOpMia)');
    });

    test('firma de texto: el nombre sale de la propia op', () {
      expect(
          etiquetaOpAjena(
              {
                'payload':
                    jsonEncode({'registrado_por_nombre': 'Duany'})
              },
              miActor: 'Jc',
              miTelegramId: 735772141,
              nombresPorTelegram: const {}),
          'de Duany · suben cuando él entre');
    });

    test('solo firma numérica: se resuelve por el directorio',
        () {
      expect(
          etiquetaOpAjena(
              {'payload': jsonEncode({'registrado_por': 969869611})},
              miActor: 'Jc',
              miTelegramId: 735772141,
              nombresPorTelegram: const {969869611: 'Duany'}),
          'de Duany · suben cuando él entre');
    });

    test('firma numérica sin nombre en el directorio: '
        '«de otra cuenta»', () {
      // La atribución de la casa (esOpMia) manda por la
      // firma del PAYLOAD: la columna telegram_id sola no
      // convierte una op en ajena. Con firma numérica de
      // otro y sin nombre resoluble, la etiqueta honesta
      // es la genérica.
      expect(
          etiquetaOpAjena(
              {
                'payload':
                    jsonEncode({'registrado_por': 1403501391})
              },
              miActor: 'Jc',
              miTelegramId: 735772141,
              nombresPorTelegram: const {}),
          'de otra cuenta · suben cuando entre su cuenta');
    });

    test('el desglose suma el total global', () {
      final ops = <Map<String, dynamic>>[
        {'payload': jsonEncode({'registrado_por': 735772141})},
        {'payload': '{}'},
        {'payload': jsonEncode({'registrado_por': 969869611})},
        {
          'payload': jsonEncode({'registrado_por_nombre': 'Gabriel'})
        },
      ];
      final d = desglosePendientesPorAutor(ops,
          miActor: 'Jc', miTelegramId: 735772141);
      expect(d.mias, 2);
      expect(d.deOtros, 2);
      expect(d.mias + d.deOtros, ops.length);
    });
  });

  group('FA-06 · la cola del dueño en pantalla', () {
    testWidgets('cabecera con el total global + desglose, '
        'y las ajenas etiquetadas', (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await LocalDb.instance.setMeta(
            'usuarios_apk',
            jsonEncode([
              {'telegram_id': 969869611, 'nombre': 'Duany'},
            ]));
        await _insertarOp(db,
            uuid: 'o-mia',
            tipo: 'pago_diario',
            payload: {'registrado_por': 735772141});
        await _insertarOp(db,
            uuid: 'o-duany-num',
            tipo: 'pago_diario',
            payload: {'registrado_por': 969869611});
        await _insertarOp(db,
            uuid: 'o-duany-txt',
            tipo: 'pago_mensual',
            payload: {'registrado_por_nombre': 'Duany'});
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(
          const MaterialApp(home: ColaScreen()));
      await _pumps(tester);
      expect(
          find.text('3 pendientes · 1 tuyas · 2 de otros'),
          findsOneWidget,
          reason: 'la cifra de cabecera no cambia (total '
              'global) y el desglose nace junto a ella');
      await tester.scrollUntilVisible(
        find.text('de Duany · suben cuando él entre'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await _pumps(tester, 4);
      expect(find.text('de Duany · suben cuando él entre'),
          findsWidgets);
      await _drenarBanner(tester);
    });
  });

  // ── FB-16 · Auditoría sin techo silencioso ──────────
  group('FB-16 · el río por bloques (LocalDb)', () {
    test('250 ops de hoy: bloques sin duplicados y la '
        'mañana alcanzable', () async {
      final db = await _bdVacia();
      final hoy = hoyHabanaIso();
      final batch = db.batch();
      for (var i = 0; i < 250; i++) {
        final minutos = i * 5; // 00:00 → 20:45
        final hh = (minutos ~/ 60).toString().padLeft(2, '0');
        final mm = (minutos % 60).toString().padLeft(2, '0');
        batch.insert('ops_queue', {
          'op_uuid': 'fb16-$i',
          'tipo': 'pago_mensual',
          'payload': jsonEncode({'cliente_id': 7}),
          'estado': 'pendiente',
          'creada_ts': '${hoy}T$hh:$mm:00.000-04:00',
        });
      }
      await batch.commit(noResult: true);

      expect(await LocalDb.instance.contarOpsDelDia(hoy), 250);

      final vistos = <String>{};
      ({String ts, int rowid})? cursor;
      var bloques = 0;
      while (true) {
        final bloque = await LocalDb.instance
            .opsAuditoriaBloque(cursor: cursor, limite: 100);
        if (bloque.isEmpty) break;
        bloques++;
        for (final o in bloque) {
          expect(vistos.add('${o['op_uuid']}'), isTrue,
              reason: 'ninguna op se repite entre bloques '
                  '(cursor estable creada_ts + rowid)');
        }
        final ultima = bloque.last;
        cursor = (
          ts: '${ultima['creada_ts']}',
          rowid: (ultima['_rowid'] as num).toInt(),
        );
        if (bloque.length < 100) break;
      }
      expect(bloques, 3);
      expect(vistos.length, 250);
      expect(vistos.contains('fb16-0'), isTrue,
          reason: 'la op de las 00:00 (la mañana) es '
              'alcanzable: ya no hay techo de 100');
    });

    test('opsEntreFechas trae la ventana completa, sin '
        'tope de conteo', () async {
      final db = await _bdVacia();
      final batch = db.batch();
      for (var i = 0; i < 620; i++) {
        batch.insert('ops_queue', {
          'op_uuid': 'vent-$i',
          'tipo': 'pago_mensual',
          'payload': '{}',
          'estado': 'aplicada',
          'creada_ts': '2026-11-03T10:00:00.000-04:00',
        });
      }
      batch.insert('ops_queue', {
        'op_uuid': 'vent-fuera',
        'tipo': 'pago_mensual',
        'payload': '{}',
        'estado': 'aplicada',
        'creada_ts': '2026-10-31T10:00:00.000-04:00',
      });
      await batch.commit(noResult: true);
      final rio = await LocalDb.instance
          .opsEntreFechas('2026-11-01', '2026-11-30');
      expect(rio.length, 620);
    });
  });

  group('FB-16 · la Auditoría en pantalla', () {
    testWidgets('contador honesto, «Ver más antiguas» y '
        'búsqueda dentro de lo cargado', (tester) async {
      // Superficie de teléfono real: a 800×600 el
      // esqueleto de carga de la pantalla desborda por
      // 16 px (defecto previo del esqueleto en ventanas
      // bajas, ajeno a esta oleada).
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await _insertarClienteEspejo(db, 7, {'nombre': 'Fulano'});
        final hoy = hoyHabanaIso();
        final batch = db.batch();
        for (var i = 0; i < 250; i++) {
          final minutos = i * 5;
          final hh = (minutos ~/ 60).toString().padLeft(2, '0');
          final mm = (minutos % 60).toString().padLeft(2, '0');
          batch.insert('ops_queue', {
            'op_uuid': 'pant-$i',
            // La primera (la de la mañana) es una
            // inscripción con nombre buscable.
            'tipo': i == 0 ? 'inscribir' : 'pago_mensual',
            'payload': jsonEncode(i == 0
                ? {'nombre': 'Madrugador Unico'}
                : {'cliente_id': 7}),
            'estado': 'pendiente',
            'creada_ts': '${hoy}T$hh:$mm:00.000-04:00',
          });
        }
        await batch.commit(noResult: true);
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(
          const MaterialApp(home: AuditoriaScreen()));
      await _pumps(tester, 20);
      expect(find.textContaining('Viendo 100 de 250 de hoy'),
          findsOneWidget,
          reason: 'el contador dice lo cargado DE lo que '
              'existe, no «100 operaciones hoy»');

      // Dos bloques más: el río entero. El Scrollable a
      // arrastrar es el de la LISTA (el primero del árbol
      // es el de las píldoras de filtro, horizontal).
      final scrollLista = find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable));
      for (var vuelta = 0; vuelta < 2; vuelta++) {
        await tester.scrollUntilVisible(
          find.text('Ver más antiguas'),
          300,
          scrollable: scrollLista.first,
        );
        await tester.tap(find.text('Ver más antiguas'));
        await _pumps(tester, 16);
      }
      expect(find.textContaining('Viendo 250 de 250 de hoy'),
          findsOneWidget);

      // La op de la mañana, buscable dentro de lo cargado.
      await tester.tap(
          find.widgetWithText(ChoiceChip, 'Todo'));
      await _pumps(tester, 4);
      await tester.enterText(
          find.byType(TextField), 'Madrugador');
      await _pumps(tester, 6);
      expect(find.textContaining('Madrugador Unico'),
          findsOneWidget);
      await _drenarBanner(tester);
    });
  });

  // ── D-B3-09 · Auditoría por persona ─────────────────
  group('D-B3-09 · carga única y ventana H-06', () {
    testWidgets('el mes con 600 ops sale del río completo; '
        'cambiar de persona no relee', (tester) async {
      final hoy = ahoraHabana();
      final lunes = hoy.subtract(Duration(days: hoy.weekday - 1));
      bool enSemana(DateTime f) {
        final d = DateTime(f.year, f.month, f.day);
        final l = DateTime(lunes.year, lunes.month, lunes.day);
        final dom = l.add(const Duration(days: 6));
        return !d.isBefore(l) && !d.isAfter(dom);
      }

      final hoyIso = _fechaIso(hoy);
      // Un día del mes fuera de esta semana (si el mes
      // entero cae en la semana, se usa el día 1 y la
      // expectativa de semana se ajusta abajo).
      var diaMesIso = _fechaIso(DateTime(hoy.year, hoy.month, 1));
      var mesFueraDeSemana = !enSemana(DateTime(hoy.year, hoy.month, 1));
      if (!mesFueraDeSemana) {
        diaMesIso = hoyIso;
      }

      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await LocalDb.instance.setMeta(
            'usuarios_apk',
            jsonEncode([
              {
                'id': 'u-gabriel',
                'telegram_id': 222,
                'nombre': 'Gabriel'
              },
              {
                'id': 'u-duany',
                'telegram_id': 111,
                'nombre': 'Duany'
              },
            ]));
        final batch = db.batch();
        // 10 sensibles de Gabriel HOY (en la semana).
        for (var i = 0; i < 10; i++) {
          batch.insert('ops_queue', {
            'op_uuid': 'sem-$i',
            'tipo': 'pago_mensual',
            'payload': jsonEncode({'registrado_por': 222}),
            'estado': 'aplicada',
            'creada_ts': '${hoyIso}T08:00:00.000-04:00',
          });
        }
        // 590 más de Gabriel dentro del mes.
        for (var i = 0; i < 590; i++) {
          batch.insert('ops_queue', {
            'op_uuid': 'mes-$i',
            'tipo': 'pago_mensual',
            'payload': jsonEncode({'registrado_por': 222}),
            'estado': 'aplicada',
            'creada_ts': '${diaMesIso}T09:00:00.000-04:00',
          });
        }
        await batch.commit(noResult: true);
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(
          home: AuditoriaPersonaScreen()));
      await _pumps(tester, 24);

      // Persona por defecto = Gabriel (la primera). El mes
      // trae las 600 del río COMPLETO: con el tope viejo
      // de 500 esto diría 500.
      expect(find.text('600'), findsOneWidget,
          reason: 'las cifras del mes salen del río '
              'completo recargado, no de un río de 500');

      // Semana: filtra en memoria sobre lo ya cargado.
      await tester.tap(find.widgetWithText(ChoiceChip, 'Semana'));
      await _pumps(tester, 16);
      expect(find.text(mesFueraDeSemana ? '10' : '600'),
          findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Mes'));
      await _pumps(tester, 16);
      expect(find.text('600'), findsOneWidget);

      // Lo sembrado DESPUÉS de la carga no aparece al
      // cambiar de persona: no hubo releectura.
      await tester.runAsync(() async {
        for (var i = 0; i < 5; i++) {
          await _insertarOp(db,
              uuid: 'nueva-$i',
              tipo: 'pago_mensual',
              estado: 'aplicada',
              payload: {'registrado_por': 222},
              creadaTs: '${hoyIso}T10:00:00.000-04:00');
        }
      });
      await tester.tap(find.text('Gabriel'));
      await _pumps(tester, 6);
      await tester.tap(find.text('Duany').last);
      await _pumps(tester, 16);
      await tester.tap(find.text('Duany'));
      await _pumps(tester, 6);
      await tester.tap(find.text('Gabriel').last);
      await _pumps(tester, 16);
      expect(find.text('600'), findsOneWidget,
          reason: 'cambiar de persona filtra en memoria: '
              'las 5 ops nuevas no entran (no se releyó)');
      expect(find.text('605'), findsNothing);
    });
  });

  // ── FB-17 + D-B3-04 · Anomalías ─────────────────────
  group('FB-17 · casos trabajables', () {
    Future<void> sembrarTurnoCorto(Database db, String turnoId,
        {String turno = 'manana', String hora = '08'}) async {
      // UNIQUE(fecha_turno, turno, telegram_id): dos casos
      // del mismo día y persona difieren en el turno.
      await db.insert('turnos', {
        'turno_id': turnoId,
        'fecha_turno': hoyHabanaIso(),
        'turno': turno,
        'hora_apertura': '${hoyHabanaIso()}T$hora:00:00.000-04:00',
        'hora_cierre': '${hoyHabanaIso()}T$hora:10:00.000-04:00',
        'telegram_id': 111,
        'estado': 'cerrado',
      });
    }

    Future<void> prepararBase(Database db) async {
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {'id': 'u-duany', 'telegram_id': 111, 'nombre': 'Duany'},
          ]));
      // Sin caso de sync: el último pull es de ahora.
      await LocalDb.instance.setMeta(
          'last_pull_ok', isoHabana(ahoraHabana()));
    }

    testWidgets('marcar «ya revisado» retira el caso y no '
        'vuelve; un hecho nuevo sí vuelve', (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await prepararBase(db);
        await sembrarTurnoCorto(db, 'turno-fb17-1');
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(
          home: AuditoriaSilenciosaScreen()));
      await _pumps(tester, 20);
      expect(find.textContaining('Turno de 10 min'),
          findsOneWidget);

      await tester.tap(find.byTooltip('Ya revisado'));
      await _pumps(tester, 10);
      expect(find.textContaining('Turno de 10 min'),
          findsNothing);
      expect(find.text('Sin anomalías'), findsOneWidget,
          reason: 'todos los detectores bien y sin casos: '
              'ahora sí es «limpio»');

      // Una pantalla NUEVA tampoco lo resucita (la marca
      // vive en meta, no en la pantalla). Se desmonta
      // primero: pumpWidget con el mismo tipo reutiliza
      // el State y no recargaría.
      await tester
          .pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpWidget(const MaterialApp(
          home: AuditoriaSilenciosaScreen()));
      await _pumps(tester, 20);
      expect(find.textContaining('Turno de 10 min'),
          findsNothing);

      // Un hecho NUEVO (otro turno, otro id fuente) del
      // mismo tipo y persona SÍ reaparece.
      await tester.runAsync(() async {
        await sembrarTurnoCorto(db, 'turno-fb17-2',
            turno: 'tarde', hora: '14');
      });
      await tester
          .pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpWidget(const MaterialApp(
          home: AuditoriaSilenciosaScreen()));
      await _pumps(tester, 20);
      expect(find.textContaining('Turno de 10 min'),
          findsOneWidget,
          reason: 'la huella incluye el id del hecho '
              'fuente: el caso nuevo no hereda la marca');
    });

    testWidgets('tocar un caso abre la auditoría de la '
        'persona del caso', (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await prepararBase(db);
        await sembrarTurnoCorto(db, 'turno-fb17-nav');
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(
          home: AuditoriaSilenciosaScreen()));
      await _pumps(tester, 20);
      await tester.tap(find.textContaining('Turno de 10 min'));
      await _pumps(tester, 20);
      expect(find.text('Auditoría por persona'),
          findsOneWidget);
    });
  });

  group('D-B3-04 · «no pude revisar» no es «limpio»', () {
    testWidgets('detector forzado a fallar: la pantalla NO '
        'dice «Sin anomalías»', (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await LocalDb.instance.setMeta(
            'last_pull_ok', isoHabana(ahoraHabana()));
        // El detector de turnos revienta: su tabla no está.
        await db.execute('DROP TABLE turnos');
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(const MaterialApp(
          home: AuditoriaSilenciosaScreen()));
      await _pumps(tester, 20);
      expect(find.text('Sin anomalías'), findsNothing);
      expect(find.text('Revisión incompleta'), findsOneWidget);
      expect(find.textContaining('No se pudo revisar'),
          findsOneWidget);
    });

    test('la huella es tipo + id del hecho fuente', () {
      expect(huellaCasoAnomalia('turno_corto', 't-1'),
          'turno_corto|t-1');
      expect(
          huellaCasoAnomalia('turno_corto', 't-1') ==
              huellaCasoAnomalia('turno_corto', 't-2'),
          isFalse,
          reason: 'dos hechos del mismo tipo no comparten '
              'huella aunque sean de la misma persona');
    });
  });

  // ── D-B3-05 · avisos sin duplicar tras timeout ──────
  group('D-B3-05 · guardarAvisoVerificado (puro)', () {
    AvisoCliente aviso(int id, String titulo) => AvisoCliente(
        id: id,
        titulo: titulo,
        cuerpo: 'Cuerpo',
        nivel: 'info',
        creadoTs: '');

    test('lo que aterrizó pero respondió tarde cuenta '
        'como guardado (no se reintenta)', () async {
      final servidor = <AvisoCliente>[];
      var llamadas = 0;
      final r = await guardarAvisoVerificado(
        guardar: () async {
          llamadas++;
          servidor.add(aviso(9, 'Nuevo'));
          // La red «llega tarde» aunque el servidor ya
          // guardó: el patrón exacto del duplicado.
          throw TimeoutException('tarde');
        },
        listar: () async => List.of(servidor),
        idsPrevios: const {1},
        idEditado: null,
        titulo: 'Nuevo',
        cuerpo: 'Cuerpo',
        nivel: 'info',
      );
      expect(r, ResultadoGuardadoAviso.guardado);
      expect(llamadas, 1,
          reason: 'sin segundo intento: no hay duplicado');
      expect(servidor.length, 1);
    });

    test('edición reflejada aunque no salga de la primera '
        'posición', () async {
      final r = await guardarAvisoVerificado(
        guardar: () async => throw TimeoutException('tarde'),
        listar: () async =>
            [aviso(9, 'Otro'), aviso(3, 'Editado')],
        idsPrevios: const {3, 9},
        idEditado: 3,
        titulo: 'Editado',
        cuerpo: 'Cuerpo',
        nivel: 'info',
      );
      expect(r, ResultadoGuardadoAviso.guardado);
    });

    test('no aterrizó → noGuardado (reintentar es seguro)',
        () async {
      final r = await guardarAvisoVerificado(
        guardar: () async => throw StateError('500'),
        listar: () async => [aviso(1, 'Viejo')],
        idsPrevios: const {1},
        idEditado: null,
        titulo: 'Nuevo',
        cuerpo: 'Cuerpo',
        nivel: 'info',
      );
      expect(r, ResultadoGuardadoAviso.noGuardado);
    });

    test('ni guardar ni comprobar → sinConfirmar', () async {
      final r = await guardarAvisoVerificado(
        guardar: () async => throw TimeoutException('t'),
        listar: () async => throw TimeoutException('t'),
        idsPrevios: const {},
        idEditado: null,
        titulo: 'Nuevo',
        cuerpo: 'Cuerpo',
        nivel: 'info',
      );
      expect(r, ResultadoGuardadoAviso.sinConfirmar);
    });
  });

  group('D-B3-05 · la pantalla de avisos', () {
    testWidgets('timeout con aterrizaje: el aviso aparece '
        'una vez y no se crea dos veces', (tester) async {
      final servidor = <AvisoCliente>[];
      var llamadasGuardar = 0;
      Future<void> guardarFalso(
          {int? id,
          required String titulo,
          required String cuerpo,
          required String nivel,
          // 1.29 O7: la costura gana fechaFin (FB-22); este
          // falso la ignora (sin fecha, como en la O6).
          String? fechaFin}) async {
        llamadasGuardar++;
        servidor.add(AvisoCliente(
            id: 99,
            titulo: titulo,
            cuerpo: cuerpo,
            nivel: nivel,
            creadoTs: '2026-11-07T10:00:00'));
        throw TimeoutException('la red llegó tarde');
      }

      Future<List<AvisoCliente>> listarFalso() async =>
          List.of(servidor);

      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          home: EditorAvisosClientesScreen(
              guardarAvisoRpc: guardarFalso,
              listarAvisosRpc: listarFalso)));
      await _pumps(tester, 16);
      expect(find.text('Sin avisos publicados'),
          findsOneWidget);

      await tester.tap(find.text('Nuevo aviso'));
      await _pumps(tester, 10);
      await tester.enterText(
          find.byType(TextField).first, 'Aviso de prueba');
      await tester.enterText(
          find.byType(TextField).at(1), 'Cuerpo de prueba');
      await tester.tap(find.text('Publicar aviso'));
      await _pumps(tester, 20);

      expect(llamadasGuardar, 1,
          reason: 'un solo guardado: nada de duplicados');
      expect(find.text('Aviso de prueba'), findsOneWidget,
          reason: 'la lista recargada lo muestra UNA vez');
    });
  });

  // ── D-B3-06 · copia a destino duradero ──────────────
  group('D-B3-06 · la copia manual sobrevive', () {
    test('dos exportaciones: dos archivos fechados en '
        'documentos/copias_manuales', () async {
      await _bdVacia();
      final carpeta =
          Directory(p.join(docsDir.path, 'copias_manuales'));
      if (await carpeta.exists()) {
        await carpeta.delete(recursive: true);
      }
      final f1 = await exportarCopiaFria();
      final f2 = await exportarCopiaFria();
      expect(p.basename(f1.path), matches(r'^ironbody-\d{8}-\d{6}\.db$'));
      expect(p.basename(f2.path),
          matches(r'^ironbody-\d{8}-\d{6}(-\d+)?\.db$'),
          reason: 'la segunda del mismo segundo no pisa '
              'a la primera: sufijo -2');
      expect(p.basename(p.dirname(f1.path)), 'copias_manuales');
      expect(p.basename(p.dirname(f2.path)), 'copias_manuales');
      expect(await f1.exists(), isTrue,
          reason: 'la copia anterior NO se borra al '
              'exportar la siguiente');
      expect(await f2.exists(), isTrue);
      final archivos = await carpeta
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      expect(archivos.length, 2);
    });
  });

  // ── D-B3-08 · CSV sin fórmulas ──────────────────────
  group('D-B3-08 · csvDeExportacion', () {
    test('los prefijos de fórmula se neutralizan', () {
      final csv = csvDeExportacion(
        ['Nombre', 'Nota'],
        [
          ['=2+5', 'bien'],
          ['+SUMA(A1:A2)', 'bien'],
          ['-2+3', 'bien'],
          ['@import', 'bien'],
          ['Normal', 'con\retorno'],
        ],
      );
      expect(csv, contains("'=2+5"));
      expect(csv, contains("'+SUMA(A1:A2)"));
      expect(csv, contains("'-2+3"));
      expect(csv, contains("'@import"));
      expect(csv, contains('"con\retorno"'),
          reason: 'el retorno de carro también obliga '
              'a entrecomillar (CSV injection clásico)');
      expect(csv, contains('Normal'));
      // La celda inocente no se toca.
      expect(csv.contains("'Normal"), isFalse);
    });
  });

  // ── FB-19 · WhatsApp al resolver un vale ────────────
  group('FB-19 · mensajes del vale (puros)', () {
    test('aprobado: nombre, premio y NUEVO vencimiento',
        () {
      final m = mensajeWaValeAprobado(
        nombre: 'Ana Pérez',
        premioDias: 15,
        nuevoHastaIso: '2026-12-05',
      );
      expect(m, contains('Ana Pérez'));
      expect(m, contains('15 días'));
      expect(m, contains(fmtFecha('2026-12-05')),
          reason: 'el mensaje lleva el nuevo vencimiento '
              'formateado, no la fecha cruda');
      expect(m, contains('58191577'),
          reason: 'lleva la línea de mensaje automático');
    });

    test('rechazado: nombre y el MOTIVO escrito', () {
      final m = mensajeWaValeRechazado(
        nombre: 'Luis',
        motivo: 'Faltan pruebas del logro',
      );
      expect(m, contains('Luis'));
      expect(m, contains('Faltan pruebas del logro'));
      expect(m, contains('58191577'));
    });
  });

  group('FB-19 · la bandeja ofrece el WhatsApp', () {
    Map<String, dynamic> bandeja() => {
          'ok': true,
          'meta': 15,
          'vales': [
            {
              'id': 7,
              'cliente_id': 5,
              'nombre': 'Ana Vale',
              'telefono': '52893421',
              'tipo_logro': 'constancia',
              'premio_dias': 15,
              'pagado_hasta': '2026-11-20',
              'creado_en': '2026-11-06T10:00:00',
            }
          ],
          'recientes': <dynamic>[],
        };

    testWidgets('aprobar → «Avisar por WhatsApp» con el '
        'nuevo vencimiento en la URL', (tester) async {
      String? urlAbierta;
      var aprobadoLlamado = false;
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: PremiosPanelScreen(
          cargarBandeja: () async => bandeja(),
          aprobarVale: (vale) async {
            aprobadoLlamado = true;
          },
          abrirWhatsApp: (url) async => urlAbierta = url,
        ),
      ));
      await _pumps(tester, 20);
      await tester.tap(find.text('Aprobar premio'));
      await _pumps(tester, 10);
      // El diálogo de confirmación (el segundo «Aprobar
      // premio» es el suyo).
      await tester.tap(find.text('Aprobar premio').last);
      await _pumps(tester, 16);
      expect(aprobadoLlamado, isTrue,
          reason: 'la aprobación pasó por la costura');
      expect(find.text('Avisar por WhatsApp'), findsOneWidget,
          reason: 'el snack de éxito ofrece avisar por '
              'WhatsApp al número del vale');
      await tester.tap(find.text('Avisar por WhatsApp'));
      await _pumps(tester, 4);
      expect(urlAbierta, isNotNull);
      final texto =
          Uri.parse(urlAbierta!).queryParameters['text'] ?? '';
      // El nuevo vencimiento = pagado_hasta del vale
      // (2026-11-20) + 15 días de premio = 2026-12-05,
      // calculado por la propia pantalla.
      expect(texto, contains(fmtFecha('2026-12-05')));
      expect(urlAbierta, contains('5352893421'),
          reason: 'wa.me con el prefijo 53 del número '
              'de 8 dígitos del vale');
      await _drenarBanner(tester);
    });

    testWidgets('rechazar → «Avisar por WhatsApp» con el '
        'motivo en la URL', (tester) async {
      String? urlAbierta;
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: PremiosPanelScreen(
          cargarBandeja: () async => bandeja(),
          rechazarVale: (vale, nota) async => {'ok': true},
          abrirWhatsApp: (url) async => urlAbierta = url,
        ),
      ));
      await _pumps(tester, 20);
      await tester.tap(find.text('Rechazar'));
      await _pumps(tester, 10);
      await tester.enterText(find.byType(TextField),
          'Faltan pruebas del logro');
      // «Rechazar vale» aparece dos veces: el título del
      // diálogo y su botón de confirmación (el último).
      await tester.tap(find.text('Rechazar vale').last);
      await _pumps(tester, 16);
      expect(find.text('Avisar por WhatsApp'), findsOneWidget);
      await tester.tap(find.text('Avisar por WhatsApp'));
      await _pumps(tester, 4);
      final texto =
          Uri.parse(urlAbierta!).queryParameters['text'] ?? '';
      expect(texto, contains('Faltan pruebas del logro'));
      await _drenarBanner(tester);
    });
  });

  // ── FB-20 · Comunidad → ficha ───────────────────────
  group('FB-20 · de la tarjeta a la ficha', () {
    testWidgets('tocar la tarjeta abre la ficha del '
        'cliente; «Ocultar» no navega', (tester) async {
      int? fichaAbierta;
      final ocultados = <int>[];
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: ComunidadPanelScreen(
          cargarPerfiles: () async => {
            'ok': true,
            'perfiles': [
              {
                'cliente_id': 5,
                'nombre': 'Ana',
                'visible': true,
                'oculto_admin': false,
                'mostrar_marcas': true,
                'mostrar_actividad': false,
                'mostrar_rutina': true,
                'mostrar_constancia': true,
              },
            ],
          },
          cargarReportes: () async =>
              {'ok': true, 'reportes': <dynamic>[]},
          cargarHistorial: () async =>
              {'ok': true, 'historial': <dynamic>[]},
          ocultarPerfil: (id, ocultar) async {
            ocultados.add(id);
            return {'ok': true};
          },
          abrirFicha: (id) => fichaAbierta = id,
        ),
      ));
      await _pumps(tester, 20);
      await tester.tap(find.text('Ocultar'));
      await _pumps(tester, 8);
      expect(ocultados, [5]);
      expect(fichaAbierta, isNull,
          reason: 'los botones de la tarjeta no disparan '
              'la navegación');
      await tester.tap(find.text('Ana'));
      await _pumps(tester, 8);
      expect(fichaAbierta, 5);
    });
  });

  // ── D-16 · Salud del sync ───────────────────────────
  group('D-16 · estadoSaludSync (puro)', () {
    test('los tres estados, con el fallo mandando', () {
      expect(
          estadoSaludSync(
              pendientes: 0, fallidas: 0, hayTablasEnRojo: false),
          EstadoSaludSync.todoSubio);
      expect(
          estadoSaludSync(
              pendientes: 3, fallidas: 0, hayTablasEnRojo: false),
          EstadoSaludSync.quedanCambios);
      expect(
          estadoSaludSync(
              pendientes: 0, fallidas: 1, hayTablasEnRojo: false),
          EstadoSaludSync.fallo);
      expect(
          estadoSaludSync(
              pendientes: 3, fallidas: 0, hayTablasEnRojo: true),
          EstadoSaludSync.fallo,
          reason: 'una tabla en rojo es fallo aunque la '
              'cola esté «solo pendiente»');
      expect(
          estadoSaludSync(
              pendientes: 2, fallidas: 1, hayTablasEnRojo: false),
          EstadoSaludSync.fallo);
    });
  });

  group('D-16 · la pantalla de Salud', () {
    testWidgets('sin pendientes ni fallos: «Todo subió»',
        (tester) async {
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(
          const MaterialApp(home: SaludSyncScreen()));
      await _pumps(tester, 24);
      expect(
          find.text('Todo subió: este teléfono está al día.'),
          findsOneWidget);
    });

    testWidgets('con pendientes: «Quedan cambios por '
        'subir» con el conteo', (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await _insertarOp(db, uuid: 'salud-1', tipo: 'pago_diario');
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(
          const MaterialApp(home: SaludSyncScreen()));
      await _pumps(tester, 24);
      expect(
          find.text('Quedan cambios por subir: 1 operación '
              'en la cola de este teléfono.'),
          findsOneWidget);
    });

    testWidgets('con una op fallida: «Falló la '
        'sincronización»', (tester) async {
      late Database db;
      await tester.runAsync(() async {
        db = await _bdVacia();
        await _insertarOp(db,
            uuid: 'salud-err',
            tipo: 'pago_diario',
            estado: 'error');
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(
          const MaterialApp(home: SaludSyncScreen()));
      await _pumps(tester, 24);
      expect(find.textContaining('Falló la sincronización'),
          findsOneWidget);
    });
  });
}
