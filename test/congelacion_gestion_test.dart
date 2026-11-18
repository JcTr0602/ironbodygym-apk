/// Pruebas de la Congelación 0.5 en Gestión (M2): modelo,
/// estados visuales, conteo de días inmune al DST y el
/// registro del espejo solo-dueño en las listas del pull.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/congelaciones_gestion.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';

CongelacionGestion _cong({
  String estado = 'aprobada',
  String? desde = '2027-03-02',
  String? hasta = '2027-03-11',
  String? inicioEfectivo = '2027-03-02',
  String? hastaEfectivo,
  int? diasMaterializados,
  int clienteId = 7,
}) {
  return CongelacionGestion.fromJson({
    'id': 'abc',
    'cliente_id': clienteId,
    'cliente_nombre': 'Prueba',
    'motivo_categoria': 'viaje',
    'motivo': 'Viaje familiar a otra provincia por dos semanas',
    'estado': estado,
    'desde': desde,
    'hasta': hasta,
    'inicio_efectivo': inicioEfectivo,
    'hasta_efectivo': hastaEfectivo,
    'dias_materializados': diasMaterializados,
    'creado_en': '2027-02-25T10:00:00Z',
  });
}

void main() {
  group('diasRangoCongelacion (componentes UTC, anti-DST)', () {
    test('rango cerrado cuenta ambos extremos', () {
      expect(
          diasRangoCongelacion(
              DateTime(2027, 3, 2), DateTime(2027, 3, 11)),
          10);
    });
    test('cruza el cambio de hora de marzo sin perder el día',
        () {
      // El DST cubano entra el segundo domingo de marzo: con
      // aritmética de reloj local el rango perdería una hora
      // y podría contar 9; por componentes da 10 exactos.
      expect(
          diasRangoCongelacion(
              DateTime(2027, 3, 13), DateTime(2027, 3, 22)),
          10);
    });
    test('un solo día cuenta 1', () {
      expect(
          diasRangoCongelacion(
              DateTime(2027, 1, 1), DateTime(2027, 1, 1)),
          1);
    });
  });

  group('CongelacionGestion: en curso y etiquetas', () {
    final antes = DateTime(2027, 3, 1);
    final durante = DateTime(2027, 3, 5);
    final despues = DateTime(2027, 3, 15);

    test('programada antes del inicio no está en curso', () {
      final c = _cong();
      expect(c.enCursoEn(antes), isFalse);
      expect(c.etiquetaEstado(antes), 'Programada');
    });
    test('en curso durante la ventana', () {
      final c = _cong();
      expect(c.enCursoEn(durante), isTrue);
      expect(c.etiquetaEstado(durante), 'En curso');
    });
    test('terminada sin materializar: sincronizando días', () {
      final c = _cong();
      expect(c.enCursoEn(despues), isFalse);
      expect(c.etiquetaEstado(despues),
          'Terminada · sincronizando días');
    });
    test('materializada se etiqueta con los días aplicados',
        () {
      final c = _cong(diasMaterializados: 10);
      expect(c.etiquetaEstado(despues),
          'Terminada · días aplicados');
      expect(c.materializada, isTrue);
    });
    test('el cierre anticipado acorta la ventana (hasta_efectivo manda)',
        () {
      final c = _cong(hastaEfectivo: '2027-03-06');
      expect(c.enCursoEn(DateTime(2027, 3, 6)), isTrue);
      expect(c.enCursoEn(DateTime(2027, 3, 7)), isFalse);
      expect(c.finEfectivo, DateTime(2027, 3, 6));
    });
    test('pendiente/rechazada/cancelada nunca están en curso',
        () {
      for (final e in ['pendiente', 'rechazada', 'cancelada']) {
        final c = _cong(estado: e);
        expect(c.enCursoEn(durante), isFalse, reason: e);
      }
    });
  });

  group('clienteCongeladoEnCurso (cortocircuito de listados)',
      () {
    test('detecta solo al cliente y solo en su ventana', () {
      final filas = [_cong(clienteId: 7), _cong(clienteId: 9)];
      final hoy = DateTime(2027, 3, 5);
      expect(clienteCongeladoEnCurso(filas, 7, hoy), isTrue);
      expect(clienteCongeladoEnCurso(filas, 8, hoy), isFalse);
      expect(
          clienteCongeladoEnCurso(filas, 7, DateTime(2027, 4, 1)),
          isFalse);
    });
  });

  group('registro del espejo solo-dueño', () {
    test('cliente_congelaciones está en tablasEspejo', () {
      expect(SyncEngine.tablasEspejo,
          contains('cliente_congelaciones'));
    });
    test('está prohibida para el entrenador', () {
      expect(LocalDb.tablasProhibidasEntrenador,
          contains('cliente_congelaciones'));
    });
    test('el pull del entrenador la excluye; el del dueño no',
        () {
      expect(SyncEngine.tablasEspejoActivasParaRol(false),
          isNot(contains('cliente_congelaciones')));
      expect(SyncEngine.tablasEspejoActivasParaRol(true),
          contains('cliente_congelaciones'));
    });
  });

  group('categorías', () {
    test('las cuatro claves del servidor tienen etiqueta', () {
      for (final k in ['viaje', 'enfermedad_lesion', 'trabajo']) {
        expect(etiquetaCategoriaCongelacion(k), isNot('Otro'),
            reason: k);
      }
      expect(etiquetaCategoriaCongelacion('otro'), 'Otro');
      expect(etiquetaCategoriaCongelacion('enfermedad_lesion'),
          'Enfermedad o lesión');
      expect(etiquetaCategoriaCongelacion('desconocida'), 'Otro');
    });
  });

  // Contrato del sobre de admin_listar_congelaciones, fijado
  // contra su definición viva en Supabase (verificada
  // 2026-11-11): jsonb_build_object('ok', true, 'lista', […],
  // 'hoy', fecha) y en error {ok:false, error:'…'}. NO existe
  // clave 'congelaciones': el Yunque Cruzado cazó que
  // listarRemoto la leía y la bandeja del dueño se vaciaba
  // con ok=true. Si alguien vuelve a la clave vieja, el
  // primer test de este grupo cae (la lista saldría vacía).
  group('contrato admin_listar_congelaciones {ok, lista, hoy}',
      () {
    Map<String, dynamic> filaJson(String id, int clienteId) => {
          'id': id,
          'cliente_id': clienteId,
          'cliente_nombre': 'Cliente $clienteId',
          'cliente_telefono': '58191577',
          'cliente_pagado_hasta': '2027-03-01',
          'motivo_categoria': 'viaje',
          'motivo': 'Viaje familiar',
          'estado': 'pendiente',
          'desde': '2027-03-02',
          'hasta': '2027-03-11',
          'creado_en': '2027-02-25T10:00:00Z',
        };

    test('el sobre real desenvuelve la lista bajo «lista»', () {
      final res = CongelacionesService.parsearRespuestaListar({
        'ok': true,
        'lista': [filaJson('a1', 7), filaJson('b2', 9)],
        'hoy': '2027-02-25',
      });
      expect(res.ok, isTrue);
      expect(res.error, isNull);
      expect(res.datos, hasLength(2));
      expect(res.datos.first.id, 'a1');
      expect(res.datos.first.clienteId, 7);
      expect(res.datos.last.clienteNombre, 'Cliente 9');
    });

    test('lista vacía con ok=true es vacío real, no error', () {
      final res = CongelacionesService.parsearRespuestaListar(
          {'ok': true, 'lista': [], 'hoy': '2027-02-25'});
      expect(res.ok, isTrue);
      expect(res.datos, isEmpty);
      expect(res.error, isNull);
    });

    test('el sobre de error de la RPC pasa como ok=false', () {
      // CONTRATO MOVIDO (1.36, bloque J-2b): este test
      // fijaba que el error del sobre viajaba tal cual
      // (res.error == 'Solo el dueño ve las
      // congelaciones.'). La adjudicación de Jc
      // (2026-11-17) sobre la excepción P-01 del Yunque
      // Exhaustivo 1.35 aplica el saneado en la fuente:
      // el parser devuelve la rama amable única del
      // listado y el texto del servidor no sale.
      final res = CongelacionesService.parsearRespuestaListar({
        'ok': false,
        'error': 'Solo el dueño ve las congelaciones.',
      });
      expect(res.ok, isFalse);
      expect(res.datos, isEmpty);
      expect(res.error,
          'No se pudieron cargar las congelaciones. Inténtalo de nuevo.');
      expect(res.error,
          isNot(contains('Solo el dueño ve las congelaciones.')));
    });

    test('una respuesta que no es el sobre es error, no vacío',
        () {
      for (final rara in [null, 'texto', 42]) {
        final res =
            CongelacionesService.parsearRespuestaListar(rara);
        expect(res.ok, isFalse, reason: '$rara');
        expect(res.datos, isEmpty);
      }
    });
  });
}
