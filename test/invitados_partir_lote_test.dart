// v1.8.0 — La auto-exclusión del lote (diseño §4): convertidos,
// conversiones en curso y «sin Plus activo» se excluyen con
// motivo y NO bloquean al resto.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/ui/invitados.dart';

InvitadoResumen _inv(String id, String estado, {bool plus = false}) =>
    InvitadoResumen(
      id: id,
      nombre: 'N$id',
      telefono: '58000000',
      estado: estado,
      plusActivo: plus,
    );

void main() {
  final sel = [
    _inv('a', 'activo'),
    _inv('b', 'convertido'),
    _inv('c', 'en_conversion'),
    _inv('d', 'activo', plus: true),
  ];

  test('plus_cortesia: excluye convertido y en_conversion', () {
    final p = partirLote(sel, 'plus_cortesia');
    expect(p.aplicables.map((i) => i.id), ['a', 'd']);
    expect(p.excluidos.map((e) => e.$1.id), ['b', 'c']);
  });

  test('vida_extender: la conversión en curso NO excluye', () {
    final p = partirLote(sel, 'vida_extender');
    expect(p.aplicables.map((i) => i.id), ['a', 'c', 'd']);
    expect(p.excluidos.single.$1.id, 'b');
  });

  test('plus_quitar: excluye a quien no tiene Plus activo', () {
    final p = partirLote(sel, 'plus_quitar');
    expect(p.aplicables.map((i) => i.id), ['d']);
    expect(p.excluidos.length, 3);
  });
}
