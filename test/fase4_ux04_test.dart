/// 1.35 FASE 4 — UX-04: la ficha como credencial.
///
/// La cabecera desplegada se recompone SIN perder una
/// sola función ni un solo texto de la cabecera vieja
/// (nota vinculante de Jc en la selección):
/// - foto a todo ancho en la banda (o el arte del rayo
///   con las iniciales cuando no hay foto);
/// - nombre e insignia de estado (textos exactos de
///   siempre) sobre el velo grafito del pie de la banda;
/// - el botón de foto como pastilla («Añadir foto» /
///   «Cambiar foto», candado sin permiso, indicador en
///   curso) y la foto tocable para verla en grande, con
///   su Hero;
/// - el progreso del período como BARRA al pie de la
///   banda (hereda el anillo: mismo color de estado,
///   gris en pausa; sin período, la línea plana);
/// - la tira de datos clave bajo la banda: «Pagado
///   hasta» y «Días que quedan» con sus textos por
///   estado (Casa / pausa / sin pagos / vence hoy /
///   quedan / vencido).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';

/// PNG válido de 1×1 (transparente).
final _png1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

Future<File> _fotoDePrueba() async {
  final f = File('${Directory.systemTemp.path}/fase4_ux04_foto.png');
  await f.writeAsBytes(_png1x1);
  return f;
}

/// 1.35 (corrección de la reconciliación, §3.7): la
/// decodificación de la foto se fuerza en zona asíncrona
/// REAL (`runAsync` + `precacheImage`). Escribir el
/// archivo o esperar su decodificación dentro de la zona
/// fake-async de `testWidgets` colgaba los dos tests con
/// foto de forma no determinista (TimeoutException a los
/// 10 min en el barrido completo; cuelgue en +0 en
/// solitario). La foto se escribe una sola vez en
/// `setUpAll` y cada test la precarga así antes de
/// afirmar — la receta que ya usan los demás tests de
/// foto de la casa.
Future<void> _precargarFoto(WidgetTester tester, File foto) async {
  final ctx = tester.element(find.byType(CabeceraFicha));
  await tester.runAsync(() => precacheImage(FileImage(foto), ctx));
}

Widget _envolver(Widget w, {double escala = 1.0}) {
  return MaterialApp(
    theme: AppTema.tacticoOscuro(),
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(
            textScaler: TextScaler.linear(escala),
            size: const Size(360, 800)),
        child: SizedBox(width: 360, child: ListView(children: [w])),
      ),
    ),
  );
}

CabeceraFicha _cabecera({
  File? foto,
  bool esCasa = false,
  int? dias = 30,
  bool congelado = false,
  bool puede = true,
  bool ocupada = false,
  double? fraccion,
  bool pausado = false,
  String? heroTag,
  VoidCallback? onFotoTap,
  VoidCallback? onCambiar,
  String? pagadoHasta = '05/12/2026',
}) {
  return CabeceraFicha(
    nombre: 'Luis Gómez',
    foto: foto,
    colorMarco: AppColores.exito,
    esCasa: esCasa,
    dias: dias,
    congelado: congelado,
    heroTag: heroTag,
    onFotoTap: onFotoTap,
    onCambiarFoto: onCambiar ?? () {},
    puedeCambiarFoto: puede,
    fotoOcupada: ocupada,
    fraccionPeriodo: fraccion,
    periodoPausado: pausado,
    pagadoHastaTexto: pagadoHasta,
  );
}

void main() {
  // §3.7: la foto se escribe en setUpAll (zona real),
  // nunca dentro de un testWidgets.
  late final File fotoPrueba;
  setUpAll(() async {
    fotoPrueba = await _fotoDePrueba();
  });

  testWidgets('con foto: banda, nombre e insignia sobre '
      'el velo, tira de datos y botón con su texto',
      (tester) async {
    final foto = fotoPrueba;
    var cambio = false;
    var vioGrande = false;
    await tester.pumpWidget(_envolver(_cabecera(
      foto: foto,
      onCambiar: () => cambio = true,
      onFotoTap: () => vioGrande = true,
    )));
    await _precargarFoto(tester, foto);
    await tester.pump();

    expect(find.text('Luis Gómez'), findsOneWidget);
    expect(find.text('AL DÍA'), findsOneWidget);
    // La tira de datos clave.
    expect(find.text('Pagado hasta'), findsOneWidget);
    expect(find.text('05/12/2026'), findsOneWidget);
    expect(find.text('Días que quedan'), findsOneWidget);
    expect(find.text('Quedan 30 días'), findsOneWidget);
    // El botón de foto, con su texto de siempre.
    expect(find.text('Cambiar foto'), findsOneWidget);
    await tester.tap(find.text('Cambiar foto'));
    expect(cambio, isTrue);
    // La foto se toca para verla en grande.
    await tester.tapAt(const Offset(180, 60));
    expect(vioGrande, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sin foto: arte del rayo e iniciales '
      'grandes; el botón dice «Añadir foto»', (tester) async {
    await tester.pumpWidget(_envolver(_cabecera()));
    await tester.pump();
    expect(find.text('LG'), findsOneWidget);
    expect(find.text('Añadir foto'), findsOneWidget);
    expect(find.text('Cambiar foto'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el progreso del período es la barra del '
      'pie de la banda; sin período, línea plana',
      (tester) async {
    await tester.pumpWidget(
        _envolver(_cabecera(fraccion: 0.5)));
    await tester.pump();
    final barra = find.byType(LinearProgressIndicator);
    expect(barra, findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(barra).valueColor!.value,
        AppColores.exito);
    // En pausa, la barra se pinta en gris.
    await tester.pumpWidget(
        _envolver(_cabecera(fraccion: 0.5, pausado: true)));
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(barra).valueColor!.value,
        AppColores.bannerGrisB);
    // Sin período no hay barra: queda la línea plana.
    await tester.pumpWidget(_envolver(_cabecera()));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Casa: chip dorado y tira sin vencimiento; '
      'congelado, sin pagos y vencido con sus textos',
      (tester) async {
    await tester.pumpWidget(_envolver(_cabecera(
        esCasa: true, dias: null, pagadoHasta: 'Sin vencimiento')));
    await tester.pump();
    expect(find.text('Cuenta a la Casa'), findsOneWidget);
    expect(find.text('Sin vencimiento'), findsWidgets);
    expect(find.text('AL DÍA'), findsNothing);

    await tester.pumpWidget(_envolver(_cabecera(congelado: true)));
    await tester.pump();
    expect(find.text('CONGELADO'), findsOneWidget);
    expect(find.text('En pausa'), findsOneWidget);

    await tester.pumpWidget(_envolver(_cabecera(dias: null)));
    await tester.pump();
    expect(find.text('SIN PAGOS'), findsOneWidget);
    expect(find.text('Sin pagos'), findsOneWidget);

    await tester.pumpWidget(_envolver(_cabecera(dias: -3)));
    await tester.pump();
    expect(find.text('Vencido hace 3 días'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sin permiso: candado y botón muerto; en '
      'curso: indicador y botón muerto', (tester) async {
    var cambio = false;
    await tester.pumpWidget(_envolver(_cabecera(
        puede: false, onCambiar: () => cambio = true)));
    await tester.pump();
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    await tester.tap(find.text('Añadir foto'));
    expect(cambio, isFalse);

    await tester.pumpWidget(_envolver(_cabecera(
        ocupada: true, onCambiar: () => cambio = true)));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Añadir foto'));
    expect(cambio, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('el Hero de la foto se conserva y a 200 % '
      'no revienta', (tester) async {
    final foto = fotoPrueba;
    await tester.pumpWidget(_envolver(
        _cabecera(foto: foto, heroTag: 'foto-credencial'),
        escala: 2.0));
    await _precargarFoto(tester, foto);
    await tester.pump();
    expect(find.byType(Hero), findsOneWidget);
    expect(find.text('Luis Gómez'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
