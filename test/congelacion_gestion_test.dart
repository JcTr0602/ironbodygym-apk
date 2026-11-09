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
}
