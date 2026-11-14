// Tests 1.29 (fijo de campo) — elegirFotoEditada.
//
// El fallo: en Inscribir (y su copia en la ficha) el flujo de foto
// no tenía try/catch y el Future se descartaba en el onPressed:
// si el selector lanzaba (already_active, por una petición
// anterior colgada) o nunca respondía, el toque moría en silencio
// — ni cámara, ni galería, ni editor. Estos tests fijan el
// contrato nuevo del helper compartido:
//   éxito → editor alcanzado y foto fijada;
//   excepción genérica → SnackBar visible;
//   already_active → SnackBar específico (cerrar y reintentar);
//   cancelación (null) → silencio correcto, sin error;
//   doble toque → una sola petición en curso;
//   foto recuperada de datos perdidos → el flujo sigue con ella
//   sin pedir otra.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:ironbody_gym/ui/foto_elegir.dart';

// PNG válido de 1x1 (el editor lo decodifica de verdad).
final _png1x1 = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docs;
  late File origenPng;

  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('foto_elegir_docs');
    final tmp = await Directory.systemTemp.createTemp('foto_elegir_src');
    origenPng = File('${tmp.path}/origen.png');
    await origenPng.writeAsBytes(_png1x1);
    // path_provider → directorio temporal propio (mismo mecanismo
    // que argon_fotos_caza_test): el helper copia ahí la elegida.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  // Superficie de teléfono: el editor (AlertDialog + LayoutBuilder)
  // se maqueta como en campo, no en el lienzo de escritorio 800x600.
  void superficieTelefono(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  Future<void> esperaCond(
      WidgetTester tester, bool Function() cond) async {
    for (var i = 0; i < 120; i++) {
      if (cond()) return;
      await tester
          .runAsync(() => Future<void>.delayed(
              const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> espera(WidgetTester tester, Finder f) =>
      esperaCond(tester, () => f.evaluate().isNotEmpty);

  // El editor prepara la foto en un isolate (compute): «Usar foto»
  // nace deshabilitado y se activa al terminar la preparación.
  Future<void> esperaEditorListo(WidgetTester tester) async {
    await espera(tester, find.text('Ajusta la foto'));
    final boton = find.widgetWithText(ElevatedButton, 'Usar foto');
    await esperaCond(tester,
        () => tester.widget<ElevatedButton>(boton).onPressed != null);
  }

  testWidgets('éxito: abre el editor y la foto queda fijada',
      (tester) async {
    superficieTelefono(tester);
    var llamadas = 0;
    await tester.pumpWidget(_ArnesFoto(
      recuperador: () async => LostDataResponse.empty(),
      selector: (origen) async {
        llamadas++;
        expect(origen, ImageSource.gallery);
        return XFile(origenPng.path);
      },
    ));
    await tester.tap(find.text('Elegir foto'));
    await esperaEditorListo(tester);
    expect(find.text('Ajusta la foto'), findsOneWidget,
        reason: 'el editor debe abrirse tras elegir la foto');
    await tester.tap(find.text('Usar foto'));
    await espera(tester, find.text('con-foto'));
    expect(find.text('con-foto'), findsOneWidget);
    expect(llamadas, 1);
    final ruta = tester
        .widget<Text>(find.byKey(const Key('ruta-foto')))
        .data!;
    expect(File(ruta).existsSync(), isTrue,
        reason: 'el archivo devuelto existe en documentos');
  });

  testWidgets('foto recuperada de datos perdidos: sigue con ella '
      'sin pedir otra', (tester) async {
    superficieTelefono(tester);
    var llamadasSelector = 0;
    await tester.pumpWidget(_ArnesFoto(
      recuperador: () async =>
          LostDataResponse(file: XFile(origenPng.path)),
      selector: (origen) async {
        llamadasSelector++;
        return null;
      },
    ));
    await tester.tap(find.text('Elegir foto'));
    await esperaEditorListo(tester);
    expect(find.text('Ajusta la foto'), findsOneWidget);
    await tester.tap(find.text('Usar foto'));
    await espera(tester, find.text('con-foto'));
    expect(find.text('con-foto'), findsOneWidget);
    expect(llamadasSelector, 0,
        reason: 'con foto recuperada no se abre el selector');
    // 1.32 (H-B6-1): la recuperación se ANUNCIA al entregar
    // el resultado — la foto ya no entra «de la nada».
    expect(
        find.text('Se recuperó la foto de la petición interrumpida.'),
        findsOneWidget);
    // Dejar vencer el aviso para no dejar temporizadores pendientes.
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('excepción genérica: SnackBar visible y sin foto',
      (tester) async {
    await tester.pumpWidget(_ArnesFoto(
      recuperador: () async => LostDataResponse.empty(),
      selector: (origen) async => throw Exception('boom'),
    ));
    await tester.tap(find.text('Elegir foto'));
    await espera(
        tester, find.text('No se pudo abrir la foto. Inténtalo de nuevo.'));
    expect(find.text('No se pudo abrir la foto. Inténtalo de nuevo.'),
        findsOneWidget);
    expect(find.text('sin-foto'), findsOneWidget);
    expect(find.text('Ajusta la foto'), findsNothing);
    // Dejar vencer el aviso para no dejar temporizadores pendientes.
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('already_active: SnackBar específico de cerrar '
      'y reintentar', (tester) async {
    await tester.pumpWidget(_ArnesFoto(
      recuperador: () async => LostDataResponse.empty(),
      selector: (origen) async => throw PlatformException(
          code: 'already_active',
          message: 'Image picker is already active'),
    ));
    await tester.tap(find.text('Elegir foto'));
    await espera(
        tester,
        find.text('No se pudo abrir la foto. Cierra la app y '
            'vuelve a intentarlo.'));
    expect(
        find.text('No se pudo abrir la foto. Cierra la app y '
            'vuelve a intentarlo.'),
        findsOneWidget);
    expect(find.text('sin-foto'), findsOneWidget);
    // Dejar vencer el aviso para no dejar temporizadores pendientes.
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('cancelación (null): silencio correcto, sin error '
      'ni editor', (tester) async {
    await tester.pumpWidget(_ArnesFoto(
      recuperador: () async => LostDataResponse.empty(),
      selector: (origen) async => null,
    ));
    await tester.tap(find.text('Elegir foto'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('sin-foto'), findsOneWidget);
    expect(find.text('Ajusta la foto'), findsNothing);
    expect(
        find.text('No se pudo abrir la foto. Inténtalo de nuevo.'),
        findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('doble toque: una sola petición en curso',
      (tester) async {
    final completer = Completer<XFile?>();
    var llamadas = 0;
    await tester.pumpWidget(_ArnesFoto(
      recuperador: () async => LostDataResponse.empty(),
      selector: (origen) {
        llamadas++;
        return completer.future;
      },
    ));
    await tester.tap(find.text('Elegir foto'));
    await tester.pump();
    await tester.tap(find.text('Elegir foto'));
    await tester.pump();
    expect(llamadas, 1,
        reason: 'el segundo toque se ignora mientras hay un '
            'flujo en curso');
    completer.complete(null);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('sin-foto'), findsOneWidget);
    // 1.34 (G-1): el bloqueo del segundo toque ahora deja
    // aviso en la bitácora, que programa su volcado a 3 s
    // (con reintentos de 10 s si el volcado falla en este
    // arnés): se quema la cadena alternando tiempo real
    // (para que el volcado corra) y falso (para que los
    // temporizadores venzan) antes de cerrar.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(
            const Duration(milliseconds: 120));
      });
      await tester.pump(const Duration(seconds: 6));
    }
  });
}

class _ArnesFoto extends StatelessWidget {
  final SelectorFoto selector;
  final RecuperadorFotoPerdida recuperador;
  const _ArnesFoto({required this.selector, required this.recuperador});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: _CuerpoFoto(selector: selector, recuperador: recuperador),
    );
  }
}

class _CuerpoFoto extends StatefulWidget {
  final SelectorFoto selector;
  final RecuperadorFotoPerdida recuperador;
  const _CuerpoFoto({required this.selector, required this.recuperador});

  @override
  State<_CuerpoFoto> createState() => _CuerpoFotoState();
}

class _CuerpoFotoState extends State<_CuerpoFoto> {
  File? _foto;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Text(_foto == null ? 'sin-foto' : 'con-foto'),
          if (_foto != null)
            Text(_foto!.path, key: const Key('ruta-foto')),
          ElevatedButton(
            onPressed: () async {
              final f = await elegirFotoEditada(
                context,
                ImageSource.gallery,
                selector: widget.selector,
                recuperador: widget.recuperador,
              );
              if (!mounted) return;
              setState(() => _foto = f);
            },
            child: const Text('Elegir foto'),
          ),
        ],
      ),
    );
  }
}
