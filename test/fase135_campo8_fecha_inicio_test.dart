// 1.35 (CAMPO-8): inscribir con fecha de inicio elegible.
//
// Diseño aprobado por Jc con su defecto mandando:
//  - POR DEFECTO el pago se asienta el día de la
//    inscripción (la `fecha` de la op es hoy) — sin tocar
//    el selector, la inscripción se comporta como antes.
//  - Solo cuando se elige otra fecha en «Comenzó el»
//    (vale pasado y el día siguiente), esa fecha viaja
//    como la `fecha` de la op: el servidor asienta el
//    pago en SU día (su caja y su nómina) y la cobertura
//    corre desde ese día (la cadena canónica apila desde
//    la fecha del pago; verificado en _op_inscribir:
//    `fecha` alimenta do_inscribir entero).
//  - La barra de resumen y el diálogo de confirmación
//    reflejan el inicio y el «vence el» ANTES de guardar.
//
// Arnés: el de la Jornada 1 (jornada_ayudas.dart).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/inscribir.dart';
import 'package:path/path.dart' as p;

import 'jornada_ayudas.dart';

Widget _hostInscribir() {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                    builder: (_) => const InscribirScreen())),
            child: const Text('abrir'),
          ),
        ),
      ),
    ),
  );
}

String _iso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
    docs = await Directory(
            p.join(Directory.systemTemp.path, 'campo8_docs'))
        .create(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            null);
  });

  Future<void> abrirYrellenar(
      WidgetTester tester, ContadorToques toques, String nombre) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    jornadaViewport(tester);
    await tester.pumpWidget(_hostInscribir());
    await toques.tap(tester, find.text('abrir'));
    await jornadaDrenar(tester);
    await jornadaEsperar(tester, find.text('Guardar inscripción'));
    await toques.campo(tester, find.byType(TextField).at(0), nombre);
    await toques.campo(tester, find.byType(TextField).at(2), '900115');
    await tester.pumpAndSettle();
  }

  testWidgets(
      'CAMPO-8 (defecto): sin tocar el selector, la op '
      'nace con fecha de hoy', (tester) async {
    final toques = ContadorToques();
    await abrirYrellenar(tester, toques, 'Campo Ocho Defecto');
    // El selector nace en «Hoy (…)».
    await toques.scrollHasta(tester, find.text('Comenzó el:'));
    expect(find.textContaining('Hoy ('), findsOneWidget);
    await toques.scrollHasta(tester, find.text('Guardar inscripción'));
    await toques.tap(tester, find.text('Guardar inscripción'));
    await jornadaEsperar(tester, find.text('Confirmar'));
    // El diálogo dice «Desde hoy».
    expect(find.textContaining('Desde hoy,'), findsOneWidget);
    await toques.tap(tester, find.text('Confirmar'));
    await jornadaDrenar(tester, vueltas: 8);
    await tester.pumpAndSettle();
    // Drenar el temporizador del banner de sync (≤30 s).
    await tester.pump(const Duration(seconds: 31));
    final ops = await jornadaOpsTodas('inscribir');
    expect(ops, hasLength(1));
    final payload = jornadaPayloadDe(ops.single);
    expect(payload['fecha'], hoyHabanaIso(),
        reason: 'el defecto manda: el pago se asienta el '
            'día de la inscripción');
  });

  testWidgets(
      'CAMPO-8 (excepción): al elegir ayer en «Comenzó el», '
      'el resumen y el diálogo lo reflejan y la op viaja '
      'con fecha de ayer', (tester) async {
    final hoy = ahoraHabana();
    // El selector del sistema muestra el mes en curso:
    // «ayer» es visible salvo el día 1 (no es el caso de
    // esta corrida y el arnés lo exige explícito).
    expect(hoy.day, greaterThan(1),
        reason: 'el test elige ayer dentro del mes visible');
    final ayer = hoy.subtract(const Duration(days: 1));
    final ayerIso = _iso(ayer);
    final toques = ContadorToques();
    await abrirYrellenar(tester, toques, 'Campo Ocho Ayer');
    await toques.scrollHasta(tester, find.text('Comenzó el:'));
    // Subida extra: la barra inferior anclada puede
    // interceptar el toque al botón (visto en la Jornada).
    await tester.drag(
        find.byType(Scrollable).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    toques.n++;
    await toques.tap(
        tester,
        find.ancestor(
            of: find.textContaining('Hoy ('),
            matching: find.byType(OutlinedButton)));
    await jornadaEsperar(tester, find.byType(DatePickerDialog));
    // La celda de ayer dentro del calendario.
    final celdaAyer = find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.text('${ayer.day}'));
    await toques.tap(tester, celdaAyer);
    await tester.pumpAndSettle();
    await toques.tap(tester, find.text('OK'));
    await jornadaDrenar(tester);
    // El selector muestra la fecha y la nota dice dónde
    // cae el pago.
    expect(find.text(fmtFecha(ayerIso)), findsWidgets);
    expect(
        find.textContaining('El pago se asentará el'), findsOneWidget);
    // La barra de resumen refleja el vencimiento desde
    // ayer (mensual: ayer + 30 días).
    final venceEsperado = fmtFecha(sumarDiasIso(ayerIso, 30));
    expect(find.textContaining('vence el $venceEsperado'),
        findsOneWidget,
        reason: 'la cobertura corre desde el día elegido');
    await toques.scrollHasta(tester, find.text('Guardar inscripción'));
    await toques.tap(tester, find.text('Guardar inscripción'));
    await jornadaEsperar(tester, find.text('Confirmar'));
    expect(find.textContaining('Desde el ${fmtFecha(ayerIso)}'),
        findsOneWidget);
    await toques.tap(tester, find.text('Confirmar'));
    await jornadaDrenar(tester, vueltas: 8);
    await tester.pumpAndSettle();
    // Drenar el temporizador del banner de sync (≤30 s).
    await tester.pump(const Duration(seconds: 31));
    final ops = await jornadaOpsTodas('inscribir');
    expect(ops, hasLength(1));
    final payload = jornadaPayloadDe(ops.single);
    expect(payload['fecha'], ayerIso,
        reason: 'la excepción elegida manda: el pago se '
            'asienta en la fecha de inicio y la cobertura '
            'corre desde ella');
  });
}
