/// 1.35 (UI-25) — la fuente de marca en los titulares.
///
/// Lo que se fija:
/// - Los cuatro roles grandes de `AppTexto` (display,
///   displayPequeno, metrica, tituloPagina) llevan la
///   familia embebida «Barlow Condensed»; el cuerpo NO
///   (secundario/etiqueta siguen en la del sistema).
/// - La familia está declarada en pubspec.yaml con sus
///   dos pesos y los archivos viven en assets/fonts/.
/// - La fuente REAL del paquete se carga y se usa: el
///   mismo importe pintado con `display` mide distinto
///   que con la fuente de test por defecto (si la
///   familia no cargara, Flutter caería a la de reserva
///   y el ancho sería el de los bloques de test).
/// - Con la fuente real, dos importes de dígitos
///   distintos alineados a la derecha ocupan el MISMO
///   ancho (las tabulares de la feature `tnum`, la
///   forense del archivo está en el informe de la
///   pieza: 475/498 ud. exactas por dígito).
///
/// Antes de la pieza ningún rol declaraba familia y el
/// pubspec no tenía sección fonts: todo esto fallaba.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/diseno.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('los cuatro roles grandes llevan la familia de '
      'marca y el cuerpo no', () {
    expect(AppTexto.display.fontFamily, 'Barlow Condensed');
    expect(
        AppTexto.displayPequeno.fontFamily, 'Barlow Condensed');
    expect(AppTexto.metrica.fontFamily, 'Barlow Condensed');
    expect(
        AppTexto.tituloPagina.fontFamily, 'Barlow Condensed');
    // El cuerpo sigue en la fuente del sistema.
    expect(AppTexto.secundario.fontFamily, isNull);
    expect(AppTexto.etiqueta.fontFamily, isNull);
    // Las cifras de los roles de dinero conservan la
    // feature tabular (con Barlow es real, no decorativa).
    expect(AppTexto.display.fontFeatures,
        contains(const FontFeature.tabularFigures()));
    expect(AppTexto.metrica.fontFeatures,
        contains(const FontFeature.tabularFigures()));
  });

  test('pubspec declara la familia con dos pesos y los '
      'archivos existen', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('family: Barlow Condensed'));
    expect(pubspec,
        contains('assets/fonts/BarlowCondensed-SemiBold.ttf'));
    expect(pubspec,
        contains('assets/fonts/BarlowCondensed-Bold.ttf'));
    for (final ruta in [
      'assets/fonts/BarlowCondensed-SemiBold.ttf',
      'assets/fonts/BarlowCondensed-Bold.ttf',
      'assets/fonts/OFL.txt',
    ]) {
      expect(File(ruta).existsSync(), isTrue, reason: ruta);
    }
    // El presupuesto de peso de la pieza: los dos TTF
    // juntos quedan en la franja 100-200 KB recortada.
    final total =
        File('assets/fonts/BarlowCondensed-SemiBold.ttf')
                .lengthSync() +
            File('assets/fonts/BarlowCondensed-Bold.ttf')
                .lengthSync();
    expect(total, lessThan(200 * 1024));
    expect(total, greaterThan(100 * 1024));
  });

  testWidgets('la fuente real del paquete pinta las '
      'cifras: anchos tabulares y huella propia', (t) async {
    // Cargar la familia DESDE el bundle de assets (lo
    // que el pubspec declara), como hace el motor al
    // arrancar la app.
    await t.runAsync(() async {
      final loader = FontLoader('Barlow Condensed');
      for (final ruta in [
        'assets/fonts/BarlowCondensed-SemiBold.ttf',
        'assets/fonts/BarlowCondensed-Bold.ttf',
      ]) {
        final datos = await File(ruta).readAsBytes();
        loader.addFont(Future.value(
            ByteData.view(datos.buffer)));
      }
      await loader.load();
    });

    Future<Size> medir(TextStyle estilo, String texto) async {
      await t.pumpWidget(MaterialApp(
        theme: AppTema.tacticoOscuro(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Text(texto, style: estilo),
          ),
        ),
      ));
      await t.pump();
      return t.getSize(find.text(texto));
    }

    // Huella propia: con la familia real, el importe NO
    // mide lo que mediría con la fuente de reserva (el
    // estilo de contraste se construye a mano: copyWith
    // con fontFamily null NO limpia la familia).
    const sinFamilia = TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.bold,
      letterSpacing: -0.25,
      height: 1.2,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final conMarca = await medir(AppTexto.metrica, '\$9 999');
    final sinMarca = await medir(sinFamilia, '\$9 999');
    expect((conMarca.width - sinMarca.width).abs(),
        greaterThan(1));

    // Tabulares en pantalla: dos importes con dígitos
    // distintos ocupan exactamente el mismo ancho.
    final a = await medir(AppTexto.metrica, '\$1 111');
    final b = await medir(AppTexto.metrica, '\$9 999');
    expect(a.width, b.width);
  });
}
