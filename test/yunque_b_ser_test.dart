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
      'YB-SER-01: sin permiso, la venta rápida no abre ni el diálogo',
      (tester) async {
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
    await tester.runAsync(() async {
      resultado = await ventaRapidaSuplemento(ctx!, {
        'id': 1,
        'nombre': 'Proteína X',
        'stock': 5,
        'precio': 100,
      });
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
    // Sin diálogo de confirmación y con el aviso de permiso.
    expect(find.byType(Dialog), findsNothing);
    expect(
        find.textContaining('permiso para vender suplementos'),
        findsOneWidget);
    await tester.runAsync(() async {
      final db = await LocalDb.instance.db;
      final filas = await db.query('ops_queue');
      expect(filas, isEmpty,
          reason: 'sin permiso de vender no se encola la op compuesta');
    });
  });
}
