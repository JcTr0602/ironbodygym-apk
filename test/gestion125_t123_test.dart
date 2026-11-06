// 1.25 T123 (F6-05): la etiqueta legible del estado de una
// op, extraída de chipEstadoOp para usarla también en
// textos (el diálogo de detalle de la cola enseñaba el
// código crudo «aplicada»/«necesita_revision»).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/cola.dart';

void main() {
  test('etiquetaEstadoOp traduce los estados conocidos', () {
    expect(etiquetaEstadoOp('aplicada'), 'Confirmada');
    expect(etiquetaEstadoOp('rechazada'), 'Rechazada');
    expect(etiquetaEstadoOp('enviada'), 'Confirmación pendiente');
    expect(etiquetaEstadoOp('pendiente'), 'Pendiente');
    expect(etiquetaEstadoOp('error'), 'Falló');
    expect(etiquetaEstadoOp('necesita_revision'), 'Requiere revisión');
  });

  test('un estado desconocido se devuelve tal cual', () {
    expect(etiquetaEstadoOp('otro_estado'), 'otro_estado');
    expect(etiquetaEstadoOp(''), '');
  });
}
