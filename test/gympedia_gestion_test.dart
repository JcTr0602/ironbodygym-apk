/// GymPedia en Gestión (v33, v1.4.4).
///
/// Verifica:
/// 1. Instalación limpia: existen el espejo y los borradores; v33.
/// 2. Upgrade 32→33: crea ambas tablas y siembra los cursores de
///    GymPedia en 0 SIN heredar el watermark global (que ya va alto).
/// 3. Un borrador NO altera el espejo hasta «publicar» (upsert al
///    espejo + borrado del borrador).
/// 4. El validador local espejo del servidor: topes en BYTES UTF-8
///    (no caracteres), referencias 2–6 con URL http, relacionados
///    existentes, sin autorreferencia ni duplicados.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/gympedia_validacion.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

Future<bool> _existeTabla(Database db, String nombre) async {
  final r = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
      [nombre]);
  return r.isNotEmpty;
}

Map<String, dynamic> _articuloValido() => {
      'id': 'tecnica-sentadilla',
      'titulo': 'Sentadilla: la técnica paso a paso',
      'categoria': 'tecnica',
      'lo_esencial': 'Resumen corto y claro.',
      'explicacion_md': 'Texto de explicación del artículo.',
      'pasos': ['Paso uno', 'Paso dos'],
      'errores': ['Error frecuente'],
      'referencias': [
        {'titulo': 'Estudio A', 'fuente': 'Revista 2020', 'url': 'https://a.org/1'},
        {'titulo': 'Estudio B', 'fuente': 'Revista 2021', 'url': 'https://b.org/2'},
      ],
      'sello': 'verde',
      'related_ids': ['tecnica-press-banca'],
      'tiene_imagen': false,
      'imagen_cambiada': false,
    };

void main() {
  test('limpia v33: espejo y borradores existen', () async {
    final db = await _abrirDbVacia();
    expect(await db.getVersion(), 33);
    expect(await _existeTabla(db, 'gympedia_articulos'), isTrue);
    expect(await _existeTabla(db, 'gympedia_borradores'), isTrue);
  });

  test('upgrade 32→33: tablas nuevas y cursores GymPedia en 0 '
      'aunque el watermark global vaya alto', () async {
    var db = await _abrirDbVacia();
    await db.execute('DROP TABLE gympedia_articulos');
    await db.execute('DROP TABLE gympedia_borradores');
    await LocalDb.instance.setWatermark(83184);
    await db.setVersion(32);
    await db.close();
    await LocalDb.resetParaTest();

    db = await LocalDb.instance.db;
    expect(await db.getVersion(), 33);
    expect(await _existeTabla(db, 'gympedia_articulos'), isTrue);
    expect(await _existeTabla(db, 'gympedia_borradores'), isTrue);
    expect(await LocalDb.instance.getMeta('wm_gympedia_articulos'), '0');
    expect(await LocalDb.instance.getMeta('wm_gympedia_borrados'), '0');
    // La clave: NO hereda los 83184 del global.
    expect(await LocalDb.instance.getWatermarkTabla('gympedia_articulos'),
        0);
  });

  test('borrador no toca el espejo; publicar sí y borra el borrador',
      () async {
    await _abrirDbVacia();
    final db = LocalDb.instance;
    await db.gympediaGuardarBorrador({
      'slug': 'tecnica-sentadilla',
      'titulo': 'Sentadilla: la técnica paso a paso',
      'categoria': 'tecnica',
      'lo_esencial': 'Resumen corto y claro.',
      'explicacion_md': 'Texto de explicación del artículo.',
      'pasos': '["Paso uno"]',
      'errores': '[]',
      'referencias': '[]',
      'sello': 'verde',
      'related_ids': '[]',
      'tiene_imagen': 0,
      'imagen_cambiada': 0,
      'base_revision': 0,
      'actualizado_ts': '2026-10-21T10:00:00-04:00',
    });
    expect(await db.gympediaPublicados(), isEmpty,
        reason: 'el borrador vive solo en su tabla');
    final b = await db.gympediaBorrador('tecnica-sentadilla');
    expect(b, isNotNull);
    expect(b!['titulo'], contains('Sentadilla'));

    // Simula el Publicar del editor: espejo optimista + sin borrador.
    await db.upsertMirrorTexto('gympedia_articulos', 'tecnica-sentadilla',
        _articuloValido()..['revision'] = 1, 555);
    await db.gympediaEliminarBorrador('tecnica-sentadilla');
    final pubs = await db.gympediaPublicados();
    expect(pubs, hasLength(1));
    expect(pubs.first['id'], 'tecnica-sentadilla');
    expect(pubs.first['revision'], 1);
    expect(await db.gympediaBorrador('tecnica-sentadilla'), isNull);

    // Retirar: el tombstone local borra el espejo.
    await db.deleteMirrorTexto('gympedia_articulos', 'tecnica-sentadilla');
    expect(await db.gympediaPublicados(), isEmpty);
  });

  group('validador local (espejo del servidor)', () {
    final publicados = {'tecnica-sentadilla', 'tecnica-press-banca'};

    test('artículo válido pasa', () {
      expect(
          GympediaValidacion.validar(_articuloValido(),
              slugsPublicados: publicados),
          isEmpty);
    });

    test('los topes son en BYTES UTF-8, no en caracteres', () {
      final a = _articuloValido();
      // 300 caracteres 'á' = 600 bytes > 500 del tope de lo_esencial.
      a['lo_esencial'] = 'á' * 300;
      final errs = GympediaValidacion.validar(a,
          slugsPublicados: publicados);
      expect(errs.any((e) => e.contains('500 bytes')), isTrue);
      // 200 caracteres = 400 bytes: pasa ese tope.
      a['lo_esencial'] = 'á' * 200;
      expect(
          GympediaValidacion.validar(a, slugsPublicados: publicados)
              .any((e) => e.contains('500 bytes')),
          isFalse);
    });

    test('explicación sobre 8192 bytes falla', () {
      final a = _articuloValido();
      a['explicacion_md'] = 'x' * 8193;
      expect(
          GympediaValidacion.validar(a, slugsPublicados: publicados)
              .any((e) => e.contains('8192')),
          isTrue);
    });

    test('referencias: menos de 2 o URL sin http fallan', () {
      final a = _articuloValido();
      a['referencias'] = [
        {'titulo': 'Solo una', 'fuente': 'X', 'url': 'https://x.org'}
      ];
      expect(
          GympediaValidacion.validar(a, slugsPublicados: publicados)
              .any((e) => e.contains('entre 2 y 6')),
          isTrue);
      a['referencias'] = [
        {'titulo': 'A', 'fuente': 'X', 'url': 'ftp://x.org'},
        {'titulo': 'B', 'fuente': 'Y', 'url': 'https://y.org'},
      ];
      expect(
          GympediaValidacion.validar(a, slugsPublicados: publicados)
              .any((e) => e.contains('http')),
          isTrue);
    });

    test('relacionados: inexistente, propio o repetido fallan', () {
      final a = _articuloValido();
      a['related_ids'] = ['no-existe'];
      expect(
          GympediaValidacion.validar(a, slugsPublicados: publicados)
              .any((e) => e.contains('no está publicado')),
          isTrue);
      a['related_ids'] = ['tecnica-sentadilla'];
      expect(
          GympediaValidacion.validar(a, slugsPublicados: publicados)
              .any((e) => e.contains('consigo mismo')),
          isTrue);
      a['related_ids'] = ['tecnica-press-banca', 'tecnica-press-banca'];
      expect(
          GympediaValidacion.validar(a, slugsPublicados: publicados)
              .any((e) => e.contains('repetido')),
          isTrue);
    });

    test('slug con mayúsculas o espacios no es válido', () {
      expect(GympediaValidacion.slugValido('Tecnica Sentadilla'), isFalse);
      expect(GympediaValidacion.slugValido('tecnica-sentadilla'), isTrue);
      expect(GympediaValidacion.slugValido('-empieza-mal'), isFalse);
      expect(GympediaValidacion.slugValido('doble--guion'), isFalse);
    });
  });
}
