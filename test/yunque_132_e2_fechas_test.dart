/// 1.32 · Escalón 2 — micro-hallazgos B1 y fechas (Pieza 2).
///
/// - H-B7-3: las etiquetas de Vales pasan el instante
///   crudo por La Habana (`fmtFechaDeInstanteServidor`);
///   antes cortaban el texto UTC y pintaban el día UTC.
/// - H-B7-2: la fecha corta de Comunidad
///   (`fechaCortaHabana`) convierte el instante UTC antes
///   de componer día/mes/año.
/// - B1-H9: el detalle de actividad lee `fecha_sesion`
///   (la clave viva de las filas de sesión), además de
///   `fecha`.
/// - B1-H8: el error de permiso de Estadísticas de
///   adopción se clasifica sobre el mensaje de ORIGEN del
///   servidor, que el catch ya no descarta.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/actividad_cliente.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/estadisticas_adopcion.dart';
import 'package:ironbody_gym/ui/panel_comunidad.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('H-B7-3: fmtFechaDeInstanteServidor', () {
    test('un instante UTC de madrugada pinta el día habanero', () {
      // 02:00 UTC del 1-nov = 22:00 del 31-oct en La Habana.
      expect(fmtFechaDeInstanteServidor('2026-11-01T02:00:00Z'),
          '31/10/2026');
      expect(
          fmtFechaDeInstanteServidor('2026-11-01T02:00:00+00:00'),
          '31/10/2026');
    });

    test('un instante de día pinta su propio día', () {
      expect(fmtFechaDeInstanteServidor('2026-11-11T15:00:00Z'),
          '11/11/2026');
    });

    test('una fecha plana se respeta tal cual', () {
      expect(fmtFechaDeInstanteServidor('2026-11-20'), '20/11/2026');
      expect(fmtFechaDeInstanteServidor(''), '');
      expect(fmtFechaDeInstanteServidor(null), '');
    });
  });

  group('H-B7-2: fechaCortaHabana', () {
    test('el instante UTC se convierte antes de componer', () {
      // 01:30 UTC del 1-nov = 21:30 del 31-oct en La Habana.
      expect(fechaCortaHabana('2026-11-01T01:30:00Z'), '31/10/2026');
    });

    test('sin zona, los campos se respetan; null → vacío', () {
      expect(fechaCortaHabana('2026-11-11T12:00:00'), '11/11/2026');
      expect(fechaCortaHabana(null), '');
      expect(fechaCortaHabana('no-es-fecha'), '');
    });
  });

  group('B1-H9: detalleActividadCliente y fecha_sesion', () {
    ActividadCliente fila(Map<String, dynamic> detalle) =>
        ActividadCliente(
          fuente: 'sesion',
          idOrigen: 1,
          actor: null,
          accion: 'sesion',
          detalle: detalle,
          creadoEn: DateTime.utc(2026, 11, 5),
        );

    test('la sesión enseña su fecha por la clave viva', () {
      final t = detalleActividadCliente(fila({
        'rutina': 'Pecho y tríceps',
        'fecha_sesion': '2026-11-05',
        'duracion_seg': 3600,
      }));
      expect(t, contains('Fecha: 2026-11-05'));
      expect(t, contains('Rutina: Pecho y tríceps'));
    });

    test('la clave `fecha` de otros tipos sigue valiendo', () {
      final t = detalleActividadCliente(fila({'fecha': '2026-10-01'}));
      expect(t, contains('Fecha: 2026-10-01'));
    });
  });

  group('B1-H8: permiso en Estadísticas de adopción', () {
    test('el mensaje de origen sale de la PostgrestException', () {
      expect(
        mensajeDeErrorServidor(const PostgrestException(
            message: 'Solo el administrador puede ver las '
                'estadísticas.',
            code: 'P0001')),
        'Solo el administrador puede ver las estadísticas.',
      );
    });

    test('la clase de permiso es alcanzable por el servidor', () {
      expect(
        esErrorPermisoEstadisticas(
          mostrado: 'No se pudieron cargar las estadísticas. '
              'Revisa la conexión e inténtalo de nuevo.',
          origen: 'Solo el administrador puede ver las '
              'estadísticas.',
        ),
        isTrue,
        reason: 'con el genérico pintado, el origen del '
            'servidor es el que clasifica el permiso',
      );
      expect(
        esErrorPermisoEstadisticas(
            mostrado: 'Solo el dueño ve estas estadísticas.',
            origen: ''),
        isTrue,
      );
      expect(
        esErrorPermisoEstadisticas(
            mostrado: 'No se pudieron cargar las estadísticas.',
            origen: 'Connection closed before full header was '
                'received'),
        isFalse,
      );
    });
  });
}
