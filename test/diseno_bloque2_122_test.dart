/// 1.22 Diseño Bloque 2 Paso 2: cabecera nueva de la ficha
/// (B1) y la foto que viaja (T2, ajustes de Argón: tag con
/// origen, builders del Hero en AvatarCliente).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';

void main() {
  test('T2: los tags llevan el origen (esquema de Argón)', () {
    expect(tagHeroCliente('buscar', 42), 'hero_buscar_cliente_42');
    expect(tagHeroCliente('listas', 7), 'hero_listas_cliente_7');
    expect(tagHeroSuplemento(3), 'hero_suplemento_3');
  });

  testWidgets('T2: AvatarCliente con heroTag monta el Hero',
      (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AvatarCliente(
          nombre: 'Ana Pérez',
          tamano: TamanoAvatar.l,
          heroTag: 'hero_buscar_cliente_5',
        ),
      ),
    ));
    final hero = t.widget<Hero>(find.byType(Hero));
    expect(hero.tag, 'hero_buscar_cliente_5');
    expect(hero.flightShuttleBuilder, isNotNull);
    expect(hero.placeholderBuilder, isNotNull);
    // Sin foto: iniciales, como siempre.
    expect(find.text('AP'), findsOneWidget);
  });

  testWidgets('Hotfix campo: el avatar decodifica SIN '
      'deformar (un solo eje: ancho; el alto queda libre)',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AvatarCliente(
          nombre: 'Ana Pérez',
          foto: File('/sin-foto-real.png'),
          tamano: TamanoAvatar.l,
          heroTag: 'hero_buscar_cliente_5',
        ),
      ),
    ));
    final imagen = t.widget<Image>(find.byType(Image));
    final prov = imagen.image as ResizeImage;
    // Con ancho Y alto a la vez, ResizeImage (policy exact)
    // ESTIRA la foto al cuadrado: el defecto reportado. Con
    // un solo eje el aspecto se conserva y cover recorta.
    expect(prov.width, 720);
    expect(prov.height, isNull);
  });

  testWidgets('B1: CabeceraFicha — foto a la izquierda, '
      'nombre, insignia y cambiar foto', (t) async {
    var cambioFoto = false;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CabeceraFicha(
          nombre: 'Luis Gómez',
          foto: null,
          colorMarco: Colors.green,
          esCasa: false,
          dias: 12,
          heroTag: null,
          onFotoTap: null,
          onCambiarFoto: () => cambioFoto = true,
        ),
      ),
    ));
    expect(find.text('Luis Gómez'), findsOneWidget);
    expect(find.text('Cambiar foto'), findsOneWidget);
    await t.tap(find.text('Cambiar foto'));
    expect(cambioFoto, isTrue);
  });

  testWidgets('B1: CabeceraFicha de Casa pinta el dorado '
      'y no la insignia de días', (t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: CabeceraFicha(
          nombre: 'Janay',
          foto: null,
          colorMarco: Colors.amber,
          esCasa: true,
          dias: -5,
          heroTag: null,
          onFotoTap: null,
          onCambiarFoto: _vacio,
        ),
      ),
    ));
    expect(find.text('Cuenta a la Casa'), findsOneWidget);
    expect(find.byType(BadgeEstado), findsNothing);
  });
}

void _vacio() {}
