/// 1.36 · Botón «Mes de cortesía» de la ficha (pedido de Jc,
/// 2026-11-18). La mitad de servidor (op `regalar_mes`) ya
/// está en vivo; aquí se prueba la mitad de la app:
///
/// - la acción vive en el Panel del dueño y SOLO la ve el
///   dueño (un entrenador no tiene panel: ni rastro);
/// - no aparece en Cuenta a la Casa ni en eliminados (el
///   servidor también los rechaza, pero la ficha ni ofrece);
/// - la confirmación enseña la FECHA RESULTANTE calculada
///   con la regla del servidor — max(vigencia, hoy) + 30
///   días — en cliente vigente (apila sobre su fecha) y en
///   cliente vencido (cuenta desde hoy);
/// - al confirmar se encola la op `regalar_mes` con el
///   payload del contrato {cliente_id, fecha} y el espejo
///   refleja el nuevo pagado_hasta en el acto (offline).
///
/// Arnés: el de la Jornada (jornada_ayudas) con drenajes
/// acotados en vez de pumpAndSettle — la ficha deja latir
/// ciclos con Timer.periodic (sync/fotos) y pumpAndSettle
/// no asienta nunca sobre ella; es la pauta de
/// jornadaCerrarCascara y de las correcciones de campo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/ficha.dart';

import 'jornada_ayudas.dart';

String _sumarDias(String iso, int dias) => DateTime.parse(iso)
    .add(Duration(days: dias))
    .toIso8601String()
    .substring(0, 10);

const _meses = [
  '',
  'enero',
  'febrero',
  'marzo',
  'abril',
  'mayo',
  'junio',
  'julio',
  'agosto',
  'septiembre',
  'octubre',
  'noviembre',
  'diciembre',
];

/// «18 de diciembre de 2026» — la forma en que la
/// confirmación enseña la fecha resultante.
String _larga(String iso) {
  final d = DateTime.parse(iso);
  return '${d.day} de ${_meses[d.month]} de ${d.year}';
}

Future<void> _sembrarCliente(
  int id, {
  required String pagadoHasta,
  int cuentaCasa = 0,
  String estado = 'activo',
}) async {
  await LocalDb.instance.upsertMirror('clientes', id, {
    'id': id,
    'nombre': 'Cortesia Caso $id',
    'estado': estado,
    'pagado_hasta': pagadoHasta,
    'telefono': '58112233',
    'carnet': '900115',
    'sexo': 'M',
    if (cuentaCasa == 1) 'cuenta_casa': 1,
  }, 1);
}

/// Cierre de cada caso: deja vencer los temporizadores de
/// una sola vez que la ficha y el sync dejan nacidos en la
/// zona falsa (la pauta de jornadaCerrarCascara, en
/// pequeño); sin esto el primer caso que monta la ficha
/// muere en el desmontaje con «Timer is still pending».
Future<void> _cerrar(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(seconds: 65));
  }
}

Future<Map<String, dynamic>> _cliente(int id) async =>
    (await LocalDb.instance.allMirror('clientes'))
        .firstWhere((c) => c['id'] == id);

/// Deja correr las animaciones de entrada de las secciones
/// hasta el final: mientras una sección entra, su envoltura
/// lleva IgnorePointer y los toques la atraviesan (cazado en
/// el diagnóstico del carril: la fila se veía, el toque no
/// caía). pumpAndSettle no sirve aquí (la ficha no asienta
/// por sus ciclos con temporizador); drenaje largo acotado.
Future<void> _asentar(WidgetTester tester) =>
    jornadaDrenar(tester, vueltas: 24, ms: 100);

Future<void> _abrirFicha(WidgetTester tester, int id) async {
  jornadaViewport(tester);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(fontFamily: 'Roboto'),
    home: FichaScreen(clienteId: id),
  ));
  await _asentar(tester);
}

/// Va a la pestaña «App Clientes» (donde vive el Panel del
/// dueño) y deja la fila de cortesía a la vista y tocable.
Future<void> _irAlPanel(WidgetTester tester) async {
  await jornadaEsperar(tester, find.text('App Clientes'));
  await tester.tap(find.text('App Clientes'));
  await _asentar(tester);
  await tester.scrollUntilVisible(find.text('Mes de cortesía'), 120,
      scrollable: find.byType(Scrollable).first);
  // Como la fila de la Casa en la Jornada S17: nace al filo
  // inferior, bajo la barra de cobro — un arrastre más.
  await tester.drag(find.byType(Scrollable).first, const Offset(0, -200));
  await _asentar(tester);
}

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('1.36 · Mes de cortesía en la ficha', () {
    testWidgets(
        'dueño + vigente: la confirmación enseña la fecha '
        'apilada (vigencia + 30) y al confirmar la op se '
        'encola y el espejo refleja el nuevo vencimiento',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      final hoy = hoyHabanaIso();
      final vigencia = _sumarDias(hoy, 10);
      final esperado = _sumarDias(vigencia, 30);
      await _sembrarCliente(60, pagadoHasta: vigencia);
      await _abrirFicha(tester, 60);
      await _irAlPanel(tester);

      await tester.tap(find.text('Mes de cortesía'));
      // La confirmación enseña la fecha RESULTANTE antes
      // de confirmar: apila sobre la vigencia (no desde hoy).
      await jornadaEsperar(
          tester, find.textContaining('Quedará pagado hasta el'));
      expect(find.textContaining(_larga(esperado)), findsOneWidget);

      await tester.tap(find.text('Dar el mes'));
      await jornadaDrenar(tester, vueltas: 8);

      final ops = await jornadaOpsTodas('regalar_mes');
      expect(ops, hasLength(1));
      final p = jornadaPayloadDe(ops.single);
      expect(p['cliente_id'], 60);
      expect(p['fecha'], hoy);
      expect((await _cliente(60))['pagado_hasta'], esperado,
          reason: 'el espejo refleja el nuevo vencimiento '
              'en el acto, sin esperar al servidor');
      await _cerrar(tester);
    });

    testWidgets(
        'dueño + vencido: la confirmación cuenta desde hoy '
        '(hoy + 30) y la op se encola igual', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      final hoy = hoyHabanaIso();
      final vencido = _sumarDias(hoy, -5);
      final esperado = _sumarDias(hoy, 30);
      await _sembrarCliente(61, pagadoHasta: vencido);
      await _abrirFicha(tester, 61);
      await _irAlPanel(tester);

      await tester.tap(find.text('Mes de cortesía'));
      await jornadaEsperar(
          tester, find.textContaining('Quedará pagado hasta el'));
      expect(find.textContaining(_larga(esperado)), findsOneWidget);

      await tester.tap(find.text('Dar el mes'));
      await jornadaDrenar(tester, vueltas: 8);

      final ops = await jornadaOpsTodas('regalar_mes');
      expect(ops, hasLength(1));
      expect(jornadaPayloadDe(ops.single)['cliente_id'], 61);
      expect((await _cliente(61))['pagado_hasta'], esperado);
      await _cerrar(tester);
    });

    testWidgets(
        'dueño + vigente: cancelar la confirmación no encola '
        'nada ni toca el vencimiento', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      final hoy = hoyHabanaIso();
      final vigencia = _sumarDias(hoy, 10);
      await _sembrarCliente(62, pagadoHasta: vigencia);
      await _abrirFicha(tester, 62);
      await _irAlPanel(tester);

      await tester.tap(find.text('Mes de cortesía'));
      await jornadaEsperar(
          tester, find.textContaining('Quedará pagado hasta el'));
      await tester.tap(find.text('Cancelar'));
      await jornadaDrenar(tester, vueltas: 6);

      expect(await jornadaOpsTodas('regalar_mes'), isEmpty);
      expect((await _cliente(62))['pagado_hasta'], vigencia);
      await _cerrar(tester);
    });

    testWidgets(
        'entrenador: el Panel del dueño no existe y la '
        'cortesía no aparece por ningún lado', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      final hoy = hoyHabanaIso();
      await _sembrarCliente(63, pagadoHasta: _sumarDias(hoy, 10));
      await _abrirFicha(tester, 63);

      expect(find.text('Panel del dueño'), findsNothing);
      expect(find.text('Mes de cortesía'), findsNothing);
      expect(await jornadaOpsTodas('regalar_mes'), isEmpty);
      await _cerrar(tester);
    });

    testWidgets(
        'dueño + Cuenta a la Casa: la cortesía no se ofrece',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      final hoy = hoyHabanaIso();
      await _sembrarCliente(64,
          pagadoHasta: _sumarDias(hoy, 10), cuentaCasa: 1);
      await _abrirFicha(tester, 64);
      await jornadaEsperar(tester, find.text('App Clientes'));
      await tester.tap(find.text('App Clientes'));
      await jornadaDrenar(tester, vueltas: 6);

      // El panel SÍ está (es el dueño) pero sin la fila:
      // se contrasta con una fila vecina que sí vive ahí.
      await tester.scrollUntilVisible(
          find.text('Quitar Cuenta a la Casa'), 120,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Panel del dueño'), findsWidgets);
      expect(find.text('Mes de cortesía'), findsNothing);
      await _cerrar(tester);
    });

    testWidgets('dueño + eliminado: la cortesía no se ofrece',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      final hoy = hoyHabanaIso();
      await _sembrarCliente(65,
          pagadoHasta: _sumarDias(hoy, 10), estado: 'eliminado');
      await _abrirFicha(tester, 65);
      // La ficha del eliminado puede ni abrir la pestaña;
      // si la abre, la fila tampoco debe estar.
      if (find.text('App Clientes').evaluate().isNotEmpty) {
        await tester.tap(find.text('App Clientes'));
        await jornadaDrenar(tester, vueltas: 6);
      }
      expect(find.text('Mes de cortesía'), findsNothing);
      expect(await jornadaOpsTodas('regalar_mes'), isEmpty);
      await _cerrar(tester);
    });
  });
}
