/// 1.32 · Escalón 2 — contratos RPC restantes (Pieza 1).
///
/// Fija los sobres vivos que el barrido B1 cazó divergentes:
///
/// - H-RPC-5 (B1-H5): el contador de reportes de Comunidad
///   devuelve null ante el {ok:false} de la RPC — «no se
///   pudo saber» —, no un 0 mentiroso.
/// - H-RPC-3 (B1-H2): la omisión deliberada de la
///   generación individual de acceso se enseña con el
///   `mensaje` del servidor, no con el error genérico.
/// - H-RPC-4 (B1-H4): los parsers leen la forma VIVA —
///   historial de comunidad por `eventos` (la clave
///   `historial` NO es el contrato) y la bandeja de
///   premios SIN `ok`/`meta`, con las claves vivas de fila.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comunidad_panel.dart';
import 'package:ironbody_gym/premios_panel.dart';
import 'package:ironbody_gym/ui/acciones_acceso.dart';

void main() {
  group('H-RPC-5: reportesNuevosDesdeRespuesta', () {
    test('ok:false (no_autorizado) → null, no 0', () {
      expect(
        reportesNuevosDesdeRespuesta(
            {'ok': false, 'motivo': 'no_autorizado'}, 0),
        isNull,
        reason: 'sin permiso no se pudo saber: el Panel no '
            'puede pintar «0 reportes nuevos»',
      );
    });

    test('respuesta que no es mapa → null', () {
      expect(reportesNuevosDesdeRespuesta(null, 0), isNull);
      expect(reportesNuevosDesdeRespuesta('basura', 0), isNull);
    });

    test('ok:true cuenta solo los ids por encima de vistos', () {
      expect(
        reportesNuevosDesdeRespuesta({
          'ok': true,
          'reportes_pendientes_ids': [3, 5, 9],
        }, 5),
        1,
      );
      expect(
        reportesNuevosDesdeRespuesta({
          'ok': true,
          'reportes_pendientes_ids': <int>[],
        }, 0),
        0,
        reason: 'ok:true sin pendientes SÍ es un 0 verdadero',
      );
    });
  });

  group('H-RPC-3: mensajeOmitidoGeneracion', () {
    test('omitido con mensaje: se enseña el del servidor', () {
      expect(
        mensajeOmitidoGeneracion({
          'ok': true,
          'omitido': true,
          'pin_temporal': null,
          'mensaje': 'Acceso de conversión con vale de canje '
              'vivo: no se genera PIN temporal.',
        }),
        'Acceso de conversión con vale de canje vivo: no se '
        'genera PIN temporal.',
      );
    });

    test('omitido sin mensaje: reserva no vacía', () {
      final m = mensajeOmitidoGeneracion({'omitido': true});
      expect(m, isNotNull);
      expect(m!.isNotEmpty, isTrue);
    });

    test('con PIN o sin omisión: null (el flujo sigue)', () {
      expect(
        mensajeOmitidoGeneracion({'ok': true, 'pin_temporal': '483920'}),
        isNull,
      );
      expect(mensajeOmitidoGeneracion({'ok': true}), isNull);
      expect(mensajeOmitidoGeneracion(<String, dynamic>{}), isNull);
    });
  });

  group('H-RPC-4: la forma viva es el contrato', () {
    test('historial de comunidad: la clave es `eventos`', () {
      final fila = {
        'id': 4,
        'cliente_id': 9,
        'accion': 'ocultar',
        'creado_en': '2026-11-06T10:00:00Z',
      };
      expect(
        parseHistorialComunidad({'ok': true, 'eventos': [fila]}).length,
        1,
      );
      expect(
        parseHistorialComunidad({'ok': true, 'historial': [fila]}),
        isEmpty,
        reason: 'la clave `historial` NO es el contrato vivo: '
            'un doble que la use quedaría verde con producción '
            'vacía (la lección de congelaciones, en espejo)',
      );
    });

    test('bandeja de premios: sin ok/meta y claves vivas', () {
      final b = parseBandejaPremios({
        'vales': [
          {
            'id': 7,
            'cliente_id': 5,
            'nombre': 'Ana Vale',
            'telefono': '52893421',
            'logro_id': 'constancia_real',
            'premio_dias': 15,
            'dias_al_reclamar': 15,
            'pagado_hasta': '2026-11-20',
            'creado_en': '2026-11-06T10:00:00',
            'creado_nota': '',
          }
        ],
        'recientes': <dynamic>[],
      });
      expect(b.vales.length, 1);
      expect(b.vales.single.logroId, 'constancia_real');
      expect(b.vales.single.diasAlReclamar, 15);
    });
  });
}
