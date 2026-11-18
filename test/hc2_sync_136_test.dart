/// H-C2 (1.36) G5 Sync/motor — 136-902, 136-922, 136-934.
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md
/// (filas PARCIALES: solo la parte confirmada).
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/huella_sync.dart';
import 'package:ironbody_gym/reparar_sync.dart';

void main() {
  group('136-902 clasificarHallazgos: la advertencia de otra cuenta, una vez',
      () {
    test('con los tres tipos de ops, la nota sale una sola vez', () {
      final f = FotoAtascos(
        opsPendientes: 2,
        opsEnviadas: 1,
        opsError: 3,
        opsRechazadas: 0,
        opsRevision: 0,
        fotosPendientes: 0,
        fotosError: 0,
        fotosIncidenciasPendientes: 0,
        comprobantesPendientes: 0,
        tablasPorRedescargar: 0,
        manifiestoSinVerificar: const [],
        espejoVacioSospechoso: false,
        clientesPrevios: 0,
        lecturasFallidas: 0,
      );
      final hs = clasificarHallazgos(f);
      final notas = hs
          .where((h) => h.detalle.contains('otra cuenta de este'))
          .length;
      expect(notas, 1,
          reason: 'la advertencia se emite una sola vez, no por hallazgo');
    });
  });

  group('136-922 filaHuellaDispositivo: nulls explícitos en watermark/seq',
      () {
    test('las claves viajan presentes aunque el valor sea null', () {
      final fila = filaHuellaDispositivo(
        userId: 'u1',
        deviceTag: 'apk-x',
        corridaId: 'c1',
        finEpoch: 100,
        latidoEpoch: 120,
        resultado: 'completa',
        subidos: 0,
        bajados: 0,
        watermarkMinimo: null,
        serverSeqAlcanzado: null,
        conteosLocales: const {'clientes': 5, 'pagos': null},
        rolActivo: 'dueno',
        versionApp: '1.36',
      );
      expect(fila.containsKey('watermark_minimo'), isTrue);
      expect(fila['watermark_minimo'], isNull);
      expect(fila.containsKey('server_seq'), isTrue);
      expect(fila['server_seq'], isNull);
      // fin y latido son instantes separados del contrato.
      expect(fila['fin_epoch'], 100);
      expect(fila['latido_epoch'], 120);
    });
  });

  group('136-934 esTemporalFoto', () {
    test('reconoce los temporales reales de variantes y los legados', () {
      expect(esTemporalFoto('/fotos/abc-thumb.tmp.webp'), isTrue);
      expect(esTemporalFoto('/fotos/abc-display.tmp.webp'), isTrue);
      expect(esTemporalFoto('/fotos/abc-original.jpg.tmp'), isTrue);
      expect(esTemporalFoto('/fotos/abc.webp.tmp'), isTrue);
    });

    test('los finales no son temporales', () {
      expect(esTemporalFoto('/fotos/abc-thumb.webp'), isFalse);
      expect(esTemporalFoto('/fotos/abc-original.jpg'), isFalse);
    });
  });
}
