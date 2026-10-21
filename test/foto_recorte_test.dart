// Etapa 4 · F1: geometría del recorte real y tubería de archivos
// (foto_recorte.dart). Oráculos NUMÉRICOS (corrección del panel:
// nada de "cuarto central" ambiguo; cada caso calcula su
// rectángulo esperado a mano desde la fórmula de cover).
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:ironbody_gym/foto_recorte.dart';

void main() {
  group('calcularRecorteFoto', () {
    test('identidad: banda central de cover (viewport 400x300, '
        'imagen 800x800)', () {
      // s0 = max(400/800, 300/800) = 0.5; pintada 400x400 en
      // (0,-50); visible (0,0,400,300) -> (0,100)-(800,700).
      final r = calcularRecorteFoto(
        matriz: Matrix4.identity(),
        viewport: const Size(400, 300),
        imagen: const Size(800, 800),
      );
      expect(r, const Rect.fromLTRB(0, 100, 800, 700));
    });

    test('zoom 2 centrado: cuarto central de la banda visible',
        () {
      // p_pantalla = 2*p + (-200,-150): inversa mapea el viewport
      // a (100,75)-(300,225); a imagen: (200,250)-(600,550).
      final m = Matrix4.translationValues(-200, -150, 0) *
          Matrix4.diagonal3Values(2, 2, 1);
      final r = calcularRecorteFoto(
        matriz: m,
        viewport: const Size(400, 300),
        imagen: const Size(800, 800),
      );
      expect(r, const Rect.fromLTRB(200, 250, 600, 550));
    });

    test('imagen vertical en viewport horizontal', () {
      // s0 = max(400/400, 300/800) = 1; pintada 400x800 en
      // (0,-250); visible -> (0,250)-(400,550).
      final r = calcularRecorteFoto(
        matriz: Matrix4.identity(),
        viewport: const Size(400, 300),
        imagen: const Size(400, 800),
      );
      expect(r, const Rect.fromLTRB(0, 250, 400, 550));
    });

    test('pan mas alla del borde: clamp a la imagen', () {
      // p_pantalla = p + (100, 0): la region visible del hijo es
      // (-100,0)-(300,300); intersectada con la pintada y a
      // imagen: (0,100)-(600,700).
      final m = Matrix4.translationValues(100, 0, 0);
      final r = calcularRecorteFoto(
        matriz: m,
        viewport: const Size(400, 300),
        imagen: const Size(800, 800),
      );
      expect(r, const Rect.fromLTRB(0, 100, 600, 700));
    });

    test('zoom 4 centrado (el maximo del visor)', () {
      // p_pantalla = 4*p + (-600,-450): la inversa mapea el
      // viewport a (150,112.5)-(250,187.5); a imagen:
      // (300,325)-(500,475).
      final m = Matrix4.translationValues(-600, -450, 0) *
          Matrix4.diagonal3Values(4, 4, 1);
      final r = calcularRecorteFoto(
        matriz: m,
        viewport: const Size(400, 300),
        imagen: const Size(800, 800),
      );
      expect(r, const Rect.fromLTRB(300, 325, 500, 475));
    });

    test('redondeo hacia afuera con fracciones (999x999)', () {
      // s0 = 400/999; banda pintada 400x400 en (0,-50):
      // top = 50/s0 = 124.875 -> floor 124;
      // bottom = 350/s0 = 874.125 -> ceil 875.
      final r = calcularRecorteFoto(
        matriz: Matrix4.identity(),
        viewport: const Size(400, 300),
        imagen: const Size(999, 999),
      );
      expect(r, const Rect.fromLTRB(0, 124, 999, 875));
    });

    test('matriz con rotacion -> null (fuera del contrato)', () {
      // El visor no produce rotacion; si llegara una, el recorte
      // por rectangulo no seria fiel y se rechaza.
      expect(
        calcularRecorteFoto(
          matriz: Matrix4.rotationZ(0.5),
          viewport: const Size(400, 300),
          imagen: const Size(800, 800),
        ),
        isNull,
      );
    });

    test('sin interseccion -> null', () {
      final m = Matrix4.translationValues(100000, 0, 0);
      expect(
        calcularRecorteFoto(
          matriz: m,
          viewport: const Size(400, 300),
          imagen: const Size(800, 800),
        ),
        isNull,
      );
    });

    test('matriz singular o tamanos invalidos -> null', () {
      final singular = Matrix4.zero();
      expect(
        calcularRecorteFoto(
          matriz: singular,
          viewport: const Size(400, 300),
          imagen: const Size(800, 800),
        ),
        isNull,
      );
      expect(
        calcularRecorteFoto(
          matriz: Matrix4.identity(),
          viewport: Size.zero,
          imagen: const Size(800, 800),
        ),
        isNull,
      );
      expect(
        calcularRecorteFoto(
          matriz: Matrix4.identity(),
          viewport: const Size(400, 300),
          imagen: Size.zero,
        ),
        isNull,
      );
    });
  });

  group('tuberia de archivos', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('foto_recorte_');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    bool esRojo(img.Image im, int x, int y) {
      final p = im.getPixel(x, y);
      return p.r > 150 && p.g < 120;
    }

    test('aplicarRecorteFoto: dimensiones exactas del recorte',
        () async {
      final src = File('${tmp.path}/origen.jpg');
      final im = img.Image(width: 800, height: 800);
      img.fill(im, color: img.ColorRgb8(200, 40, 40));
      await src.writeAsBytes(img.encodeJpg(im));
      final out = await aplicarRecorteFoto(
        trabajo: src,
        recorte: const Rect.fromLTRB(200, 250, 600, 550),
        rutaDestino: '${tmp.path}/salida.jpg',
      );
      expect(out, isNotNull);
      final dec = img.decodeImage(await out!.readAsBytes());
      expect(dec!.width, 400);
      expect(dec.height, 300);
      expect(await File('${tmp.path}/salida.jpg.tmp').exists(),
          isFalse);
    });

    test('aplicarRecorteFoto: destino en directorio inexistente '
        '-> null y sin temporales', () async {
      final src = File('${tmp.path}/origen.jpg');
      final im = img.Image(width: 100, height: 100);
      img.fill(im, color: img.ColorRgb8(40, 200, 40));
      await src.writeAsBytes(img.encodeJpg(im));
      final destino = '${tmp.path}/no_existe/salida.jpg';
      expect(
        await aplicarRecorteFoto(
          trabajo: src,
          recorte: const Rect.fromLTRB(0, 0, 50, 50),
          rutaDestino: destino,
        ),
        isNull,
      );
      expect(await File('$destino.tmp').exists(), isFalse);
      expect(await File(destino).exists(), isFalse);
    });

    test('decodeImage directo: el decodificador JPEG aplica el '
        'EXIF y lo consume (rama que toma preparar)', () async {
      // Aislado de prepararFotoTrabajo (correccion del panel):
      // asi se demuestra QUE rama se ejecuta con JPEG, no solo
      // que el resultado final sale orientado.
      final bytes =
          await File('test/fixtures/foto_exif6.jpg').readAsBytes();
      final im = img.decodeImage(bytes)!;
      expect(im.width, 80);
      expect(im.height, 120);
      expect(im.exif.imageIfd.hasOrientation, isFalse);
      expect(esRojo(im, 70, 10), isTrue);
    });

    test('aplicarRecorteFoto: archivo corrupto -> null', () async {
      final src = File('${tmp.path}/malo.jpg');
      await src.writeAsBytes([1, 2, 3, 4, 5]);
      expect(
        await aplicarRecorteFoto(
          trabajo: src,
          recorte: const Rect.fromLTRB(0, 0, 10, 10),
          rutaDestino: '${tmp.path}/salida.jpg',
        ),
        isNull,
      );
    });

    test('prepararFotoTrabajo: sin EXIF trabaja el original',
        () async {
      final f = File('test/fixtures/foto_sin_exif.jpg');
      final t = await prepararFotoTrabajo(f,
          rutaOrientada: '${tmp.path}/orientada.jpg');
      expect(t, isNotNull);
      expect(t!.archivo.path, f.path);
      expect(t.ancho, 120);
      expect(t.alto, 80);
    });

    test('prepararFotoTrabajo: EXIF 6 orienta (dims de pantalla '
        'y parche arriba-derecha)', () async {
      // El decodificador JPEG aplica el EXIF al decodificar
      // (verificado contra PIL): las dimensiones del trabajo
      // son las de pantalla, 80x120, no las crudas 120x80.
      final f = File('test/fixtures/foto_exif6.jpg');
      final t = await prepararFotoTrabajo(f,
          rutaOrientada: '${tmp.path}/orientada.jpg');
      expect(t, isNotNull);
      // Rama del decodificador: no se crea copia; el trabajo ES
      // el archivo original (ver el test de decodeImage directo).
      expect(t!.archivo.path, f.path);
      expect(t.ancho, 80);
      expect(t.alto, 120);
      final dec = img.decodeImage(await t.archivo.readAsBytes())!;
      expect(esRojo(dec, 70, 10), isTrue,
          reason: 'el parche rojo debia quedar arriba a la derecha');
      expect(esRojo(dec, 10, 10), isFalse);
    });

    test('extremo a extremo EXIF 6: el recorte en coords de '
        'pantalla captura el parche visto', () async {
      // Lo que el usuario encuadra sobre la foto YA orientada
      // (80x120) es lo que sale: el cuadrante superior derecho
      // en pantalla contiene el parche rojo.
      final f = File('test/fixtures/foto_exif6.jpg');
      final t = await prepararFotoTrabajo(f,
          rutaOrientada: '${tmp.path}/orientada.jpg');
      final out = await aplicarRecorteFoto(
        trabajo: t!.archivo,
        recorte: const Rect.fromLTRB(40, 0, 80, 60),
        rutaDestino: '${tmp.path}/salida.jpg',
      );
      expect(out, isNotNull);
      final dec = img.decodeImage(await out!.readAsBytes())!;
      expect(dec.width, 40);
      expect(dec.height, 60);
      expect(esRojo(dec, 30, 10), isTrue);
      // La mitad inferior en pantalla es azul entera: un recorte
      // ahi no puede traer rojo (si la orientacion se aplicara
      // dos veces o al reves, apareceria).
      final out2 = await aplicarRecorteFoto(
        trabajo: t.archivo,
        recorte: const Rect.fromLTRB(0, 60, 80, 120),
        rutaDestino: '${tmp.path}/salida2.jpg',
      );
      final dec2 = img.decodeImage(await out2!.readAsBytes())!;
      expect(dec2.width, 80);
      expect(dec2.height, 60);
      expect(esRojo(dec2, 70, 30), isFalse);
      expect(esRojo(dec2, 10, 30), isFalse);
    });

    test('prepararFotoTrabajo: EXIF 2 espeja y el parche queda '
        'arriba-derecha', () async {
      final f = File('test/fixtures/foto_exif2.jpg');
      final t = await prepararFotoTrabajo(f,
          rutaOrientada: '${tmp.path}/orientada.jpg');
      expect(t, isNotNull);
      expect(t!.ancho, 120);
      expect(t.alto, 80);
      final dec = img.decodeImage(await t.archivo.readAsBytes())!;
      expect(esRojo(dec, 110, 10), isTrue);
      expect(esRojo(dec, 10, 10), isFalse);
    });

    test('prepararFotoTrabajo: archivo corrupto -> null', () async {
      final f = File('${tmp.path}/malo.jpg');
      await f.writeAsBytes([9, 9, 9]);
      expect(
        await prepararFotoTrabajo(f,
            rutaOrientada: '${tmp.path}/orientada.jpg'),
        isNull,
      );
    });
  });
}
