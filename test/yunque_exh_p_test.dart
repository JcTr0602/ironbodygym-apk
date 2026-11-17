/// Yunque Exhaustivo 1.35 — Carril P (plataforma):
/// ningún código interno crudo llega a pantalla.
///
/// Disposición final del coordinador (tras los choques
/// declarados por el carril):
/// - P-01 (congelaciones): APLICADO en las vías de
///   excepción y de snacks — `listarRemoto` traduce la
///   excepción con `mensajeErrorAmable` y resolver/cerrar
///   pintan las ramas amables únicas de la capa de
///   servicio (testeadas aquí como funciones puras).
///   El saneado del sobre {ok:false} en
///   `parsearRespuestaListar` quedó REVERTIDO: el paso
///   directo del mensaje de dominio del servidor es
///   contrato fijado por test/congelacion_gestion_test
///   («Solo el dueño ve las congelaciones.») y su
///   endurecimiento espera decisión en el paquete de
///   contratos. Aquí se fija ese contrato tal cual.
/// - P-02 (mensajeErrorAnuncio): la corrección (rama por
///   defecto genérica) quedó probada y REVERTIDA por
///   choque con test/gestion128_m5a_test.dart:165-166,
///   que fija que un código desconocido se muestra tal
///   cual. Sus tests discriminantes quedan en este
///   archivo como `skip` con el motivo: son el test del
///   desbloqueo si Jc actualiza aquel contrato. El test
///   de códigos conocidos sigue activo (no cambia en
///   ninguna de las dos versiones de la función).
///
/// listarRemoto() en sí no se ejercita (exige
/// Supabase/red); su catch delega en mensajeErrorAmable,
/// ya cubierto por la suite de errores_sync.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/anuncios_admin.dart';
import 'package:ironbody_gym/congelaciones_gestion.dart';

void main() {
  group('P-02 mensajeErrorAnuncio (EN PAQUETE DE DECISIÓN)', () {
    test(
      'un código nuevo del servidor no aparece en el texto',
      () {
        const codigo = 'TEXTO_DEMASIADO_LARGO_V2';
        final m = mensajeErrorAnuncio(codigo);
        expect(m, isNot(contains(codigo)));
        expect(
            m,
            'El servidor no aceptó el anuncio. Revisa el texto e '
            'inténtalo de nuevo.');
      },
      skip: 'P-02 espera decisión: gestion128_m5a_test fija el '
          'código crudo; este test es el discriminante del '
          'desbloqueo (Yunque Exhaustivo 1.35).',
    );

    test(
      'otro código desconocido cualquiera tampoco aparece',
      () {
        final m = mensajeErrorAnuncio('CODIGO_INTERNO_999_XYZ');
        expect(m, isNot(contains('CODIGO_INTERNO_999_XYZ')));
        expect(m, contains('no aceptó el anuncio'));
      },
      skip: 'P-02 espera decisión: gestion128_m5a_test fija el '
          'código crudo (Yunque Exhaustivo 1.35).',
    );

    test('un código conocido conserva su frase específica', () {
      expect(mensajeErrorAnuncio('SOLO_DUENO'),
          'Solo el dueño puede gestionar los anuncios.');
      expect(mensajeErrorAnuncio('CUERPO_INVALIDO'),
          contains('entre 1 y 4000 caracteres'));
      expect(mensajeErrorAnuncio('NO_EXISTE'),
          contains('ya no existe en el servidor'));
      expect(mensajeErrorAnuncio(null), 'El servidor no aplicó el cambio.');
    });
  });

  group('P-01 ramas amables de congelaciones: nunca el texto de entrada',
      () {
    const crudos = [
      'PostgrestException(message: duplicate key, code: 23505)',
      'PGRST116: relation not found',
      'Fuera de reglas: detalle interno del servidor',
      'Error del servidor',
    ];

    test('resolver: cualquier error de servidor → rama amable única', () {
      for (final crudo in crudos) {
        final m = mensajeResolverCongelacionFallido(crudo);
        expect(m, isNot(contains(crudo)), reason: crudo);
        expect(m, 'No se pudo resolver la solicitud. Inténtalo de nuevo.');
      }
      expect(mensajeResolverCongelacionFallido(null),
          'No se pudo resolver la solicitud. Inténtalo de nuevo.');
    });

    test('cerrar: cualquier error de servidor → rama amable única', () {
      for (final crudo in crudos) {
        final m = mensajeCerrarCongelacionFallido(crudo);
        expect(m, isNot(contains(crudo)), reason: crudo);
        expect(m, 'No se pudo cerrar la congelación. Inténtalo de nuevo.');
      }
      expect(mensajeCerrarCongelacionFallido(null),
          'No se pudo cerrar la congelación. Inténtalo de nuevo.');
    });

    test('listar: cualquier error de servidor → rama amable única', () {
      for (final crudo in crudos) {
        final m = mensajeListarCongelacionesFallido(crudo);
        expect(m, isNot(contains(crudo)), reason: crudo);
        expect(
            m, 'No se pudieron cargar las congelaciones. Inténtalo de nuevo.');
      }
    });
  });

  group('P-01 parsearRespuestaListar: contrato del sobre', () {
    test('el mensaje de dominio del sobre viaja tal cual (contrato fijado)',
        () {
      final res = CongelacionesService.parsearRespuestaListar({
        'ok': false,
        'error': 'Solo el dueño ve las congelaciones.',
      });
      expect(res.ok, isFalse);
      expect(res.datos, isEmpty);
      expect(res.error, 'Solo el dueño ve las congelaciones.');
    });

    test('una respuesta que no es el sobre sale «Error del servidor»', () {
      for (final rara in [null, 'texto crudo del servidor', 42]) {
        final res = CongelacionesService.parsearRespuestaListar(rara);
        expect(res.ok, isFalse, reason: '$rara');
        expect(res.datos, isEmpty);
        expect(res.error, 'Error del servidor');
      }
    });

    test('el sobre válido sigue desenvolviendo la lista sin error', () {
      final res = CongelacionesService.parsearRespuestaListar({
        'ok': true,
        'lista': [
          {
            'id': 'a1',
            'cliente_id': 7,
            'motivo_categoria': 'viaje',
            'motivo': 'Viaje familiar',
            'estado': 'pendiente',
          },
        ],
        'hoy': '2027-02-25',
      });
      expect(res.ok, isTrue);
      expect(res.error, isNull);
      expect(res.datos, hasLength(1));
    });
  });
}
