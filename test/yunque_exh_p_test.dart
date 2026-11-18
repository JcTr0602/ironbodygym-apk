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
///   `parsearRespuestaListar` quedó REVERTIDO en la
///   1.35 (el paso directo del mensaje de dominio era
///   contrato de test/congelacion_gestion_test) y se
///   APLICA en la 1.36 por adjudicación de Jc
///   (2026-11-17, bloque J-2b): el sobre sale con la
///   rama amable del listado y aquel contrato se
///   actualizó con constancia del cambio.
/// - P-02 (mensajeErrorAnuncio): la corrección (rama por
///   defecto genérica) quedó probada y REVERTIDA en la
///   1.35 por choque con test/gestion128_m5a_test.dart,
///   que fijaba que un código desconocido se muestra tal
///   cual. APLICADA en la 1.36 por adjudicación de Jc
///   (2026-11-17, bloque J-2a): los tests discriminantes
///   de abajo ya no llevan `skip` y el contrato de
///   gestion128_m5a_test se actualizó al nuevo
///   comportamiento con constancia del cambio.
///
/// listarRemoto() en sí no se ejercita (exige
/// Supabase/red); su catch delega en mensajeErrorAmable,
/// ya cubierto por la suite de errores_sync.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/anuncios_admin.dart';
import 'package:ironbody_gym/congelaciones_gestion.dart';

void main() {
  group('P-02 mensajeErrorAnuncio (APLICADO, adjudicación '
      'de Jc 2026-11-17)', () {
    test('un código nuevo del servidor no aparece en el texto',
        () {
      const codigo = 'TEXTO_DEMASIADO_LARGO_V2';
      final m = mensajeErrorAnuncio(codigo);
      expect(m, isNot(contains(codigo)));
      expect(
          m,
          'El servidor no aceptó el anuncio. Revisa el texto e '
          'inténtalo de nuevo.');
    });

    test('otro código desconocido cualquiera tampoco aparece',
        () {
      final m = mensajeErrorAnuncio('CODIGO_INTERNO_999_XYZ');
      expect(m, isNot(contains('CODIGO_INTERNO_999_XYZ')));
      expect(m, contains('no aceptó el anuncio'));
    });

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
    // CONTRATO MOVIDO (1.36, bloque J-2b): este grupo
    // fijaba que el mensaje de dominio del sobre viajaba
    // tal cual y que lo no-sobre salía «Error del
    // servidor». La adjudicación de Jc (2026-11-17)
    // sobre la excepción P-01 del Yunque Exhaustivo
    // 1.35 aplica el saneado en la fuente: TODO fallo del
    // parser sale con la rama amable única del listado.
    test('el error del sobre sale con la rama amable, no tal cual',
        () {
      final res = CongelacionesService.parsearRespuestaListar({
        'ok': false,
        'error': 'Solo el dueño ve las congelaciones.',
      });
      expect(res.ok, isFalse);
      expect(res.datos, isEmpty);
      expect(res.error,
          'No se pudieron cargar las congelaciones. Inténtalo de nuevo.');
    });

    test('un crudo de PostgREST en el sobre tampoco aparece', () {
      const crudo = 'PGRST202: function not found in schema cache';
      final res = CongelacionesService.parsearRespuestaListar({
        'ok': false,
        'error': crudo,
      });
      expect(res.ok, isFalse);
      expect(res.datos, isEmpty);
      expect(res.error, isNot(contains(crudo)));
      expect(res.error,
          'No se pudieron cargar las congelaciones. Inténtalo de nuevo.');
    });

    test('una respuesta que no es el sobre sale con la rama amable',
        () {
      for (final rara in [null, 'texto crudo del servidor', 42]) {
        final res = CongelacionesService.parsearRespuestaListar(rara);
        expect(res.ok, isFalse, reason: '$rara');
        expect(res.datos, isEmpty);
        expect(res.error,
            'No se pudieron cargar las congelaciones. Inténtalo de nuevo.');
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
