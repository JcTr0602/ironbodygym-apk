/// Correcciones del panel 1.11 (Luna NO APRUEBA; Kimi sin
/// respuesta por transporte; Terra sin respuesta por Zen agotado).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/plus_reportes.dart';

void main() {
  group('fusión recordatorios con cambio local más reciente (panel 1.11)', () {
    test('local más reciente no lo pisa el espejo viejo', () {
      final out = LocalDb.fusionarRecordatorios(
        [
          {
            'id': 'r1',
            'titulo': 'Pausado offline',
            'tipo': 'personalizado',
            'alcance': 'solo_mio',
            'activa': 0,
            'creada_ts': '2026-10-01',
            'actualizada_ts': '2026-10-25T12:00:00-04:00',
          },
        ],
        [
          {
            'id': 'r1',
            'titulo': 'Pausado offline',
            'tipo': 'personalizado',
            'alcance': 'solo_mio',
            'activa': 1,
            'creada_ts': '2026-10-01',
            'actualizada_ts': '2026-10-24T10:00:00-04:00',
          },
        ],
      );
      expect(out.length, 1);
      expect(out.first['activa'], 0);
    });

    test('espejo más reciente sigue ganando (caso 1.11 original)', () {
      final out = LocalDb.fusionarRecordatorios(
        [
          {
            'id': 'r1',
            'titulo': 'Cumpleaños',
            'tipo': 'personalizado',
            'alcance': 'todos',
            'activa': 1,
            'creada_ts': '2026-10-01',
            'actualizada_ts': '',
          },
        ],
        [
          {
            'id': 'r1',
            'titulo': 'Cumpleaños',
            'tipo': 'personalizado',
            'alcance': 'todos',
            'activa': 1,
            'disparado_en_fecha_habana': '2026-10-25',
            'creada_ts': '2026-10-01',
            'actualizada_ts': '2026-10-25T08:00:00-04:00',
          },
        ],
      );
      expect(out.first['disparado_en_fecha_habana'], '2026-10-25');
    });
  });

  group('C5: confirmados pagina hasta agotar (panel 1.11)', () {
    test('250 confirmados llegan completos en 3 llamadas', () async {
      final desdeVistos = <int>[];
      final svc = PlusReportesService(rpc: (nombre, params) async {
        final desde = (params?['p_desde'] as int?) ?? 0;
        desdeVistos.add(desde);
        final total = 250;
        final fin = (desde + 100).clamp(0, total);
        return [
          for (var i = desde; i < fin; i++)
            {
              'id': i + 1,
              'invitado_id': 'i${i + 1}',
              'creado_en': '2026-10-23T08:00:00Z',
              'monto_cup': 1000,
            },
        ];
      });
      final lista = await svc.confirmados();
      expect(lista.length, 250);
      expect(desdeVistos, [0, 100, 200]);
    });
  });
}
