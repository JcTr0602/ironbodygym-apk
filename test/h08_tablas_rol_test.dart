/// Tests de H-08 (1.23, espejo por rol) — parte pura:
/// - tablas activas por rol: 39 admin / 27 entrenador (las 12
///   del Grupo 1 resuelto fuera; nomina_bonos NO es Grupo 1).
/// - la intersección en LocalDb.tablasConWatermarkParaRol.
/// - SyncScope.resolver intersectado con el rol.
/// - la guarda anti-espejo-vacío de clientes/suplementos.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('H-08: tablas activas por rol', () {
    test('admin/dueño: las 39 de siempre, sin cambios', () {
      final t = SyncEngine.tablasEspejoActivasParaRol(true);
      expect(t.length, 39);
      expect(t, SyncEngine.tablasEspejo);
    });

    test('el Grupo 1 resuelto es exactamente el de la decisión', () {
      expect(LocalDb.tablasProhibidasEntrenador, {
        'gastos',
        'servicio_pomos',
        'servicio_lotes',
        'servicio_compras',
        'suplemento_ajustes',
        'espejo_entregas_efectivo',
        'diferencias_caja',
        'espejo_tarifas_especiales',
        'espejo_recordatorio_config',
        'turnos_apertura',
        'turnos_cierre',
        'espejo_gympedia_borradores',
      });
      expect(LocalDb.tablasProhibidasEntrenador.length, 12);
    });

    test('entrenador: 39 − 12 = 27, sin ninguna del Grupo 1', () {
      final t = SyncEngine.tablasEspejoActivasParaRol(false);
      expect(t.length, 27);
      for (final g1 in LocalDb.tablasProhibidasEntrenador) {
        expect(t.contains(g1), isFalse, reason: g1);
      }
    });

    test('nomina_bonos NO es Grupo 1: el entrenador sí la pide', () {
      // Su corte es por fila en el servidor (Grupo 2); la
      // pantalla Mi Nómina del entrenador lee esta tabla.
      expect(LocalDb.tablasProhibidasEntrenador.contains('nomina_bonos'),
          isFalse);
      expect(SyncEngine.tablasEspejoActivasParaRol(false),
          contains('nomina_bonos'));
    });
  });

  group('H-08: watermarks por rol', () {
    test('admin: la lista histórica intacta', () {
      expect(LocalDb.tablasConWatermarkParaRol(true),
          LocalDb.tablasConWatermark);
    });

    test('entrenador: fuera el Grupo 1 que lleva watermark (11)', () {
      final admin = LocalDb.tablasConWatermarkParaRol(true);
      final ent = LocalDb.tablasConWatermarkParaRol(false);
      for (final t in ent) {
        expect(LocalDb.tablasProhibidasEntrenador.contains(t), isFalse,
            reason: t);
      }
      // 11 de las 12 del Grupo 1 están en tablasConWatermark;
      // espejo_gympedia_borradores está exenta de antemano.
      expect(admin.length - ent.length, 11);
      expect(ent, contains('nomina_bonos'));
      expect(ent, contains('clientes'));
    });
  });

  group('H-08: SyncScope.resolver por rol', () {
    test('sin rol informado: comportamiento histórico', () {
      expect(SyncScope.resolver('servicios'),
          containsAll(['servicio_lotes', 'servicio_compras', 'servicio_pomos']));
    });

    test('entrenador: el scope pierde el Grupo 1 y conserva el resto', () {
      final ent = SyncScope.resolver('servicios', esAdmin: false);
      expect(ent.contains('servicio_lotes'), isFalse);
      expect(ent.contains('servicio_compras'), isFalse);
      expect(ent.contains('servicio_pomos'), isFalse);
      expect(ent, contains('servicio_ventas'));
      expect(ent, contains('servicio_botes'));
    });

    test('admin: el scope completo', () {
      expect(SyncScope.resolver('servicios', esAdmin: true),
          SyncScope.resolver('servicios'));
    });

    test('scope de una sola tabla prohibida: vacío para el entrenador', () {
      expect(SyncScope.resolver('gastos', esAdmin: false), isEmpty);
      expect(SyncScope.resolver('gastos', esAdmin: true), ['gastos']);
    });
  });

  group('H-08: guarda anti-espejo-vacío', () {
    test('clientes/suplementos vacíos contra >10 locales: prohibida', () {
      expect(
          SyncEngine.purgaVacioProhibidaH08(
              tabla: 'clientes', idsVistos: 0, filasLocales: 11),
          isTrue);
      expect(
          SyncEngine.purgaVacioProhibidaH08(
              tabla: 'suplementos', idsVistos: 0, filasLocales: 160),
          isTrue);
    });

    test('no se dispara fuera de los casos exactos', () {
      // 10 filas no son «sustancia» suficiente.
      expect(
          SyncEngine.purgaVacioProhibidaH08(
              tabla: 'clientes', idsVistos: 0, filasLocales: 10),
          isFalse);
      // El servidor SÍ vio filas: no es el caso vacío.
      expect(
          SyncEngine.purgaVacioProhibidaH08(
              tabla: 'clientes', idsVistos: 3, filasLocales: 50),
          isFalse);
      // Otras tablas no entran en esta guarda.
      expect(
          SyncEngine.purgaVacioProhibidaH08(
              tabla: 'pagos', idsVistos: 0, filasLocales: 50),
          isFalse);
      // Sin filas locales no hay nada que proteger.
      expect(
          SyncEngine.purgaVacioProhibidaH08(
              tabla: 'clientes', idsVistos: 0, filasLocales: 0),
          isFalse);
    });
  });
}
