/// Corrección ARG136-04 (adjudicación Argón 1.36, V4) —
/// ES LA FILA VIVA 136-104: en Mi Día, el filtro de
/// clientes protegidos (P1#3, `esVistaProtegida`) se
/// aplicaba solo a «Por cobrar hoy»; el bucle de
/// «Cobrado hoy» no lo miraba y un entrenador veía el
/// nombre, la foto, el monto, el método y la hora de los
/// cobros de un protegido, y su importe sumaba al total
/// del día y al agrupado por entrenador. Para el dueño
/// `esVistaProtegida` es false por diseño: él lo ve todo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/mi_dia.dart';

import 'jornada_ayudas.dart';

const _tidGabriel = 1403501391;

Future<void> _sembrar() async {
  final hoy = hoyHabanaIso();
  final db = LocalDb.instance;
  // Cliente protegido (id 900) y cliente normal (id 901),
  // ambos al día para que no salgan por «Por cobrar».
  await db.upsertMirror('clientes', 900, {
    'id': 900,
    'nombre': 'Protegido Secreto',
    'protegido': 1,
    'estado': 'activo',
    'pagado_hasta': '2027-01-01',
  }, 1);
  await db.upsertMirror('clientes', 901, {
    'id': 901,
    'nombre': 'Cliente Visible',
    'protegido': 0,
    'estado': 'activo',
    'pagado_hasta': '2027-01-01',
  }, 2);
  // Cobros de hoy registrados por Gabriel (la vista del
  // entrenador va filtrada por su propio telegram id).
  await db.upsertMirror('pagos', 1, {
    'id': 1,
    'cliente_id': 900,
    'monto': 2000,
    'fecha': hoy,
    'metodo': 'efectivo',
    'periodo': 'mensual',
    'telegram_user_id': _tidGabriel,
    'registrado_por': 'Gabriel',
    'creado_en': '${hoy}T09:00:00-05:00',
  }, 3);
  await db.upsertMirror('pagos', 2, {
    'id': 2,
    'cliente_id': 901,
    'monto': 2000,
    'fecha': hoy,
    'metodo': 'efectivo',
    'periodo': 'mensual',
    'telegram_user_id': _tidGabriel,
    'registrado_por': 'Gabriel',
    'creado_en': '${hoy}T10:00:00-05:00',
  }, 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets('entrenador: el cobro del protegido no '
      'aparece en Cobrado hoy; el del cliente normal sí',
      (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionEntrenador(tester);
    await tester.runAsync(_sembrar);
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MiDiaScreen()));
    await jornadaDrenar(tester, vueltas: 10);
    await jornadaEsperar(tester, find.textContaining('Cliente Visible'));
    expect(find.textContaining('Cliente Visible'), findsWidgets);
    expect(find.textContaining('Protegido Secreto'), findsNothing,
        reason: '136-104: el protegido no entra en los '
            'cobrados de un no-dueño, ni por la fila ni por '
            'el agrupado por entrenador');
    expect(tester.takeException(), isNull);
  });

  testWidgets('dueño: el cobro del protegido sí aparece '
      '(esVistaProtegida es false para él)', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(_sembrar);
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(home: MiDiaScreen()));
    await jornadaDrenar(tester, vueltas: 10);
    await jornadaEsperar(
        tester, find.textContaining('Protegido Secreto'));
    expect(find.textContaining('Protegido Secreto'), findsWidgets);
    expect(find.textContaining('Cliente Visible'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
