/// Corte B 1.32 · H-CB-5 (Hydrogen B-2): la cota de la
/// foto confirmada de AP-1 (`&sync_seq=lte.<serverSeq>`)
/// NO puede aplicarse a las tablas de secuencia PROPIA
/// (gympedia_solicitudes, permisos_bandeja,
/// espejo_gympedia_borradores, cliente_congelaciones):
/// su sync_seq es un BIGSERIAL por tabla, incomparable
/// con el server_seq global. Hoy es inocuo (el global va
/// por ~212k y supera cualquier secuencia propia), pero
/// en un entorno nuevo la cota ocultaría filas válidas
/// de esas tablas para siempre (su watermark jamás las
/// alcanzaría: el filtro las excluye antes de verlas).
///
/// El sitio gemelo de `sync_borrados` NO es este defecto:
/// las tumbas comparten la secuencia global por diseño
/// (su propio comentario AP-1 lo declara) y su cota es
/// correcta — verificado contra el código, sin tocar.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  group('cotaFotoParaTabla (H-CB-5)', () {
    test('tabla de secuencia global con foto: lleva la cota',
        () {
      expect(SyncEngine.cotaFotoParaTabla('clientes', 212500),
          '&sync_seq=lte.212500');
      expect(SyncEngine.cotaFotoParaTabla('pagos', 10),
          '&sync_seq=lte.10');
    });

    test('sin foto (serverSeq null): sin cota para nadie',
        () {
      expect(SyncEngine.cotaFotoParaTabla('clientes', null), '');
      expect(
          SyncEngine.cotaFotoParaTabla('permisos_bandeja', null),
          '');
    });

    test('tablas de secuencia PROPIA: jamás acotadas por el '
        'serverSeq global', () {
      for (final t in const [
        'gympedia_solicitudes',
        'permisos_bandeja',
        'espejo_gympedia_borradores',
        'cliente_congelaciones',
      ]) {
        expect(SyncEngine.cotaFotoParaTabla(t, 212500), '',
            reason: '$t: su sync_seq es un BIGSERIAL propio, '
                'incomparable con el global');
        expect(SyncEngine.cotaFotoParaTabla(t, 10), '',
            reason: '$t: en un entorno nuevo (serverSeq aún '
                'bajo) la cota ocultaría sus filas válidas');
      }
    });

    test('el conjunto de secuencia propia contiene las '
        'tablas del hallazgo', () {
      expect(
          SyncEngine.tablasConSecuenciaPropia,
          containsAll(<String>{
            'gympedia_solicitudes',
            'permisos_bandeja',
            'espejo_gympedia_borradores',
            'cliente_congelaciones',
          }));
    });
  });
}
