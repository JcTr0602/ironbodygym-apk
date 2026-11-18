/// Corrección ARG136-05 (adjudicación Argón 1.36, H8):
/// en Actividad, el filtro de protegidos de un no-dueño
/// era solo por ID (cliente_id de la entrada o el patrón
/// «cliente NNN» del detalle). Una entrada SIN cliente_id
/// rescatable cuyo detalle nombra a un protegido
/// sobrevivía: la tarjeta pintaba la línea de detalle con
/// su nombre y la insignia con su monto. La corrección
/// retira también las entradas cuyo detalle contiene un
/// nombre protegido (conjunto armado de TODO el espejo,
/// la pauta de AuditoriaScreen). La hoja de detalle ya
/// comprobaba esVistaProtegida para ofrecer ficha/recibo:
/// la brecha era solo la línea y el monto de la tarjeta,
/// y se cierra en la carga, así que tampoco llega a los
/// KPI ni a la hoja.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/actividad.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'jornada_ayudas.dart';

/// Re-siembra la foto de permisos de Gabriel con
/// can_ver_todos_pagos: así el recorte de atribución del
/// ítem 8 no retira nada y el único filtro que decide
/// sobre las entradas sembradas es el de protegidos.
Future<void> _permisosVerTodo() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
      'cache_permisos_entrenador_json@gabriel',
      jsonEncode({
        'can_cobrar_pagos': true,
        'can_inscribir_clientes': true,
        'can_editar_fichas': true,
        'can_gestionar_turnos': true,
        'can_registrar_gastos': true,
        'can_vender_suplementos': true,
        'can_view_payroll': true,
        'can_ver_todos_pagos': true,
      }));
  PermisosEntrenador().limpiar();
  await PermisosEntrenador().cargar();
}

Future<void> _sembrar() async {
  final hoy = hoyHabanaIso();
  final db = LocalDb.instance;
  await db.upsertMirror('clientes', 900, {
    'id': 900,
    'nombre': 'Protegido Secreto',
    'protegido': 1,
    'estado': 'activo',
  }, 1);
  await db.upsertMirror('clientes', 901, {
    'id': 901,
    'nombre': 'Cliente Visible',
    'protegido': 0,
    'estado': 'activo',
  }, 2);
  // El feed del servidor: la entrada del protegido NO
  // trae cliente_id ni patrón «cliente NNN» — solo su
  // nombre dentro del detalle, la forma que se colaba.
  await db.setMeta(
      'sync_estado_actividad',
      jsonEncode([
        {
          'ts': '${hoy}T10:00:00-05:00',
          'actor': 'Duany',
          'rol': '',
          'accion': 'pago_mensualidad',
          'detalle':
              'Protegido Secreto — 2000 CUP (mensual, efectivo)',
        },
        {
          'ts': '${hoy}T09:00:00-05:00',
          'actor': 'Duany',
          'rol': '',
          'accion': 'pago_mensualidad',
          'detalle':
              'Cliente Visible — 2000 CUP (mensual, efectivo)',
          'cliente_id': 901,
        },
      ]));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets('entrenador con ver-todo: la entrada que '
      'nombra a un protegido sin cliente_id no aparece; '
      'la del cliente normal sí', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    await tester.runAsync(_permisosVerTodo);
    await tester.runAsync(_sembrar);
    jornadaViewport(tester);
    await tester
        .pumpWidget(const MaterialApp(home: ActividadScreen()));
    await jornadaDrenar(tester, vueltas: 10);
    await jornadaEsperar(tester, find.textContaining('Cliente Visible'));
    expect(find.textContaining('Cliente Visible'), findsWidgets);
    expect(find.textContaining('Protegido Secreto'), findsNothing,
        reason: 'el nombre del protegido no puede llegar a '
            'la tarjeta ni por la línea de detalle');
    expect(tester.takeException(), isNull);
  });

  group('detalleNombraProtegido (pura)', () {
    test('contención sobre el detalle crudo, normalizada',
        () {
      const nombres = {'protegido secreto'};
      expect(
          detalleNombraProtegido(
              'Protegido Secreto — 2000 CUP (mensual, efectivo)',
              nombres),
          isTrue);
      expect(
          detalleNombraProtegido(
              'Cliente Visible — 2000 CUP (mensual, efectivo)',
              nombres),
          isFalse);
      expect(detalleNombraProtegido('', nombres), isFalse);
      expect(
          detalleNombraProtegido('Protegido Secreto — 2000 CUP',
              const <String>{}),
          isFalse);
    });
  });
}
