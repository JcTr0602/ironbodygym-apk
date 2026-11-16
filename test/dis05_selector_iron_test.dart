/// 1.35 DIS-05 — tests del widget `SelectorIron` ANTES de
/// migrar la primera pantalla (diseño `135_prep/INFORME.md`
/// §2.2): abrir/cerrar, elegir persiste y el cerrado muestra
/// la etiqueta (nunca el id), error de validación visible en
/// el sabor Form, hoja sobre teclado y captura 360 dp × 1,3
/// del cerrado y del panel (compuerta visual; la captura solo
/// escribe PNG con --dart-define=DIS05_CAPTURAS=true).
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/hoja_accion.dart';

const _capturasHabilitadas = bool.fromEnvironment('DIS05_CAPTURAS');
const _dirCapturas =
    '/home/hatch/workspace/cola-123/gestion/135_dis05/capturas';

const _opciones = <OpcionSelector<String>>[
  OpcionSelector('a', 'Alfa'),
  OpcionSelector('b', 'Beta'),
  OpcionSelector('c', 'Gamma'),
];

/// Arnés con estado: guarda el valor vigente y lo enseña en
/// crudo (`valor=<id>`) para probar que viaja el VALOR y el
/// cerrado pinta la ETIQUETA.
class _Arnes extends StatefulWidget {
  final void Function(String)? alCambiarExtra;
  const _Arnes({this.alCambiarExtra});

  @override
  State<_Arnes> createState() => _ArnesState();
}

class _ArnesState extends State<_Arnes> {
  String _valor = 'b';
  int llamadas = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectorIron<String>(
              valor: _valor,
              opciones: _opciones,
              etiqueta: 'Nivel',
              alCambiar: (v) {
                llamadas++;
                widget.alCambiarExtra?.call(v);
                setState(() => _valor = v);
              },
            ),
            const SizedBox(height: 8),
            Text('valor=$_valor'),
          ],
        ),
      ),
    );
  }
}

Future<void> _montar(WidgetTester t, Widget hijo) {
  return t.pumpWidget(MaterialApp(
    theme: AppTema.tacticoOscuro(),
    home: hijo,
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('el cerrado muestra la etiqueta, nunca el id',
      (t) async {
    await _montar(t, const _Arnes());
    await t.pump();
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('b'), findsNothing);
    expect(find.text('Nivel'), findsOneWidget);
  });

  testWidgets(
      'abrir enseña la hoja de la casa con radios y título; '
      'cerrar con la X no cambia nada', (t) async {
    await _montar(t, const _Arnes());
    await t.pump();
    await t.tap(find.byType(SelectorIron<String>));
    await t.pumpAndSettle();
    // La hoja de la casa, con el título = etiqueta del campo.
    expect(find.byType(HojaAccion), findsOneWidget);
    expect(find.text('Nivel'), findsWidgets);
    expect(find.text('Alfa'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
    // Un solo radio marcado: el de la opción vigente.
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
    await t.tap(find.byTooltip('Cerrar'));
    await t.pumpAndSettle();
    expect(find.byType(HojaAccion), findsNothing);
    expect(find.text('valor=b'), findsOneWidget);
  });

  testWidgets(
      'elegir persiste: alCambiar recibe el VALOR y el cerrado '
      'muestra su etiqueta', (t) async {
    String? recibido;
    await _montar(t, _Arnes(alCambiarExtra: (v) => recibido = v));
    await t.pump();
    await t.tap(find.byType(SelectorIron<String>));
    await t.pumpAndSettle();
    await t.tap(find.text('Gamma'));
    await t.pumpAndSettle();
    expect(find.byType(HojaAccion), findsNothing);
    expect(recibido, 'c');
    expect(find.text('valor=c'), findsOneWidget);
    expect(find.text('Gamma'), findsOneWidget);
  });

  testWidgets(
      're-elegir la opción actual también cierra y dispara '
      '(como el menú del SDK)', (t) async {
    var llamadas = 0;
    await _montar(t, MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectorIron<String>(
            valor: 'b',
            opciones: _opciones,
            etiqueta: 'Nivel',
            alCambiar: (_) => llamadas++,
          ),
        ),
      ),
    ));
    await t.pump();
    await t.tap(find.byType(SelectorIron<String>));
    await t.pumpAndSettle();
    // La fila de la hoja (el cerrado también enseña «Beta»).
    await t.tap(find.descendant(
        of: find.byType(HojaAccion), matching: find.text('Beta')));
    await t.pumpAndSettle();
    expect(find.byType(HojaAccion), findsNothing);
    expect(llamadas, 1);
  });

  testWidgets(
      'sin selección enseña la pista; elegir la opción de valor '
      'null se distingue de cancelar', (t) async {
    String? valor = 'x';
    var llamadas = 0;
    await _montar(t, StatefulBuilder(
      builder: (ctx, setB) => Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: SelectorIron<String?>(
            valor: valor,
            opciones: const [
              OpcionSelector<String?>(null, 'Todos'),
              OpcionSelector<String?>('x', 'Equis'),
            ],
            pista: 'Todos los tipos',
            tituloPanel: 'Tipo',
            alCambiar: (v) {
              llamadas++;
              setB(() => valor = v);
            },
          ),
        ),
      ),
    ));
    await t.pump();
    expect(find.text('Equis'), findsOneWidget);
    // Elegir «Todos» (valor null) DISPARA y limpia el valor:
    // no es un cancelar.
    await t.tap(find.byType(SelectorIron<String?>));
    await t.pumpAndSettle();
    expect(find.text('Tipo'), findsOneWidget);
    await t.tap(find.text('Todos'));
    await t.pumpAndSettle();
    expect(llamadas, 1);
    expect(valor, isNull);
    // Sin selección, el cerrado enseña la pista.
    expect(find.text('Todos los tipos'), findsOneWidget);
    // Y cancelar (cerrar sin tocar opción) no dispara.
    await t.tap(find.byType(SelectorIron<String?>));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('Cerrar'));
    await t.pumpAndSettle();
    expect(llamadas, 1);
  });

  testWidgets('deshabilitado (alCambiar null) no abre el panel',
      (t) async {
    await _montar(t, MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: const Scaffold(
        body: Padding(
          padding: EdgeInsets.all(16),
          child: SelectorIron<String>(
            valor: 'b',
            opciones: _opciones,
            etiqueta: 'Nivel',
            alCambiar: null,
          ),
        ),
      ),
    ));
    await t.pump();
    await t.tap(find.byType(SelectorIron<String>));
    await t.pumpAndSettle();
    expect(find.byType(HojaAccion), findsNothing);
  });

  testWidgets(
      'sabor Form: el error de validación se ve y onSaved '
      'recibe el valor elegido', (t) async {
    final claveForm = GlobalKey<FormState>();
    String? guardado;
    String? cambiado;
    await _montar(t, MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: claveForm,
            child: SelectorIronForm<String>(
              valorInicial: 'a',
              opciones: _opciones,
              etiqueta: 'Nivel',
              validador: (v) =>
                  v == 'a' ? 'Elige otra opción' : null,
              alGuardar: (v) => guardado = v,
              alCambiar: (v) => cambiado = v,
            ),
          ),
        ),
      ),
    ));
    await t.pump();
    expect(find.text('Alfa'), findsOneWidget);
    // La validación del formulario enseña el error del campo.
    expect(claveForm.currentState!.validate(), isFalse);
    await t.pump();
    expect(find.text('Elige otra opción'), findsOneWidget);
    // Elegir otra opción limpia el error y alimenta onSaved.
    await t.tap(find.byType(SelectorIronForm<String>));
    await t.pumpAndSettle();
    await t.tap(find.text('Beta'));
    await t.pumpAndSettle();
    expect(cambiado, 'b');
    expect(find.text('Beta'), findsOneWidget);
    expect(claveForm.currentState!.validate(), isTrue);
    await t.pump();
    expect(find.text('Elige otra opción'), findsNothing);
    claveForm.currentState!.save();
    expect(guardado, 'b');
  });

  testWidgets('la hoja no queda bajo el teclado', (t) async {
    t.view.physicalSize = const Size(360, 800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await _montar(t, const _Arnes());
    await t.pump();
    // Teclado abierto: 300 dp de viewInsets inferior.
    t.view.viewInsets = const FakeViewPadding(bottom: 300);
    await t.pump();
    await t.tap(find.byType(SelectorIron<String>));
    await t.pumpAndSettle();
    expect(find.byType(HojaAccion), findsOneWidget);
    final rect = t.getRect(find.byType(HojaAccion));
    // El borde inferior de la hoja queda sobre el teclado
    // (800 - 300 = 500), no bajo él.
    expect(rect.bottom, lessThanOrEqualTo(500.5),
        reason: 'la hoja baja hasta ${rect.bottom} con el '
            'teclado ocupando desde 500');
    // Y la última opción se ve entera sobre el teclado.
    final rectGamma = t.getRect(find.text('Gamma'));
    expect(rectGamma.bottom, lessThanOrEqualTo(500.5));
  });

  testWidgets('en pantalla ancha el panel es un diálogo centrado',
      (t) async {
    t.view.physicalSize = const Size(900, 700);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await _montar(t, const _Arnes());
    await t.pump();
    await t.tap(find.byType(SelectorIron<String>));
    await t.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(HojaAccion), findsOneWidget);
    await t.tap(find.text('Alfa'));
    await t.pumpAndSettle();
    expect(find.text('valor=a'), findsOneWidget);
  });

  testWidgets('captura 360 dp × 1,3: cerrado y panel',
      (t) async {
    if (!_capturasHabilitadas) return;
    await t.runAsync(_cargarFuentesReales);
    t.view.physicalSize = const Size(360 * 1.3, 740 * 1.3);
    t.view.devicePixelRatio = 1.3;
    addTearDown(t.view.reset);
    final k = GlobalKey();
    // La frontera va SOBRE el MaterialApp: la hoja modal vive
    // en el overlay del Navigator, fuera de la ruta de inicio;
    // con la frontera dentro, el panel no saldría en la foto.
    await t.pumpWidget(RepaintBoundary(
      key: k,
      child: MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: const _Arnes(),
      ),
    ));
    await t.pump();
    await _capturar(t, k, 'selector_cerrado.png');
    await t.tap(find.byType(SelectorIron<String>));
    await t.pumpAndSettle();
    await _capturar(t, k, 'selector_panel.png');
    await t.tap(find.byTooltip('Cerrar'));
    await t.pumpAndSettle();
  });
}

Future<void> _cargarFuentesReales() async {
  const dir =
      '/home/hatch/flutter-sdk/flutter/bin/cache/artifacts/material_fonts';
  final loader = FontLoader('Roboto');
  for (final f in [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf'
  ]) {
    final bytes = await File('$dir/$f').readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
  final iconos = FontLoader('MaterialIcons');
  final otf = await File('$dir/MaterialIcons-Regular.otf').readAsBytes();
  iconos.addFont(Future.value(ByteData.view(otf.buffer)));
  await iconos.load();
}

Future<void> _capturar(
    WidgetTester tester, GlobalKey key, String nombre) async {
  if (!_capturasHabilitadas) return;
  await tester.pump(const Duration(milliseconds: 120));
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.3);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final dir = Directory(_dirCapturas);
    await dir.create(recursive: true);
    await File('${dir.path}/$nombre')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}
