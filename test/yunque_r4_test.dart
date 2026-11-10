/// Yunque de cambios 1.31 — Ronda 4: contratos de las
/// correcciones de la ronda.
///
/// - R4-M3-1: la foto de atascos cuenta las lecturas
///   fallidas (error ≠ vacío también en el diagnóstico) y
///   ninguna superficie declara «todo en orden» con una
///   foto parcial.
/// - R4-M3-3: Reparar sincronización es solo del dueño
///   (misma puerta que la Salud).
/// - R4-M3-5: «Es correcto» (apagar la alarma de espejo
///   vacío) solo lo ve el dueño y deja bitácora con actor.
/// - R4-M3-6: la bitácora de la reparación nombra al actor.
/// - R4-M1-1: la reposición de la alarma tras un reinicio
///   solo reprograma el instante guardado si sigue en el
///   futuro (función pura).
/// - R4-M1-5: la cadena previa a runApp acota los pasos
///   degradables con timeout.
/// - R4-M1-8: el barrido de cierre automático sin caché de
///   horarios deja rastro en bitácora.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/diferencias_caja.dart';
import 'package:ironbody_gym/estadisticas_servicios.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/notificaciones_recordatorios.dart';
import 'package:ironbody_gym/reparar_sync.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

Future<void> _prepararDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<int> _nOps(String tipo) async {
  final d = await LocalDb.instance.db;
  final rows = await d.query('ops_queue',
      where: 'tipo=?', whereArgs: [tipo]);
  return rows.length;
}

void main() {
  group('R4-M3-1 · foto de atascos honesta', () {
    test('la foto sin fallos es completa; con fallos, parcial', () {
      expect(const FotoAtascos().fotoCompleta, isTrue);
      expect(const FotoAtascos().lecturasFallidas, 0);
      expect(
          const FotoAtascos(lecturasFallidas: 2).fotoCompleta,
          isFalse);
    });

    test('capturarAtascos cuenta y registra cada lectura rota',
        () {
      final s = _fuente('lib/reparar_sync.dart');
      expect(s, contains('fallo('));
      expect(s, contains('reparar_foto_lectura_fallo'));
      expect(s, contains('lecturasFallidas: fallidas'));
    });

    test('la pantalla no declara orden con la foto parcial',
        () {
      final s = _fuente('lib/ui/reparar_sync_screen.dart');
      expect(s, contains('hallazgos.isEmpty && foto.fotoCompleta'));
      expect(
          s, contains('r.antes.fotoCompleta && r.despues.fotoCompleta'));
      expect(s, contains('!r.despues.fotoCompleta'));
    });
  });

  group('R4-M3-3/M3-5/M3-6 · puertas y bitácora', () {
    test('Reparar sincronización exige dueño en el build', () {
      final s = _fuente('lib/ui/reparar_sync_screen.dart');
      expect(s, contains('if (!AuthService().isOwner)'));
      expect(s, contains('La reparación del sync es solo el dueño.'));
    });

    test('la reparación registra al actor en la bitácora', () {
      final s = _fuente('lib/reparar_sync.dart');
      expect(s, contains("actor=\$actor"));
      expect(s, contains('foto_fallos_antes'));
      expect(s, contains('foto_fallos_despues'));
    });

    test('«Es correcto» solo lo ve el dueño y deja bitácora',
        () {
      final s = _fuente('lib/ui/diagnostico_espejo_card.dart');
      expect(s, contains('if (esDueno) ...['));
      expect(s, contains('espejo_vacio_marcado_correcto'));
      expect(s, contains('if (!auth.isOwner) return;'));
    });
  });

  group('R4-M1-1 · reposición de alarma tras reinicio', () {
    const ahora = 1000000;
    test('instante futuro guardado: se repone ESE instante', () {
      expect(epochReprogramacionTrasReinicio('2000000', ahora),
          2000000);
      expect(epochReprogramacionTrasReinicio(' 2000000 ', ahora),
          2000000);
    });
    test('instante pasado o presente: no se repone', () {
      expect(epochReprogramacionTrasReinicio('999999', ahora),
          isNull);
      expect(epochReprogramacionTrasReinicio('1000000', ahora),
          isNull);
    });
    test('marca ausente o ilegible: no se repone', () {
      expect(epochReprogramacionTrasReinicio(null, ahora),
          isNull);
      expect(epochReprogramacionTrasReinicio('', ahora), isNull);
      expect(epochReprogramacionTrasReinicio('ayer', ahora),
          isNull);
    });
  });

  group('R4-M1-5/M1-8 · arranque y cierre automático', () {
    test('los pasos degradables del arranque llevan timeout',
        () {
      final s = _fuente('lib/main.dart');
      expect(s, contains('_pasoArranqueDegradable'));
      expect(
          s, contains("await paso().timeout(const Duration(seconds: 10))"));
      expect(s, contains("'app_log'"));
      expect(s, contains("'centinela'"));
      expect(s, contains("'tema'"));
    });

    test('sin caché de horarios, el barrido deja rastro', () {
      final s = _fuente('lib/cierre_automatico.dart');
      expect(s, contains('sin_cache_horarios'));
    });
  });

  group('R4-M7-1 · apertura de expediente sin duplicados', () {
    test('segunda apertura con la primera en cola: lanza y '
        'no encola', () async {
      await _prepararDb();
      final svc = DiferenciasCajaService.instance;
      await svc.abrir(liquidacionId: 'liq-1');
      expect(await _nOps('diferencia_abrir'), 1);
      await expectLater(
        svc.abrir(liquidacionId: 'liq-1'),
        throwsA(isA<StateError>()),
      );
      expect(await _nOps('diferencia_abrir'), 1);
    });

    test('apertura con expediente ya en el espejo: lanza',
        () async {
      await _prepararDb();
      await LocalDb.instance.upsertMirrorTexto(
          'diferencias_caja', 'e-1',
          {'id': 'e-1', 'liquidacion_id': 'liq-2',
           'estado': 'abierta'}, 1);
      await expectLater(
        DiferenciasCajaService.instance
            .abrir(liquidacionId: 'liq-2'),
        throwsA(isA<StateError>()),
      );
      expect(await _nOps('diferencia_abrir'), 0);
    });

    test('porLiquidacion ve la apertura encolada (overlay)',
        () async {
      await _prepararDb();
      await DiferenciasCajaService.instance
          .abrir(liquidacionId: 'liq-3');
      final mapa = await DiferenciasCajaService.instance
          .porLiquidacion();
      expect(mapa['liq-3'], isNotNull);
      expect(mapa['liq-3']!['pendiente_sync'], 1);
    });

    test('el botón de Arqueo lleva guarda de vuelo y catch',
        () {
      final s = _fuente('lib/ui/arqueo.dart');
      expect(s, contains('_abriendoExpediente'));
    });

    test('el diálogo Resolver lleva guarda y error visible',
        () {
      final s = _fuente('lib/ui/diferencias_caja.dart');
      expect(s, contains('_resolviendo'));
      expect(s, contains('_errorResolver'));
    });
  });

  group('R4-M4 · agregaciones de reportes', () {
    test('M4-4: el snapshot comision_monto manda en el 1B',
        () {
      final r = calcular1B(
        ventas: [
          {
            'tipo': 'dosis_sin_agua',
            'cantidad': 2,
            'precio_unitario': 600.0,
            'comision_unitaria': 50.0,
            'comision_monto': 130.0,
          },
        ],
        salidas: const [],
        botes: const [],
        boteDeLote: const {},
        movsAgua: const [],
      );
      expect(r.b['comision'], 130.0,
          reason: 'snapshot 130, no 50×2=100');
      expect(r.b['neto_dueno'],
          (r.b['margen'] as double) - 130.0);
    });

    test('M4-5: una fila sin cantidad no suma en los cortes',
        () {
      final ventas = <Map<String, dynamic>>[
        {
          'tipo': 'dosis_sin_agua',
          'precio_unitario': 600.0,
          'vendedor_id': 111,
        },
      ];
      final porVendedor = agruparPorVendedor(ventas);
      expect(porVendedor.single.unidades, 0);
      expect(porVendedor.single.ingresos, 0);
      final porPomo = agruparPorPomo(ventas);
      expect(porPomo.single.dosis, 0);
    });

    test('M4-1: la comparativa excluye Casa y anulados',
        () {
      final s = _fuente('lib/ui/comparativa_mensual.dart');
      expect(s, contains('idsCuentasCasa()'));
      expect(s, contains('pagosAnuladosEnCola()'));
      expect(s, contains('esPagoAnulado(p, anuladosCola)'));
    });

    test('M4-6/M4-8: Casa tolerante y método por contains',
        () {
      expect(_fuente('lib/ui/pagos_por_metodo.dart'),
          contains('esCasaTolerante'));
      expect(_fuente('lib/ui/pagos_por_metodo.dart'),
          contains(".contains('transfer')"));
      expect(_fuente('lib/ui/servicios_estadisticas.dart'),
          contains('esCasaTolerante'));
      expect(_fuente('lib/negocio.dart'),
          contains("casaV == '1'"));
    });
  });

  group('R4-M6/M10 · fotos y rendimiento', () {
    test('M6-2: el post-pick de la Guía avisa si lanza', () {
      final s = _fuente('lib/ui/guia_editor.dart');
      expect(s, contains('No se pudo procesar la imagen (\$e)'));
    });

    test('M6-3: el diálogo de medidas valida rango antes '
        'de cerrar', () {
      final s = _fuente('lib/ui/medidas_cliente.dart');
      expect(s, contains('_errorRango'));
      expect(s, contains('kMetricasMedicion[e.key]'));
    });

    test('M6-5: un 200 sin lista de fotos es error, no vacío',
        () {
      final s =
          _fuente('lib/ui/fotos_progreso_nube_ficha.dart');
      expect(s,
          contains("if (fotos is! List) throw Exception('respuesta')"));
      expect(s, isNot(contains('return const [];')));
    });

    test('M10-3: el estado de cuenta filtra servicios por '
        'cliente', () {
      final s = _fuente('lib/ui/estado_cuenta.dart');
      expect(s,
          contains('servicioVentasPorFiltro(clienteId: widget.clienteId)'));
    });
  });
}
