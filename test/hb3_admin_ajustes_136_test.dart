// H-B3 (136-834/835/839/841) — contrato: el índice de
// Ajustes aplica el rol por fila y trae «Novedades de mi
// versión»; los montos inválidos se nombran campo a campo;
// el error de la tarifa especial se ancla a su campo.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/ajustes.dart';
import 'package:ironbody_gym/ui/config_precios_bancarios.dart';
import 'package:ironbody_gym/ui/tarifas_especiales.dart';

void main() {
  group('136-834 · seccionVisibleAjustes con rol', () {
    test('el dueño ve Datos visible buscando «exportar»', () {
      expect(
          seccionVisibleAjustes('Datos', 'exportar', esDueno: true),
          isTrue);
    });

    test('el entrenador NO: «exportar» en Datos solo vive en '
        'la fila solo-dueño («Importar respaldo» es de todos '
        'y no contiene «exportar»)', () {
      expect(
          seccionVisibleAjustes('Datos', 'exportar', esDueno: false),
          isFalse);
      // Y «respaldo» SÍ le enseña Datos, por Importar.
      expect(
          seccionVisibleAjustes('Datos', 'respaldo', esDueno: false),
          isTrue);
    });

    test('el entrenador sí encuentra filas suyas de Datos', () {
      expect(
          seccionVisibleAjustes('Datos', 'importar', esDueno: false),
          isTrue);
      expect(
          seccionVisibleAjustes('Datos', 'espacio', esDueno: false),
          isTrue);
    });

    test('Diagnóstico entero es invisible para el entrenador', () {
      expect(
          seccionVisibleAjustes('Diagnóstico', 'bitácora',
              esDueno: false),
          isFalse);
      expect(
          seccionVisibleAjustes('Diagnóstico', 'bitácora',
              esDueno: true),
          isTrue);
    });

    test('sin rol declarado (compatibilidad) se comporta '
        'como dueño', () {
      expect(seccionVisibleAjustes('Datos', 'exportar'), isTrue);
    });
  });

  group('136-835 · índice de Acerca de', () {
    test('«Novedades de mi versión» está indexada y encuentra '
        'la sección', () {
      expect(titulosPorSeccionAjustes['Acerca de'],
          contains('Novedades de mi versión'));
      expect(
          seccionVisibleAjustes('Acerca de', 'novedades de mi'),
          isTrue);
    });
  });

  group('136-841 · parsearCambiosMontosConErrores', () {
    Map<String, TextEditingController> ctrls(
            Map<String, String> textos) =>
        {
          for (final e in textos.entries)
            e.key: TextEditingController(text: e.value)
        };

    test('vacío = sin cambio, no error', () {
      final r = parsearCambiosMontosConErrores(
          ctrls({'transferencia': '', 'pago_diario': '  '}));
      expect(r.cambios, isEmpty);
      expect(r.errores, isEmpty);
    });

    test('válido entra en cambios', () {
      final r = parsearCambiosMontosConErrores(
          ctrls({'transferencia': '2500'}));
      expect(r.cambios, {'transferencia': 2500.0});
      expect(r.errores, isEmpty);
    });

    test('no parseable y no positivo se nombran por campo', () {
      final r = parsearCambiosMontosConErrores(ctrls({
        'transferencia': 'abc',
        'pago_diario': '0',
        'tasa_usd': '-5',
        'mensualidad_menores': '100',
      }));
      expect(r.cambios, {'mensualidad_menores': 100.0});
      expect(r.errores.keys,
          containsAll(['transferencia', 'pago_diario', 'tasa_usd']));
      expect(r.errores['transferencia'], 'Escribe un importe válido');
      expect(r.errores['pago_diario'], 'Debe ser mayor que 0');
    });

    test('parsearCambiosMontos clásico sigue intacto', () {
      expect(
          parsearCambiosMontos(
              ctrls({'transferencia': '10', 'pago_diario': 'x'})),
          {'transferencia': 10.0});
    });
  });

  group('136-839 · campoErrorTarifaEspecial', () {
    String? campo({
      String nombre = 'Ana',
      String efectivo = '1000',
      String transfer = '',
      String desde = '2026-11-01',
      String hasta = '',
      String motivo = 'Pactado con el cliente',
    }) =>
        campoErrorTarifaEspecial(
            nombre: nombre,
            efectivo: efectivo,
            transfer: transfer,
            desde: desde,
            hasta: hasta,
            motivo: motivo);

    test('todo bien → null', () {
      expect(campo(), isNull);
    });

    test('sin nombre → campo nombre', () {
      expect(campo(nombre: ' '), 'nombre');
    });

    test('sin ningún monto válido → campo montos', () {
      expect(campo(efectivo: '', transfer: 'x'), 'montos');
      expect(campo(efectivo: '0'), 'montos');
    });

    test('sin motivo → campo motivo', () {
      expect(campo(motivo: ' '), 'motivo');
    });

    test('sin desde → campo desde; hasta anterior → hasta', () {
      expect(campo(desde: ''), 'desde');
      expect(campo(hasta: '2026-10-01'), 'hasta');
    });

    test('el campo coincide con que haya error de validación', () {
      // Si errorValidacionTarifaEspecial no ve error, el
      // campo es null; si lo ve, el campo no es null.
      for (final c in <Map<String, String>>[
        {'nombre': 'Ana'},
        {'nombre': ''},
        {'efectivo': '-3'},
        {'motivo': ''},
        {'desde': 'no-fecha'},
        {'hasta': '2020-01-01'},
      ]) {
        final nombre = c['nombre'] ?? 'Ana';
        final efectivo = c['efectivo'] ?? '1000';
        final motivo = c['motivo'] ?? 'Pactado';
        final desde = c['desde'] ?? '2026-11-01';
        final hasta = c['hasta'] ?? '';
        final err = errorValidacionTarifaEspecial(
            nombre: nombre,
            efectivo: efectivo,
            transfer: '',
            desde: desde,
            hasta: hasta,
            motivo: motivo);
        final f = campoErrorTarifaEspecial(
            nombre: nombre,
            efectivo: efectivo,
            transfer: '',
            desde: desde,
            hasta: hasta,
            motivo: motivo);
        expect(f == null, err == null,
            reason: 'caso $c: error=$err campo=$f');
      }
    });
  });
}
