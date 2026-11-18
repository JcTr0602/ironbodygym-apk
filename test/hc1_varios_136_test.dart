/// H-C1 (1.36): grupo F — 136-537, 136-549, 136-582
/// (parte confirmada de cada fila PARCIAL).
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ironbody_gym/ui/ficha_que_falta.dart';
import 'package:ironbody_gym/ui/foto_elegir.dart';
import 'package:ironbody_gym/ui/panel_buscador.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('136-537 · el día 60 exacto ya cuenta como sin medición', () {
    final hoy = DateTime(2026, 11, 18);
    final hace60 = DateTime(2026, 9, 19);
    final hace59 = DateTime(2026, 9, 20);
    List<PendienteFicha> con(DateTime ult) => pendientesDeFicha(
          tieneFoto: true,
          telefonoValido: true,
          tieneAccesoApp: true,
          ultimaMedicionEn: ult,
          hoy: hoy,
        );
    expect(con(hace60), contains(PendienteFicha.sinMedicionReciente));
    expect(con(hace59), isNot(contains(PendienteFicha.sinMedicionReciente)));
  });

  test('136-582 · el panel busca teléfonos por dígitos con separadores',
      () {
    final clientes = <Map<String, dynamic>>[
      {'id': 1, 'nombre': 'Ana Pérez', 'telefono': '58191577'},
      {'id': 2, 'nombre': 'Luis Díaz', 'telefono': '52446688'},
    ];
    expect(buscarClientesPanel('5819-1577', clientes).length, 1);
    expect(buscarClientesPanel('53 5819 1577', clientes).length, 1);
    expect(buscarClientesPanel('1577', clientes).length, 1);
    expect(buscarClientesPanel('9999', clientes), isEmpty);
    expect(buscarClientesPanel('ana', clientes).length, 1);
  });

  test('136-549 · la foto recuperada se valida contra el contexto',
      () async {
    SharedPreferences.setMockInitialValues({});
    await registrarContextoFoto(flujo: 'ficha', entidadId: '42');
    expect(await fotoRecuperadaEsDeEsteFlujo('ficha', '42'), isTrue);
    expect(await fotoRecuperadaEsDeEsteFlujo('ficha', '77'), isFalse);
    expect(await fotoRecuperadaEsDeEsteFlujo('inscribir', '42'), isFalse);
    // Sin flujo declarado (legado): no hay contra qué validar.
    expect(await fotoRecuperadaEsDeEsteFlujo(null, null), isTrue);
    await limpiarContextoFoto();
    // Sin contexto guardado: se acepta.
    expect(await fotoRecuperadaEsDeEsteFlujo('ficha', '42'), isTrue);
  });
}
