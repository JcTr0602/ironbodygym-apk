/// SL-6 · catálogo de Suplementos:
/// - G05-9: dar de alta vive en UN solo sitio permanente
///   (la cabecera «Nuevo»); no hay botón flotante duplicado.
/// - G05-10: la promo va PLEGADA tras el botón
///   «Promo · activa/inactiva»; su interruptor no ocupa
///   espacio permanente y aparece al desplegar.
/// - G05-13 (fuente): fuera el placeholder a mano
///   _PlaceholderFoto de la rejilla; manda el único
///   PlaceholderSuplemento de la casa.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/suplementos.dart';

import 'jornada_ayudas.dart';

Future<void> _sembrarUno() async {
  await LocalDb.instance.upsertMirror('suplementos', 1, {
    'id': 1,
    'nombre': 'Producto Catálogo',
    'precio_oficial': 1000,
    'stock': 5,
    'moneda': 'CUP',
    'activo': 1,
  }, 1);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
    await jornadaCargarRoboto();
  });

  testWidgets(
      'G05-9: un solo acceso permanente a dar de alta '
      '(cabecera) y ningún flotante', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(_sembrarUno);
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(
      home: SuplementosScreen(),
    ));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(tester, find.text('Producto Catálogo'));
    expect(find.byType(FloatingActionButton), findsNothing,
        reason: 'sin segundo sitio flotante para el alta');
    expect(find.text('Nuevo'), findsOneWidget,
        reason: 'el alta vive en la cabecera, un solo sitio');
  });

  testWidgets(
      'G05-10: la promo nace plegada tras «Promo · activa» '
      'y su interruptor sale al desplegar', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(() async {
      await _sembrarUno();
      await LocalDb.instance
          .setAjustes({'promo_suplementos': 1});
    });
    jornadaViewport(tester);
    await tester.pumpWidget(const MaterialApp(
      home: SuplementosScreen(),
    ));
    await jornadaDrenar(tester, vueltas: 8);
    await jornadaEsperar(tester, find.text('Producto Catálogo'));
    expect(find.text('Promo · activa'), findsOneWidget,
        reason: 'el botón resume el estado de la promo');
    expect(find.byType(Switch), findsNothing,
        reason: 'G05-10: plegada, la banda no ocupa su '
            'espacio permanente (sin interruptor a la vista)');
    await tester.tap(find.text('Promo · activa'));
    await jornadaDrenar(tester, vueltas: 4);
    expect(find.byType(Switch), findsOneWidget,
        reason: 'desplegando, la promo está con su '
            'interruptor');
  });

  test('G05-13 (fuente): la rejilla ya no usa el '
      'placeholder a mano de gradiente', () {
    final sup =
        File('lib/ui/suplementos.dart').readAsStringSync();
    expect(sup, isNot(contains('_PlaceholderFoto')),
        reason: 'una sola marca de foto genérica: '
            'PlaceholderSuplemento');
    expect(sup, contains('PlaceholderSuplemento('));
    final centro =
        File('lib/ui/centro_compras.dart').readAsStringSync();
    expect(centro, contains('PlaceholderSuplemento('),
        reason: 'el Extracto también usa la marca única '
            'cuando el producto no tiene foto');

    // F02-HE (z21_sl6-4): lo anterior se satisfacía con un
    // renombre o un comentario. Se acota la ventana al
    // CUERPO de cada función/clase que pinta la foto y se
    // exige la llamada COMPLETA con sus argumentos, en el
    // sitio donde el comportamiento ocurre (el runtimeType
    // en la rejilla no es asertable por el arnés: sin foto
    // propia la rejilla pinta la foto genérica por asset
    // por diseño y el placeholder solo vive en las ramas
    // de error/sin archivo de esos cuerpos).
    String ventana(String fuente, String desde, String hasta) {
      final i = fuente.indexOf(desde);
      expect(i, greaterThanOrEqualTo(0),
          reason: 'existe el cuerpo de $desde');
      final j = fuente.indexOf(hasta, i + desde.length);
      expect(j, greaterThan(i),
          reason: 'el cuerpo de $desde cierra en $hasta');
      return fuente.substring(i, j);
    }

    int llamadas(String texto, String llamada) =>
        llamada.allMatches(texto).length;

    // La foto de la rejilla/lista: AMBOS errorBuilder (foto
    // local y foto genérica) y el respaldo final sin foto
    // construyen la marca compartida con sus argumentos.
    final fotoSup = ventana(sup, 'class _FotoSuplementoState',
        'class _ShimmerFoto');
    expect(
        llamadas(fotoSup,
            'PlaceholderSuplemento(alto: null, radio: 0)'),
        greaterThanOrEqualTo(3),
        reason: 'los dos errorBuilder y el respaldo final '
            'de _FotoSuplementoState llaman a la marca '
            'única con sus argumentos, no la nombran');
    // La mini superior: su _sinFoto ES la marca compartida
    // y su build la USA al no haber archivo (no basta con
    // que el identificador exista en el archivo).
    final miniTop = ventana(sup, 'class _FotoMiniTopState',
        'class _FotoSuplemento extends');
    expect(miniTop,
        contains('const PlaceholderSuplemento();'),
        reason: '_sinFoto de la mini es la marca de la casa');
    expect(miniTop, contains('return _sinFoto(ctx);'),
        reason: 'la mini usa _sinFoto cuando no hay foto');
    expect(miniTop, contains('=> _sinFoto(ctx)'),
        reason: 'y también como errorBuilder de la foto');
    // El Extracto: en el cuerpo de su foto, el sin-foto es
    // la marca única con SU tamaño (40/radio sm/icono 20).
    final fotoExtracto = ventana(
        centro, 'class _FotoExtractoState', '\n}\n');
    final extractoPlano =
        fotoExtracto.replaceAll(RegExp(r'\s+'), ' ');
    expect(
        extractoPlano,
        contains('PlaceholderSuplemento( alto: 40, '
            'radio: AppRadio.sm, tamanoIcono: 20)'),
        reason: 'el sin-foto del Extracto construye la '
            'marca única con sus argumentos completos');
  });
}
