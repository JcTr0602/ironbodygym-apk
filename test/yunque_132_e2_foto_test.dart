/// 1.32 · Escalón 2 — H-B6-1 y Compuerta 5 (Pieza 6).
///
/// - El contexto de la petición de foto {flujo, entidad}
///   se persiste ANTES de abrir el plugin, se lee de
///   vuelta y se limpia cuando el flujo termina con el
///   proceso vivo.
/// - El gancho de rehidratación
///   (`consultarFotoRecuperadaAlRehidratar`) devuelve la
///   foto que esperaba en el plugin CON su contexto y
///   limpia las preferencias; sin foto, limpia un
///   contexto rancio y devuelve null.
/// - Un flujo con `flujoFoto` deja el contexto visible
///   DURANTE la petición (lo que vería el gancho si el
///   proceso muriera a mitad) y limpio al completar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ironbody_gym/ui/foto_elegir.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('contexto persistente de la petición', () {
    test('registrar → leer → limpiar', () async {
      await registrarContextoFoto(
          flujo: 'ficha_cliente', entidadId: '321');
      final ctx = await leerContextoFoto();
      expect(ctx, isNotNull);
      expect(ctx!.flujo, 'ficha_cliente');
      expect(ctx.entidadId, '321');
      await limpiarContextoFoto();
      expect(await leerContextoFoto(), isNull);
    });

    test('sin entidad: el flujo viaja solo', () async {
      await registrarContextoFoto(flujo: 'inscribir');
      final ctx = await leerContextoFoto();
      expect(ctx!.flujo, 'inscribir');
      expect(ctx.entidadId, isNull);
    });

    test('sin nada registrado: null', () async {
      expect(await leerContextoFoto(), isNull);
    });
  });

  group('gancho de rehidratación', () {
    test('foto esperando + contexto: los devuelve y limpia',
        () async {
      await registrarContextoFoto(
          flujo: 'ficha_cliente', entidadId: '321');
      final r = await consultarFotoRecuperadaAlRehidratar(
        recuperador: () async =>
            LostDataResponse(file: XFile('/tmp/esperando.jpg')),
      );
      expect(r, isNotNull);
      expect(r!.archivo.path, '/tmp/esperando.jpg');
      expect(r.contexto!.flujo, 'ficha_cliente');
      expect(r.contexto!.entidadId, '321');
      expect(await leerContextoFoto(), isNull,
          reason: 'el contexto se consume: no se ofrece '
              'dos veces');
    });

    test('sin foto: null y el contexto rancio se limpia',
        () async {
      await registrarContextoFoto(flujo: 'inscribir');
      final r = await consultarFotoRecuperadaAlRehidratar(
        recuperador: () async => LostDataResponse.empty(),
      );
      expect(r, isNull);
      expect(await leerContextoFoto(), isNull,
          reason: 'una petición que ya no existe no deja '
              'contexto huérfano');
    });

    test('foto sin contexto registrado: llega con contexto '
        'null (la cáscara decide)', () async {
      final r = await consultarFotoRecuperadaAlRehidratar(
        recuperador: () async =>
            LostDataResponse(file: XFile('/tmp/huerfana.jpg')),
      );
      expect(r, isNotNull);
      expect(r!.contexto, isNull);
    });
  });

  testWidgets(
      'el flujo registra el contexto durante la petición '
      'y lo limpia al completar', (tester) async {
    ContextoFotoPendiente? durante;
    await tester.pumpWidget(_ArnesCtx(
      selector: (origen) async {
        // Dentro de la petición: el contexto ya está
        // persistido (si el proceso muriera aquí, el
        // gancho lo encontraría así).
        durante = await leerContextoFoto();
        return XFile('/tmp/nueva.jpg');
      },
    ));
    await tester.tap(find.text('Elegir'));
    for (var i = 0; i < 60 && durante == null; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(durante, isNotNull);
    expect(durante!.flujo, 'ficha_cliente');
    expect(durante!.entidadId, '321');
    for (var i = 0;
        i < 60 && find.text('con-foto').evaluate().isEmpty;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('con-foto'), findsOneWidget);
    expect(await leerContextoFoto(), isNull,
        reason: 'con el proceso vivo, el finally limpia '
            'el contexto');
  });
}

class _ArnesCtx extends StatelessWidget {
  final SelectorFoto selector;
  const _ArnesCtx({required this.selector});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: _CuerpoCtx(selector: selector));
  }
}

class _CuerpoCtx extends StatefulWidget {
  final SelectorFoto selector;
  const _CuerpoCtx({required this.selector});

  @override
  State<_CuerpoCtx> createState() => _CuerpoCtxState();
}

class _CuerpoCtxState extends State<_CuerpoCtx> {
  XFile? _foto;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Text(_foto == null ? 'sin-foto' : 'con-foto'),
          ElevatedButton(
            onPressed: () async {
              final f = await elegirFotoSegura(
                context,
                origen: ImageSource.gallery,
                selector: widget.selector,
                recuperador: () async => LostDataResponse.empty(),
                flujoFoto: 'ficha_cliente',
                entidadIdFoto: '321',
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
