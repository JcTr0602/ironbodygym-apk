/// 1.27 (campo Duany 2026-11-06): el manifiesto diario
/// vigila también las 5 tablas de servicios.
///
/// El espejo de servicios de un entrenador quedó desfasado
/// (sin su fila de `servicio_pomos`: la app le decía «sin
/// pomo activo» y no podía vender dosis) y nunca se
/// autocuró porque verificarManifiesto solo comparaba 8
/// tablas, ninguna de servicios. Contrato que fijan estos
/// tests:
///
/// 1. SyncEngine.tablasManifiesto incluye las 5 tablas de
///    servicios con el nombre local EXACTO del espejo (es
///    el nombre que consume la bandera
///    `forzar_redescarga_<local>` en _download y el que
///    usa seqFilaMirror contra la BD local).
/// 2. Las 8 entradas históricas no se mueven.
/// 3. Los nombres locales son tablas que el pull baja de
///    verdad: las 5 históricas para AMBOS roles (scope
///    «servicios» de dueño y entrenador) y, desde la 1.28,
///    lotes y compras SOLO para el dueño (prohibidas del
///    entrenador por diseño: de ellas se deriva el conteo
///    de dosis que no debe ver; la fila
///    del pomo es operativa, D-01 del cierre 1.23).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('tablasManifiesto (1.27)', () {
    const esperadasServicios = {
      'sync_servicio_pomos': 'servicio_pomos',
      'sync_servicio_ventas': 'servicio_ventas',
      'sync_servicio_salidas': 'servicio_salidas',
      'sync_servicio_botes': 'servicio_botes',
      'sync_servicio_agua_movimientos': 'servicio_agua_movimientos',
      // 1.28 (M1-A2/C-R1M3-H3): lotes y compras entran en la
      // vigilancia (ya bajaban y eran purgables sin estar en
      // el manifiesto).
      'sync_servicio_lotes': 'servicio_lotes',
      'sync_servicio_compras': 'servicio_compras',
    };

    test('incluye las tablas de servicios con su nombre local', () {
      for (final e in esperadasServicios.entries) {
        expect(SyncEngine.tablasManifiesto[e.key], e.value,
            reason: 'falta ${e.key} → ${e.value} en el manifiesto');
      }
    });

    test('conserva las 8 entradas históricas intactas', () {
      const historicas = {
        'sync_clientes': 'clientes',
        'sync_pagos': 'pagos',
        'sync_pagos_diarios': 'pagos_diarios',
        'sync_gastos': 'gastos',
        'sync_suplementos': 'suplementos',
        'sync_ventas_suplementos': 'ventas_suplementos',
        'sync_categorias_suplemento': 'categorias_suplemento',
        'sync_incidencias': 'incidencias_mirror',
      };
      for (final e in historicas.entries) {
        expect(SyncEngine.tablasManifiesto[e.key], e.value,
            reason: 'la entrada histórica ${e.key} cambió');
      }
      // 1.28 (M1-B1): el mapa crece de 15 a 40 entradas —
      // la autocura cubre TODAS las tablas que baja el pull
      // (las 39 de tablasEspejo) + incidencias_mirror. Las
      // 25 nuevas se fijan una a una en
      // gestion128_m1bc_test.dart (paridad con supTablas);
      // aquí solo se actualiza el total con esa justificación.
      // 1.29 (Oleada 4, FB-09): +1 — solicitudes_relleno entra
      // en el pull y en el manifiesto (fijada en m1bc).
      // 1.30 (D2, GEN-10): +1 — sync_avisos_vistos entra en el
      // pull y en el manifiesto (fijada en manifiesto_130).
      expect(SyncEngine.tablasManifiesto.length,
          historicas.length + esperadasServicios.length + 27);
    });

    test(
        'los nombres locales de servicios son tablas que el '
        'scope «servicios» baja para dueño y entrenador', () {
      // Las 5 históricas bajan para AMBOS roles.
      const ambosRoles = {
        'servicio_pomos',
        'servicio_ventas',
        'servicio_salidas',
        'servicio_botes',
        'servicio_agua_movimientos',
      };
      // 1.28: lotes y compras bajan SOLO para el dueño. Están
      // en tablasProhibidasEntrenador a propósito (de sus
      // filas se deriva el conteo de dosis que el entrenador
      // no debe ver); su vigilancia del manifiesto aplica al
      // teléfono del dueño, y verificarManifiesto las salta
      // para el entrenador.
      const soloDueno = {'servicio_lotes', 'servicio_compras'};
      final scopeDueno =
          SyncScope.resolver('servicios', esAdmin: true).toSet();
      final scopeEntrenador =
          SyncScope.resolver('servicios', esAdmin: false).toSet();
      for (final local in ambosRoles) {
        expect(scopeDueno, contains(local),
            reason: '$local no baja en el scope del dueño: la '
                'bandera forzar_redescarga_$local nunca se '
                'consumiría en su pull');
        expect(scopeEntrenador, contains(local),
            reason: '$local no baja en el scope del entrenador: '
                'es justo el espejo que hay que autocurar');
      }
      for (final local in soloDueno) {
        expect(scopeDueno, contains(local),
            reason: '$local no baja en el scope del dueño: la '
                'bandera forzar_redescarga_$local nunca se '
                'consumiría en su pull');
        expect(scopeEntrenador, isNot(contains(local)),
            reason: '$local NO debe bajar al entrenador: es '
                'tabla prohibida por diseño (conteo de dosis)');
        expect(LocalDb.tablasProhibidasEntrenador, contains(local),
            reason: '$local debe seguir en la lista de '
                'prohibidas del entrenador');
      }
    });
  });
}
