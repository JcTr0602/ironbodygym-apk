/// 1.36 FICHA (136-191…136-230): contratos del carril
/// F-FICHA sobre las piezas puras de la ficha — la
/// credencial (Hero siempre montado, banda replanteada,
/// teléfono en la tira, botón de foto de 48 dp), el
/// esqueleto con la silueta real y el reparto explícito
/// de pestañas.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/ficha_congelacion.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';
import 'package:ironbody_gym/ui/skeleton.dart';

Widget _cabecera({
  File? foto,
  String? heroTag,
  String? telefonoTexto,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
            child: CabeceraFicha(
          nombre: 'Ana Pérez',
          foto: foto,
          colorMarco: Colors.green,
          esCasa: false,
          dias: 20,
          heroTag: heroTag,
          onFotoTap: null,
          onCambiarFoto: () {},
          pagadoHastaTexto: '05/12/2026',
          telefonoTexto: telefonoTexto,
            )),
      ),
    );

void main() {
  testWidgets('136-214/215 · sin foto y con origen, el Hero destino '
      'existe desde el primer frame', (t) async {
    await t.pumpWidget(_cabecera(heroTag: 'hero-buscar-7'));
    expect(find.byType(Hero), findsOneWidget);
  });

  testWidgets('136-192 · sin foto la banda baja: la credencial '
      'mide menos que con foto', (t) async {
    await t.pumpWidget(_cabecera());
    final sinFoto = t.getSize(find.byType(CabeceraFicha)).height;
    // PNG válido de 1×1 (un FileImage roto haría fallar el
    // frame por el error de carga, no por el alto).
    final f = File('${Directory.systemTemp.path}/ficha136.png')
      ..writeAsBytesSync(const [
        137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, //
        82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, //
        137, 0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 98, 0, 1, 0, //
        0, 5, 0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, //
        174, 66, 96, 130,
      ]);
    await t.pumpWidget(_cabecera(foto: f));
    final conFoto = t.getSize(find.byType(CabeceraFicha)).height;
    // Banda 152 sin foto frente a 196 con foto (la tira es
    // la misma): la diferencia es la de la banda.
    expect(conFoto - sinFoto, 44);
  });

  testWidgets('136-228 · el botón de foto mide 48 dp de alto',
      (t) async {
    await t.pumpWidget(_cabecera());
    final ink = find.ancestor(
        of: find.text('Añadir foto'),
        matching: find.byType(InkWell));
    expect(t.getSize(ink).height, greaterThanOrEqualTo(48));
  });

  testWidgets('136-191 · el teléfono válido sube a la tira de '
      'la credencial; sin teléfono la celda no se pinta',
      (t) async {
    await t.pumpWidget(_cabecera(telefonoTexto: '58191577'));
    expect(find.text('Teléfono'), findsOneWidget);
    expect(find.text('58191577'), findsOneWidget);
    await t.pumpWidget(_cabecera());
    expect(find.text('Teléfono'), findsNothing);
  });

  testWidgets('136-216 · el esqueleto dibuja la banda de la '
      'credencial (196 dp), no el avatar circular antiguo',
      (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: SkeletonFicha()),
    ));
    expect(
        find.byWidgetPredicate(
            (w) => w is SkeletonLinea && w.alto == 196),
        findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is SkeletonLinea && w.alto == 96),
        findsNothing);
  });

  test('136-194 · reparto explícito: Congelación va a '
      '«Pagos y Notas» por decisión (0), no por defecto',
      () {
    expect(
        pestanaDeSeccionFicha(
            const SeccionCongelacionFicha(clienteId: 1)),
        0);
    expect(
        pestanaDeSeccionFicha(const Resumen360Ficha(
            resumen: (n: 1, total: 2000.0, metodoTop: 'efectivo'))),
        0);
  });

  testWidgets('136-207 · el Historial memoizado pinta igual '
      'en dos builds con las mismas entradas', (t) async {
    final entradas = <Map<String, dynamic>>[
      {
        'tipo': 'pago',
        'titulo': 'Pago de mensualidad',
        'subtitulo': 'Efectivo',
        'trailing': '2000',
        'color': Colors.green,
        'icono': Icons.payments_rounded,
        'pago': {'metodo': 'efectivo', 'monto': 2000},
        'fecha': '2026-11-05',
      },
    ];
    Widget app() => MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TarjetaHistorialFicha(
                entradas: entradas,
                filtro: 'todo',
                onFiltro: (_) {},
                serviciosHist: const [],
                clienteId: 1,
                esAdmin: false,
                esOwner: false,
                onReenviarRecibo: (_) {},
                onVerComprobante: (_) {},
                onCorregirPago: (_) {},
                onConciliar: (_) {},
              ),
            ),
          ),
        );
    await t.pumpWidget(app());
    expect(find.text('Pago de mensualidad'), findsOneWidget);
    await t.pumpWidget(app());
    expect(find.text('Pago de mensualidad'), findsOneWidget);
  });
}
