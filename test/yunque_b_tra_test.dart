/// Yunque B · YB-TRA-01 (Gestión 1.31): si contar la cola
/// al cierre de una corrida FALLA, el resultado no puede
/// decir «al día»: el conteo indeterminado bloquea el
/// veredicto de éxito, el resumen lo nombra y el detalle lo
/// explica. Error ≠ cero (regla de la casa).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  test('YB-TRA-01: conteo indeterminado jamás es «al día»', () {
    const res = SyncResultado(
      corrio: true,
      pendientesRestantes: 0,
      conteoIndeterminado: true,
    );
    expect(res.alDia, isFalse);
    expect(res.resumenCorto, isNot(contains('al día')));
    expect(res.resumenCorto, contains('No se pudo verificar'));
    expect(res.textoPendientes, contains('No se pudo verificar'));
    expect(res.textoPendientes, contains('reintentará'));
  });

  test('YB-TRA-01: el conteo bueno conserva el veredicto de siempre', () {
    const vacia = SyncResultado(corrio: true);
    expect(vacia.conteoIndeterminado, isFalse);
    expect(vacia.alDia, isTrue);
    expect(vacia.resumenCorto, 'Todo estaba al día');
    expect(vacia.textoPendientes, isEmpty);

    const conPendientes = SyncResultado(
      corrio: true,
      pendientesRestantes: 2,
      porSubir: 2,
    );
    expect(conPendientes.alDia, isFalse);
    expect(conPendientes.resumenCorto, contains('quedan 2'));
  });
}
