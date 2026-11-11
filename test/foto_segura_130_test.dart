// Tests del cierre §17 (auditoría ×10) — elegirFotoSegura.
//
// El hueco que caza: CINCO handlers tocados por la 1.30
// llamaban a ImagePicker().pickImage SIN la red de
// seguridad de la casa (suplementos, diálogo de pago,
// GymPedia, usuarios, detalle de incidencia) — el patrón
// exacto del fallo de campo 2026-11-07: si Android mata
// la actividad del selector, la petición queda colgada
// (already_active) y todo toque posterior de foto muere
// en silencio. elegirFotoSegura (foto_elegir.dart) es la
// vía sin editor de recorte: guarda anti-doble-toque
// compartida, retrieveLostData primero, try/catch con
// SnackBar en lenguaje llano y jamás lanzar.
//
// Contrato fijado aquí:
//   foto recuperada → se devuelve ella, sin abrir selector;
//   recuperador con error y sin foto → se sigue al selector
//     (el plugin ya limpió su estado colgado);
//   éxito del selector → la foto elegida;
//   already_active → null + SnackBar específico;
//   excepción genérica → null + SnackBar genérico;
//   cancelación → null en silencio;
//   doble toque → la segunda llamada ni llama al selector.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';

import 'package:ironbody_gym/ui/foto_elegir.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> esperaCond(
      WidgetTester tester, bool Function() cond) async {
    for (var i = 0; i < 120; i++) {
      if (cond()) return;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // Deja vencer el SnackBar para no arrastrar temporizadores
  // pendientes entre tests (mismo cierre que foto_elegir_129).
  Future<void> vencerAviso(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('foto recuperada: se devuelve ella y el '
      'selector no se abre', (tester) async {
    var llamadasSelector = 0;
    await tester.pumpWidget(_ArnesSegura(
      recuperador: () async =>
          LostDataResponse(file: XFile('/tmp/recuperada.jpg')),
      selector: (origen) async {
        llamadasSelector++;
        return null;
      },
    ));
    await tester.tap(find.text('Elegir'));
    await esperaCond(
        tester, () => find.text('con-foto').evaluate().isNotEmpty);
    expect(find.text('con-foto'), findsOneWidget);
    expect(
        tester.widget<Text>(find.byKey(const Key('ruta'))).data,
        '/tmp/recuperada.jpg');
    expect(llamadasSelector, 0,
        reason: 'con foto recuperada no se pide otra');
    // 1.32 (H-B6-1): la recuperación se ANUNCIA.
    expect(
        find.text('Se recuperó la foto de la petición interrumpida.'),
        findsOneWidget);
    await vencerAviso(tester);
  });

  testWidgets('recuperador con error y sin foto: se sigue '
      'al selector', (tester) async {
    var llamadasSelector = 0;
    await tester.pumpWidget(_ArnesSegura(
      recuperador: () async => LostDataResponse(
          exception: PlatformException(code: 'channel-error')),
      selector: (origen) async {
        llamadasSelector++;
        return XFile('/tmp/nueva.jpg');
      },
    ));
    await tester.tap(find.text('Elegir'));
    await esperaCond(
        tester, () => find.text('con-foto').evaluate().isNotEmpty);
    expect(find.text('con-foto'), findsOneWidget);
    expect(llamadasSelector, 1,
        reason: 'el error de datos perdidos limpia el estado '
            'colgado del plugin y se pide una foto nueva');
    // La rama de recuperación con error registra en AppLog:
    // sin BD (este arnés no la abre), su flush reintenta con
    // temporizadores (3 s + 3 × 10 s hasta descartar el lote
    // al 4º fallo): se bombea la cadena entera.
    await vencerAviso(tester);
    await tester.pump(const Duration(seconds: 12));
    await tester.pump();
  });

  testWidgets('already_active: null con el SnackBar '
      'específico, sin lanzar', (tester) async {
    await tester.pumpWidget(_ArnesSegura(
      recuperador: () async => LostDataResponse.empty(),
      selector: (origen) async => throw PlatformException(
          code: 'already_active',
          message: 'Image picker is already active'),
    ));
    await tester.tap(find.text('Elegir'));
    await esperaCond(
        tester,
        () => find
            .text('No se pudo abrir la foto. Cierra la app y '
                'vuelve a intentarlo.')
            .evaluate()
            .isNotEmpty);
    expect(find.text('sin-foto'), findsOneWidget);
    await vencerAviso(tester);
  });

  testWidgets('excepción genérica: null con el SnackBar '
      'genérico, sin lanzar', (tester) async {
    await tester.pumpWidget(_ArnesSegura(
      recuperador: () async => LostDataResponse.empty(),
      selector: (origen) async => throw Exception('boom'),
    ));
    await tester.tap(find.text('Elegir'));
    await esperaCond(
        tester,
        () => find
            .text('No se pudo abrir la foto. Inténtalo de nuevo.')
            .evaluate()
            .isNotEmpty);
    expect(find.text('sin-foto'), findsOneWidget);
    await vencerAviso(tester);
  });

  testWidgets('cancelación: null en silencio', (tester) async {
    await tester.pumpWidget(_ArnesSegura(
      recuperador: () async => LostDataResponse.empty(),
      selector: (origen) async => null,
    ));
    await tester.tap(find.text('Elegir'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('sin-foto'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('doble toque: la segunda llamada no llega '
      'al selector', (tester) async {
    final completer = Completer<XFile?>();
    var llamadas = 0;
    await tester.pumpWidget(_ArnesSegura(
      recuperador: () async => LostDataResponse.empty(),
      selector: (origen) {
        llamadas++;
        return completer.future;
      },
    ));
    await tester.tap(find.text('Elegir'));
    await tester.pump();
    await tester.tap(find.text('Elegir'));
    await tester.pump();
    expect(llamadas, 1,
        reason: 'la guarda global deja pasar un solo flujo '
            'del plugin a la vez');
    completer.complete(null);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('sin-foto'), findsOneWidget);
  });
}

class _ArnesSegura extends StatelessWidget {
  final SelectorFoto selector;
  final RecuperadorFotoPerdida recuperador;
  const _ArnesSegura(
      {required this.selector, required this.recuperador});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: _CuerpoSegura(selector: selector, recuperador: recuperador),
    );
  }
}

class _CuerpoSegura extends StatefulWidget {
  final SelectorFoto selector;
  final RecuperadorFotoPerdida recuperador;
  const _CuerpoSegura(
      {required this.selector, required this.recuperador});

  @override
  State<_CuerpoSegura> createState() => _CuerpoSeguraState();
}

class _CuerpoSeguraState extends State<_CuerpoSegura> {
  XFile? _foto;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Text(_foto == null ? 'sin-foto' : 'con-foto'),
          if (_foto != null)
            Text(_foto!.path, key: const Key('ruta')),
          ElevatedButton(
            onPressed: () async {
              final f = await elegirFotoSegura(
                context,
                origen: ImageSource.gallery,
                selector: widget.selector,
                recuperador: widget.recuperador,
              );
              if (!mounted) return;
              setState(() => _foto = f);
            },
            child: const Text('Elegir'),
          ),
        ],
      ),
    );
  }
}
