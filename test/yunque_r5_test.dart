/// Yunque de cambios 1.31 — Ronda 5: contratos de las
/// correcciones de la ronda.
///
/// - R5-M4-1: el predicado de fiado pendiente de «Por
///   cobrar» usa la forma tolerante canónica (1 o true):
///   un `es_fiado` bool no puede esconder una deuda de la
///   superficie de cobro.
/// - R5-M1-1/M1-2/M1-3/M1-4/M1-6: la campaña filtra por el
///   estado canónico, deduplica por cliente/teléfono, no
///   disfraza «sin verificar» de «sin destinatarios», tiene
///   defensa propia de dueño (campaña y hub) y el buzón
///   distingue «verificado» de «aún sin verificar».
/// - R5-M3-1…M3-5: las hojas de exportación aplican los
///   filtros canónicos (Casa, anulados, cortesías, fiados),
///   los tres escapes CSV neutralizan fórmulas, el
///   exportador duplicado avisa sus fallos y el texto del
///   paquete no anuncia una nómina que no va.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/estadisticas_servicios.dart';
import 'package:ironbody_gym/ui/cuentas_por_cobrar.dart';
import 'package:ironbody_gym/ui/exportar_excel.dart';

String _fuente(String ruta) => File(ruta).readAsStringSync();

void main() {
  group('R5-M4-1 · esFiadoPendienteVenta (forma tolerante)', () {
    test('es_fiado numérico 1 sin saldar → pendiente', () {
      expect(esFiadoPendienteVenta({'es_fiado': 1}), isTrue);
      expect(
          esFiadoPendienteVenta({'es_fiado': 1, 'fiado_saldado': 0}),
          isTrue);
    });

    test('es_fiado bool true sin saldar → pendiente (el caso cazado)',
        () {
      expect(esFiadoPendienteVenta({'es_fiado': true}), isTrue);
    });

    test('saldado en forma numérica o bool → fuera', () {
      expect(
          esFiadoPendienteVenta({'es_fiado': 1, 'fiado_saldado': 1}),
          isFalse);
      expect(
          esFiadoPendienteVenta(
              {'es_fiado': true, 'fiado_saldado': true}),
          isFalse);
      expect(
          esFiadoPendienteVenta({'es_fiado': 1, 'fiado_saldado': true}),
          isFalse);
    });

    test('sin flag de fiado → fuera, en cualquier forma', () {
      expect(esFiadoPendienteVenta({'es_fiado': 0}), isFalse);
      expect(esFiadoPendienteVenta({'es_fiado': false}), isFalse);
      expect(esFiadoPendienteVenta(const {}), isFalse);
    });
  });

  group('R5-M3 · exportaciones con los filtros canónicos', () {
    test('pagoExportable: el pago normal viaja', () {
      expect(
          pagoExportable(
              {'metodo': 'efectivo', 'cliente_id': 5, 'id': 9},
              const {},
              const {}),
          isTrue);
    });

    test('pagoExportable: Casa fuera (marca propia y conjunto)', () {
      expect(
          pagoExportable({'metodo': 'efectivo', 'casa': 1}, const {},
              const {}),
          isFalse);
      expect(
          pagoExportable({'metodo': 'efectivo', 'casa': true},
              const {}, const {}),
          isFalse);
      expect(
          pagoExportable(
              {'metodo': 'transferencia', 'cliente_id': 7},
              const {7},
              const {}),
          isFalse);
    });

    test('pagoExportable: cortesía y promo fuera', () {
      expect(
          pagoExportable({'metodo': 'cortesia'}, const {}, const {}),
          isFalse);
      expect(pagoExportable({'metodo': 'promo'}, const {}, const {}),
          isFalse);
    });

    test('pagoExportable: anulado fuera (marca y cola)', () {
      expect(
          pagoExportable({'metodo': 'efectivo', 'anulado': 1},
              const {}, const {}),
          isFalse);
      expect(
          pagoExportable(
              {'metodo': 'efectivo', 'id': 42}, const {}, const {42}),
          isFalse);
    });

    test('filasVentasMes: el fiado sin saldar no viaja; el saldado sí',
        () {
      final filas = filasVentasMes(
        [
          {
            'fecha': '2026-11-05',
            'es_fiado': 1,
            'cantidad': 1,
            'total': 100,
          },
          {
            'fecha': '2026-11-06',
            'es_fiado': true,
            'cantidad': 1,
            'total': 100,
          },
          {
            'fecha': '2026-11-07',
            'es_fiado': 1,
            'fiado_saldado': 1,
            'cantidad': 2,
            'total': 200,
          },
          {'fecha': '2026-11-08', 'cantidad': 1, 'total': 50},
        ],
        const {},
        '2026-11',
        const {},
      );
      expect(filas, hasLength(2));
      expect(filas[0][0], '2026-11-07');
      expect(filas[1][0], '2026-11-08');
    });

    test('csvEstadisticas neutraliza fórmulas y CR como la canónica',
        () {
      final csv = csvEstadisticas(
        ['nombre'],
        [
          ['=2+5'],
          ['Bote, "grande"'],
          ['linea\rrota'],
        ],
      );
      expect(csv, contains("'=2+5"));
      expect(csv, contains('"Bote, ""grande"""'));
      expect(csv, contains('"linea\rrota"'));
    });
  });

  group('R5-M1/M3 · contratos de fuente', () {
    final campana = _fuente('lib/ui/campana_wa.dart');
    final hub = _fuente('lib/ui/hub_comunicacion.dart');
    final buzon = _fuente('lib/ui/buzon_dueno.dart');
    final home = _fuente('lib/ui/home.dart');
    final admin = _fuente('lib/ui/admin.dart');
    final exportar = _fuente('lib/ui/exportar_excel.dart');

    test('M1-1: la audiencia filtra por el estado canónico', () {
      expect(campana, contains("a.estado == 'activo'"));
      expect(campana, isNot(contains('a.activo && a.ultimoAccesoEn')));
    });

    test('M1-3: la audiencia se deduplica antes del tope', () {
      expect(campana, contains('_dedupAudiencia(cruda)'));
    });

    test('M1-2: «sin verificar» no se dice «sin destinatarios»', () {
      expect(campana, contains('No se pudo cargar la lista de accesos'));
      expect(campana, contains('!AccesoAppCache.instance.cargado'));
    });

    test('M1-4: campaña y hub con defensa propia de dueño', () {
      expect(campana, contains('Las campañas son solo del dueño.'));
      expect(hub, contains('La comunicación es solo del dueño.'));
    });

    test('M1-6: el buzón distingue verificado de sin verificar', () {
      expect(buzon, contains('final bool verificado;'));
      expect(home, contains('verificado: verificado'));
    });

    test('M3-4: el exportador duplicado avisa sus fallos', () {
      expect(admin, contains("AppLog.error('ui', 'exportar_fallo'"));
      expect(admin, contains('No se pudo exportar'));
    });

    test('M3-5: el texto del paquete no promete la nómina ausente',
        () {
      expect(exportar, contains('la nómina no se pudo generar'));
    });
  });
}
