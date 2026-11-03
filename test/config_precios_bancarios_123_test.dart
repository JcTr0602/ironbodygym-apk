import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/config_precios_bancarios.dart';

/// 1.23 (B3 Paso 3a): parseo y validación de la configuración
/// de precios y datos bancarios como funciones puras.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  TextEditingController ctrl(String t) =>
      TextEditingController(text: t);

  group('parsearCambiosMontos', () {
    test('acepta válidos con coma decimal; ignora el resto', () {
      final cambios = parsearCambiosMontos({
        'transferencia': ctrl('2500'),
        'pago_diario': ctrl('200,5'),
        'mensualidad_menores': ctrl(''),
        'tasa_usd': ctrl('abc'),
        'precio_app_plus': ctrl('-100'),
      });
      expect(cambios, {'transferencia': 2500.0, 'pago_diario': 200.5});
    });

    test('Infinity NO se cuela como precio (clase N-2)', () {
      final cambios = parsearCambiosMontos({
        'tasa_usd': ctrl('Infinity'),
        'transferencia': ctrl('1e999'),
      });
      expect(cambios, isEmpty);
    });

    test('cero no es un precio válido', () {
      final cambios = parsearCambiosMontos({
        'pago_diario': ctrl('0'),
      });
      expect(cambios, isEmpty);
    });
  });

  group('validarCambiosBancarios', () {
    test('tarjeta válida se normaliza en grupos de 4', () {
      final r = validarCambiosBancarios(
        {'tarjeta_bandec': ctrl('1234567812345678')},
        {},
      );
      expect(r.errores, isEmpty);
      expect(r.cambios, {'tarjeta_bandec': '1234 5678 1234 5678'});
    });

    test('tarjeta de 15 dígitos es error, no cambio', () {
      final r = validarCambiosBancarios(
        {'tarjeta_bpa': ctrl('1234 5678 1234 567')},
        {},
      );
      expect(r.cambios, isEmpty);
      expect(r.errores, ['BPA: 16 dígitos']);
    });

    test('móvil debe tener 8 dígitos y empezar por 5 o 6', () {
      final mal = validarCambiosBancarios(
        {'movil_confirmacion': ctrl('41234567')},
        {},
      );
      expect(mal.errores, ['Móvil: 8 dígitos, empieza por 5 o 6']);
      final bien = validarCambiosBancarios(
        {'movil_confirmacion': ctrl('58191577')},
        {},
      );
      expect(bien.cambios, {'movil_confirmacion': '58191577'});
    });

    test('sin cambios contra el ajuste vigente → no se envía', () {
      final r = validarCambiosBancarios(
        {'tarjeta_bandec': ctrl('1234 5678 1234 5678')},
        {'tarjeta_bandec': '1234 5678 1234 5678'},
      );
      expect(r.cambios, isEmpty);
      expect(r.errores, isEmpty);
    });

    test('vacío no se envía (vaciar lo decide el servidor)', () {
      final r = validarCambiosBancarios(
        {'tarjeta_bandec': ctrl('   ')},
        {'tarjeta_bandec': '1234 5678 1234 5678'},
      );
      expect(r.cambios, isEmpty);
    });

    test('titular: texto tal cual, máx. 80', () {
      final r = validarCambiosBancarios(
        {'titular': ctrl('Julio César Pérez')},
        {},
      );
      expect(r.cambios, {'titular': 'Julio César Pérez'});
      final largo = validarCambiosBancarios(
        {'titular': ctrl('x' * 81)},
        {},
      );
      expect(largo.errores, ['Titular: máx. 80 caracteres']);
    });
  });

  test('etiquetaMonto: conocida y desconocida', () {
    expect(etiquetaMonto('tasa_usd'), 'Tasa USD (CUP por 1 USD)');
    expect(etiquetaMonto('clave_rara'), 'clave_rara');
  });
}
