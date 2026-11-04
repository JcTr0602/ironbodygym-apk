/// 1.23 Bloque 6 — W5: alerta de teléfono sin sincronizar.
///
/// - La clasificación es pura y trabaja con instantes: en
///   turno + más del umbral de turno = atrasado; sin turno +
///   más de 24 h = inactivo; sin fila = sinRegistro.
/// - La edad se mide contra la hora del servidor capturada
///   (meta server_timestamp_ultimo_sync), no contra el reloj
///   del dispositivo.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ultimo_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  group('W5 clasificación pura', () {
    final ahora = DateTime.utc(2026, 11, 3, 20, 0);

    String hace(Duration d) => ahora.subtract(d).toIso8601String();

    test('en turno: dentro del umbral está al día', () {
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: hace(const Duration(hours: 3, minutes: 59)),
              ahoraServidorUtc: ahora,
              enTurno: true),
          EstadoSyncTelefono.alDia);
    });

    test('en turno: pasado el umbral (4 h) está atrasado', () {
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: hace(const Duration(hours: 4, minutes: 1)),
              ahoraServidorUtc: ahora,
              enTurno: true),
          EstadoSyncTelefono.atrasado);
    });

    test('sin turno: 12 h sigue al día; 25 h es inactivo', () {
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: hace(const Duration(hours: 12)),
              ahoraServidorUtc: ahora,
              enTurno: false),
          EstadoSyncTelefono.alDia);
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: hace(const Duration(hours: 25)),
              ahoraServidorUtc: ahora,
              enTurno: false),
          EstadoSyncTelefono.inactivo);
    });

    test('la misma edad clasifica distinto según el turno', () {
      // 6 h: atrasado si está en turno; al día si no lo está.
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: hace(const Duration(hours: 6)),
              ahoraServidorUtc: ahora,
              enTurno: true),
          EstadoSyncTelefono.atrasado);
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: hace(const Duration(hours: 6)),
              ahoraServidorUtc: ahora,
              enTurno: false),
          EstadoSyncTelefono.alDia);
    });

    test('sin fila o con fecha ilegible: sinRegistro', () {
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: null,
              ahoraServidorUtc: ahora,
              enTurno: true),
          EstadoSyncTelefono.sinRegistro);
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: 'no-es-fecha',
              ahoraServidorUtc: ahora,
              enTurno: false),
          EstadoSyncTelefono.sinRegistro);
    });

    test('una sync «del futuro» (reloj raro) no da negativo', () {
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: ahora
                  .add(const Duration(hours: 1))
                  .toIso8601String(),
              ahoraServidorUtc: ahora,
              enTurno: true),
          EstadoSyncTelefono.alDia);
    });

    test('las zonas no intervienen: el mismo instante con '
        'otro offset clasifica igual', () {
      // 2026-11-03T11:00-04:00 == 15:00Z; ahora 20:00Z: 5 h.
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: '2026-11-03T11:00:00-04:00',
              ahoraServidorUtc: ahora,
              enTurno: true),
          EstadoSyncTelefono.atrasado);
    });
  });

  group('W5 hora del servidor guardada', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
    });

    setUp(() async {
      await LocalDb.resetParaTest();
    });

    test('sin captura devuelve null (degradación)', () async {
      expect(await ahoraServidorUltimoSync(), isNull);
    });

    test('lee la meta escrita por el motor', () async {
      await LocalDb.instance.setMeta('server_timestamp_ultimo_sync',
          '2026-11-03T20:00:00.000Z');
      final t = await ahoraServidorUltimoSync();
      expect(t, DateTime.utc(2026, 11, 3, 20));
      expect(t!.isUtc, isTrue);
    });

    test('delta panel: la hora del servidor AVANZA entre pulls '
        '(calibración por el instante de recepción)', () async {
      await LocalDb.instance.setMeta('server_timestamp_ultimo_sync',
          '2026-11-03T20:00:00.000Z');
      // Recibida hace 2 h según el reloj real: el «ahora del
      // servidor» debe ser la marca + ~2 h, no la marca pelada.
      final recibidoHace2h =
          DateTime.now().toUtc().subtract(const Duration(hours: 2));
      await LocalDb.instance.setMeta('server_timestamp_recibido_en',
          recibidoHace2h.toIso8601String());
      final t = await ahoraServidorUltimoSync();
      final esperado = DateTime.utc(2026, 11, 3, 22);
      expect(t!.difference(esperado).inSeconds.abs() < 10, isTrue,
          reason: 'la referencia no puede quedar congelada');
    });
  });

  group('W5 bordes exactos (delta panel)', () {
    final ahora = DateTime.utc(2026, 11, 3, 20);

    test('exactamente 4 h en turno: aún al día; 4 h + 1 s: '
        'atrasado', () {
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt:
                  ahora.subtract(const Duration(hours: 4))
                      .toIso8601String(),
              ahoraServidorUtc: ahora,
              enTurno: true),
          EstadoSyncTelefono.alDia);
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: ahora
                  .subtract(const Duration(hours: 4, seconds: 1))
                  .toIso8601String(),
              ahoraServidorUtc: ahora,
              enTurno: true),
          EstadoSyncTelefono.atrasado);
    });

    test('exactamente 24 h sin turno: aún al día; 24 h + 1 s: '
        'inactivo', () {
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt:
                  ahora.subtract(const Duration(hours: 24))
                      .toIso8601String(),
              ahoraServidorUtc: ahora,
              enTurno: false),
          EstadoSyncTelefono.alDia);
      expect(
          clasificarSyncTelefono(
              ultimoSyncAt: ahora
                  .subtract(const Duration(hours: 24, seconds: 1))
                  .toIso8601String(),
              ahoraServidorUtc: ahora,
              enTurno: false),
          EstadoSyncTelefono.inactivo);
    });
  });
}
