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
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/ui/detalle_suplemento.dart';
import 'package:ironbody_gym/ui/permisos_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
}
