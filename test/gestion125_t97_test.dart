/// 1.25 T97: la bandeja única gana la fila «vence hoy»
/// en su nivel propio de la escala de gravedad
/// (0 bloqueante · 1 dinero detenido · 2 vence hoy ·
/// 3 informativo) y el stock crítico baja a
/// informativo, detrás de los vencimientos.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart' as invitados_svc;
import 'package:ironbody_gym/plus_reportes.dart';
import 'package:ironbody_gym/ui/panel_dueno_atencion.dart';
import 'package:ironbody_gym/ui/panel_dueno_swr.dart';

void main() {
  final sello = DateTime(2026, 11, 6, 9, 0);

  FotoAtencion foto({
    List<String> vencen = const [],
    List<Map<String, dynamic>> stock = const [],
    List<Map<String, dynamic>> pend = const [],
    String? syncError,
  }) {
    final sol = BandejaSwr<invitados_svc.InvitadoResumen>()
      ..exito(const [], sello);
    final reps = BandejaSwr<ReportePlus>()..exito(const [], sello);
    return FotoAtencion(
      solicitudes: sol,
      reportes: reps,
      reservasSolicitadas: const [],
      nombreSupl: const {},
      pendienteEntrenadores: pend,
      sinReporteAyer: const [],
      sinReporteHoy: const [],
      incidenciasPend: 0,
      syncError: syncError,
      stockCritico: stock,
      vencenHoyNombres: vencen,
    );
  }

  test('sin vencimientos no hay fila de vence hoy', () {
    expect(pendientesAtencion(foto()), isEmpty);
  });

  test('un cliente: singular, destino a la bandeja de avisos', () {
    final filas = pendientesAtencion(foto(vencen: ['Ana Pérez']));
    expect(filas, hasLength(1));
    final f = filas.single;
    expect(f.destino, DestinoAtencion.vencimientos);
    expect(f.titulo, '1 cliente vence hoy');
    expect(f.detalle, 'Ana Pérez');
    expect(f.boton, 'Avisar');
    expect(f.gravedad, 2);
  });

  test('varios: plural con el primero y el resto contado', () {
    final filas =
        pendientesAtencion(foto(vencen: ['Ana', 'Beto', 'Cora']));
    expect(filas.single.titulo, '3 clientes vencen hoy');
    expect(filas.single.detalle, 'Ana y 2 más');
  });

  test('la escala ordena: sync < dinero < vence hoy < stock', () {
    final filas = pendientesAtencion(foto(
      syncError: 'timeout de red',
      pend: [
        {'nombre': 'Duany', 'total': 500.0},
      ],
      vencen: ['Ana'],
      stock: [
        {'nombre': 'Whey', 'stock': 1},
      ],
    ));
    expect(
      filas.map((f) => f.gravedad).toList(),
      [0, 1, 2, 3],
    );
    expect(filas[2].destino, DestinoAtencion.vencimientos);
    expect(filas[3].destino, DestinoAtencion.suplementos);
  });
}
