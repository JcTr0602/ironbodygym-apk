// v1.8.0 — Libro corrido de adelantos: agrupa por mes_nomina
// (A1), arrastra la deuda y neta los reversos.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';

Map<String, dynamic> ev(String mes, num monto, {int? reversoDe}) => {
      'mes_nomina': mes,
      'monto': monto,
      'reverso_de': reversoDe,
      'fecha': '$mes-15',
    };

void main() {
  test('mes normal: neto = bruto + comisiones - adelantos', () {
    final libro = libroAdelantos(
      eventos: [ev('2026-10', 500)],
      brutoPorMes: {'2026-10': 3000},
      comisionesPorMes: {'2026-10': 200},
      hastaMes: '2026-10',
    );
    final m = libro.single;
    expect(m.adelantos, 500);
    expect(m.neto, 2700);
    expect(m.aPagar, 2700);
    expect(m.deudaSaliente, 0);
  });

  test('adelantos > devengado: se paga 0 y la deuda se arrastra',
      () {
    final libro = libroAdelantos(
      eventos: [ev('2026-09', 4000), ev('2026-10', 300)],
      brutoPorMes: {'2026-09': 3000, '2026-10': 3000},
      comisionesPorMes: const {},
      hastaMes: '2026-10',
    );
    final sep = libro.firstWhere((m) => m.mes == '2026-09');
    final oct = libro.firstWhere((m) => m.mes == '2026-10');
    expect(sep.aPagar, 0);
    expect(sep.deudaSaliente, 1000);
    expect(oct.deudaEntrante, 1000);
    expect(oct.neto, 3000 - 300 - 1000);
  });

  test('bruto 0 (sin clientes): todo el adelanto pasa a deuda', () {
    final libro = libroAdelantos(
      eventos: [ev('2026-10', 800)],
      brutoPorMes: const {},
      comisionesPorMes: const {},
      hastaMes: '2026-10',
    );
    expect(libro.single.deudaSaliente, 800);
    expect(libro.single.aPagar, 0);
  });

  test('el reverso neta en SU mes_nomina (no en el del registro)',
      () {
    // El registro cayó en septiembre; el reverso, por A1, cayó
    // en octubre (septiembre ya liquidado): cada mes ve lo suyo.
    final libro = libroAdelantos(
      eventos: [ev('2026-09', 500), ev('2026-10', -500, reversoDe: 1)],
      brutoPorMes: {'2026-09': 3000, '2026-10': 3000},
      comisionesPorMes: const {},
      hastaMes: '2026-10',
    );
    final sep = libro.firstWhere((m) => m.mes == '2026-09');
    final oct = libro.firstWhere((m) => m.mes == '2026-10');
    expect(sep.adelantos, 500);
    expect(oct.adelantos, -500);
    expect(oct.neto, 3500); // el reverso SUMA en su mes
  });

  test('la deuda atraviesa meses sin datos', () {
    final libro = libroAdelantos(
      eventos: [ev('2026-08', 5000)],
      brutoPorMes: {'2026-08': 1000, '2026-10': 3000},
      comisionesPorMes: const {},
      hastaMes: '2026-10',
    );
    final sep = libro.firstWhere((m) => m.mes == '2026-09');
    expect(sep.deudaEntrante, 4000);
    expect(sep.deudaSaliente, 4000);
    final oct = libro.firstWhere((m) => m.mes == '2026-10');
    expect(oct.deudaEntrante, 4000);
    expect(oct.aPagar, 0);
  });

  test('sin nada: solo aparece el mes en curso, en cero', () {
    final libro = libroAdelantos(
      eventos: const [],
      brutoPorMes: const {},
      comisionesPorMes: const {},
      hastaMes: '2026-10',
    );
    expect(libro.length, 1);
    expect(libro.single.neto, 0);
  });
}
