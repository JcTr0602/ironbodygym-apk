import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ironbody_gym/perfil.dart';

/// Bloque 1 — Buscar: la configuración de deslizables es local,
/// con lista cerrada y defaults seguros (derecha: cobrar,
/// izquierda: ninguna). Sin sync, sin valores inventados.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaults de deslizables en Buscar', () async {
    final p = PerfilService.instance;
    expect(await p.getSwipeBuscarDer(), 'cobrar');
    expect(await p.getSwipeBuscarIzq(), 'ninguna');
  });

  test('roundtrip de cada acción de la lista cerrada', () async {
    const acciones = ['ninguna', 'cobrar', 'diario', 'venta', 'editar'];
    final p = PerfilService.instance;
    for (final a in acciones) {
      await p.setSwipeBuscarDer(a);
      expect(await p.getSwipeBuscarDer(), a);
      await p.setSwipeBuscarIzq(a);
      expect(await p.getSwipeBuscarIzq(), a);
    }
  });
}
