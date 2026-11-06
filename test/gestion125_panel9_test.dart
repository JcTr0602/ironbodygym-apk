// 1.25 Panel 9: registro antes → después de las ediciones
// de cliente (captura en negocio, presentación en la
// Auditoría).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/ui/auditoria.dart';

void main() {
  group('antesEdicionCliente (captura, diff mínimo)', () {
    final anterior = {
      'nombre': 'Ana Pérez',
      'telefono': '51234567',
      'carnet': '95010112345',
      'sexo': 'F',
      'notas': null,
    };
    test('solo entran los campos que cambian de verdad', () {
      final antes = antesEdicionCliente(anterior, {
        'cliente_id': 7,
        'nombre': 'Ana Pérez', // igual: fuera
        'telefono': '52345678', // cambia: dentro
        'carnet': '95010112345', // igual: fuera
        'sexo': 'F',
      });
      expect(antes, {'telefono': '51234567'});
    });
    test('sin fila anterior o sin cambios, foto vacía', () {
      expect(antesEdicionCliente(null, {'telefono': '52345678'}),
          isEmpty);
      expect(
          antesEdicionCliente(anterior, {'telefono': '51234567'}),
          isEmpty);
    });
    test('null y cadena vacía cuentan como el mismo vacío', () {
      expect(antesEdicionCliente(anterior, {'notas': ''}), isEmpty);
      final antes = antesEdicionCliente(anterior, {'notas': 'lesión'});
      expect(antes, {'notas': null});
    });
    test('cliente_id nunca entra en la foto', () {
      final antes =
          antesEdicionCliente(anterior, {'cliente_id': 99});
      expect(antes, isEmpty);
    });
  });

  group('lineasAntesDespues (presentación)', () {
    test('arma las líneas con etiquetas humanas', () {
      final lineas = lineasAntesDespues({
        'telefono': '52345678',
        'nombre': 'Ana P.',
        'antes': {'telefono': '51234567', 'nombre': 'Ana Pérez'},
      });
      expect(lineas, [
        'nombre: Ana Pérez → Ana P.',
        'teléfono: 51234567 → 52345678',
      ]);
    });
    test('sin foto (ops viejas) no hay líneas', () {
      expect(lineasAntesDespues({'telefono': '52345678'}), isEmpty);
      expect(lineasAntesDespues({'antes': 'basura'}), isEmpty);
    });
    test('vacío se lee «—» y lo largo se recorta', () {
      final lineas = lineasAntesDespues({
        'notas': 'x' * 50,
        'antes': {'notas': null},
      });
      expect(lineas.single, startsWith('notas: — → '));
      expect(lineas.single.length, lessThan(60));
    });
  });
}
