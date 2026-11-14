// JORNADA 1 · S16 — Congelar a un cliente y reactivarlo.
//
// La Congelación vive en DOS pisos: las solicitudes y
// aprobaciones viajan por RPC del servidor (admin_resolver_
// congelacion: ahí se revalidan duración 7–30, tope de 2 y
// 45 días/12 meses y la extensión de cobertura) y el
// ESPEJO local cliente_congelaciones manda en lo que la app
// muestra y excluye sin conexión. En la superficie TEST
// (servidor falso) se ejecuta el piso local completo: la
// ficha enseña la pausa aprobada en curso, el cliente
// congelado NO sale en los avisos de vencimiento aunque su
// fecha ya pasó, el listado de congelados lo recoge y los
// bordes del modelo (programada/en curso/terminada) se
// verifican contra el reloj. La resolución por RPC con el
// servidor caído degrada con error visible, no con un
// vacío falso.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/congelaciones_gestion.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/congelados.dart';
import 'package:ironbody_gym/ui/ficha.dart';

import 'jornada_ayudas.dart';

String _iso(DateTime d) => isoHabana(d).substring(0, 10);

Future<void> _sembrarPausaEnCurso() async {
  final hoy = ahoraHabana();
  await LocalDb.instance.upsertMirror('clientes', 20, {
    'id': 20,
    'nombre': 'Pausa Jornada',
    'estado': 'activo',
    // Vencido por fecha hace 5 días: sin la pausa, sería
    // un vencido más en todas las listas.
    'pagado_hasta': _iso(hoy.subtract(const Duration(days: 5))),
    'telefono': '58112233',
    'carnet': '900115',
    'sexo': 'M',
  }, 1);
  await LocalDb.instance.upsertMirror('cliente_congelaciones', 1, {
    'id': 'cg-jornada-1',
    'cliente_id': 20,
    'cliente_nombre': 'Pausa Jornada',
    'motivo_categoria': 'viaje',
    'motivo': 'Viaje de trabajo',
    'estado': 'aprobada',
    'desde': _iso(hoy.subtract(const Duration(days: 2))),
    'hasta': _iso(hoy.add(const Duration(days: 8))),
    'inicio_efectivo': _iso(hoy.subtract(const Duration(days: 2))),
    'hasta_efectivo': _iso(hoy.add(const Duration(days: 8))),
    'dias_a_extender': 10,
  }, 1);
}

void main() {
  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  group('Jornada S16 · congelación', () {
    testWidgets(
        'pausa aprobada en curso: la ficha la enseña y el '
        'cliente no sale en avisos de vencimiento',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      await _sembrarPausaEnCurso();
      jornadaViewport(tester);

      final hoy = ahoraHabana();
      final delCliente =
          await CongelacionesService.instance.deCliente(20);
      expect(delCliente, hasLength(1));
      expect(delCliente.single.enCursoEn(hoy), isTrue);
      expect(delCliente.single.etiquetaEstado(hoy), 'En curso');
      expect(
          await CongelacionesService.instance
              .idsCongeladosEnCurso(hoy),
          contains(20));
      // La exclusión que importa a diario: vencido por
      // fecha, pero la bandeja de WhatsApp NO lo propone
      // como vencido mientras la pausa corre.
      final avisos = await avisosWhatsappHoy();
      expect(avisos.where((a) => a['cliente_id'] == 20), isEmpty,
          reason: 'congelado en curso no recibe aviso de '
              'vencimiento');

      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const FichaScreen(clienteId: 20),
      ));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
          find.textContaining('Congelación aprobada'), 120,
          scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Congelación aprobada'),
          findsWidgets);
      expect(find.text('Cerrar ahora'), findsWidgets,
          reason: 'reactivar/cerrar es tan directo como '
              'congelar: un botón en la propia ficha, sin '
              'esperar a que expire sola');
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'el listado de Congelados recoge al cliente con '
        'estado congelado (legado) y no a los activos',
        (tester) async {
      await jornadaPreparar(tester);
      await jornadaSesionDueno(tester);
      final futuro = _iso(
          ahoraHabana().add(const Duration(days: 20)));
      await LocalDb.instance.upsertMirror('clientes', 21, {
        'id': 21,
        'nombre': 'Congelado Legado Jornada',
        'estado': 'congelado',
        'pagado_hasta': futuro,
      }, 1);
      await LocalDb.instance.upsertMirror('clientes', 22, {
        'id': 22,
        'nombre': 'Activo Jornada',
        'estado': 'activo',
        'pagado_hasta': futuro,
      }, 1);
      jornadaViewport(tester);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: const CongeladosScreen(),
      ));
      await tester.pumpAndSettle();
      await jornadaEsperar(
          tester, find.text('Congelado Legado Jornada'));
      expect(find.text('Activo Jornada'), findsNothing);
      await jornadaCerrarCascara(tester);
    });

    testWidgets(
        'bordes del modelo: programada no es en curso, '
        'terminada tampoco, pendiente jamás', (tester) async {
      await jornadaPreparar(tester);
      final hoy = ahoraHabana();
      CongelacionGestion caso({
        required String estado,
        required DateTime inicio,
        required DateTime fin,
        int? materializados,
      }) =>
          CongelacionGestion(
            id: 'x',
            clienteId: 20,
            motivoCategoria: 'viaje',
            motivo: 'Viaje',
            estado: estado,
            inicioEfectivo: inicio,
            hastaEfectivo: fin,
            diasMaterializados: materializados,
          );
      final programada = caso(
          estado: 'aprobada',
          inicio: hoy.add(const Duration(days: 1)),
          fin: hoy.add(const Duration(days: 10)));
      expect(programada.enCursoEn(hoy), isFalse);
      expect(programada.etiquetaEstado(hoy), 'Programada');
      final terminada = caso(
          estado: 'aprobada',
          inicio: hoy.subtract(const Duration(days: 10)),
          fin: hoy.subtract(const Duration(days: 1)),
          materializados: 9);
      expect(terminada.enCursoEn(hoy), isFalse);
      // La etiqueta lleva el sub-estado de la extensión:
      // aplicada o aún sincronizando, nunca un «Terminada»
      // pelado que oculte en qué punto va la cadena.
      expect(terminada.etiquetaEstado(hoy),
          'Terminada · días aplicados');
      final sinMaterializar = caso(
          estado: 'aprobada',
          inicio: hoy.subtract(const Duration(days: 10)),
          fin: hoy.subtract(const Duration(days: 1)));
      expect(sinMaterializar.etiquetaEstado(hoy),
          'Terminada · sincronizando días');
      final pendiente = caso(
          estado: 'pendiente',
          inicio: hoy.subtract(const Duration(days: 1)),
          fin: hoy.add(const Duration(days: 5)));
      expect(pendiente.enCursoEn(hoy), isFalse,
          reason: 'sin aprobación del dueño no hay pausa: '
              'la solicitud sola no congela nada');
      await jornadaCerrarCascara(tester);
    });
  });
}
