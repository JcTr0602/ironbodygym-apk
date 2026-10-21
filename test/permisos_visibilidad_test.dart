// Permisos 2+3: candados de visibilidad de la UI
// (can_ver_cifras / can_ver_todos_pagos). La regla de
// arranque: sin foto de permisos cargada no se restringe.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/permisos_visibilidad.dart';

void main() {
  group('cifrasVisibles', () {
    test('el dueño siempre ve', () {
      expect(
          cifrasVisibles(
              esDueno: true, permisosCargados: true, canVerCifras: false),
          isTrue);
    });
    test('sin foto cargada: fail-closed (panel 2026-10-21)', () {
      expect(
          cifrasVisibles(
              esDueno: false,
              permisosCargados: false,
              canVerCifras: false),
          isFalse);
      // Ni alegando la clave: sin foto no hay concesión.
      expect(
          cifrasVisibles(
              esDueno: false,
              permisosCargados: false,
              canVerCifras: true),
          isFalse);
    });
    test('con foto, la clave manda', () {
      expect(
          cifrasVisibles(
              esDueno: false, permisosCargados: true, canVerCifras: true),
          isTrue);
      expect(
          cifrasVisibles(
              esDueno: false,
              permisosCargados: true,
              canVerCifras: false),
          isFalse);
    });
  });

  group('pagosSinRestriccion', () {
    test('misma matriz que cifras', () {
      expect(
          pagosSinRestriccion(
              esDueno: false,
              permisosCargados: true,
              canVerTodosPagos: false),
          isFalse);
      expect(
          pagosSinRestriccion(
              esDueno: false,
              permisosCargados: false,
              canVerTodosPagos: false),
          isFalse);
      expect(
          pagosSinRestriccion(
              esDueno: true,
              permisosCargados: true,
              canVerTodosPagos: false),
          isTrue);
    });
  });

  group('filtrarPagosPorEntrenador', () {
    final pagos = <Map<String, dynamic>>[
      {'id': 1, 'telegram_user_id': 111},
      {'id': 2, 'telegram_user_id': '222'}, // texto: también vale
      {'id': 3, 'telegram_user_id': 111},
      {'id': 4}, // sin atribución: fuera
      {'id': 5, 'telegram_user_id': null},
    ];
    test('deja solo los propios, normalizando texto/número', () {
      expect(filtrarPagosPorEntrenador(pagos, 111).map((p) => p['id']),
          [1, 3]);
      expect(filtrarPagosPorEntrenador(pagos, 222).map((p) => p['id']),
          [2]);
    });
    test('sin telegram id no se atribuye ninguno', () {
      expect(filtrarPagosPorEntrenador(pagos, null), isEmpty);
    });
    test('la atribución es exacta: 111.9 no es el usuario 111 '
        '(panel 2026-10-21)', () {
      final raros = <Map<String, dynamic>>[
        {'id': 1, 'telegram_user_id': 111.9},
        {'id': 2, 'telegram_user_id': 111.0},
        {'id': 3, 'telegram_user_id': ' 111 '},
      ];
      expect(filtrarPagosPorEntrenador(raros, 111).map((p) => p['id']),
          [2, 3]);
    });
  });
}
