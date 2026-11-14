/// 1.34 · CARRIL ARTE — contrato de alfa de las ilustraciones
/// de estados vacíos.
///
/// La orden de Jc: ninguna ilustración generada puede volver
/// a aparecer con el fondo cuadrado horneado de la lámina.
/// Este test lo fija en código, al estilo del contrato de
/// alfa de Clientes: decodifica cada spot servido y afirma
/// alfa REAL (esquinas transparentes, fracción transparente
/// y fracción opaca sanas). Contra los JPG de la base falla
/// (el archivo ni es WebP ni tiene canal alfa); con los WebP
/// procesados pasa.
///
/// Las 12 quedan fijadas aquí: las 9 del carril de arte y
/// pomo, pastel y megafono, que en la lámina eran escenas
/// de objeto sobre mueble sin separación limpia y se
/// cerraron REGENERADAS como spots nativos (pieza
/// 134-arte-regen). Ningún vacio_* vive ya en JPG.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Las 12 ilustraciones, todas WebP con alfa (mismo nombre
/// base): 9 convertidas por el carril de arte y 3 regeneradas
/// (pomo, pastel, megafono) por la pieza 134-arte-regen.
const _spots = [
  'papelera',
  'caja',
  'escudo',
  'sobre',
  'lupa',
  'recepcion',
  'reloj',
  'calendario',
  'cable',
  'pomo',
  'pastel',
  'megafono',
];

Future<ui.Image> _decodificar(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  return frame.image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final n in _spots) {
    test('vacio_$n: WebP con alfa real, esquinas transparentes',
        () async {
      final f = File('assets/vacio_$n.webp');
      expect(f.existsSync(), isTrue,
          reason: 'falta assets/vacio_$n.webp');
      final bytes = await f.readAsBytes();
      // Firma del contenedor: RIFF + WEBP.
      expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(bytes.sublist(8, 12)), 'WEBP');

      final img = await _decodificar(bytes);
      final datos = await img.toByteData(
          format: ui.ImageByteFormat.rawRgba);
      expect(datos, isNotNull);
      final px = datos!;
      int alfaEn(int x, int y) =>
          px.getUint8((y * img.width + x) * 4 + 3);

      // Las cuatro esquinas, transparentes: nada del fondo
      // horneado puede sobrevivir en el borde del spot.
      for (final (x, y) in [
        (0, 0),
        (img.width - 1, 0),
        (0, img.height - 1),
        (img.width - 1, img.height - 1),
      ]) {
        expect(alfaEn(x, y), lessThanOrEqualTo(16),
            reason: 'esquina ($x,$y) de vacio_$n con alfa '
                '${alfaEn(x, y)}: ¿volvió el fondo horneado?');
      }

      // Fracciones sanas: hay transparencia de verdad
      // (el exterior del motivo) y motivo opaco de verdad
      // (no es un velo semitransparente entero).
      var transparentes = 0;
      var opacos = 0;
      final total = img.width * img.height;
      for (var i = 3; i < px.lengthInBytes; i += 4) {
        final a = px.getUint8(i);
        if (a < 12) transparentes++;
        if (a > 250) opacos++;
      }
      expect(transparentes / total, greaterThan(0.15),
          reason: 'vacio_$n apenas tiene transparencia');
      expect(opacos / total, greaterThan(0.15),
          reason: 'vacio_$n apenas tiene motivo opaco');
    });
  }

  test('pubspec y lib/ no referencian los JPG convertidos', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    for (final n in _spots) {
      expect(pubspec, contains('assets/vacio_$n.webp'),
          reason: 'pubspec sin vacio_$n.webp');
      expect(pubspec, isNot(contains('assets/vacio_$n.jpg')),
          reason: 'pubspec aún declara vacio_$n.jpg');
    }
    final dart = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final f in dart) {
      final fuente = f.readAsStringSync();
      for (final n in _spots) {
        expect(fuente, isNot(contains('assets/vacio_$n.jpg')),
            reason: '${f.path} aún referencia vacio_$n.jpg');
      }
    }
  });
}
