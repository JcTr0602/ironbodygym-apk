/// Gestión 1.30 — Oleada 1: el manifiesto deja de mentir por
/// omisión (plan §2.4: tests de la app).
///
/// - Inventario: `SyncEngine.tablasManifiesto` (las 43 que pide
///   la app) ⊆ allowlist de la RPC `sync_manifiesto` (44
///   entradas: las 40 de la Oleada 1 del servidor, fijadas
///   contra la lista del plan §2.1/§2.2 y contra la definición
///   aplicada el 2026-11-08, + las 2 que publicó la ventana
///   §10 — GEN-07: `sync_servicio_lotes` y
///   `sync_servicio_compras` — + la de GEN-10 en la oleada D2:
///   `sync_avisos_vistos`, solo-dueño, + la de la Congelación
///   0.5: `sync_cliente_congelaciones`, solo-dueño con
///   denegación específica). Si la RPC pierde una tabla,
///   este test lo canta antes de que un teléfono la deje
///   «sin verificar» para siempre.
/// - Paridad inversa con el pull: toda tabla del manifiesto
///   tiene espejo local real (sin entradas fantasma).
/// - Llaves especiales: las dos tablas sin columna `id` en
///   Supabase riman con el lector local por su llave real —
///   sync_entregas_efectivo → op_uuid (el conversor del pull
///   guarda la fila local con id = op_uuid) y
///   sync_permisos_bandeja → telegram_id (la fila local nace
///   con id = telegram_id). La RPC devuelve rid con esa misma
///   llave desde la Oleada 1; si alguien la cambia a `id`, la
///   tabla divergiría en cada pasada.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('Oleada 1 · inventario del manifiesto', () {
    // Allowlist de la RPC: las 28 previas + las 12 del plan
    // §2.2 (Oleada 1) + las 2 de la ventana §10 / GEN-07
    // (servicio_lotes y servicio_compras, que el puente no
    // publicaba y la ventana §10 publicó). Fijada por test de
    // fuente contra la definición aplicada (ver
    // cola-123/gestion/manifiesto_130_sql/).
    const allowlistRpc = <String>{
      'sync_clientes',
      'sync_pagos',
      'sync_pagos_diarios',
      'sync_gastos',
      'sync_suplementos',
      'sync_ventas_suplementos',
      'sync_categorias_suplemento',
      'sync_incidencias',
      'sync_borrados',
      'sync_servicio_pomos',
      'sync_servicio_ventas',
      'sync_servicio_salidas',
      'sync_servicio_botes',
      'sync_servicio_agua_movimientos',
      // Las 2 de la ventana §10 (GEN-07): el puente pasó a
      // publicarlas y la RPC las admite en el manifiesto.
      'sync_servicio_lotes',
      'sync_servicio_compras',
      'sync_gympedia',
      'sync_gympedia_borradores',
      'sync_gympedia_solicitudes',
      'sync_guia_ejercicios',
      'sync_equipos_guia',
      'sync_reservas',
      'sync_cliente_mediciones',
      'sync_turnos_apertura',
      'sync_suplemento_ajustes',
      'sync_diferencias_caja',
      'sync_adelantos',
      'sync_nomina_liquidada',
      'sync_nomina_liquidada_snapshot',
      'sync_nomina_confirmaciones',
      // Las 12 que entran con la Oleada 1 (plan §2.2):
      'sync_turnos_cierre',
      'sync_liquidaciones_caja',
      'sync_acceso_bloqueos',
      'sync_incidencias_sync',
      'sync_permisos_bandeja',
      'sync_avisos_entrenadores',
      // GEN-10 (D2): vistos de avisos, solo-dueño en la RPC.
      'sync_avisos_vistos',
      // Congelación 0.5: congelaciones de mensualidad,
      // solo-dueño en la RPC (los motivos no bajan al staff).
      'sync_cliente_congelaciones',
      'sync_solicitudes_adelanto',
      'sync_solicitudes_relleno',
      'sync_nomina_bonos',
      'sync_tarifas_especiales',
      'sync_entregas_efectivo',
      'sync_recordatorio_config',
    };

    test('la app pide 43 y la RPC permite 44: las 43 pedidas '
        'están dentro y la única de más es sync_borrados', () {
      expect(SyncEngine.tablasManifiesto.length, 43);
      expect(allowlistRpc.length, 44);
      // servicio_lotes y servicio_compras YA existen como
      // tablas sync_* en Supabase: la ventana §10 (GEN-07) las
      // publicó en el puente y entraron en el allowlist de la
      // RPC, cerrando el «sin verificar por diseño» (M1-A2)
      // que este test fijaba antes. La app las pedía desde la
      // Oleada 1: ahora la diferencia pedidas − permitidas es
      // VACÍA y las 43 verifican de verdad.
      final diferencia =
          SyncEngine.tablasManifiesto.keys.toSet().difference(allowlistRpc);
      expect(diferencia, isEmpty,
          reason: 'toda tabla que la app pide debe estar en el '
              'allowlist de la RPC (contrato tras GEN-10: '
              '43 pedidas ⊆ 44 permitidas)');
      // La RPC además cubre sync_borrados: la app la verifica
      // por su propio camino (el manifiesto de borrados viaja
      // en la misma RPC, fuera de tablasManifiesto). Es la
      // única entrada del allowlist sin fila en el mapa.
      expect(allowlistRpc.difference(
          SyncEngine.tablasManifiesto.keys.toSet()), {'sync_borrados'},
          reason: 'allowlist y manifiesto riman salvo '
              'sync_borrados, que la app pide por otro camino');
    });

    test('las 12 del plan §2.2 están pedidas por la app con su '
        'espejo local correcto', () {
      const esperadas = <String, String>{
        'sync_turnos_cierre': 'turnos_cierre',
        'sync_liquidaciones_caja': 'liquidaciones_caja',
        'sync_acceso_bloqueos': 'acceso_bloqueos',
        'sync_incidencias_sync': 'incidencias_sync',
        'sync_permisos_bandeja': 'permisos_bandeja',
        'sync_avisos_entrenadores': 'avisos_entrenadores',
        'sync_solicitudes_adelanto': 'solicitudes_adelanto',
        'sync_solicitudes_relleno': 'solicitudes_relleno',
        'sync_nomina_bonos': 'nomina_bonos',
        'sync_tarifas_especiales': 'espejo_tarifas_especiales',
        'sync_entregas_efectivo': 'espejo_entregas_efectivo',
        'sync_recordatorio_config': 'espejo_recordatorio_config',
      };
      esperadas.forEach((sup, local) {
        expect(SyncEngine.tablasManifiesto[sup], local,
            reason: '$sup debe vigilar el espejo $local');
        expect(allowlistRpc, contains(sup));
      });
    });

    test('llaves especiales sin columna id: el conversor del '
        'pull guarda la fila local con la llave de la RPC '
        '(fuente)', () {
      final fuente = File('lib/sync.dart').readAsStringSync();
      // entregas: id local = op_uuid (la RPC devuelve
      // rid = op_uuid desde la Oleada 1).
      expect(
          fuente,
          contains("final id = tabla == 'espejo_entregas_efectivo'\n"
              "          ? '\${m['op_uuid'] ?? ''}'"),
          reason: 'si el conversor dejara de guardar op_uuid '
              'como id local, el manifiesto de entregas '
              'divergiría en cada pasada');
      // permisos: el select del pull pide telegram_id como
      // primera columna (la fila local nace con id =
      // telegram_id; la RPC devuelve rid = telegram_id::text).
      expect(fuente,
          contains("'permisos_bandeja' => 'telegram_id,otorgado_en,sync_seq'"),
          reason: 'el manifiesto de permisos compara contra '
              'ids locales = telegram_id');
    });

    test('la RPC y sus timeouts: la llamada del manifiesto '
        'sigue con su timeout propio de 12 s (fuente)', () {
      final fuente = File('lib/sync.dart').readAsStringSync();
      final i = fuente.indexOf("Uri.parse('\$_base/rest/v1/rpc/sync_manifiesto')");
      expect(i, isNonNegative);
      final seg = fuente.substring(i, i + 900);
      expect(seg, contains('timeout: const Duration(seconds: 12)'),
          reason: 'el manifiesto es una lectura de hashes en '
              'serie: su timeout propio es parte del contrato '
              'anti-bucle (cortacircuitos CorteManifiesto)');
    });
  });
}
