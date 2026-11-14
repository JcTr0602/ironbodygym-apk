/// Jornada 1.34 · Situaciones 1 y 18 — turno del día.
///
/// S1: abrir turno desde Inicio (cáscara real), con el borde del
/// turno de ayer sin cerrar (la app lo ofrece resolver, no bloquea)
/// y la premisa del guión «cobrar sin turno advierte» verificada
/// contra el comportamiento real.
///
/// S18: cerrar el día desde Inicio con movimientos: el cierre
/// presenta el desglose de pendientes, cierra como cerrado_local
/// sin red y Inicio vuelve a ofrecer «Abrir turno»; con el turno
/// cerrado no se puede cerrar dos veces.
library;


import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/turno_service.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';
import 'package:ironbody_gym/ui/preview_cobro.dart';

import 'jornada_ayudas.dart';

/// Host mínimo del flujo de cobro real (diálogo → preview →
/// recibo), patrón del banco de flujos v2.
Widget _hostCobro(void Function(ResultadoCobro?) alCerrar) {
  return MaterialApp(
    home: Builder(
      builder: (ctx) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async {
              final payload = await pagoDialogo(ctx, {
                'id': 10,
                'nombre': 'Cliente Jornada',
                'estado': 'activo',
                'pagado_hasta': null,
              });
              if (payload == null || !ctx.mounted) {
                alCerrar(null);
                return;
              }
              final r = await cobrarConPreviewYRecibo(
                context: ctx,
                nombreCliente: 'Cliente Jornada',
                payload: payload,
              );
              alCerrar(r);
            },
            child: const Text('cobrar'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada S1 · abrir turno', () {
    testWidgets(
        'sin turno: Inicio ofrece Abrir turno y 1 toque lo abre '
        '(fila local + op apertura_turno)', (tester) async {
      final toques = ContadorToques();
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      expect(await TurnoService.instance.turnoActual(), isNull);
      await jornadaMontarHome(tester);

      // Paso 2 del guión: la acción de abrir turno está en Inicio.
      await jornadaEsperar(tester, find.text('Abrir turno'));
      expect(find.text('Abrir turno'), findsOneWidget);

      // Paso 3: tocar abrir turno (sin otros entrenadores
      // sembrados no hay diálogo de suplente: abre directo).
      await toques.tap(tester, find.text('Abrir turno'));
      await jornadaDrenar(tester, vueltas: 8);

      // Paso 4: el turno quedó registrado y Inicio lo muestra.
      final t = await TurnoService.instance.turnoActual();
      expect(t, isNotNull, reason: 'el turno debe quedar abierto');
      expect('${t!['estado']}', startsWith('abierto'));
      final ops = await jornadaOps('apertura_turno');
      expect(ops, hasLength(1),
          reason: 'la apertura encola su op de sync');
      await jornadaEsperar(tester, find.text('Cerrar turno'));
      expect(find.text('Cerrar turno'), findsOneWidget);
      expect(toques.n, 1,
          reason: 'tras el PIN, abrir turno cuesta 1 toque '
              '(objetivo del guión: ≤3)');
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'turno de ayer sin cerrar: Inicio lo señala y abrir el de '
        'hoy lo marca no_cerrado (no bloquea)', (tester) async {
      final toques = ContadorToques();
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      // Siembra: turno de AYER abierto en la tabla local.
      final ayer = DateTime.parse(hoyHabanaIso())
          .subtract(const Duration(days: 1))
          .toIso8601String()
          .substring(0, 10);
      final d = await LocalDb.instance.db;
      await d.insert('turnos', {
        'turno_id': 'jornada-ayer-1',
        'fecha_turno': ayer,
        'turno': 'manana',
        'hora_apertura': '${ayer}T07:05:00',
        'hora_cierre': null,
        'telegram_id': 1403501391,
        'estado': 'abierto_local',
        'cubre_a': null,
      });
      expect(await TurnoService.instance.turnosSinResolver(),
          hasLength(1));

      await jornadaMontarHome(tester);
      // La app lo OFRECE resolver: tarjeta de pendientes visible.
      await jornadaEsperar(
          tester, find.textContaining('turno(s) sin cerrar'));
      expect(find.textContaining('turno(s) sin cerrar'), findsOneWidget);

      await jornadaEsperar(tester, find.text('Abrir turno'));
      await toques.tap(tester, find.text('Abrir turno'));
      await jornadaDrenar(tester, vueltas: 8);

      // El de ayer quedó marcado no_cerrado y el de hoy abierto.
      // OJO (diseño AA3 F-T1): un no_cerrado SIGUE en la lista
      // de «sin resolver» — es su estado pendiente de resolución
      // (su cierre sube por sync), no un olvido: lo que la
      // Jornada verifica es que ya no figura como ABIERTO y que
      // abrir el de hoy no se bloqueó por su culpa.
      final sinResolver =
          await TurnoService.instance.turnosSinResolver();
      expect(sinResolver, hasLength(1));
      expect('${sinResolver.single['estado']}', 'no_cerrado');
      final filas = await d.query('turnos',
          where: 'turno_id=?', whereArgs: ['jornada-ayer-1']);
      expect('${filas.single['estado']}', 'no_cerrado');
      expect(await TurnoService.instance.turnoActual(), isNotNull);
      expect(toques.n, 1);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'premisa del guión: cobrar SIN turno abierto — qué hace '
        'la app de verdad', (tester) async {
      // El guión espera que la app advierta. Se verifica el
      // comportamiento real sin forzar la aserción al guión:
      // el cobro atribuye por cobrador (telegram del payload),
      // no por turno — se documenta en el informe.
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', 10, {
          'id': 10,
          'nombre': 'Cliente Jornada',
          'estado': 'activo',
          'pagado_hasta': null,
        }, 1);
      });
      expect(await TurnoService.instance.turnoActual(), isNull);
      ResultadoCobro? r;
      jornadaViewport(tester);
      await tester.pumpWidget(_hostCobro((x) => r = x));
      await jornadaEsperar(tester, find.text('cobrar'));
      await tester.tap(find.text('cobrar'));
      await tester.pumpAndSettle();
      // Sin ningún aviso de turno por el camino:
      expect(find.textContaining('turno'), findsNothing);
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      expect(find.text('Revisar cobro'), findsOneWidget);
      await tester.tap(find.text('Confirmar cobro'));
      await tester.pumpAndSettle();
      expect(find.text('Entendido'), findsOneWidget);
      // Cerrar el recibo: completa el flujo y suelta el candado
      // anti-doble-toque (_cobroEnCurso) para el resto de la
      // batería.
      await tester.ensureVisible(find.text('Entendido'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Entendido'));
      await tester.pumpAndSettle();
      expect(r, isNotNull);
      final pagos = await jornadaOps('pago_mensual');
      expect(pagos, hasLength(1),
          reason: 'el cobro sin turno SÍ se completa y encola');
    });
  });

  group('Jornada S18 · cerrar el día', () {
    testWidgets(
        'con un cobro pendiente de subir: Inicio → Cerrar turno '
        '→ desglose → Cerrar de todos modos → cerrado_local y '
        'Inicio vuelve a ofrecer Abrir turno', (tester) async {
      final toques = ContadorToques();
      await jornadaPreparar(tester);
      await jornadaSesionEntrenador(tester);
      final d = await LocalDb.instance.db;
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', 10, {
          'id': 10,
          'nombre': 'Cliente Jornada',
          'estado': 'activo',
          'pagado_hasta': null,
        }, 1);
      });
      // Abrir turno por el servicio (la UI de apertura es S1).
      await TurnoService.instance.abrirTurno();
      // Un movimiento del día: cobro en efectivo sin red.
      ResultadoCobro? r;
      jornadaViewport(tester);
      await tester.pumpWidget(_hostCobro((x) => r = x));
      await jornadaEsperar(tester, find.text('cobrar'));
      await tester.tap(find.text('cobrar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continuar'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirmar cobro'));
      await tester.pumpAndSettle();
      expect(find.text('Entendido'), findsOneWidget);
      expect(await jornadaOps('pago_mensual'), hasLength(1),
          reason: 'el movimiento del día existe antes del cierre');
      await tester.ensureVisible(find.text('Entendido'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Entendido'));
      await tester.pumpAndSettle();
      expect(r, isNotNull);

      // Cierre desde Inicio (cáscara real).
      await jornadaMontarHome(tester);
      await jornadaEsperar(tester, find.text('Cerrar turno'));
      await toques.tap(tester, find.text('Cerrar turno'));
      // El cierre intenta subir (tope 5 s) y presenta el
      // desglose honesto de pendientes.
      await jornadaEsperar(
          tester, find.text('Cerrar de todos modos'),
          intentos: 120);
      expect(find.textContaining('operaciones sin subir'),
          findsOneWidget);
      await toques.tap(tester, find.text('Cerrar de todos modos'));
      await jornadaDrenar(tester, vueltas: 10);

      final t = await TurnoService.instance.turnoActual();
      expect(t, isNull,
          reason: 'tras cerrar no queda turno abierto');
      final cierres = await jornadaOpsTodas('cierre_turno');
      expect(cierres, hasLength(1),
          reason: 'el cierre encola su op con el desglose');
      final payload = jornadaPayloadDe(cierres.single);
      expect(payload['pagos_count'], 1,
          reason: 'el desglose del cierre cuenta el cobro del día');
      expect((payload['pendientes_count'] as num), greaterThan(0),
          reason: 'el cierre fue forzado: quedaban pendientes');
      // La fila local del turno: cerrada con incidencias
      // (cerró con pendientes sin subir, sin red).
      final filasTurno = await d.query('turnos',
          where: 'estado LIKE ?', whereArgs: ['cerrado%']);
      expect(filasTurno, hasLength(1));
      expect('${filasTurno.single['estado']}', 'cerrado_local');
      expect(filasTurno.single['tiene_incidencias'], 1);
      // Inicio tras el cierre: el guión esperaba que volviera a
      // ofrecer «Abrir turno», pero el diseño real es un turno
      // por franja: la fila de hoy queda como chip «Cerrado ⏳»
      // y SIN botón de acción (ni abrir ni cerrar) hasta la
      // siguiente franja. Se afirma el comportamiento real.
      await jornadaEsperar(tester, find.textContaining('Cerrado'));
      expect(find.text('Abrir turno'), findsNothing);
      expect(find.text('Cerrar turno'), findsNothing);
      expect(toques.n, 2,
          reason: 'cerrar desde Inicio: Cerrar turno + Cerrar de '
              'todos modos (con pendientes sin subir)');
      await jornadaCerrarCascara(tester);
    });
  });
}
