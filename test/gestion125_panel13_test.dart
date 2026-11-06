// 1.25 Panel 13: resultado por partes del lote de avisos
// (puras de estado y agrupación de la bandeja).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/bandeja_whatsapp.dart';

void main() {
  final avisos = <Map<String, dynamic>>[
    {'tipo': 'vencido', 'cliente_id': 1, 'nombre': 'Ana', 'telefono': '51234567'},
    {'tipo': 'vence_hoy', 'cliente_id': 2, 'nombre': 'Luis', 'telefono': ''},
    {'tipo': 'por_vencer', 'cliente_id': 3, 'nombre': 'Eva', 'telefono': '53 53456789'},
    {'tipo': 'cumple', 'cliente_id': 4, 'nombre': 'Leo', 'telefono': null},
  ];
  test('la clave del lote es tipo + cliente_id', () {
    expect(claveAvisoLote(avisos[0]), 'vencido_1');
  });
  test('estado: tocado manda; sin teléfono no se puede; el resto espera', () {
    final tocados = {'vencido_1'};
    expect(estadoAvisoLote(avisos[0], tocados),
        EstadoAvisoLote.contactado);
    expect(estadoAvisoLote(avisos[1], tocados),
        EstadoAvisoLote.sinTelefono);
    expect(estadoAvisoLote(avisos[2], tocados),
        EstadoAvisoLote.pendiente);
    expect(estadoAvisoLote(avisos[3], tocados),
        EstadoAvisoLote.sinTelefono);
  });
  test('el resumen agrupa las tres partes sin perder avisos', () {
    final g = resumenLoteAvisos(avisos, {'vencido_1'});
    expect(g[EstadoAvisoLote.contactado]!.length, 1);
    expect(g[EstadoAvisoLote.sinTelefono]!.length, 2);
    expect(g[EstadoAvisoLote.pendiente]!.length, 1);
    final total = g.values.fold<int>(0, (s, l) => s + l.length);
    expect(total, avisos.length);
  });
  test('rótulos de tipo legibles', () {
    expect(rotuloTipoAvisoLote('vence_hoy'), 'Vence hoy');
    expect(rotuloTipoAvisoLote('cumple'), 'Cumpleaños');
    expect(rotuloTipoAvisoLote('otro'), 'otro');
  });
}
