/// Caza 1.21 — Argón Fotos: regresiones de los hallazgos
/// confirmados contra el código vivo (2026-11-02).
///  L1-ALTA  encolarFoto invalida las variantes 'pendiente' de
///           la foto anterior del mismo cliente (filas, archivos
///           y claves TUS), sin tocar las de otro cliente.
///  L3-ALTA  descartar un comprobante borra también sus claves
///           TUS de reanudación en meta.
///  L3-MEDIA re-encolar un comprobante con el mismo uuid borra
///           el archivo de la extensión anterior y las claves TUS.
///  L4-CRÍTICA procesar() respeta el lease entre procesos: con
///           un lease ajeno vigente devuelve 0 y no toca las
///           filas; sin lease ajeno, lo reclama y lo libera.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comprobantes.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _preparar() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  await LocalDb.resetParaTest();
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  return LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider → un directorio temporal propio por corrida:
  // encolarFoto escribe en <docs>/fotos.
  late Directory docs;
  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('fotos_caza_docs');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => docs.path);
  });

  test('L1-ALTA: encolarFoto invalida la foto pendiente anterior '
      'del mismo cliente y conserva la de otro', () async {
    final db = await _preparar();
    // Cliente 5 con foto vigente 'op-vieja' en el espejo.
    await db.insert('clientes', {
      'id': 5,
      'data': jsonEncode({'nombre': 'Cinco', 'foto_uuid': 'op-vieja'}),
      'sync_seq': 1,
    });
    final fotosDir = Directory('${docs.path}/fotos');
    await fotosDir.create(recursive: true);
    final vieja = File('${fotosDir.path}/vieja-display.webp');
    await vieja.writeAsBytes([9, 9, 9]);
    final ahora = isoHabana(ahoraHabana());
    await db.insert('fotos_cola', {
      'op_uuid': 'op-vieja',
      'tipo': 'display',
      'cliente_id': 5,
      'ruta_local': vieja.path,
      'estado': 'pendiente',
      'intentos': 0,
      'creado_en': ahora,
      'actualizado_en': ahora,
    });
    // Pendiente de OTRO cliente: no se toca.
    final otra = File('${fotosDir.path}/otra-display.webp');
    await otra.writeAsBytes([8, 8]);
    await db.insert('fotos_cola', {
      'op_uuid': 'op-otra',
      'tipo': 'display',
      'cliente_id': 9,
      'ruta_local': otra.path,
      'estado': 'pendiente',
      'intentos': 0,
      'creado_en': ahora,
      'actualizado_en': ahora,
    });
    await LocalDb.instance
        .setMeta('tus_loc_op-vieja_display', 'https://x/y');
    await LocalDb.instance.setMeta('tus_offset_op-vieja_display', '3');

    // La foto nueva: sin plugin de compresión en test, cae al
    // fallback (copia .jpg) e inserta su fila 'original'.
    final origen = File('${docs.path}/nueva.jpg');
    await origen.writeAsBytes([1, 2, 3]);
    await FotosColaService.instance.encolarFoto(
        opUuid: 'op-nueva', clienteId: 5, rutaOriginal: origen.path);

    final viejas = await db.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-vieja']);
    expect(viejas, isEmpty, reason: 'la fila vieja se cancela');
    expect(await vieja.exists(), isFalse,
        reason: 'su archivo se borra');
    expect(await LocalDb.instance.getMeta('tus_loc_op-vieja_display'),
        isNull);
    expect(
        await LocalDb.instance.getMeta('tus_offset_op-vieja_display'),
        isNull);
    final otras = await db.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-otra']);
    expect(otras, hasLength(1),
        reason: 'la foto de otro cliente queda intacta');
    expect(await otra.exists(), isTrue);
    final nuevas = await db.query('fotos_cola',
        where: 'op_uuid = ?', whereArgs: ['op-nueva']);
    expect(nuevas, isNotEmpty, reason: 'la foto nueva queda encolada');
  });

  test('L4: el lease de fotos_cola respeta un lease ajeno vigente '
      '(el epoch va como entero; como texto el reclamo pasaba '
      'siempre)', () async {
    await _preparar();
    final leaseAjeno =
        'otro-worker|${isoHabana(ahoraHabana().add(const Duration(minutes: 10)))}';
    await LocalDb.instance.setMeta('fotos_worker_lease', leaseAjeno);
    final n = await FotosColaService.instance.procesarCola();
    expect(n, 0);
    expect(await LocalDb.instance.getMeta('fotos_worker_lease'),
        leaseAjeno,
        reason: 'el lease ajeno queda intacto');
  });

  test('L3-ALTA: descartar comprobante borra sus claves TUS',
      () async {
    final db = await _preparar();
    final tmp = await Directory.systemTemp.createTemp('comp_caza');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final origen = File('${tmp.path}/captura.jpg');
    await origen.writeAsBytes([1, 2, 3]);
    await ComprobantesService.instance.encolar(
        comprobanteUuid: 'uuid-descartar',
        rutaOrigen: origen.path,
        baseDir: tmp);
    await LocalDb.instance
        .setMeta('tus_loc_uuid-descartar_comp', 'https://x/y');
    await LocalDb.instance
        .setMeta('tus_offset_uuid-descartar_comp', '7');

    await ComprobantesService.instance.descartar('uuid-descartar');

    expect(
        await ComprobantesService.instance.filaDe('uuid-descartar'),
        isNull);
    expect(await LocalDb.instance.getMeta('tus_loc_uuid-descartar_comp'),
        isNull);
    expect(
        await LocalDb.instance
            .getMeta('tus_offset_uuid-descartar_comp'),
        isNull);
    expect(db, isNotNull); // la BD sigue viva tras el descarte
  });

  test('L3-MEDIA: re-encolar el mismo uuid borra el archivo de la '
      'otra extensión y las claves TUS', () async {
    await _preparar();
    final tmp = await Directory.systemTemp.createTemp('comp_caza2');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final dirComp = Directory('${tmp.path}/comprobantes');
    await dirComp.create(recursive: true);
    final webpViejo = File('${dirComp.path}/uuid-re.webp');
    await webpViejo.writeAsBytes([7, 7, 7]);
    await LocalDb.instance.setMeta('tus_loc_uuid-re_comp', 'https://x');
    await LocalDb.instance.setMeta('tus_offset_uuid-re_comp', '4');

    final origen = File('${tmp.path}/captura.jpg');
    await origen.writeAsBytes([5, 5]);
    await ComprobantesService.instance.encolar(
        comprobanteUuid: 'uuid-re',
        rutaOrigen: origen.path,
        baseDir: tmp);

    expect(await webpViejo.exists(), isFalse,
        reason: 'el .webp anterior no queda huérfano');
    expect(await LocalDb.instance.getMeta('tus_loc_uuid-re_comp'),
        isNull);
    expect(await LocalDb.instance.getMeta('tus_offset_uuid-re_comp'),
        isNull);
    final fila = await ComprobantesService.instance.filaDe('uuid-re');
    expect(fila, isNotNull);
    expect(fila!['estado'], 'pendiente');
  });

  test('L4-CRÍTICA: procesar con lease ajeno vigente no sube ni '
      'toca filas; sin lease ajeno lo libera al salir', () async {
    await _preparar();
    final tmp = await Directory.systemTemp.createTemp('comp_caza3');
    addTearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });
    final origen = File('${tmp.path}/captura.jpg');
    await origen.writeAsBytes([3, 3]);
    await ComprobantesService.instance.encolar(
        comprobanteUuid: 'uuid-lease',
        rutaOrigen: origen.path,
        baseDir: tmp);

    // Lease ajeno vigente (expira en 10 min): procesar sale con 0.
    final leaseAjeno =
        'otro-worker|${isoHabana(ahoraHabana().add(const Duration(minutes: 10)))}';
    await LocalDb.instance
        .setMeta('comprobantes_worker_lease', leaseAjeno);
    final n = await ComprobantesService.instance.procesar();
    expect(n, 0);
    final fila = await ComprobantesService.instance.filaDe('uuid-lease');
    expect(fila!['estado'], 'pendiente',
        reason: 'la fila no se tocó: el ciclo fue del otro worker');
    expect(
        await LocalDb.instance.getMeta('comprobantes_worker_lease'),
        leaseAjeno,
        reason: 'el lease ajeno no se pisa ni se libera');

    // Sin lease ajeno: el ciclo corre (la subida fallará sin red,
    // pero el lease se reclama y queda LIBERADO al salir).
    await LocalDb.instance.setMeta('comprobantes_worker_lease', '');
    await ComprobantesService.instance.procesar();
    expect(await LocalDb.instance.getMeta('comprobantes_worker_lease'),
        '',
        reason: 'el lease propio se libera en el finally');
  });
}
