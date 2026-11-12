// 1.32 (Oleada 2, Fase 3 — Publicador Unificado):
// la copia local de las listas del Publicador
// (Compuerta 3: abrir con caché en 0 ms con sello de
// copia). Puros de codificación tolerante + el sello.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/publicador_cache.dart';

void main() {
  group('claves por usuario (M5-A1)', () {
    test('la clave separa usuarios y separa las dos listas', () {
      expect(claveCopiaAnuncios(111), isNot(claveCopiaAnuncios(222)));
      expect(claveCopiaAvisos(111), isNot(claveCopiaAvisos(222)));
      expect(claveCopiaAnuncios(111), isNot(claveCopiaAvisos(111)));
      // Sin sesión identificada: la cubeta 0, como
      // panel_cache.
      expect(claveCopiaAnuncios(null), claveCopiaAnuncios(0));
    });
  });

  group('CopiaAnuncios', () {
    final hora = DateTime(2026, 11, 12, 9, 41);
    final json = <String, dynamic>{
      'ok': true,
      'anuncios': [
        {'id': 3, 'titulo': 'Cerrado el lunes', 'cuerpo_md': 'Texto'},
      ],
    };

    test('codificar → decodificar conserva hora y payload', () {
      final copia = CopiaAnuncios.decodificar(
          CopiaAnuncios(hora, json).codificar());
      expect(copia, isNotNull);
      expect(copia!.hora.hour, 9);
      expect(copia.hora.minute, 41);
      expect(copia.json['ok'], true);
      final anuncios = copia.json['anuncios'] as List;
      expect(anuncios.single['titulo'], 'Cerrado el lunes');
    });

    test('degradaciones = null, nunca una excepción', () {
      expect(CopiaAnuncios.decodificar(null), isNull);
      expect(CopiaAnuncios.decodificar(''), isNull);
      expect(CopiaAnuncios.decodificar('no es json'), isNull);
      expect(CopiaAnuncios.decodificar('[]'), isNull);
      expect(CopiaAnuncios.decodificar('{"ts":"basura","datos":{}}'),
          isNull);
      expect(CopiaAnuncios.decodificar('{"ts":"2026-11-12T09:41:00"}'),
          isNull);
      expect(
          CopiaAnuncios.decodificar(
              '{"ts":"2026-11-12T09:41:00","datos":[1]}'),
          isNull);
    });
  });

  group('CopiaAvisos', () {
    final hora = DateTime(2026, 11, 12, 18, 5);
    final filas = <Map<String, dynamic>>[
      {
        'id': 7,
        'titulo': 'Horario especial',
        'cuerpo': 'El sábado abrimos a las 8.',
        'nivel': 'importante',
        'creado_ts': '2026-11-12T10:00:00',
        'fecha_fin': '2026-11-20',
      },
      {'id': 8, 'titulo': 'Otro', 'cuerpo': 'X', 'nivel': 'info'},
    ];

    test('codificar → decodificar conserva hora y filas', () {
      final copia =
          CopiaAvisos.decodificar(CopiaAvisos(hora, filas).codificar());
      expect(copia, isNotNull);
      expect(copia!.hora.hour, 18);
      expect(copia.filas, hasLength(2));
      expect(copia.filas.first['titulo'], 'Horario especial');
      expect(copia.filas.first['fecha_fin'], '2026-11-20');
    });

    test('una fila que no es mapa se salta; el resto sobrevive', () {
      final copia = CopiaAvisos.decodificar(
          '{"ts":"2026-11-12T18:05:00","datos":[{"id":1},42,{"id":2}]}');
      expect(copia, isNotNull);
      expect(copia!.filas, hasLength(2));
    });

    test('degradaciones = null', () {
      expect(CopiaAvisos.decodificar(null), isNull);
      expect(CopiaAvisos.decodificar('###'), isNull);
      expect(
          CopiaAvisos.decodificar(
              '{"ts":"2026-11-12T18:05:00","datos":{}}'),
          isNull);
    });
  });

  group('SelloCopiaPublicador', () {
    testWidgets('actualizando: dice copia guardada y su hora',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SelloCopiaPublicador(
            hora: DateTime(2026, 11, 12, 9, 41),
            actualizando: true,
          ),
        ),
      ));
      expect(find.textContaining('Copia guardada de las 09:41'),
          findsOneWidget);
      expect(find.textContaining('actualizando'), findsOneWidget);
    });

    testWidgets('sin revalidar: dice sin conexión y la hora de la copia',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SelloCopiaPublicador(
            hora: DateTime(2026, 11, 12, 18, 5),
            actualizando: false,
          ),
        ),
      ));
      expect(find.text('Sin conexión · copia de las 18:05'),
          findsOneWidget);
    });
  });
}
