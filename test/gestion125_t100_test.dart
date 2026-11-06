/// 1.25 T100: el buscador del Panel — normalización sin
/// acentos, búsqueda por nombre y por sinónimo (los
/// tres ejemplos de la tarjeta), tokens en cualquier
/// orden y recientes que descartan ids muertos.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/panel_buscador.dart';

void main() {
  group('normalizarTextoPanel', () {
    test('minúsculas, sin acentos ni eñe, espacios colapsados', () {
      expect(normalizarTextoPanel('  Síncronización   Ñandú '),
          'sincronizacion nandu');
      expect(normalizarTextoPanel('ÁÉÍÓÚ ü'), 'aeiou u');
    });
  });

  group('buscarFuncionesPanel', () {
    List<String> ids(String q) =>
        buscarFuncionesPanel(q).map((f) => f.id).toList();

    test('consulta vacía no devuelve nada', () {
      expect(buscarFuncionesPanel(''), isEmpty);
      expect(buscarFuncionesPanel('   '), isEmpty);
    });

    test('los ejemplos de la tarjeta encuentran su función', () {
      expect(ids('quitar acceso'), contains('candado'));
      expect(ids('cobrar plus'), contains('reportes_plus'));
      expect(ids('arreglar sync'), contains('estado_sync'));
    });

    test('por título, sin acentos y en cualquier orden', () {
      expect(ids('nomina'), containsAll(['nomina', 'nomina_precalculada']));
      expect(ids('caja cierre'), contains('cierre_caja'));
      expect(ids('SINCRONIZACIÓN'), contains('cola_sync'));
    });

    test('todos los tokens deben estar: sin falsos positivos', () {
      expect(ids('precio luna'), isEmpty);
    });
  });

  group('el catálogo', () {
    test('ids únicos y con título y al menos un sinónimo', () {
      final ids = catalogoFuncionesPanel.map((f) => f.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final f in catalogoFuncionesPanel) {
        expect(f.titulo, isNotEmpty);
        expect(f.sinonimos, isNotEmpty, reason: f.id);
      }
    });

    test('cubre las cinco secciones del Centro de Precios', () {
      final ids = catalogoFuncionesPanel.map((f) => f.id).toSet();
      expect(
          ids,
          containsAll(
              ['precios_metodo', 'tipos_pago', 'tarifas', 'bancarios', 'pago_base']));
    });
  });

  group('recientesPanel', () {
    test('orden guardado y sin ids que ya no existen', () {
      final r = recientesPanel(['nomina', 'id_muerto', 'candado']);
      expect(r.map((f) => f.id).toList(), ['nomina', 'candado']);
    });
  });
}
