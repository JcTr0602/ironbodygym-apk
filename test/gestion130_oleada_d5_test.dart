/// Gestión 1.30 · Oleada D5 — Servicios Admin por grupos
/// (UI130-17), TarjetaSuplemento (UI130-18) y TarjetaDecision
/// compartida (UI130-19).
///
/// Contrato que se fija:
/// - 17: el guardado POR GRUPO encola exactamente las mismas
///   claves que habría encolado el guardado único anterior
///   para ese mismo cambio (la del método + la legacy que
///   sigue al efectivo), y ninguna de otro grupo; el estado
///   del grupo pasa por «Cambios sin guardar» y «Guardado ·
///   hh:mm». La comisión es un grupo propio.
/// - 18: un componente, dos densidades; la rejilla dimensiona
///   la celda por contenido (altoCeldaCatalogo) y a escala de
///   texto 2 no recorta; el stock va como ChipEstado con
///   palabra; sin foto propia se enseña la genérica de su
///   clase MARCADA «Foto genérica»; en la fila, el cuerpo
///   abre el detalle y «Vender» abre la venta (zonas).
/// - 19: TarjetaDecision es la anatomía de las dos tarjetas
///   de decisión (goldens de sus dos variantes); la lista
///   operativa carga con esqueleto, vacía con EstadoVacio y
///   su buscador es el CampoTexto del kit.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/modelos/incidencia.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/detalle_suplemento.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/incidencias/lista_incidencias.dart';
import 'package:ironbody_gym/ui/incidencias/widgets/tarjeta_incidencia.dart';
import 'package:ironbody_gym/ui/servicios_admin.dart';
import 'package:ironbody_gym/ui/skeleton.dart';
import 'package:ironbody_gym/ui/suplementos.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ---------------------------------------------------------------------------
// Arnés (patrón FB-09 / banco v2: FFI sin isolate + runAsync)
// ---------------------------------------------------------------------------

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
  await LocalDb.instance.db;
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

/// El push que dispara el guardado deja un ciclo de sync
/// entrelazado (red real en runAsync, esperas en la zona
/// falsa): se drena hasta que muere, como en FB-09.
Future<void> _drenarSync(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 1));
  }
}

Future<List<Map<String, dynamic>>> _opsAjuste(WidgetTester tester) async {
  return (await tester.runAsync(() async {
    final db = await LocalDb.instance.db;
    return db.query('ops_queue', where: 'tipo = ?', whereArgs: ['ajuste']);
  }))!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // app_links (deep links de Supabase Auth): sin mock, la
    // activación de su canal de eventos lanza
    // MissingPluginException de forma intermitente.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
            const EventChannel('com.llfbandit.app_links/events'),
            MockStreamHandler.inline(onListen: (args, events) {}));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.llfbandit.app_links/messages'),
            (call) async => null);
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('D5 · UI130-17 guardado por grupo', () {
    Future<void> preparar(WidgetTester tester) async {
      // Ventana alta: todos los grupos de precios construidos
      // sin desplazar la lista.
      tester.view.physicalSize = const Size(900, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.setAjustes({
          'servicio_precio_sin_agua': 600,
          'servicio_precio_con_agua': 900,
          'servicio_precio_agua': 300,
          'servicio_comision_dosis': 50,
        });
        await _fijarSesion(
            email: 'jctr0602@ironbody.gym', telegramId: 735772141);
      });
      await tester.pumpWidget(
          const MaterialApp(home: ServiciosAdminScreen()));
      expect(
          await _esperarTexto(tester, 'Ración (dosis sin agua)'), isTrue);
      await _ciclos(tester);
    }

    testWidgets(
        'editar solo la ración encola solo sus claves '
        '(equivalencia con el guardado único)', (tester) async {
      await preparar(tester);
      // Sin tocar nada, ningún grupo acusa cambios.
      expect(find.text('Cambios sin guardar'), findsNothing);

      // El primer campo de moneda es el efectivo de la ración.
      await tester.enterText(find.byType(TextFormField).first, '700');
      await _ciclos(tester, 4);
      expect(find.text('Cambios sin guardar'), findsOneWidget);

      // Guardar ESE grupo (su botón es el primero).
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar').first);
      expect(await _esperarTexto(tester, 'Guardado ·'), isTrue);
      await _ciclos(tester);
      expect(find.text('Cambios sin guardar'), findsNothing);

      // Exactamente las claves que el guardado único habría
      // encolado por este cambio: la del método y la legacy.
      final ops = await _opsAjuste(tester);
      expect(ops.length, 2);
      final porClave = <String, num>{};
      for (final o in ops) {
        final payload =
            jsonDecode(o['payload'] as String) as Map<String, dynamic>;
        porClave['${payload['clave']}'] =
            (payload['valor'] as num?) ?? -1;
      }
      expect(porClave, {
        'servicio_precio_racion_efectivo': 700,
        'servicio_precio_sin_agua': 700,
      });
      await _drenarSync(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('la comisión guarda sola su clave', (tester) async {
      await preparar(tester);
      // El último campo de moneda es la comisión; su Guardar,
      // el último de los cuatro.
      await tester.enterText(find.byType(TextFormField).last, '80');
      await _ciclos(tester, 4);
      expect(find.text('Cambios sin guardar'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Guardar').last);
      expect(await _esperarTexto(tester, 'Guardado ·'), isTrue);
      final ops = await _opsAjuste(tester);
      expect(ops.length, 1);
      final payload =
          jsonDecode(ops.single['payload'] as String) as Map<String, dynamic>;
      expect(payload['clave'], 'servicio_comision_dosis');
      expect(payload['valor'], 80);
      await _drenarSync(tester);
      expect(tester.takeException(), isNull);
    });
  });

  group('D5 · UI130-18 catálogo', () {
    test('la foto genérica sale del nombre y la categoría', () {
      expect(assetFotoGenericaSuplemento('Creatina monohidrato'),
          'assets/sup_generica_creatina.jpg');
      expect(assetFotoGenericaSuplemento('CREATINA en polvo'),
          'assets/sup_generica_creatina.jpg');
      expect(assetFotoGenericaSuplemento('Pre-entreno Psychotic'),
          'assets/sup_generica_preentreno.jpg');
      expect(assetFotoGenericaSuplemento('Preentreno X'),
          'assets/sup_generica_preentreno.jpg');
      expect(assetFotoGenericaSuplemento('Shaker 700 ml'),
          'assets/sup_generica_shaker.jpg');
      expect(assetFotoGenericaSuplemento('Vaso mezclador'),
          'assets/sup_generica_shaker.jpg');
      expect(assetFotoGenericaSuplemento('Barrita de proteína'),
          'assets/sup_generica_barritas.jpg');
      expect(assetFotoGenericaSuplemento('Botella deportiva 1L'),
          'assets/sup_generica_botella.jpg');
      expect(assetFotoGenericaSuplemento('Batido listo',
              categoria: 'Bebidas'),
          'assets/sup_generica_botella.jpg');
      expect(assetFotoGenericaSuplemento('Whey Protein Gold'),
          'assets/sup_generica_proteina.jpg');
      expect(assetFotoGenericaSuplemento('Cosa desconocida'),
          'assets/sup_generica_proteina.jpg');
    });

    test('sin foto propia: el predicado y los 6 activos', () {
      expect(supSinFotoPropia({'nombre': 'X'}), isTrue);
      expect(supSinFotoPropia({'foto_local': '', 'foto_storage': null}),
          isTrue);
      expect(supSinFotoPropia({'foto_local': '/tmp/x.jpg'}), isFalse);
      expect(supSinFotoPropia({'foto_storage': 'a.webp'}), isFalse);
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final n in [
        'proteina',
        'creatina',
        'preentreno',
        'shaker',
        'barritas',
        'botella',
      ]) {
        expect(File('assets/sup_generica_$n.jpg').existsSync(), isTrue,
            reason: 'falta el activo de $n');
        expect(pubspec.contains('assets/sup_generica_$n.jpg'), isTrue,
            reason: '$n no está declarado en pubspec');
      }
    });

    test('altoCeldaCatalogo crece con la escala de texto', () {
      final a1 = altoCeldaCatalogo(400, const TextScaler.linear(1));
      final a2 = altoCeldaCatalogo(400, const TextScaler.linear(2));
      expect(a2, greaterThan(a1));
      // A escala 1, el alto queda cerca del que daba el ratio
      // histórico 0,52 sobre la misma celda.
      final celda = (400 - AppEspacio.md * 2 - 12) / 2;
      expect(a1, closeTo(celda / 0.52, 40));
    });

    testWidgets(
        'rejilla a escala 2: sin recortes, chip con palabra '
        'y foto genérica marcada', (tester) async {
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.upsertMirror('suplementos', 1, {
          'id': 1,
          'nombre': 'Proteína Banco',
          'stock': 2,
          'precio_oficial': 5000,
          'activo': 1,
          'moneda': 'CUP',
          'peso_valor': 300,
          'peso_unidad': 'g',
          'servicios_estandar': 60,
        }, 1);
        await LocalDb.instance.upsertMirror('suplementos', 2, {
          'id': 2,
          'nombre': 'Creatina Banco',
          'stock': 10,
          'precio_oficial': 3500,
          'activo': 1,
          'moneda': 'CUP',
        }, 2);
      });
      await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SuplementosScreen(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: 'la celda dimensionada por contenido no recorta');
      expect(find.text('2 suplementos'), findsOneWidget);
      expect(find.text('Vender'), findsWidgets);
      expect(find.text('Stock bajo · 2'), findsWidgets);
      expect(find.byType(ChipEstado), findsWidgets);
      // Ninguno de los dos tiene foto propia: la genérica va
      // marcada como tal.
      expect(find.text('Foto genérica'), findsWidgets);
    });

    testWidgets(
        'fila: el cuerpo abre el detalle y «Vender» abre '
        'la venta (zonas separadas)', (tester) async {
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.upsertMirror('suplementos', 2, {
          'id': 2,
          'nombre': 'Creatina Banco',
          'stock': 5,
          'precio_oficial': 3500,
          'activo': 1,
          'moneda': 'CUP',
        }, 2);
      });
      await tester.pumpWidget(
          const MaterialApp(home: SuplementosScreen()));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.view_list_rounded));
      await tester.pumpAndSettle();
      expect(find.text('Foto genérica'), findsOneWidget);

      // La zona de la acción abre la venta rápida (el diálogo
      // de ventaRapidaSuplemento), no el detalle.
      await tester.tap(find.widgetWithText(BotonPrimario, 'Vender'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(DetalleSuplementoScreen), findsNothing);
      // Cierre §17 (×30): la aserción «ListTile background
      // color» que este diálogo arrastraba (el CheckboxListTile
      // de la advertencia sin promo dentro de su caja tintada)
      // quedó corregida en el sitio (Material transparente
      // propio). El test ya no la drena: afirma que NO salta.
      expect(tester.takeException(), isNull);
      // Cerrar el diálogo tocando la barrera.
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);

      // La zona del cuerpo abre el detalle.
      await tester.tap(find.text('Creatina Banco'));
      await tester.pumpAndSettle();
      expect(find.byType(DetalleSuplementoScreen), findsOneWidget);
    });
  });

  group('D5 · UI130-19 TarjetaDecision', () {
    Widget envolver(Widget hijo) => MaterialApp(
          theme: AppTema.claro(),
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 400, child: hijo),
            ),
          ),
        );

    testWidgets('golden: la variante operativa', (tester) async {
      await tester.pumpWidget(envolver(TarjetaDecision(
        icono: Icons.report_rounded,
        colorIcono: AppColores.alerta,
        titulo: 'La caminadora 2 hace ruido al correr',
        subtitulo: 'Equipos · 📍 Sala de cardio',
        chipEstado: ChipEstado.semantico(
            texto: 'Pendiente', significado: SignificadoChip.alerta),
        contexto: 'Lleva 2 días',
        iconoContexto: Icons.schedule_rounded,
        contextoSecundario: '👤 Duany',
        iconoContextoSecundario: Icons.person_rounded,
        prioridadTexto: 'Alta',
        colorPrioridad: AppColores.error,
      )));
      await expectLater(find.byType(TarjetaDecision),
          matchesGoldenFile('goldens/d5_tarjeta_decision_operativa.png'));
    });

    testWidgets('golden: la variante de sincronización', (tester) async {
      await tester.pumpWidget(envolver(TarjetaDecision(
        icono: Icons.sync_problem_rounded,
        colorIcono: AppColores.alerta,
        titulo: 'Pago mensual',
        chipEstado: ChipEstado.semantico(
            texto: 'Pendiente', significado: SignificadoChip.alerta),
        contexto: 'Galaxy S23 · 2026-11-08 09:41',
        motivo: 'Motivo: el pago ya existe en el servidor',
        resumen: 'Cliente: Ana Pérez · Monto: 2000 CUP',
        pie: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.close_rounded, size: 18),
              label: const Text('Descartar'),
              onPressed: () {},
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('Aprobar'),
              onPressed: () {},
            ),
          ],
        ),
      )));
      expect(find.text('Descartar'), findsOneWidget);
      expect(find.text('Aprobar'), findsOneWidget);
      expect(find.textContaining('Motivo:'), findsOneWidget);
      await expectLater(find.byType(TarjetaDecision),
          matchesGoldenFile('goldens/d5_tarjeta_decision_sync.png'));
    });

    testWidgets(
        'TarjetaIncidencia adopta la anatomía compartida',
        (tester) async {
      final inc = Incidencia(
        id: 'i1',
        descripcion: 'Foco fundido en el baño',
        estado: 'pendiente',
        prioridad: 'alta',
        asignadoA: 'entrenador:duany:Duany',
        ubicacion: 'Baño',
        creadaPor: 'duany',
        creadaEn: DateTime.now().subtract(const Duration(days: 2)),
      );
      await tester.pumpWidget(MaterialApp(
        theme: AppTema.claro(),
        home: Scaffold(
          body: TarjetaIncidencia(
            incidencia: inc,
            tipo: null,
            onTap: () {},
          ),
        ),
      ));
      expect(find.byType(TarjetaDecision), findsOneWidget);
      expect(find.text('Foco fundido en el baño'), findsOneWidget);
      expect(find.text('Pendiente'), findsOneWidget);
      expect(find.text('Alta'), findsOneWidget);
      expect(find.textContaining('Lleva'), findsOneWidget);
      expect(find.textContaining('Duany'), findsWidgets);
    });

    testWidgets(
        'la lista operativa: esqueleto al cargar, EstadoVacio '
        'sin datos y buscador del kit', (tester) async {
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await tester.pumpWidget(
          const MaterialApp(home: ListaIncidenciasScreen()));
      // El primer frame aún carga: esqueleto de filas.
      expect(find.byType(SkeletonLista), findsOneWidget);
      expect(await _esperarTexto(tester, 'Sin incidencias'), isTrue);
      expect(find.byType(EstadoVacio), findsOneWidget);
      expect(find.byType(CampoTexto), findsOneWidget);
    });

    testWidgets('la lista operativa con datos enseña la tarjeta',
        (tester) async {
      await tester.runAsync(() async {
        await _bdVacia();
        final d = await LocalDb.instance.db;
        await d.insert('incidencias_local', {
          'id': 'inc-1',
          'tipo': 'equipo',
          'tipo_id': null,
          'descripcion': 'La caminadora 2 hace ruido',
          'detalle': null,
          'estado': 'pendiente',
          'asignado_a': 'entrenador:duany:Duany',
          'prioridad': 'alta',
          'fecha_limite': null,
          'ubicacion': 'Sala de cardio',
          'creada_por': 'duany',
          'creada_en': DateTime.now()
              .subtract(const Duration(days: 2))
              .toIso8601String(),
          'resuelta_por': null,
          'resuelta_en': null,
          'nota_resolucion': null,
          'version': 1,
          'sync_estado': 'synced',
          'actualizado_en': null,
        });
      });
      await tester.pumpWidget(
          const MaterialApp(home: ListaIncidenciasScreen()));
      expect(
          await _esperarTexto(tester, 'La caminadora 2 hace ruido'),
          isTrue);
      expect(find.byType(TarjetaIncidencia), findsOneWidget);
      expect(find.byType(TarjetaDecision), findsOneWidget);
      expect(find.text('Pendiente'), findsWidgets);
    });
  });
}
