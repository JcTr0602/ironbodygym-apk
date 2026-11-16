/// SL-3 · G01-5 + G02-3 — las hojas de mis archivos son la
/// hoja de la casa (showHojaIron / HojaAccion), nunca
/// showModalBottomSheet crudo.
///
/// - G01-5: dashboard.dart abría el detalle de ingresos con
///   showModalBottomSheet crudo (su otra hoja, _detalleDia,
///   ya usaba showHojaIron).
/// - G02-3: el aviso de WhatsApp se presentaba con tres
///   hojas distintas; la presentación de MIS archivos es la
///   de listas.dart (_elegirAviso: «Avisar por WhatsApp» /
///   «Solo marcar como avisado», que devuelve 'whatsapp' /
///   'marcar'). Se unifica a la hoja de la casa conservando
///   el contrato de retorno. Las otras dos presentaciones
///   viven en buscar.dart (fuera del mapa de SL-3) y se
///   reportan en el informe, no se invaden.
///
/// Contrato de fuente (la pauta de la casa para superficies):
/// en la base ambos archivos contienen showModalBottomSheet
/// → rojo; corregidos, ninguno.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('G01-5 · dashboard.dart: sin hoja cruda; el detalle de '
      'ingresos usa showHojaIron', () {
    final src = File('lib/ui/dashboard.dart').readAsStringSync();
    expect(src.contains('showModalBottomSheet('), isFalse,
        reason: 'dashboard.dart no debe abrir hojas crudas');
    final i = src.indexOf('Future<void> _detalleIngresos');
    expect(i, greaterThanOrEqualTo(0));
    final cuerpo = src.substring(i, src.indexOf('Widget _filaDetalle', i));
    expect(cuerpo.contains('showHojaIron'), isTrue,
        reason: 'el detalle de ingresos abre con la hoja de la casa');
  });

  test('G02-3 · listas.dart: sin hoja cruda; _elegirAviso usa '
      'showHojaIron y conserva su contrato', () {
    final src = File('lib/ui/listas.dart').readAsStringSync();
    expect(src.contains('showModalBottomSheet('), isFalse,
        reason: 'listas.dart no debe abrir hojas crudas');
    final i = src.indexOf('Future<String?> _elegirAviso');
    expect(i, greaterThanOrEqualTo(0));
    final cuerpo = src.substring(i, src.indexOf('Future<bool> _abrirWhatsapp', i));
    expect(cuerpo.contains('showHojaIron'), isTrue,
        reason: 'la elección del aviso WA abre con la hoja de la casa');
    expect(cuerpo.contains("'whatsapp'"), isTrue);
    expect(cuerpo.contains("'marcar'"), isTrue);
  });
}
