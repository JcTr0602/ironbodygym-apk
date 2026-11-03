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

  // 1.22 IG-01: el estado LOCAL de conversión manda aunque el
  // resumen del servidor aún diga «activo».
  ConversionInvitado conv(String id, EstadoConversion e) =>
      ConversionInvitado(
        invitadoId: id,
        conversionUuid: 'u-$id',
        estado: e,
        creadaEn: '2026-11-02T00:00:00',
        actualizadaEn: '2026-11-02T00:00:00',
      );

  test('IG-01: opEncolada local excluye de plus_quitar', () {
    final p = partirLote(
      [_inv('x', 'activo', plus: true)],
      'plus_quitar',
      locales: {'x': conv('x', EstadoConversion.opEncolada)},
    );
    expect(p.aplicables, isEmpty);
    expect(p.excluidos.single.$2, 'conversión en curso');
  });

  test('IG-01: preparada local excluye de plus_cortesia pero '
      'NO de vida_extender', () {
    final locales = {'x': conv('x', EstadoConversion.preparada)};
    final p1 = partirLote([_inv('x', 'activo')], 'plus_cortesia',
        locales: locales);
    expect(p1.aplicables, isEmpty);
    final p2 = partirLote([_inv('x', 'activo')], 'vida_extender',
        locales: locales);
    expect(p2.aplicables.single.id, 'x');
  });

  test('IG-01: confirmada local cuenta como «ya es cliente»', () {
    final p = partirLote(
      [_inv('x', 'activo', plus: true)],
      'plus_quitar',
      locales: {'x': conv('x', EstadoConversion.confirmada)},
    );
    expect(p.aplicables, isEmpty);
    expect(p.excluidos.single.$2, 'ya es cliente');
  });

  test('IG-01: cancelada/rechazada local NO excluye', () {
    for (final e in [
      EstadoConversion.cancelada,
      EstadoConversion.opRechazada,
    ]) {
      final p = partirLote(
        [_inv('x', 'activo', plus: true)],
        'plus_quitar',
        locales: {'x': conv('x', e)},
      );
      expect(p.aplicables.single.id, 'x', reason: '$e no excluye');
    }
  });
}
