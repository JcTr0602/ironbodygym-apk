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
/// 3. Los 5 nombres locales son tablas que el pull baja
///    de verdad para AMBOS roles: están en el scope
///    «servicios» resuelto para dueño y para entrenador
///    (ninguna es tabla prohibida del entrenador: la fila
///    del pomo es operativa, D-01 del cierre 1.23).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('tablasManifiesto (1.27)', () {
    const esperadasServicios = {
      'sync_servicio_pomos': 'servicio_pomos',
      'sync_servicio_ventas': 'servicio_ventas',
      'sync_servicio_salidas': 'servicio_salidas',
      'sync_servicio_botes': 'servicio_botes',
      'sync_servicio_agua_movimientos': 'servicio_agua_movimientos',
    };

    test('incluye las 5 tablas de servicios con su nombre local', () {
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
      expect(SyncEngine.tablasManifiesto.length,
          historicas.length + esperadasServicios.length);
    });

    test(
        'los nombres locales de servicios son tablas que el '
        'scope «servicios» baja para dueño y entrenador', () {
      final locales = esperadasServicios.values.toSet();
      final scopeDueno =
          SyncScope.resolver('servicios', esAdmin: true).toSet();
      final scopeEntrenador =
          SyncScope.resolver('servicios', esAdmin: false).toSet();
      for (final local in locales) {
        expect(scopeDueno, contains(local),
            reason: '$local no baja en el scope del dueño: la '
                'bandera forzar_redescarga_$local nunca se '
                'consumiría en su pull');
        expect(scopeEntrenador, contains(local),
            reason: '$local no baja en el scope del entrenador: '
                'es justo el espejo que hay que autocurar');
      }
    });
  });
}
