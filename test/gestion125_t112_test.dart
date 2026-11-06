// 1.25 T112: el Centro de control — cuatro pestañas en
// sencillo, cada una con su vista embebida.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/centro_control.dart';
import 'package:ironbody_gym/ui/panel_buscador.dart';

void main() {
  test('las pestañas son las cuatro miradas, en sencillo', () {
    expect(pestanasCentroControl.map((p) => p.titulo),
        ['Qué pasó', 'Registro', 'Por persona', 'Anomalías']);
  });
  testWidgets('cada pestaña tiene su vista embebida', (tester) async {
    for (final p in pestanasCentroControl) {
      expect(vistaPestanaControl(p.id), isNotNull,
          reason: 'sin vista: ${p.id}');
    }
    expect(vistaPestanaControl('no_existe'), isNull);
  });
  test('el buscador del Panel encuentra el centro', () {
    final r = buscarFuncionesPanel('qué pasó');
    expect(r.map((f) => f.id), contains('centro_control'));
    final r2 = buscarFuncionesPanel('centro de control');
    expect(r2.map((f) => f.id), contains('centro_control'));
  });
}
