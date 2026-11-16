/// Jornada 1.34 · Situaciones 4–7 — cobros.
///
/// S4: mensualidad en efectivo a un activo (desde la FICHA real):
/// la cadena canónica apila desde la cobertura vigente y el
/// efectivo entra al «pendiente a entregar» del entrenador.
/// S5: mensualidad por transferencia (2500): la op nace con
/// método transferencia y NO toca el efectivo a entregar (la
/// confirmación de Jc es del servidor/bot, no de esta app).
/// S6: renovar a un vencido: la cobertura arranca de HOY, sin
/// regalar el hueco ni cobrarlo.
/// S7: períodos cortos — Semana (600/+7 d) y Quincena (1200/+15 d)
/// en el diálogo de pago, con su tipo distinguible; el diario
/// (200) vive en su pantalla propia (PagoDiarioScreen), sin
/// obligar a crear ficha.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/pago_diario.dart';
import 'package:ironbody_gym/ui/preview_cobro.dart';

import 'jornada_ayudas.dart';

String _hoy() => hoyHabanaIso();

String _enDias(int n) => DateTime.parse(_hoy())
    .add(Duration(days: n))
    .toIso8601String()
    .substring(0, 10);

Future<Map<String, dynamic>?> _cliente(int id) async {
  final todos = await LocalDb.instance.allMirror('clientes');
  for (final c in todos) {
    if (c['id'] == id) return c;
  }
  return null;
}

Future<void> _sembrarCliente(
    int id, String nombre, String? pagadoHasta) async {
  await LocalDb.instance.upsertMirror('clientes', id, {
    'id': id,
    'nombre': nombre,
    'telefono': '58112233',
    'estado': 'activo',
    'pagado_hasta': pagadoHasta,
    'fecha_inscripcion': _enDias(-120),
  }, 1);
}

/// Host del flujo de cobro completo (diálogo → preview → recibo).
Widget _hostCobro(int id, String nombre, void Function() alRecibo) {
  return MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final payload = await pagoDialogo(ctx, {
                'id': id,
                'nombre': nombre,
                'estado': 'activo',
                'pagado_hasta': null,
              });
              if (payload == null || !ctx.mounted) return;
              await cobrarConPreviewYRecibo(
                context: ctx,
                nombreCliente: nombre,
                payload: payload,
              );
              alRecibo();
            },
            child: const Text('cobrar'),
          ),
        ),
      ),
    ),
  );
}

/// Host que captura SOLO el payload del Paso 1 del diálogo.
Widget _hostDialogo(
    int id, String nombre, void Function(Map<String, dynamic>?) alVolver) {
  return MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final payload = await pagoDialogo(ctx, {
                'id': id,
                'nombre': nombre,
                'estado': 'activo',
                'pagado_hasta': null,
              });
              alVolver(payload);
            },
            child: const Text('dialogo'),
          ),
        ),
      ),
    ),
  );
}

/// Elige el tipo de período en el Paso 1: el selector es un
/// DESPLEGABLE («Semana · 7 días · 600 CUP»): abrirlo y tocar
/// la opción = 2 toques (el mensual viene preseleccionado y
/// no cuesta ninguno).
Future<void> _elegirTipo(WidgetTester tester, ContadorToques toques,
    String fragmento) async {
  await jornadaEsperar(
      tester, find.byType(SelectorIron<String>));
  await toques.tap(tester, find.byType(SelectorIron<String>).first);
  await tester.pumpAndSettle();
  await jornadaEsperar(tester, find.textContaining(fragmento));
  await toques.tap(tester, find.textContaining(fragmento).last);
  await tester.pumpAndSettle();
}

/// Completa diálogo→preview→recibo contando toques desde el
/// botón del host (el host sustituye al toque que abre el
/// diálogo desde la ficha/lista).
Future<void> _completarCobro(
    WidgetTester tester, ContadorToques toques) async {
  await jornadaEsperar(tester, find.text('Continuar'));
  await toques.tap(tester, find.text('Continuar'));
  await tester.pumpAndSettle();
  await jornadaEsperar(tester, find.text('Revisar cobro'));
  await toques.tap(tester, find.text('Confirmar cobro'));
  await tester.pumpAndSettle();
  await jornadaEsperar(tester, find.text('Entendido'));
  await tester.ensureVisible(find.text('Entendido'));
  await tester.pumpAndSettle();
  await toques.tap(tester, find.text('Entendido'));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada S4 · cobrar mensualidad en efectivo (desde la ficha)', () {
    testWidgets(
        'activo con cobertura: apila desde su «pagado hasta», '
        'op pago_mensual 2000 efectivo y pendiente a entregar '
        'del entrenador = 2000', (tester) async {
      final toques = ContadorToques();
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      final coberturaVieja = _enDias(10);
      await tester.runAsync(() => _sembrarCliente(10, 'Activo Cuatro', coberturaVieja));

      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const FichaScreen(clienteId: 10)));
      await jornadaDrenar(tester, vueltas: 8);
      await jornadaDescartarDialogos(tester);

      // Paso 2 del guión: la acción de cobrar de la ficha es el
      // botón fijo inferior «Registrar pago» (la barra compacta
      // que aparece al bajar dice «Cobrar»: misma acción).
      await jornadaEsperar(tester, find.text('Registrar pago'));
      await toques.tap(tester, find.text('Registrar pago'));
      await tester.pumpAndSettle();
      // Pasos 3–4: período mensual y Efectivo vienen por defecto;
      // el monto precargado es el estándar (2000).
      await _completarCobro(tester, toques);

      // Paso 5: el dato cayó — op, espejo y pendiente.
      final ops = await jornadaOps('pago_mensual');
      expect(ops, hasLength(1));
      final payload = jornadaPayloadDe(ops.single);
      expect(payload['cliente_id'], 10);
      expect((payload['monto'] as num).toInt(), 2000);
      expect(payload['metodo'], 'efectivo');
      final nuevoHasta = '${payload['pagado_hasta']}';
      final delta = DateTime.parse(nuevoHasta)
          .difference(DateTime.parse(coberturaVieja))
          .inDays;
      expect(delta, inInclusiveRange(28, 31),
          reason: 'la cadena apila UN mes desde la cobertura '
              'vigente ($coberturaVieja → $nuevoHasta), no desde hoy');
      final espejo = await _cliente(10);
      expect('${espejo?['pagado_hasta']}', nuevoHasta,
          reason: 'el espejo refleja el nuevo pagado hasta');
      expect(await pendienteEntrega(1403501391), 2000,
          reason: 'el efectivo cobrado por el entrenador entra '
              'a su pendiente a entregar');
      expect(toques.n, 4,
          reason: 'ficha → Registrar pago → Continuar → '
              'Confirmar → Entendido = 4 toques (objetivo ≤4)');
      await jornadaCerrarCascara(tester);
    });
  });

  group('Jornada S5 · cobrar por transferencia', () {
    testWidgets(
        'op con método transferencia y monto 2500; el pendiente '
        'a entregar en efectivo NO se mueve', (tester) async {
      final toques = ContadorToques();
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await tester.runAsync(() => _sembrarCliente(11, 'Transfiere Cinco', _enDias(5)));
      expect(await pendienteEntrega(1403501391), 0);

      jornadaViewport(tester);
      var recibo = false;
      await tester.pumpWidget(_hostCobro(11, 'Transfiere Cinco', () => recibo = true));
      await jornadaEsperar(tester, find.text('cobrar'));
      await toques.tap(tester, find.text('cobrar'));
      await tester.pumpAndSettle();
      // Paso 2: elegir Transferencia en el Paso 1.
      await jornadaEsperar(tester, find.text('Transferencia'));
      await toques.tap(tester, find.text('Transferencia'));
      await tester.pumpAndSettle();
      await _completarCobro(tester, toques);
      expect(recibo, isTrue);

      final ops = await jornadaOps('pago_mensual');
      expect(ops, hasLength(1));
      final payload = jornadaPayloadDe(ops.single);
      expect(payload['metodo'], 'transferencia');
      expect((payload['monto'] as num).toInt(), 2500,
          reason: 'la mensualidad por transferencia es 2500');
      expect(await pendienteEntrega(1403501391), 0,
          reason: 'la transferencia va a la cuenta del dueño: '
              'jamás suma al efectivo a entregar');
      expect(toques.n, 5,
          reason: 'abrir + Transferencia + Continuar + Confirmar '
              '+ Entendido');
    });
  });

  group('Jornada S6 · renovar a un vencido', () {
    testWidgets(
        'vencido hace 20 días: la nueva cobertura arranca de HOY '
        '(ni regala el hueco ni lo cobra)', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await tester.runAsync(() => _sembrarCliente(12, 'Vencido Seis', _enDias(-20)));

      jornadaViewport(tester);
      await tester.pumpWidget(_hostCobro(12, 'Vencido Seis', () {}));
      await jornadaEsperar(tester, find.text('cobrar'));
      await tester.tap(find.text('cobrar'));
      await tester.pumpAndSettle();
      final toques = ContadorToques();
      await _completarCobro(tester, toques);

      final ops = await jornadaOps('pago_mensual');
      expect(ops, hasLength(1));
      final payload = jornadaPayloadDe(ops.single);
      final nuevoHasta = DateTime.parse('${payload['pagado_hasta']}');
      final desdeHoy = nuevoHasta.difference(DateTime.parse(_hoy())).inDays;
      expect(desdeHoy, inInclusiveRange(28, 31),
          reason: 'renovar = hoy + 1 mes: la cadena toma '
              'max(cobertura, fecha) = fecha');
      final espejo = await _cliente(12);
      expect(
          DateTime.parse('${espejo?['pagado_hasta']}')
              .isAfter(DateTime.parse(_hoy())),
          isTrue,
          reason: 'el cliente vuelve a estar cubierto (activo)');
    });
  });

  group('Jornada S7 · períodos cortos', () {
    testWidgets(
        'Semana y Quincena en el diálogo: monto y días cambian '
        'con el período y el tipo queda distinguible', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await tester.runAsync(() => _sembrarCliente(13, 'Corto Siete', null));

      jornadaViewport(tester);
      Map<String, dynamic>? payload;
      await tester.pumpWidget(_hostDialogo(13, 'Corto Siete', (p) => payload = p));
      // Semana:
      await jornadaEsperar(tester, find.text('dialogo'));
      await tester.tap(find.text('dialogo'));
      await tester.pumpAndSettle();
      await _elegirTipo(tester, ContadorToques(), 'Semana');
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(payload, isNotNull);
      expect(payload!['periodo'], 'semanal');
      expect((payload!['monto'] as num).toInt(), 600);
      expect('${payload!['pagado_hasta']}', _enDias(7),
          reason: 'la semana compra exactamente 7 días desde hoy '
              '(sin cobertura previa)');

      // Quincena (diálogo nuevo):
      payload = null;
      await tester.tap(find.text('dialogo'));
      await tester.pumpAndSettle();
      await _elegirTipo(tester, ContadorToques(), 'Quincena');
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(payload, isNotNull);
      expect(payload!['periodo'], 'quincenal');
      expect((payload!['monto'] as num).toInt(), 1200);
      expect('${payload!['pagado_hasta']}', _enDias(15));
    });

    testWidgets(
        'la Semana confirmada cae como pago_mensual tipado '
        'semanal (no un mensual disfrazado)', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await tester.runAsync(() => _sembrarCliente(14, 'Semana Ocho', null));
      jornadaViewport(tester);
      final toques = ContadorToques();
      await tester.pumpWidget(_hostCobro(14, 'Semana Ocho', () {}));
      await jornadaEsperar(tester, find.text('cobrar'));
      await toques.tap(tester, find.text('cobrar'));
      await tester.pumpAndSettle();
      await _elegirTipo(tester, toques, 'Semana');
      await _completarCobro(tester, toques);
      final ops = await jornadaOps('pago_mensual');
      expect(ops, hasLength(1));
      final payload = jornadaPayloadDe(ops.single);
      expect(payload['periodo'], 'semanal');
      expect('${payload['pagado_hasta']}', _enDias(7));
      expect(toques.n, 6,
          reason: 'abrir diálogo + 2 del desplegable de período '
              '+ Continuar + Confirmar + Entendido: el período '
              'corto cuesta 2 toques más que el mensual');
    });

    testWidgets(
        'diario: la pantalla Pago Diario registra 200 en '
        'efectivo sin crear ficha ni tocar clientes', (tester) async {
      final toques = ContadorToques();
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: const PagoDiarioScreen()));
      await jornadaDrenar(tester, vueltas: 6);
      await jornadaEsperar(
          tester, find.textContaining('Pago diario ·'));
      expect(find.textContaining('200'), findsWidgets);
      final registrar = find.textContaining('Registrar 1');
      await jornadaEsperar(tester, registrar);
      await toques.tap(tester, registrar.first);
      await jornadaDrenar(tester, vueltas: 6);
      final ops = await jornadaOpsTodas('pago_diario');
      expect(ops, hasLength(1),
          reason: 'el diario encola su op propia pago_diario');
      final payload = jornadaPayloadDe(ops.single);
      expect((payload['total'] as num?)?.toInt() ?? (payload['monto'] as num).toInt(), 200);
      // Sin ficha: ningún cliente creado ni tocado.
      expect(await LocalDb.instance.allMirror('clientes'), isEmpty);
      expect(toques.n, 1,
          reason: 'desde la pantalla: Registrar = 1 toque '
              '(+1 para llegar desde Inicio por el pase del día)');
      // Salida como la del usuario: volver atrás con la app
      // intacta (la barra Deshacer viva muere con su pantalla,
      // Bloque 5) antes de desmontar el árbol del test.
      Navigator.of(tester.element(find.byType(PagoDiarioScreen))).pop();
      await jornadaDrenar(tester, vueltas: 4);
      await jornadaCerrarCascara(tester);
    });
  });
}
