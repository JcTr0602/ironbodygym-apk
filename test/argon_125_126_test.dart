// Ajustes de los veredictos de Argón 1.25 y 1.26:
// puras tocadas (repetir cobro, buscador del Panel).
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';
import 'package:ironbody_gym/ui/panel_buscador.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('seleccionRepetirCobro (Argón 1.25 MEDIA)', () {
    test('mensual estándar con método', () {
      final s = seleccionRepetirCobro(
          {'periodo': 'mensual', 'metodo': 'efectivo'});
      expect(s.tipoId, 'mensual');
      expect(s.metodo, 'efectivo');
    });

    test('el tipo_id de la fila manda sobre el periodo', () {
      final s = seleccionRepetirCobro({
        'periodo': 'tipo:oferta_verano',
        'metodo': 'transferencia',
        'tipo_id': 'oferta_verano',
      });
      expect(s.tipoId, 'oferta_verano');
    });

    test('sin tipo_id, el prefijo tipo: del periodo se extrae', () {
      final s = seleccionRepetirCobro(
          {'periodo': 'tipo:pareja', 'metodo': 'efectivo'});
      expect(s.tipoId, 'pareja');
      expect(s.metodo, 'efectivo');
    });

    test('personalizado puro no se repite', () {
      final s = seleccionRepetirCobro(
          {'periodo': 'personalizado', 'metodo': 'efectivo'});
      expect(s.tipoId, isNull);
    });

    test('promo/cortesia: el tipo se repite, el método no (contrato 1.25)',
        () {
      final p = seleccionRepetirCobro(
          {'periodo': 'mensual', 'metodo': 'promo'});
      expect(p.tipoId, 'mensual');
      expect(p.metodo, isNull);
      final c = seleccionRepetirCobro(
          {'periodo': 'tipo:pareja', 'metodo': 'cortesia'});
      expect(c.tipoId, 'pareja');
      expect(c.metodo, isNull);
    });

    test('sin pago no hay selección', () {
      final s = seleccionRepetirCobro(null);
      expect(s.tipoId, isNull);
      expect(s.metodo, isNull);
    });
  });

  group('buscarClientesPanel (Argón 1.25 ALTA)', () {
    final clientes = [
      {'id': 1, 'nombre': 'Ana Normal', 'telefono': '58111111'},
      {
        'id': 2,
        'nombre': 'Beto Protegido',
        'telefono': '58222222',
        'protegido': 1,
      },
      {
        'id': 3,
        'nombre': 'Cora Protegida',
        'telefono': '58333333',
        'protegido': '1',
      },
    ];

    test('sin sesión de dueño, los protegidos no salen', () {
      // La sesión dummy no es de dueño: la vista protegida
      // falla cerrada y el filtro los excluye.
      expect(buscarClientesPanel('Ana', clientes)
          .map((c) => c['id']), [1]);
      expect(buscarClientesPanel('Beto', clientes), isEmpty);
      expect(buscarClientesPanel('Cora', clientes), isEmpty);
    });

    test('el teléfono de un protegido tampoco lo delata', () {
      final r = buscarClientesPanel('58222222', clientes);
      expect(r, isEmpty);
    });
  });
}
