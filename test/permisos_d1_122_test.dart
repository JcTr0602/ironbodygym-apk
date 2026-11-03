/// Autoauditoría 1.22 #2 — permisos (defensa en profundidad)
/// y D-1:
/// P-1: panel de permisos con guarda de dueño también en los
/// métodos, no solo en build.
/// P-2: vista previa del cliente (declarada «solo dueño»)
/// gana su guarda fail-closed.
/// P-3: el editor de planes revalida el permiso al guardar y
/// las acciones compartidas de acceso guardan dueño dentro.
/// D-1: una medición con created_at corrupto ya no «nace
/// ahora» (quedaba primera y editable 24 h): cae a la época.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/pestana_progreso.dart';

String _leer(String ruta) => File(ruta).readAsStringSync();

int _ocurrencias(String texto, String patron) =>
    patron.allMatches(texto).length;

void main() {
  group('D-1: Medicion.fromJson con fecha corrupta', () {
    test('created_at vacío o ilegible cae a la época, no a ahora',
        () {
      final vacia = Medicion.fromJson(const {
        'id': 1,
        'cliente_id': '7',
        'peso_kg': 80,
        'created_at': '',
      });
      // Instante cero exacto (en hora local habanera el año
      // calendario es 1969: se aserta el instante, no el año).
      expect(vacia.createdAt.millisecondsSinceEpoch, 0);
      final ilegible = Medicion.fromJson(const {
        'id': 2,
        'cliente_id': '7',
        'peso_kg': 80,
        'created_at': 'no-es-fecha',
      });
      expect(ilegible.createdAt.millisecondsSinceEpoch, 0);
      final buena = Medicion.fromJson(const {
        'id': 3,
        'cliente_id': '7',
        'peso_kg': 80,
        'created_at': '2026-11-02T10:30:00',
      });
      expect(buena.createdAt.year, 2026);
      expect(buena.createdAt.month, 11);
    });
  });

  group('Guardas de permisos (código)', () {
    test('P-1: panel_permisos guarda dueño en build y métodos',
        () {
      final src = _leer('lib/ui/panel_permisos.dart');
      // build + _cargar + _releerEntrenador + _togglePermiso +
      // _toggleActivo = 5 apariciones de la guarda.
      expect(_ocurrencias(src, 'if (!AuthService().isOwner)'),
          greaterThanOrEqualTo(5));
    });
    test('P-2: vista_previa_cliente tiene guarda fail-closed',
        () {
      final src = _leer('lib/ui/vista_previa_cliente.dart');
      expect(
          src.contains('Solo el dueño puede ver la vista previa'),
          isTrue);
      expect(src.contains('if (!AuthService().isOwner)'), isTrue);
    });
    test('P-3: editor de planes revalida al guardar', () {
      final src = _leer('lib/ui/editor_plan_nutricional.dart');
      final cuerpo =
          src.substring(src.indexOf('Future<void> _guardar()'));
      expect(cuerpo.contains('PermisosEntrenador().canEditNutrition'),
          isTrue);
      expect(cuerpo.contains('AuthService().isOwner'), isTrue);
    });
    test('P-3: acciones de acceso comparten guarda de dueño',
        () {
      final src = _leer('lib/ui/acciones_acceso.dart');
      // Definición del helper + 4 funciones que lo invocan.
      expect(_ocurrencias(src, '_soloDueno'), greaterThanOrEqualTo(5));
    });
  });
}
