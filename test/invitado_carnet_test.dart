// Carnet de invitado en el detalle de Gestión (0.9.1): el
// campo viaja en invitado_detalle y se parsea; los registros
// viejos (sin carnet) quedan null y la UI muestra «Sin carnet».
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';

Map<String, dynamic> _json({String? carnet}) {
  final inv = <String, dynamic>{
    'id': 'inv-1',
    'nombre': 'Prueba',
    'telefono': '51234567',
    'fecha_nac': '2005-03-17',
    'estado': 'activo',
  };
  if (carnet != null) inv['carnet'] = carnet;
  return {'invitado': inv};
}

void main() {
  test('detalle parsea el carnet cuando viene', () {
    final d = InvitadoDetalle.fromJson(_json(carnet: '05031712345'));
    expect(d.carnet, '05031712345');
    expect(d.fechaNac, '2005-03-17');
  });

  test('detalle viejo sin carnet queda null', () {
    final d = InvitadoDetalle.fromJson(_json());
    expect(d.carnet, isNull);
  });
}
