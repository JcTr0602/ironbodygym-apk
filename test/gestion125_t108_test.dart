// 1.25 T108: el hub «Comunicación» — índice completo y
// cada destino con su pantalla.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/hub_comunicacion.dart';
import 'package:ironbody_gym/ui/panel_buscador.dart';

void main() {
  test('el hub reúne las 7 piezas de la comunicación', () {
    expect(destinosComunicacion.map((d) => d.id), [
      'bandeja',
      'cumpleanos',
      'campanas',
      'avisos_clientes',
      'avisos_entrenadores',
      'plantillas',
      'recordatorios',
    ]);
  });
  testWidgets('cada destino del hub tiene pantalla', (tester) async {
    for (final d in destinosComunicacion) {
      expect(pantallaDestinoComunicacion(d.id), isNotNull,
          reason: 'sin pantalla: ${d.id}');
    }
    expect(pantallaDestinoComunicacion('no_existe'), isNull);
  });
  test('el buscador del Panel encuentra el hub', () {
    final r = buscarFuncionesPanel('comunicación');
    expect(r.map((f) => f.id), contains('comunicacion'));
    final r2 = buscarFuncionesPanel('mensajes whatsapp');
    expect(r2.map((f) => f.id), contains('comunicacion'));
  });
}
