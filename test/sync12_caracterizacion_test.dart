/// SYNC-12 (1.35) — CARACTERIZACIÓN del comportamiento ACTUAL
/// (1.34.0+95, pre-refactor) de los 4 sitios de aplanamiento
/// «error de lectura → valor válido falso» que el dictamen
/// SYNC-12 del Yunque 2 mandó convertir a triestado.
///
/// Estos tests NO fijan el comportamiento deseado: fijan el
/// de HOY, con nombre explícito, para que la pasada del
/// refactor tenga su A/B delante y cada cambio de semántica
/// sea una decisión visible en el diff de este archivo,
/// nunca un efecto colateral. Cuando un paso del plan se
/// aplique, el test correspondiente se reescribe aquí con
/// el neutro nuevo y la referencia al paso.
///
/// Sitios (inventario vivo @ 37b978c):
///  1. Foto del motor — `SyncStatus.hayNovedades`/`enLinea`
///     como `bool` con defaults false/true (lib/sync.dart).
///  2. `DiarioSync.conteosLocales` — fallo de COUNT por
///     tabla → 0 (lib/diario_sync.dart:769).
///  3. `DiarioSync.conteosPublicados` — valor null en el
///     JSON publicado → 0 (lib/diario_sync.dart:788).
///  4. Salud — catches que componen gris/verde/«todo subió»
///     ante fallo de lectura (lib/salud_sync.dart).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/diario_sync.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/salud_sync.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/ui/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _init() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  LocalDb.nombreArchivoDbForzado = 'test_sync12_caracterizacion.db';
  try {
    // ignore: deprecated_member_use
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  } catch (_) {}
  await LocalDb.resetParaTest();
  final dir = await getDatabasesPath();
  for (final suf in ['', '-wal', '-shm']) {
    try {
      await File(p.join(dir, 'test_sync12_caracterizacion.db$suf'))
          .delete();
    } catch (_) {}
  }
}

void main() {
  group('SYNC-12 sitio 1 · foto del motor (defaults que aplanan)', () {
    test('HOY: const SyncStatus() nace «en línea, sin novedades»', () {
      const s = SyncStatus();
      // El aplanamiento nace en el constructor: antes del
      // primer cálculo la foto ya afirma línea y ausencia de
      // novedades, y sus marcas valen 0.
      expect(s.enLinea, isTrue);
      expect(s.hayNovedades, isFalse);
      expect(s.watermarkMinimo, 0);
      expect(s.serverSeq, 0);
    });

    test('HOY: frase de la foto por defecto = todo sincronizado', () {
      const s = SyncStatus();
      expect(s.frase, 'Todo guardado y sincronizado');
    });

    test('HOY: frase sin línea distingue pendientes de reposo', () {
      expect(const SyncStatus(enLinea: false).frase,
          'Sin conexión — todo guardado en este teléfono');
      expect(const SyncStatus(enLinea: false, pending: 2).frase,
          'Sin conexión — 2 cambios guardados en este teléfono');
      expect(const SyncStatus(pending: 1).frase, '1 cambio por enviar');
    });

    test('HOY: varianteBannerDe — la partición vigente sin neutros', () {
      final ok = DateTime(2026, 11, 14, 10, 0);
      // Sin línea manda sobre todo lo demás en reposo.
      expect(
          varianteBannerDe(
              SyncStatus(enLinea: false, pending: 3, lastOk: ok)),
          VarianteBanner.sinConexion);
      // Pendientes mandan sobre novedades.
      expect(
          varianteBannerDe(
              SyncStatus(pending: 1, hayNovedades: true, lastOk: ok)),
          VarianteBanner.pendientes);
      // Novedades mandan sobre «al día».
      expect(varianteBannerDe(SyncStatus(hayNovedades: true, lastOk: ok)),
          VarianteBanner.novedades);
      // Sin lastOk nunca se puede decir «al día».
      expect(varianteBannerDe(const SyncStatus()),
          VarianteBanner.sinSincronizar);
      expect(varianteBannerDe(SyncStatus(lastOk: ok)),
          VarianteBanner.alDia);
      // El aviso persistido (A-3) manda sobre el «al día».
      expect(
          varianteBannerDe(
              SyncStatus(lastOk: ok, avisoSyncCorto: 'La bajada falló')),
          VarianteBanner.error);
    });
  });

  group('SYNC-12 sitio 2 · conteosLocales (fallo de COUNT → 0)', () {
    setUpAll(_init);

    test('HOY: tabla real vacía y tabla inexistente dan el MISMO 0',
        () async {
      final c = await DiarioSync.instance
          .conteosLocales(['clientes', 'tabla_que_no_existe_sync12']);
      // La tabla espejo existe y está vacía: 0 real.
      expect(c['clientes'], 0);
      // La tabla no existe: el COUNT lanza y el catch lo
      // aplana al mismo 0 — indistinguible del vacío real.
      // ESTE es el aplanamiento que el paso 1 convertirá en
      // null («sin leer»).
      expect(c['tabla_que_no_existe_sync12'], 0);
    });
  });

  group('SYNC-12 sitio 3 · conteosPublicados (null publicado → 0)', () {
    setUpAll(_init);

    test('HOY: sin meta publicada → null (honesto a nivel de mapa)',
        () async {
      expect(await DiarioSync.instance.conteosPublicados(), isNull);
    });

    test('HOY: un null DENTRO del JSON publicado se aplana a 0',
        () async {
      await LocalDb.instance.setMeta(
          'conteos_espejo_publicados', '{"clientes": 7, "pagos": null}');
      final c = await DiarioSync.instance.conteosPublicados();
      expect(c, isNotNull);
      expect(c!['clientes'], 7);
      // El servidor no publicó conteo de pagos (null) y la
      // app lo convierte en «0 en el servidor»: denominador
      // fabricado. El paso 1 debe conservar el null.
      expect(c['pagos'], 0);
    });

    test('HOY: JSON corrupto en la meta → null (no inventa conteos)',
        () async {
      await LocalDb.instance
          .setMeta('conteos_espejo_publicados', 'no-es-json');
      expect(await DiarioSync.instance.conteosPublicados(), isNull);
    });
  });

  group('SYNC-12 sitio 4 · salud (catch → gris/verde/«todo subió»)', () {
    test('HOY: estadoSaludSync(0, 0, sin rojos) = todoSubio', () {
      // Los conteos de cola ilegibles llegan aquí como 0/0
      // por los catches de cargarSaludSync: la composición
      // pura no tiene forma de saber que no se pudo leer.
      expect(
          estadoSaludSync(
              pendientes: 0, fallidas: 0, hayTablasEnRojo: false),
          EstadoSaludSync.todoSubio);
      expect(
          estadoSaludSync(
              pendientes: 3, fallidas: 0, hayTablasEnRojo: false),
          EstadoSaludSync.quedanCambios);
      expect(
          estadoSaludSync(
              pendientes: 0, fallidas: 1, hayTablasEnRojo: false),
          EstadoSaludSync.fallo);
      expect(
          estadoSaludSync(
              pendientes: 0, fallidas: 0, hayTablasEnRojo: true),
          EstadoSaludSync.fallo);
    });

    test('HOY: semaforoTabla con los valores de un COUNT fallido = gris',
        () {
      // Cuando contarFilasMirror lanza, cargarSaludSync deja
      // filas=0 y watermark=0 sin error registrado: el
      // semáforo pinta gris («nunca bajó»), no «no se pudo
      // leer» — ese estado NO existe hoy. El paso 3 lo crea.
      expect(
          semaforoTabla(
              hayError: false,
              corruptas: 0,
              divergente: false,
              ausente: false,
              sinPermiso: false,
              sinVerificar: false,
              watermark: 0,
              serverSeq: 0,
              filas: 0),
          SemaforoTabla.gris);
      // Y con filas reales leídas el mismo resto da verde:
      // la diferencia entre «vacía» y «ilegible» hoy no
      // existe en el tipo.
      expect(
          semaforoTabla(
              hayError: false,
              corruptas: 0,
              divergente: false,
              ausente: false,
              sinPermiso: false,
              sinVerificar: false,
              watermark: 5,
              serverSeq: 5,
              filas: 3),
          SemaforoTabla.verde);
    });
  });
}
