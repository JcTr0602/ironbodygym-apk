// H-B4 (136-900/904/905): contratos puros de errores y reparar.
// - 905: «invalid» sin acento clasifica como validación.
// - 900: el genérico de diagnóstico trae la acción concreta.
// - 904: el hallazgo de manifiesto sin verificar lista las
//   tablas con nombre amigable.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/reparar_sync.dart';

void main() {
  group('136-905 invalid sin acento', () {
    test('clasifica como validación', () {
      final e = clasificarError(Exception('invalid input syntax'));
      expect(e.tipo, TipoErrorSync.validacion);
      expect(e.codigo, 'validacion_negocio');
    });
  });

  group('136-900 genérico con acción', () {
    test('resumenErrorDiagnostico desconocido trae la acción', () {
      final r = resumenErrorDiagnostico('xyzzy desconocido');
      expect(r, contains('exporta la bitácora'));
      expect(r, isNot('error de sincronización'));
    });
  });

  group('136-904 hallazgo con nombres amigables', () {
    test('lista las tablas sin verificar por su nombre', () {
      final hs = clasificarHallazgos(const FotoAtascos(
        manifiestoSinVerificar: ['clientes', 'pagos'],
      ));
      final h = hs.firstWhere((x) => x.titulo.contains('comprobar'));
      expect(h.detalle, contains('clientes'));
      expect(h.detalle, contains('pagos'));
    });
  });
}
