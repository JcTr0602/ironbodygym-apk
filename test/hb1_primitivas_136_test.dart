/// H-B1 (1.36): primitivas y pilares —
/// 136-324, 136-337, 136-338, 136-339, 136-341, 136-342,
/// 136-343, 136-349, 136-352, 136-355, 136-356, 136-359,
/// 136-360, 136-361, 136-362.
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/diseno.dart';
import 'package:ironbody_gym/ui/primitivas.dart';

String _src(String p) => File(p).readAsStringSync();

Widget _envolver(Widget w) => MaterialApp(
      theme: AppTema.sol(),
      home: Scaffold(body: w),
    );

void main() {
  testWidgets('136-352 · el pad nombra sus teclas de acción', (t) async {
    await t.pumpWidget(_envolver(PadNumerico(
      valor: '12',
      onCambia: (_) {},
    )));
    expect(find.bySemanticsLabel('Borrar'), findsOneWidget);
    expect(find.bySemanticsLabel('Punto decimal'), findsOneWidget);
    expect(find.bySemanticsLabel('Limpiar'), findsOneWidget);
  });

  testWidgets('136-355 · DeslizarConfirmar confirma por acción semántica',
      (t) async {
    var confirmado = false;
    await t.pumpWidget(_envolver(DeslizarConfirmar(
      texto: 'Desliza para confirmar',
      habilitado: true,
      onConfirmar: () => confirmado = true,
    )));
    // La acción personalizada «Confirmar» existe en el
    // subárbol semántico y dispara la confirmación.
    final raiz = t.getSemantics(find.byType(DeslizarConfirmar));
    SemanticsNode? dueno;
    int? idAccion;
    bool buscar(SemanticsNode n) {
      final ids =
          n.getSemanticsData().customSemanticsActionIds ?? const <int>[];
      for (final i in ids) {
        if (CustomSemanticsAction.getAction(i)?.label == 'Confirmar') {
          dueno = n;
          idAccion = i;
        }
      }
      n.visitChildren(buscar);
      return true;
    }

    buscar(raiz);
    expect(idAccion, isNotNull,
        reason: 'el carril expone la acción semántica «Confirmar»');
    t.binding.pipelineOwner.semanticsOwner!.performAction(
        dueno!.id, SemanticsAction.customAction, idAccion);
    await t.pump();
    expect(confirmado, isTrue);
  });

  testWidgets('136-356 · el borde se atenúa deshabilitado', (t) async {
    await t.pumpWidget(_envolver(DeslizarConfirmar(
      texto: 'Desliza',
      habilitado: false,
      onConfirmar: () {},
    )));
    final cont = t.widget<Container>(
        find.byKey(const ValueKey('deslizar-carril')));
    final deco = cont.decoration! as BoxDecoration;
    expect(deco.border!.top.color,
        AppColores.naranja.withValues(alpha: 0.35));
  });

  testWidgets('136-360/361 · CampoMontoPad: botón con cifra de la casa',
      (t) async {
    var toques = 0;
    await t.pumpWidget(_envolver(CampoMontoPad(
      etiqueta: 'Importe',
      valor: '1500',
      onTap: () => toques++,
    )));
    final texto = t.widget<Text>(find.text('1500'));
    expect(texto.style, AppTexto.conTabulares(AppTexto.metrica));
    await t.tap(find.text('1500'));
    expect(toques, 1);
  });

  group('contratos de fuente · pilares y tacto', () {
    test('136-337 · token de generación en _contarUrgencia', () {
      final s = _src('lib/ui/pilar_clientes.dart');
      expect(s, contains('_genUrgencia'));
      expect(s, contains('gen == _genUrgencia'));
    });
    test('136-324 · tacto+fundido en Negocio, Tienda y Centro', () {
      for (final f in [
        'lib/ui/pilar_negocio.dart',
        'lib/ui/pilar_tienda.dart'
      ]) {
        final s = _src(f);
        expect(s, contains('Tacto.seleccion()'), reason: f);
        expect(s, contains('FundidoAlCambiar('), reason: f);
      }
      expect(_src('lib/ui/centro_control.dart'),
          contains('onTap: (_) => Tacto.seleccion()'));
      expect(_src('lib/ui/primitivas.dart'),
          contains('Tacto.seleccion();\n                      setState(() => _valor = r.valor);'));
    });
    test('136-341 · Tienda con ScrollHorizontalConPista', () {
      expect(_src('lib/ui/pilar_tienda.dart'),
          contains('ScrollHorizontalConPista('));
    });
    test('136-338/339 · Caja: recarga anunciada y liquidar sin Telegram',
        () {
      final s = _src('lib/ui/pilar_negocio.dart');
      expect(s, contains("if (mounted && !_cargando) setState(() => _cargando = true);"));
      expect(s, contains('no tiene cuenta de Telegram vinculada'));
      expect(s, contains("e['telegram_id'] == null"));
    });
    test('136-342/343 · gates con EstadoVacio y enlaces con insignia', () {
      expect(_src('lib/ui/turnos_hub.dart'), contains('EstadoVacio('));
      final hub = _src('lib/ui/hub_comunicacion.dart');
      expect(hub, contains('EstadoVacio('));
      expect(hub, contains('IconoModuloBadge.naranja(d.icono'));
    });
    test('136-349 · Tacto no vibra hasta leer la preferencia', () {
      final s = _src('lib/ui/primitivas.dart');
      expect(s, contains('_leyendo'));
      expect(s, isNot(contains('provisional hasta que lea el ajuste')));
    });
    test('136-359/362 · animaciones con token corto', () {
      final s = _src('lib/ui/primitivas.dart');
      expect(s, contains('_animarA(1, confirmar: true)'));
      expect(s, contains('AnimatedOpacity('));
    });
  });
}
