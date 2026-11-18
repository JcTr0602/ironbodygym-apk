/// H-C1 (1.36): base, tema, home, primitivas y gráficos —
/// 136-327, 136-328, 136-331, 136-351, 136-357, 136-400.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md
/// (filas PARCIALES: solo la parte confirmada).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ironbody_gym/main.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/theme.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/grafico_peso.dart';
import 'package:ironbody_gym/ui/pestana_progreso.dart';
import 'package:ironbody_gym/ui/primitivas.dart';

Widget _envolver(Widget w) => MaterialApp(
      theme: AppTema.sol(),
      home: Scaffold(body: w),
    );

Medicion _med(double? peso, DateTime f) => Medicion(
      id: 1,
      clienteId: '1',
      pesoKg: peso,
      registradoPor: 'x',
      createdAt: f,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('136-331 · la referencia manda el push; sin push, la op más vieja',
      () {
    final push = DateTime.utc(2026, 11, 10);
    final vieja = DateTime.utc(2026, 11, 1);
    expect(
        referenciaAntiguedadPendientes(
            ultimaPush: push, opMasVieja: vieja),
        push);
    expect(
        referenciaAntiguedadPendientes(
            ultimaPush: null, opMasVieja: vieja),
        vieja);
    expect(referenciaAntiguedadPendientes(), isNull);
  });

  test('136-328 · ciclo() avanza desde el tema VISIBLE (mode)', () async {
    SharedPreferences.setMockInitialValues({});
    ThemeController.mode.value = ThemeMode.dark;
    await ThemeController.ciclo();
    // Visible oscuro → sistema (aunque no hubiera nada guardado).
    expect(ThemeController.mode.value, ThemeMode.system);
    ThemeController.mode.value = ThemeMode.light;
    await ThemeController.ciclo();
    expect(ThemeController.mode.value, ThemeMode.dark);
    ThemeController.mode.value = ThemeMode.system;
  });

  testWidgets('136-327 · la pantalla de error de arranque reintenta',
      (t) async {
    var intentos = 0;
    await t.pumpWidget(PantallaErrorArranque(
      detalle: 'boom inicial',
      alReintentar: () async {
        intentos++;
        if (intentos == 1) throw 'boom de nuevo';
      },
    ));
    expect(find.text('La app no pudo arrancar'), findsOneWidget);
    expect(find.text('boom inicial'), findsOneWidget);
    await t.tap(find.text('Reintentar'));
    await t.pumpAndSettle();
    // El primer reintento falla y el detalle se actualiza.
    expect(find.text('boom de nuevo'), findsOneWidget);
    await t.tap(find.text('Reintentar'));
    await t.pumpAndSettle();
    expect(intentos, 2);
  });

  testWidgets('136-351 · cada tecla del pad mide 48 dp de alto', (t) async {
    await t.pumpWidget(_envolver(PadNumerico(
      valor: '',
      onCambia: (_) {},
    )));
    // 4 filas × 48 dp.
    expect(t.getSize(find.byType(PadNumerico)).height, 192);
  });

  testWidgets(
      '136-357 · al deshabilitar, el progreso del deslizar vuelve a 0',
      (t) async {
    Widget deslizar(bool hab) => _envolver(DeslizarConfirmar(
          texto: 'Desliza',
          habilitado: hab,
          onConfirmar: () {},
        ));
    await t.pumpWidget(deslizar(true));
    final pulgar = find.byKey(const ValueKey('deslizar-pulgar'));
    final x0 = t.getTopLeft(pulgar).dx;
    // Arrastre parcial.
    await t.drag(pulgar, const Offset(60, 0));
    await t.pump();
    expect(t.getTopLeft(pulgar).dx, greaterThan(x0));
    // Se deshabilita a media carrera: el pulgar vuelve.
    await t.pumpWidget(deslizar(false));
    await t.pump();
    expect(t.getTopLeft(pulgar).dx, x0);
  });

  test('136-400 · los dos filtros de serie comparten isFinite y fecha',
      () {
    final futura = DateTime.now().add(const Duration(days: 30));
    final buena = DateTime(2026, 11, 1);
    final meds = [
      _med(80, buena),
      _med(double.infinity, buena),
      _med(90, futura),
      _med(70, DateTime(1970)),
    ];
    expect(puntosPesoValidos(meds).length, 1);
    expect(
        serieMetricaOpcional(meds, (m) => m.pesoKg).length, 1);
    expect(fechaPuntoSerieValida(buena, DateTime(2026, 11, 18)), isTrue);
    expect(fechaPuntoSerieValida(futura, DateTime(2026, 11, 18)), isFalse);
  });
}
