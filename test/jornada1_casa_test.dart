// JORNADA 1 · S17 — Cuenta a la Casa.
//
// Solo el dueño la otorga, desde la ficha (menú ⋮ → Pasar
// a Cuenta a la Casa → motivo opcional → confirmar): op
// cuenta_casa + reflejo optimista en el espejo. Después:
// la ficha lo enseña dorado como «Cuenta a la Casa» sin
// vencimiento, el cobro desde la ficha está BLOQUEADO con
// su explicación, no sale en los avisos de vencimiento ni
// cuenta en la base de nómina aunque tenga un pago del
// mes, y al REVOCARLA vuelve a regir su pagado_hasta real
// (ya vencido: sin sorpresas silenciosas).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/nomina_calc.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/listas.dart';

import 'jornada_ayudas.dart';

final _navJornada = GlobalKey<NavigatorState>();

Future<void> _sembrar() async {
  final hoy = ahoraHabana();
  final vencido =
      isoHabana(hoy.subtract(const Duration(days: 10))).substring(0, 10);
  await LocalDb.instance.upsertMirror('clientes', 40, {
    'id': 40,
    'nombre': 'Casa Jornada',
    'estado': 'activo',
    'pagado_hasta': vencido,
    'telefono': '58112233',
    'carnet': '900115',
    'sexo': 'F',
  }, 1);
  await LocalDb.instance.upsertMirror('clientes', 41, {
    'id': 41,
    'nombre': 'Normal Jornada',
    'estado': 'activo',
    'pagado_hasta': isoHabana(hoy.add(const Duration(days: 20)))
        .substring(0, 10),
    'carnet': '910220',
    'sexo': 'M',
  }, 1);
  // Ambos «pagaron» este mes (filas del espejo): la base
  // de nómina solo debe contar al normal.
  final hoyIso = hoyHabanaIso();
  await LocalDb.instance.upsertMirror('pagos', 401, {
    'id': 401,
    'cliente_id': 40,
    'fecha': hoyIso,
    'monto': 2000,
    'metodo': 'efectivo',
    'telegram_user_id': 1403501391,
  }, 1);
  await LocalDb.instance.upsertMirror('pagos', 402, {
    'id': 402,
    'cliente_id': 41,
    'fecha': hoyIso,
    'monto': 2000,
    'metodo': 'efectivo',
    'telegram_user_id': 1403501391,
  }, 1);
}

Future<Map<String, dynamic>> _cliente(int id) async =>
    (await LocalDb.instance.allMirror('clientes'))
        .firstWhere((c) => c['id'] == id);

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada S17 · Cuenta a la Casa', () {
    testWidgets(
        'otorgar desde la ficha: op, dorado, cobro '
        'bloqueado, fuera de avisos y de la nómina; al '
        'revocar vuelve su vencimiento real', (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrar();
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: _navJornada,
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const FichaScreen(clienteId: 40),
      ));
      await tester.pumpAndSettle();
      final toques = ContadorToques();

      // Otorgar: el Panel del dueño vive en la pestaña
      // «App Clientes» de la ficha.
      await toques.tap(tester, find.text('App Clientes'));
      await tester.pumpAndSettle();
      await toques.scrollHasta(
          tester, find.text('Pasar a Cuenta a la Casa'));
      // La fila nace al filo inferior, bajo la barra de
      // cobro: un arrastre más para tocarla de verdad.
      await tester.drag(
          find.byType(Scrollable).first, const Offset(0, -200));
      toques.n++;
      await tester.pumpAndSettle();
      await toques.tap(tester, find.text('Pasar a Cuenta a la Casa'));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Pasar a la Casa'));
      await toques.tap(tester, find.text('Pasar a la Casa'));
      await jornadaDrenar(tester, vueltas: 8);

      final ops = await jornadaOpsTodas('cuenta_casa');
      expect(ops, hasLength(1));
      final p = jornadaPayloadDe(ops.single);
      expect(p['cliente_id'], 40);
      expect(p['activar'], isTrue);
      expect(esCuentaCasa(await _cliente(40)), isTrue,
          reason: 'el espejo refleja la Casa al momento '
              '(reflejo optimista, sin esperar al pull)');
      expect(await LocalDb.instance.idsCuentasCasa(), contains(40));

      // La ficha recargada lo enseña como Casa, no como
      // vencido (su fecha sigue siendo la vieja).
      await tester.pumpAndSettle();
      expect(find.text('Cuenta a la Casa'), findsWidgets);

      // Los números: ni avisos de vencimiento ni base de
      // nómina (su pago del mes no cuenta; el del normal sí).
      // Ojo: el aviso de RECIBO de su pago sí es legítimo —
      // lo que la Casa excluye es el de vencimiento.
      final avisos = await avisosWhatsappHoy();
      expect(
          avisos.where((a) =>
              a['cliente_id'] == 40 && a['tipo'] != 'recibo'),
          isEmpty,
          reason: 'sin aviso de vencimiento para la Casa '
              '(el recibo de su pago es otra cosa)');
      final pref = hoyHabanaIso().substring(0, 7);
      expect(await NominaCalc.clientesQuePagaronElMes(pref), 1,
          reason: 'la base del mes cuenta solo al cliente '
              'normal: la Casa no contamina la nómina');

      // En la propia ficha ni siquiera hay botón de cobro:
      // la barra inferior enseña el aviso de la Casa.
      expect(find.text('Registrar pago'), findsNothing);
      expect(find.textContaining('no cobra mensualidad'),
          findsWidgets);
      // Y por la otra puerta (el cobro rápido de Listas) la
      // guarda enseña el bloqueo con su explicación. Entrar
      // a Listas desde la cáscara = 1 toque (el arnés empuja
      // la pantalla con la llave del navegador).
      _navJornada.currentState!.push(MaterialPageRoute(
          builder: (_) => const ListasScreen()));
      toques.n++;
      await tester.pumpAndSettle();
      // Listas abre en Vencimientos; la Casa cuenta como
      // «al día» (nunca vence): su fila vive en ese chip,
      // el último de una fila horizontal que hay que
      // deslizar para alcanzarlo.
      await tester.dragFrom(
          const Offset(300, 79), const Offset(-280, 0));
      toques.n++;
      await tester.pumpAndSettle();
      await toques.tap(tester, find.textContaining('Al día (2)'));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Casa Jornada'));
      // El botón naranja de cobro rápido de SU fila (las
      // filas van por nombre: Casa antes que Normal).
      await toques.tap(tester,
          find.byIcon(Icons.payments_rounded).first);
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Entendido'));
      expect(
          find.textContaining('el cobro de mensualidad está bloqueado'),
          findsOneWidget);
      await toques.tap(tester, find.text('Entendido'));
      await tester.pumpAndSettle();
      expect(await jornadaOpsTodas('pago_mensual'), isEmpty,
          reason: 'ningún cobro nació para la Casa');
      // Volver a la ficha para la reversa.
      await tester.pageBack();
      await tester.pumpAndSettle();

      // Reversa: quitar la Casa → rige su fecha real.
      await toques.tap(tester, find.text('App Clientes'));
      await tester.pumpAndSettle();
      await toques.scrollHasta(
          tester, find.text('Quitar Cuenta a la Casa'));
      await tester.drag(
          find.byType(Scrollable).first, const Offset(0, -200));
      toques.n++;
      await tester.pumpAndSettle();
      await toques.tap(tester, find.text('Quitar Cuenta a la Casa'));
      await tester.pumpAndSettle();
      await jornadaEsperar(tester, find.text('Quitar'));
      await toques.tap(tester, find.text('Quitar'));
      await jornadaDrenar(tester, vueltas: 8);

      final ops2 = await jornadaOpsTodas('cuenta_casa');
      expect(ops2, hasLength(2));
      expect(jornadaPayloadDe(ops2.last)['activar'], isFalse);
      expect(esCuentaCasa(await _cliente(40)), isFalse);
      final avisos2 = await avisosWhatsappHoy();
      expect(
          avisos2.where((a) =>
              a['cliente_id'] == 40 && a['tipo'] != 'recibo'),
          isNotEmpty,
          reason: 'al revocar, su vencimiento real (hace '
              '10 días) vuelve a contar: queda vencido, sin '
              'sorpresas silenciosas');
      expect(toques.n, 15,
          reason: 'otorgar (pestaña App Clientes + desplazar '
              '+ arrastre + acción + confirmar) 5 + cobro '
              'bloqueado por Listas (entrar + deslizar la fila '
              'de chips + chip Al día + botón de cobro rápido '
              'de su fila + Entendido) 5 + revocar (pestaña + '
              'desplazar + arrastre + acción + confirmar) '
              '5 = 15');
      await jornadaCerrarCascara(tester);
    });
  });
}
