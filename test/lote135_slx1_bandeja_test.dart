/// LOTE SIGUIENTE 1.35 · SL-X1 · G04-4 — la Bandeja de
/// solicitudes GymPedia no pinta ids internos: el cliente
/// sin nombre en el espejo salía «Cliente 999», el autor
/// sin nombre «Entrenador 888111» y la publicada enseñaba
/// «Publicada como «articulo-secreto-123»» (el articulo_id
/// crudo). Corregido: nombre del espejo o genérico legible.
///
/// Discriminante: con esos datos sembrados, ningún texto
/// de ninguna pestaña contiene los ids (en la base salen:
/// ROJO).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/bandeja.dart';

import 'jornada_ayudas.dart';

List<String> _textos(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await jornadaSetUpAll();
  });

  testWidgets('G04-4 · Bandeja sin ids a pantalla en '
      'Pendientes, Publicadas y Borradores', (tester) async {
    await jornadaPreparar(tester);
    await jornadaSesionDueno(tester);
    await tester.runAsync(() async {
      await LocalDb.instance.upsertMirror('clientes', 7, {
        'id': 7,
        'nombre': 'Ana',
        'estado': 'activo',
      }, 1);
      await LocalDb.instance.upsertMirror('gympedia_solicitudes', 1, {
        'id': 1,
        'tema': 'Tema pendiente de prueba',
        'cliente_id': 999,
        'estado_bandeja': 'pendiente',
        'creada_en': '2026-11-15T10:00:00',
      }, 1);
      await LocalDb.instance.upsertMirror('gympedia_solicitudes', 2, {
        'id': 2,
        'tema': 'Tema publicado de prueba',
        'cliente_id': 7,
        'estado_bandeja': 'publicada',
        'articulo_id': 'articulo-secreto-123',
        'creada_en': '2026-11-13T10:00:00',
        'cerrada_en': '2026-11-14T10:00:00',
      }, 1);
      await LocalDb.instance
          .upsertMirror('espejo_gympedia_borradores', 5, {
        'id': 'bor-1',
        'titulo': 'Borrador de prueba',
        'autor_telegram_id': 888111,
        'actualizado_en': '2026-11-15T09:00:00',
      }, 1);
    });
    await tester.pumpWidget(const MaterialApp(home: BandejaScreen()));
    await jornadaDrenar(tester, vueltas: 10);

    // Pendientes: cliente desconocido → genérico, no «999».
    expect(find.text('Tema pendiente de prueba'), findsOneWidget);
    expect(_textos(tester).join('\n'), isNot(contains('999')),
        reason: 'el cliente_id no va a pantalla');
    expect(_textos(tester).join('\n'), contains('Cliente'));

    // Publicadas: sin el articulo_id crudo.
    await tester.tap(find.text('Publicadas'));
    await jornadaDrenar(tester, vueltas: 4);
    expect(find.text('Tema publicado de prueba'), findsOneWidget);
    expect(_textos(tester).join('\n'),
        isNot(contains('articulo-secreto-123')),
        reason: 'el articulo_id no va a pantalla');
    expect(_textos(tester).join('\n'), contains('Publicada'));
    expect(_textos(tester).join('\n'), contains('Ana'));

    // Borradores: autor desconocido → genérico, no «888111».
    await tester.tap(find.text('Borradores'));
    await jornadaDrenar(tester, vueltas: 4);
    expect(find.text('Borrador de prueba'), findsOneWidget);
    expect(_textos(tester).join('\n'), isNot(contains('888111')),
        reason: 'el telegram_id del autor no va a pantalla');
    expect(_textos(tester).join('\n'), contains('Entrenador'));
  });
}
