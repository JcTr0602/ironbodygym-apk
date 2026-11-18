/// 1.36 · S2-SISTEMA-TIPOGRAFÍA: sellos de las filas
/// 136-295…136-318 (auditoría exclusiva de tipografía).
///
/// - 136-313: censo de tamaños fuera de la escalera cerrada.
/// - 136-314: contrato de roles tabulares + FilaLibro.
/// - 136-315: censo de pesos cerrados (sin w800/w900).
/// - 136-316: frontera de familias declarada en el tema.
/// - 136-317: batería ×1,45 «sin elipsis en el dato».
/// - 136-318: espacio duro en la composición de importes
///   e interlineado display ≥ línea natural (1,20).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart' show fmtMontoConMoneda;
import 'package:ironbody_gym/ui/cierre_nomina_imagen.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

Iterable<File> _dartLib() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  group('136-314 · el dinero nace tabular', () {
    test('todo rol que pinta importes declara tabularFigures', () {
      for (final rol in [
        AppTexto.display,
        AppTexto.displayPequeno,
        AppTexto.metrica,
        AppTexto.tituloPagina, // 136-295: era el único sin la línea
        AppTexto.cifraFila, // 136-313: escalón nuevo de fila
        AppTexto.pinDigitos,
      ]) {
        expect(rol.fontFeatures,
            contains(const FontFeature.tabularFigures()),
            reason: 'rol sin tnum: $rol');
      }
    });

    testWidgets('FilaLibro pinta su monto tabular por defecto (136-296)',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: FilaLibro(concepto: 'Cuota', monto: '1 400 CUP'),
        ),
      ));
      final texto = tester.widget<Text>(find.text('1 400 CUP'));
      expect(texto.style!.fontFeatures,
          contains(const FontFeature.tabularFigures()));
      expect(texto.style!.fontSize, 14);
      expect(texto.style!.fontWeight, FontWeight.bold);
    });
  });

  group('136-313 · escalera cerrada con censo', () {
    test('roles re-nivelados: AppBar 20, sección y panel con rol propio',
        () {
      expect(AppTexto.tituloPagina.fontSize, 20);
      expect(AppTexto.titulo.fontSize, 18);
      expect(AppTexto.cabeceraSeccion.fontSize, 15);
      expect(AppTexto.cabeceraPanel.fontSize, 12);
      expect(AppTexto.cabeceraPanel.letterSpacing, 1.6,
          reason: 'el tracking 1.6 declarado UNA vez (136-306)');
      expect(AppTexto.cifraFila.fontSize, 14);
      final tema = AppTema.sol();
      expect(tema.appBarTheme.titleTextStyle!.fontSize, 20,
          reason: 'la AppBar titula con tituloPagina (136-305)');
    });

    test('censo: ningún fontSize literal fuera de la escalera', () {
      final escalera = {11.0, 12.0, 13.0, 14.0, 15.0, 18.0};
      // Excepciones NOMBRADAS (136-306/313): marca/glifo y
      // subsistema de salida-imagen (papel fijo delimitado
      // por 136-263), y tamaños derivados de un parámetro.
      const excepciones = {
        'lib/ui/arranque_marca.dart', // 44: wordmark de arranque (marca)
        'lib/ui/ficha_secciones.dart', // 64: glifo/inicial de marca
        'lib/ui/cierre_nomina_imagen.dart', // subsistema imagen
        'lib/ui/tarjeta_imagen.dart', // subsistema imagen
        // 1.36 (cierre de Aplica-136): tarjetas_wa es el
        // subsistema de imagen de las tarjetas de WhatsApp
        // (136-291…294): lienzo fijo 4:5 con escala propia de
        // captura (TJ-01), misma doctrina que las dos de arriba.
        'lib/ui/tarjetas_wa.dart', // subsistema imagen (tarjetas WA)
      };
      final patron = RegExp(r'fontSize:\s*([0-9]+(?:\.[0-9]+)?)');
      final fallos = <String>[];
      for (final f in _dartLib()) {
        if (f.path == 'lib/ui/diseno.dart') continue;
        if (excepciones.contains(f.path)) continue;
        for (final m in patron.allMatches(f.readAsStringSync())) {
          final v = double.parse(m.group(1)!);
          if (!escalera.contains(v)) {
            fallos.add('${f.path}: fontSize $v');
          }
        }
      }
      expect(fallos, isEmpty, reason: fallos.join('\n'));
    });

    test('censo: el tracking 1.6 no vive fuera del rol cabeceraPanel', () {
      // Excepción nombrada (cierre de Aplica-136): el subsistema
      // de imagen de tarjetas WA (lienzo fijo, escala propia).
      const excepciones = {'lib/ui/tarjetas_wa.dart'};
      for (final f in _dartLib()) {
        if (f.path == 'lib/ui/diseno.dart') continue;
        if (excepciones.contains(f.path)) continue;
        expect(f.readAsStringSync().contains('letterSpacing: 1.6'),
            isFalse,
            reason: '${f.path} sobrescribe el tracking de panel');
      }
    });
  });

  group('136-315 · pesos cerrados', () {
    test('censo: ni w800 ni w900 en lib/ (lista blanca vacía)', () {
      // Excepción nombrada (cierre de Aplica-136): el
      // subsistema de imagen de tarjetas WA (136-291…294) pinta
      // un PÓSTER de lienzo fijo con su escala display propia
      // (diseño aprobado por Jc); los pesos cerrados gobiernan
      // el texto de la UI, no el papel de salida — misma
      // doctrina que las excepciones del censo de fontSize.
      const excepciones = {'lib/ui/tarjetas_wa.dart'};
      for (final f in _dartLib()) {
        if (excepciones.contains(f.path)) continue;
        final t = f.readAsStringSync();
        expect(t.contains('FontWeight.w800'), isFalse,
            reason: '${f.path} pide w800');
        expect(t.contains('FontWeight.w900'), isFalse,
            reason: '${f.path} pide w900');
      }
    });

    test('el 600 de Barlow tiene uso declarado: pinDigitos', () {
      expect(AppTexto.pinDigitos.fontFamily, AppTexto.familiaDisplay);
      expect(AppTexto.pinDigitos.fontWeight, FontWeight.w600);
    });
  });

  group('136-316 · frontera de familias en el tema', () {
    test('el tema declara fontFamilyFallback con la red elegida', () {
      // El SDK no expone getter de fontFamilyFallback en
      // ThemeData: el sello es sobre la declaración.
      final fuente = _fuente('lib/ui/diseno.dart');
      expect(fuente, contains('fontFamilyFallback: const ['));
      expect(fuente, contains('AppTexto.familiaDisplay'));
      expect(fuente, contains('AppTexto.familiaRespaldo'));
      expect(AppTema.sol(), isNotNull);
    });

    test('los roles Barlow declaran su red de rescate por glifo', () {
      for (final rol in [
        AppTexto.display,
        AppTexto.displayPequeno,
        AppTexto.tituloPagina,
        AppTexto.metrica,
      ]) {
        expect(rol.fontFamilyFallback,
            contains(AppTexto.familiaRespaldo),
            reason: 'rol Barlow sin fallback declarado: $rol');
      }
    });

    test('censo: ninguna familia literal fuera de diseno.dart', () {
      for (final f in _dartLib()) {
        if (f.path == 'lib/ui/diseno.dart') continue;
        expect(f.readAsStringSync().contains('fontFamily:'), isFalse,
            reason: '${f.path} pide una familia fuera de la '
                'declaración (136-311/316)');
      }
    });

    test('el mono del editor sale del rol declarado (136-311)', () {
      expect(AppTexto.codigo.fontFamily, AppTexto.familiaCodigo);
      expect(_fuente('lib/ui/gympedia_editor.dart'),
          contains('AppTexto.codigo'));
    });
  });

  group('136-318 · higiene de composición', () {
    test('fmtMontoConMoneda une cifra y moneda con espacio duro', () {
      final s = fmtMontoConMoneda(1400, 'CUP');
      expect(s, '1400\u00A0CUP');
      expect(s.contains('\u00A0'), isTrue);
      expect(s.contains(' CUP'), isFalse,
          reason: 'sin espacio ordinario entre cifra y moneda');
    });

    test('los roles display respetan la línea natural de Barlow (1,20)',
        () {
      expect(AppTexto.display.height, greaterThanOrEqualTo(1.2));
      expect(AppTexto.displayPequeno.height,
          greaterThanOrEqualTo(1.2));
    });

    test('el héroe de Por cobrar compone con la compañera (136-309)',
        () {
      expect(_fuente('lib/ui/por_cobrar.dart'),
          contains('fmtMontoConMoneda'));
    });
  });

  group('136-317 · letra grande ×1,45: el dato no se elide', () {
    testWidgets('FilaLibro a ×1,45: el monto completo está en el árbol',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
                textScaler: TextScaler.linear(1.45)),
            child: FilaLibro(
                concepto: 'Cuota mensual', monto: '123456 CUP'),
          ),
        ),
      ));
      expect(find.text('123456 CUP'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'la imagen de nómina aísla el TextScaler del sistema (136-307-6)',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(
                textScaler: TextScaler.linear(1.45)),
            child: ImagenCierreNomina(
              mesEtiqueta: 'Octubre de 2026',
              filas: [],
              generadoEtiqueta: 'Generada hoy',
            ),
          ),
        ),
      ));
      final ctx = tester.element(find.text('IRON BODY GYM'));
      expect(MediaQuery.textScalerOf(ctx), TextScaler.noScaling,
          reason: 'la imagen de WhatsApp se compone igual en '
              'cualquier teléfono');
    });

    test('censo de sitios 136-307/308: sin elipsis en el dato', () {
      final admin = _fuente('lib/ui/admin.dart');
      expect(admin.contains('overflow: TextOverflow.ellipsis),\n          const SizedBox(height: 2),\n          Text(etiqueta'),
          isFalse);
      expect(_fuente('lib/ui/componentes.dart'),
          contains('dato de decisión: no se elide'),
          reason: 'SelectorIron: el valor elegido crece a 2 '
              'líneas (136-307-4)');
      expect(_fuente('lib/ui/suplementos.dart'),
          contains('_precioTexto(context, maxLines: 2)'),
          reason: 'la rejilla no se come el equivalente en '
              'CUP (136-308)');
      expect(_fuente('lib/ui/listas.dart'),
          contains('labelStyle: AppTexto.subtitulo'),
          reason: 'las pestañas de Listas fijan su etiqueta '
              'a la escala (136-307-3)');
    });
  });
}
