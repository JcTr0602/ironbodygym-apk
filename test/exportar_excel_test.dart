/// Exportar más que clientes y pagos (7/25 del programa de
/// mejoras): hojas de ventas del mes, catálogo de suplementos y
/// nómina del mes. Cubre los constructores puros de filas
/// (filasVentasMes, filasSuplementos, filaNominaMes, esVentaAnulada).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/ui/exportar_excel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('esVentaAnulada cubre las 5 marcas de anulación', () {
    expect(esVentaAnulada({'anulada': 1}), isTrue);
    expect(esVentaAnulada({'anulada': true}), isTrue);
    expect(esVentaAnulada({'anulado': 1}), isTrue);
    expect(esVentaAnulada({'anulado': true}), isTrue);
    expect(esVentaAnulada({'estado': 'anulada'}), isTrue);
    expect(esVentaAnulada({'anulada': 0}), isFalse);
    expect(esVentaAnulada({}), isFalse);
  });

  test('filasVentasMes: mes, anuladas y protegidos fuera', () {
    final filas = filasVentasMes(
      [
        {
          'fecha': '2026-10-30',
          'suplemento_id': 1,
          'cantidad': 2,
          'total': 60,
          'moneda': 'USD',
          'comprador_nombre': 'Yennifer',
          'registrado_por_nombre': 'Gabriel',
          'cliente_id': 145,
        },
        {
          'fecha': '2026-10-30',
          'suplemento_id': 2,
          'cantidad': 1,
          'precio': 1500,
          'moneda': 'CUP',
          'comprador_nombre': 'Cliente externo',
          'registrado_por': 969869611,
        },
        // Otro mes: fuera.
        {'fecha': '2026-09-15', 'suplemento_id': 1},
        // Anulada: fuera.
        {'fecha': '2026-10-30', 'suplemento_id': 1, 'anulada': 1},
        // Comprador protegido: fuera.
        {
          'fecha': '2026-10-30',
          'suplemento_id': 1,
          'cliente_id': 99,
        },
      ],
      {1: 'Creatina', 2: 'Proteína'},
      '2026-10',
      {99},
    );
    expect(filas.length, 2);
    expect(filas[0][1], 'Creatina');
    expect(filas[0][3], '60');
    expect(filas[0][4], 'USD');
    expect(filas[0][5], 'Yennifer');
    expect(filas[0][6], 'Gabriel');
    // Sin total, cae al precio; sin nombre de vendedor, al id.
    expect(filas[1][3], '1500');
    expect(filas[1][6], '969869611');
  });

  test('filasSuplementos resuelve categoría y fallbacks', () {
    final filas = filasSuplementos(
      [
        {
          'nombre': 'Creatina',
          'categoria_id': 3,
          'precio_oficial': 35,
          'stock': 19,
        },
        {'nombre': 'Sin datos'},
      ],
      {3: 'Creatinas'},
    );
    expect(filas[0], ['Creatina', 'Creatinas', '35', '19']);
    expect(filas[1], ['Sin datos', '', '', '0']);
  });

  test('filaNominaMes deriva base, devengado, neto y a pagar', () {
    const libro = MesLibroAdelantos(
      mes: '2026-10',
      bruto: 14250,
      comisiones: 500,
      bonos: 1000,
      adelantos: 9700,
      deudaEntrante: 0,
      items: [],
    );
    expect(
        filaNominaMes('Duany', libro, 150, liquidada: false),
        ['Duany', '95', '14250', '500', '1000', '15750', '9700',
          '0', '6050', '6050', 'no']);
    // Con deuda que supera lo devengado: a pagar 0, neto negativo.
    const enDeuda = MesLibroAdelantos(
      mes: '2026-10',
      bruto: 1500,
      comisiones: 0,
      adelantos: 5000,
      deudaEntrante: 0,
      items: [],
    );
    final fila = filaNominaMes('Gabriel', enDeuda, 150);
    expect(fila[8], '-3500');
    expect(fila[9], '0');
  });
}
