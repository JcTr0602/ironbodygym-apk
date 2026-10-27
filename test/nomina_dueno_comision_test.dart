/// Fix 1.15 (caso real 2026-10-27): la nómina del dueño iteraba
/// entrenadores solo por registrado_por. Jc registró 4 dosis a
/// nombre de Duany (comision_entrenador_id=Duany) y Duany no tenía
/// ninguna venta registrada por él mismo: su tid nunca se iteraba
/// y su comisión (+200) no aparecía, mientras Gabriel (que registró
/// las suyas) sí mostraba la suya.
///
/// Estos tests son PUROS (sin BD): cubren el helper de iteración y
/// el cálculo por tid que la pantalla usa.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/nomina_calc.dart';

const _jc = 735772141;
const _duany = 969869611;
const _gabriel = 1403501391;

Map<String, dynamic> _dosis({
  required int registradoPor,
  String registradoNombre = '',
  required int comisionEntrenadorId,
  String fecha = '2026-10-27',
  num cantidad = 1,
  num comisionUnitaria = 50,
  num? comisionMonto = 50,
  dynamic casa = 0,
}) =>
    {
      'tipo': 'dosis_sin_agua',
      'cantidad': cantidad,
      'comision_unitaria': comisionUnitaria,
      'comision_monto': comisionMonto,
      'fecha': fecha,
      'casa': casa,
      'registrado_por': registradoPor,
      'registrado_por_nombre': registradoNombre,
      'comision_entrenador_id': comisionEntrenadorId,
    };

final _usuariosApk = [
  {'username': 'duany', 'telegram_id': _duany, 'nombre': 'Duany'},
  {'username': 'gabriel', 'telegram_id': _gabriel, 'nombre': 'Gabriel'},
];

void main() {
  test('dueño registra a nombre de Duany: Duany se itera y cobra 4x50',
      () {
    final ventas = [
      for (var i = 0; i < 4; i++)
        _dosis(
          registradoPor: _jc,
          registradoNombre: 'Jc',
          comisionEntrenadorId: _duany,
        ),
    ];
    final tids =
        NominaCalc.tidsConComisionServicio(ventas, _usuariosApk);
    // Antes del fix, el mapa solo tenía a Jc y Duany no se iteraba.
    expect(tids[_duany], 'Duany');
    expect(tids[_jc], 'Jc');
    final r =
        NominaCalc.comisionDosisDesdeVentas(ventas, _duany, '2026-10');
    expect(r.dosis, 4);
    expect(r.total, 200);
    // La cubeta de la pantalla sale del nombre del mapa.
    expect(tids[_duany]!.toLowerCase().contains('duany'), isTrue);
  });

  test('regresión: quien registra lo suyo sigue igual (Gabriel 3x50)',
      () {
    final ventas = [
      for (var i = 0; i < 3; i++)
        _dosis(
          registradoPor: _gabriel,
          registradoNombre: 'Gabriel',
          comisionEntrenadorId: _gabriel,
        ),
    ];
    final tids =
        NominaCalc.tidsConComisionServicio(ventas, _usuariosApk);
    expect(tids[_gabriel], 'Gabriel');
    final r = NominaCalc.comisionDosisDesdeVentas(
        ventas, _gabriel, '2026-10');
    expect(r.dosis, 3);
    expect(r.total, 150);
  });

  test('ganador sin entrada en usuarios_apk: se itera con nombre vacío',
      () {
    final ventas = [
      _dosis(
        registradoPor: _jc,
        registradoNombre: 'Jc',
        comisionEntrenadorId: 555111222,
      ),
    ];
    final tids = NominaCalc.tidsConComisionServicio(ventas, _usuariosApk);
    expect(tids.containsKey(555111222), isTrue);
    expect(tids[555111222], '');
    final r = NominaCalc.comisionDosisDesdeVentas(
        ventas, 555111222, '2026-10');
    expect(r.dosis, 1);
    expect(r.total, 50);
  });
}
