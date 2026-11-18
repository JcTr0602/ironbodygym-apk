/// Yunque B · YB-SER-01 (Gestión 1.31): sin
/// `can_vender_suplementos`, la venta rápida de suplementos
/// se niega ANTES de abrir el diálogo de venta — nada de
/// «Venta registrada» en pantalla con la op rebotada en el
/// servidor. Sin sesión, la foto de permisos cierra en
/// falso (fail-closed, como en permisos_115b_test).
///
/// Nota de arnés: testWidgets corre en zona FakeAsync y el
/// refresco de permisos hace E/S real — la llamada bajo
/// prueba va dentro de tester.runAsync.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/ui/detalle_suplemento.dart';
import 'package:ironbody_gym/ui/permisos_ui.dart';
import 'package:ironbody_gym/ui/venta_suplemento_inscripcion.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('YB-SER-01: sin sesión, vender cierra en falso (fail-closed)',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    await PermisosEntrenador().cargar();
    expect(PermisosEntrenador().canVenderSuplementos, isFalse);
  });

  testWidgets(
      'YB-SER-01: sin permiso, la venta rápida no abre el diálogo '
      'de venta y cierra en falso', (tester) async {
    SharedPreferences.setMockInitialValues({});
    BuildContext? ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ),
    ));
    bool? resultado;
    // CONTRATO MOVIDO (1.36, cierre de Aplica-136): la fila
    // 136-868 (H-B4, commit fc9e485) cambió el aviso de «sin
    // conexión» al comprobar permisos — snack corto + detalle
    // en DIÁLOGO («Permisos sin comprobar») que la función
    // ESPERA antes de devolver false. La versión anterior de
    // este test aguardaba la llamada en runAsync sin nadie que
    // aceptara ese diálogo y COLGABA la suite (verificado en el
    // cierre: la base 0bba410 pasa este archivo en 5 s; el tip
    // se quedaba en este test). La vigilancia YB-SER-01 se
    // conserva: sin permiso la venta NO se abre — el único
    // diálogo que aparece es el aviso de permisos — y la
    // función cierra en falso al aceptarlo.
    // Patrón de la casa (gestion125_b2): la espera real vive
    // DENTRO de runAsync; bombear en bucle desde el test
    // estrangula la E/S real de la zona asíncrona.
    await tester.runAsync(() async {
      ventaRapidaSuplemento(ctx!, {
        'id': 1,
        'nombre': 'Proteína X',
        'stock': 5,
        'precio': 100,
      }).then((v) => resultado = v);
      // Tiempo real para que el refresco contra el puerto
      // cerrado falle y el aviso de permisos se monte.
      await Future<void>.delayed(const Duration(seconds: 5));
    });
    await tester.pump();
    expect(find.text('Permisos sin comprobar'), findsOneWidget);
    await tester.tap(find.text('Entendido'));
    await tester.pump();
    // Latido real para que la llamada cierre tras el pop.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
    });
    expect(resultado, isFalse);
    await tester.pump();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('YB-SER-01: el helper deja pasar con permiso verdadero',
      (tester) async {
    BuildContext? ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      ),
    ));
    expect(
        await permisoOperativoOkConRefresco(ctx!, () => true, 'vender'),
        isTrue);
  });

  // Pieza añadida de la oleada (hermana de YB-SER-01): el
  // flujo de inscripción + venta exige TAMBIÉN
  // can_vender_suplementos (el servidor pide inscribir Y
  // vender para la op compuesta): sin él, la pantalla se
  // niega antes del diálogo de confirmación y no encola
  // nada.
  testWidgets(
      'YB-SER-01 hermana: inscripción+venta sin permiso de '
      'vender no llega al diálogo ni encola la op',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.runAsync(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
    });
    await tester.pumpWidget(const MaterialApp(
      home: VentaSuplementoInscripcionScreen(
        suplemento: {
          'id': 5,
          'nombre': 'Proteína X',
          'stock': 10,
          'precio': 100,
        },
        cantidad: 1,
        precio: 100,
        moneda: 'CUP',
        precioOficial: 100,
      ),
    ));
    await tester.pump();
    await tester.enterText(find.byType(TextField).first, 'Cliente Nuevo');
    await tester.runAsync(() async {
      await tester
          .tap(find.text('Confirmar inscripción + venta'));
      // La guarda hace E/S real (refresco de permisos).
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    // CONTRATO MOVIDO (1.36, cierre de Aplica-136): por la fila
    // 136-868 el aviso sin conexión al comprobar permisos es un
    // DIÁLOGO («Permisos sin comprobar») que la guarda espera;
    // antes era solo un snack y este test fijaba «sin diálogo».
    // La vigilancia se conserva: el diálogo presente es el
    // AVISO de permisos (no una confirmación de venta), nombra
    // el permiso de vender suplementos y, al aceptarlo, la
    // guarda deniega y la op compuesta NO se encola (abajo).
    expect(find.text('Permisos sin comprobar'), findsOneWidget);
    expect(
        find.textContaining('permiso para vender suplementos'),
        findsOneWidget);
    await tester.tap(find.text('Entendido'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Dialog), findsNothing);
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      final filas = await db.query('ops_queue');
      expect(filas, isEmpty,
          reason: 'sin permiso de vender no se encola la op compuesta');
    });
  });
}
