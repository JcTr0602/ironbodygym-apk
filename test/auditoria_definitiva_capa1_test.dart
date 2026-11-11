/// Auditoría Definitiva · Capa 1 (parcial) — correcciones de la
/// oleada sobre Gestión 1.31 (base ef074cd). Cada grupo caza la
/// entrada numerada del consolidado
/// (cola-123/auditoria_definitiva/consolidado_capa1_parcial.md §E).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comprobantes.dart';
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/diagnostico_espejo.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/modelos/incidencia.dart';
import 'package:ironbody_gym/reparar_sync.dart';
import 'package:ironbody_gym/ui/incidencias/editar_incidencia.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/sync.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/foto_elegir.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  for (final sufijo in ['', '-wal', '-shm']) {
    for (final nombre in ['ironbody.db', 'ironbody_$pid.db']) {
      try {
        await File(p.join(dir, nombre) + sufijo).delete();
      } catch (_) {}
    }
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Map<String, dynamic> _opPago({
  required int clienteId,
  required String? optimista,
  required String? anterior,
  String opUuid = 'op-test',
}) {
  return {
    'op_uuid': opUuid,
    'tipo': 'pago_mensual',
    'payload': jsonEncode({
      'cliente_id': clienteId,
      if (optimista != null) 'pagado_hasta': optimista,
      'pagado_hasta_anterior': anterior,
    }),
  };
}

Future<String?> _pagadoHastaEspejo(int clienteId) async {
  final filas =
      await LocalDb.instance.mirrorPorIds('clientes', [clienteId]);
  if (filas.isEmpty) return null;
  final v = filas.first['pagado_hasta'];
  return v == null ? null : '$v';
}

Future<String?> _selloEspejo(int clienteId) async {
  final filas =
      await LocalDb.instance.mirrorPorIds('clientes', [clienteId]);
  if (filas.isEmpty) return null;
  final v = filas.first['ultimo_pago_op_uuid'];
  return v == null ? null : '$v';
}

void main() {
  group('A-3 · reversión del vencimiento con guarda de procedencia',
      () {
    test('revierte si el espejo aún lleva el valor de ESTA op',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          501,
          {'id': 501, 'nombre': 'A', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 501,
              optimista: '2026-12-10',
              anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(501), '2026-11-10');
    });

    test('NO pisa el vencimiento de un pago posterior confirmado',
        () async {
      await _abrirDbVacia();
      // El espejo ya muestra el vencimiento del SEGUNDO pago
      // (confirmado); la op rechazada es la PRIMERA.
      await LocalDb.instance.upsertMirror(
          'clientes',
          502,
          {'id': 502, 'nombre': 'B', 'pagado_hasta': '2027-01-09'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 502,
              optimista: '2026-12-10',
              anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(502), '2027-01-09',
          reason: 'la reversión tardía borró el pago válido');
    });

    test('anterior null limpia el vencimiento solo si es el suyo',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          503,
          {'id': 503, 'nombre': 'C', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(clienteId: 503, optimista: '2026-12-10', anterior: null));
      expect(await _pagadoHastaEspejo(503), isNull);
    });

    test('op sin vencimiento optimista en el payload: no toca nada',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          504,
          {'id': 504, 'nombre': 'D', 'pagado_hasta': '2026-12-10'},
          1);
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(clienteId: 504, optimista: null, anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(504), '2026-12-10');
    });

    // 1.31 (H-04 residuo A-3, yunque de app): el caso
    // MISMO VALOR — dos pagos en vuelo que pintan el
    // MISMO pagado_hasta resultante. La guarda por VALOR
    // no podía distinguirlos y la reversión del primero
    // pisaba el segundo, confirmado. RESUELTO en el
    // Yunque de Sincronización (YS-5) con la guarda por
    // IDENTIDAD: el espejo guarda qué op pintó el
    // vencimiento (`ultimo_pago_op_uuid`).
    test('MISMO VALOR (YS-5): la procedencia es de la '
        'SEGUNDA op — el rechazo de la primera NO revierte',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          505,
          {'id': 505, 'nombre': 'E', 'pagado_hasta': '2026-12-10'},
          1);
      // La segunda op pintó el vencimiento vigente y se
      // confirmó; la rechazada es la primera.
      await LocalDb.instance
          .registrarProcedenciaPago(505, 'op-segunda');
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 505,
              optimista: '2026-12-10',
              anterior: '2026-11-10',
              opUuid: 'op-primera'));
      expect(await _pagadoHastaEspejo(505), '2026-12-10',
          reason: 'YS-5 roto: la reversión volvió a pisar el '
              'pago confirmado con el mismo valor');
    });

    test('H12: procedencia de OTRA op → no revierte, pero '
        'deja puesta la re-descarga forzada de clientes',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          508,
          {'id': 508, 'nombre': 'G', 'pagado_hasta': '2026-12-10'},
          1);
      await LocalDb.instance
          .registrarProcedenciaPago(508, 'op-segunda');
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 508,
              optimista: '2026-12-10',
              anterior: '2026-11-10',
              opUuid: 'op-primera'));
      // No revierte: el vencimiento vigente es de la segunda.
      expect(await _pagadoHastaEspejo(508), '2026-12-10');
      // Y la convergencia no queda fiada al pull delta: si
      // AMBAS ops hubieran sido rechazadas, la fila del
      // servidor nunca avanzó su sync_seq y el delta jamás
      // traería al cliente (patrón Missail).
      expect(
          await LocalDb.instance
              .getMeta('forzar_redescarga_clientes'),
          '1',
          reason: 'la rama procedencia != miUuid no activó la '
              're-descarga forzada');
    });

    test('YS-5: procedencia de ESTA op + mismo valor → '
        'revierte como siempre', () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          506,
          {'id': 506, 'nombre': 'F', 'pagado_hasta': '2026-12-10'},
          1);
      // El vencimiento vigente lo pintó esta misma op.
      await LocalDb.instance
          .registrarProcedenciaPago(506, 'op-test');
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 506,
              optimista: '2026-12-10',
              anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(506), '2026-11-10',
          reason: 'la identidad coincide: la reversión es '
              'legítima y dejó de ocurrir');
    });

    test('H5: la reversión LIMPIA el sello de la op revertida',
        () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          507,
          {'id': 507, 'nombre': 'H', 'pagado_hasta': '2026-12-10'},
          1);
      await LocalDb.instance
          .registrarProcedenciaPago(507, 'op-test');
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 507,
              optimista: '2026-12-10',
              anterior: '2026-11-10'));
      expect(await _pagadoHastaEspejo(507), '2026-11-10');
      expect(await _selloEspejo(507), isNull,
          reason: 'el sello sobrevivió a la reversión de su '
              'op: quedó apuntando a una op muerta');
    });

    test('H6: deshacer el cobro B no bloquea la reversión '
        'del cobro A anterior en vuelo', () async {
      await _abrirDbVacia();
      // A pinta su vencimiento (2026-12-10) y queda en vuelo.
      await LocalDb.instance.upsertMirror(
          'clientes',
          510,
          {'id': 510, 'nombre': 'J', 'pagado_hasta': '2026-12-10'},
          1);
      await LocalDb.instance
          .registrarProcedenciaPago(510, 'op-a');
      // B pinta encima (2027-01-09) y sella su op…
      await LocalDb.instance
          .updateMirrorPagadoHasta(510, '2027-01-09');
      await LocalDb.instance
          .registrarProcedenciaPago(510, 'op-b');
      // …y el cajero lo DESHACE en la ventana de 15 s: la
      // rama deshecho restaura el valor previo (el de A) y
      // limpia el sello de B.
      await LocalDb.instance
          .updateMirrorPagadoHasta(510, '2026-12-10');
      await LocalDb.instance.limpiarProcedenciaPago(510, 'op-b');
      expect(await _selloEspejo(510), isNull,
          reason: 'el sello de la op deshecha sobrevivió');
      // A se rechaza después: sin el sello podrido de B, la
      // guarda de identidad no delega y la reversión de A
      // ocurre como siempre.
      await SyncEngine.instance.revertirVencimientoOptimistaParaTest(
          _opPago(
              clienteId: 510,
              optimista: '2026-12-10',
              anterior: '2026-11-10',
              opUuid: 'op-a'));
      expect(await _pagadoHastaEspejo(510), '2026-11-10',
          reason: 'la reversión de A quedó bloqueada por el '
              'sello huérfano de B');
    });

    test('H6: pin — la rama deshecho del preview limpia el '
        'sello de la op deshecha', () {
      final preview =
          File('lib/ui/preview_cobro.dart').readAsStringSync();
      final i = preview
          .indexOf("resultado == 'deshecho' && clienteId != null");
      expect(i, isNonNegative);
      // La rama vive casi al final del archivo: se lee
      // hasta el fin en vez de una ventana fija.
      final rama = preview.substring(i);
      expect(rama, contains('limpiarProcedenciaPago'),
          reason: 'la rama deshecho dejó de limpiar el sello: '
              'volvería el bloqueo de H6');
    });

    test('H5/H6: limpiarProcedenciaPago solo limpia si el '
        'sello nombra a ESA op', () async {
      await _abrirDbVacia();
      await LocalDb.instance.upsertMirror(
          'clientes',
          509,
          {'id': 509, 'nombre': 'I', 'pagado_hasta': '2026-12-10'},
          1);
      await LocalDb.instance
          .registrarProcedenciaPago(509, 'op-b');
      // Un uuid ajeno NO limpia: el sello es de un cobro
      // posterior vivo.
      await LocalDb.instance.limpiarProcedenciaPago(509, 'op-a');
      expect(await _selloEspejo(509), 'op-b');
      // El propio sí.
      await LocalDb.instance.limpiarProcedenciaPago(509, 'op-b');
      expect(await _selloEspejo(509), isNull);
    });
  });

  group('A-2 · el sello de éxito exige push limpio (estructural)',
      () {
    final sync = File('lib/sync.dart').readAsStringSync();

    test('los bumps del push ensucian el veredicto de la corrida',
        () {
      final i = sync.indexOf('Future<void> _bumpConReversion');
      expect(i, isNonNegative);
      final cuerpo = sync.substring(i, i + 400);
      expect(cuerpo, contains('_fallosUltimoPush++'),
          reason: 'un bump ya no cuenta como fallo del push: '
              'el ciclo volvería a sellar en verde con la '
              'subida rota');
      expect(sync, contains('pushOk = _ultimoPushLimpio;'),
          reason: 'run() volvió a dar el push por bueno solo '
              'porque _doPush no lanzó');
    });

    test('la rama de ciclo completo exige pushOk para sellar', () {
      expect(sync, contains('if (completo && pushOk)'),
          reason: 'la rama completo volvió a sellar sin mirar '
              'la subida');
      final j = sync.indexOf('} else if (completo) {');
      expect(j, isNonNegative,
          reason: 'falta la rama «bajada completa, subida '
              'sucia» que conserva el error');
      final rama = sync.substring(j, j + 700);
      expect(rama, contains("setMeta('last_sync_error', msgPushSucio)"));
      expect(rama, isNot(contains('_marcarOk()')),
          reason: 'la rama de subida sucia no puede sellar');
    });

    test('el gancho de éxito y la limpieza de error van '
        'condicionados', () {
      expect(
          sync,
          contains('if (errorCorrida == null) _avisarSyncExitoso();'),
          reason: 'run() volvió a avisar éxito con la corrida '
              'en error');
      expect(sync, contains('if (_ultimoPushLimpio) _avisarSyncExitoso();'),
          reason: 'push() volvió a avisar éxito sin push limpio');
      final k = sync.indexOf("if (_ultimoPushLimpio) {\n"
          "        await _db.setMeta('last_sync_error', '');");
      expect(k, isNonNegative,
          reason: 'push() volvió a limpiar last_sync_error '
              'incondicionalmente');
    });
  });

  group('A-4 · la bandera de comprobantes no queda pegada', () {
    test('tras la pausa QoS, el siguiente ciclo SÍ procesa',
        () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      // Comprobante pendiente con el archivo ausente: si un
      // ciclo llega a procesarlo, termina en 'error'
      // (archivo_ausente) sin tocar la red.
      await d.insert('comprobantes_pago', {
        'comprobante_uuid': 'comp-a4',
        'ruta_local': '/no/existe/comp-a4.jpg',
        'storage_path': 'comprobantes/comp-a4.jpg',
        'estado': 'pendiente',
        'creado_en': '2026-11-10T00:00:00-05:00',
        'intentos': 0,
        'proximo_intento_en': 0,
      });
      // Una op de cobro pendiente cierra la puerta QoS.
      await db.queueOp(
          opUuid: 'op-a4',
          tipo: 'pago_mensual',
          payload: {'cliente_id': 1});
      expect(await ComprobantesService.instance.procesar(), 0);
      var fila = await ComprobantesService.instance.filaDe('comp-a4');
      expect(fila?['estado'], 'pendiente',
          reason: 'la puerta QoS no debió tocar la fila');
      // La op se aplica y la puerta se abre. Con la bandera
      // pegada (el defecto), este procesar() devolvería 0 al
      // instante sin mirar la fila.
      await db.markOp('op-a4', 'aplicada');
      await ComprobantesService.instance.procesar();
      fila = await ComprobantesService.instance.filaDe('comp-a4');
      expect(fila?['estado'], 'error',
          reason: 'el ciclo tras la pausa QoS no corrió: '
              '_procesando quedó pegada');
    });
  });

  group('B-3 · SessionExpired no se traga en TUS (estructural)',
      () {
    final sync = File('lib/sync.dart').readAsStringSync();

    test('_tusCrear y _tusOffset relanzan SessionExpired', () {
      final i = sync.indexOf('Future<String?> _tusCrear');
      expect(i, isNonNegative);
      final crear = sync.substring(i, i + 2600);
      expect(crear, contains('on SessionExpired'),
          reason: '_tusCrear volvió a tragar la sesión vencida '
              'como «TUS no disponible»');
      final j = sync.indexOf('Future<int> _tusOffset');
      expect(j, isNonNegative);
      final offset = sync.substring(j, j + 900);
      expect(offset, contains('on SessionExpired'),
          reason: '_tusOffset volvió a disfrazar la sesión '
              'vencida de «no se pudo averiguar» (-2)');
      // La rama receptora existe: subirFotoCola la convierte en
      // reintentable, sin fallback a PUT con la sesión muerta.
      expect(sync, contains("error: 'sesión expirada'"));
    });
  });

  group('A-5 · migración v71 (columna generacion)', () {
    test('comprobantes_pago nace con generacion en limpio',
        () async {
      await _abrirDbVacia();
      final d = await LocalDb.instance.db;
      final cols = await d.rawQuery(
          "SELECT name FROM pragma_table_info('comprobantes_pago')");
      expect(cols.map((c) => c['name']), contains('generacion'));
      expect(LocalDb.versionActual, 72);
    });
  });

  group('B-18 · encolar asegura el nuevo antes de borrar el viejo',
      () {
    test('re-encolar con el origen ausente NO destruye el '
        'comprobante anterior', () async {
      await _abrirDbVacia();
      final tmp = await Directory.systemTemp.createTemp('comp_b18');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final origen = File('${tmp.path}/captura.jpg');
      await origen.writeAsBytes([1, 2, 3, 4, 5]);
      await ComprobantesService.instance.encolar(
          comprobanteUuid: 'comp-b18',
          rutaOrigen: origen.path,
          baseDir: tmp);
      var fila =
          await ComprobantesService.instance.filaDe('comp-b18');
      expect(fila?['estado'], 'pendiente');
      final rutaVieja = fila!['ruta_local'] as String;
      expect(await File(rutaVieja).exists(), isTrue);

      // Re-encolado cuyo origen ya no existe: la llamada falla
      // y el comprobante anterior queda intacto (con el orden
      // viejo, su archivo ya estaba borrado y la fila apuntaba
      // al vacío).
      await expectLater(
          ComprobantesService.instance.encolar(
              comprobanteUuid: 'comp-b18',
              rutaOrigen: '${tmp.path}/ya-no-esta.jpg',
              baseDir: tmp),
          throwsA(anything));
      fila = await ComprobantesService.instance.filaDe('comp-b18');
      expect(fila?['ruta_local'], rutaVieja);
      expect(fila?['estado'], 'pendiente');
      expect(await File(rutaVieja).readAsBytes(), [1, 2, 3, 4, 5]);
    });

    test('re-encolar válido sustituye el archivo', () async {
      await _abrirDbVacia();
      final tmp = await Directory.systemTemp.createTemp('comp_b18b');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final o1 = File('${tmp.path}/uno.jpg');
      await o1.writeAsBytes([9, 9]);
      await ComprobantesService.instance.encolar(
          comprobanteUuid: 'comp-b18b',
          rutaOrigen: o1.path,
          baseDir: tmp);
      final o2 = File('${tmp.path}/dos.jpg');
      await o2.writeAsBytes([7, 7, 7]);
      await ComprobantesService.instance.encolar(
          comprobanteUuid: 'comp-b18b',
          rutaOrigen: o2.path,
          baseDir: tmp);
      final fila =
          await ComprobantesService.instance.filaDe('comp-b18b');
      expect(
          await File(fila!['ruta_local'] as String).readAsBytes(),
          [7, 7, 7]);
    });
  });

  group('B-14 · foto de incidencia a documentos gestionados', () {
    late Directory docs;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      docs = await Directory.systemTemp.createTemp('b14_docs');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => docs.path);
    });

    test('copia con su extensión y devuelve la ruta gestionada',
        () async {
      final tmp = await Directory.systemTemp.createTemp('b14_tmp');
      addTearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });
      final origen = File('${tmp.path}/cache_picker.jpg');
      await origen.writeAsBytes([5, 6, 7, 8]);
      final ruta = await copiarFotoGestionada(
        subdirectorio: 'incidencias_fotos',
        nombreBase: 'foto-1',
        rutaOrigen: origen.path,
      );
      expect(ruta, '${docs.path}/incidencias_fotos/foto-1.jpg');
      expect(await File(ruta).readAsBytes(), [5, 6, 7, 8]);
      // La copia sobrevive a la purga de la caché temporal.
      await origen.delete();
      expect(await File(ruta).exists(), isTrue);
    });

    test('origen desaparecido o vacío: lanza y no crea copia',
        () async {
      await expectLater(
          copiarFotoGestionada(
            subdirectorio: 'incidencias_fotos',
            nombreBase: 'foto-x',
            rutaOrigen: '${docs.path}/no-existe.jpg',
          ),
          throwsA(isA<StateError>()));
      expect(
          await File('${docs.path}/incidencias_fotos/foto-x.jpg')
              .exists(),
          isFalse);
    });

    test('los dos sitios de detalle guardan la copia gestionada '
        '(estructural)', () {
      final detalle = File('lib/ui/incidencias/detalle_incidencia.dart')
          .readAsStringSync();
      expect(detalle, contains('copiarFotoGestionada'));
      expect(detalle.contains("'local_path': xfile.path"), isFalse,
          reason: 'la ruta temporal del selector volvió a '
              'guardarse como local_path');
      expect(detalle.contains("'local_path': fotoPath"), isFalse);
    });
  });

  group('B-13 · la foto en error conserva su única copia', () {
    late Directory docs;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      docs = await Directory.systemTemp.createTemp('b13_docs');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => docs.path);
    });

    test('limpiarHuerfanos purga la completada vieja y NO toca '
        'la fila en error ni su archivo', () async {
      await _abrirDbVacia();
      final db = await LocalDb.instance.db;
      final fotosDir = Directory('${docs.path}/fotos');
      await fotosDir.create(recursive: true);
      final hace8 = isoHabana(
          ahoraHabana().subtract(const Duration(days: 8)));
      final ahora = isoHabana(ahoraHabana());
      Future<void> sembrar(String uuid, String estado) async {
        final f = File('${fotosDir.path}/$uuid.jpg');
        await f.writeAsBytes([1, 2, 3]);
        await db.insert('fotos_cola', {
          'op_uuid': uuid,
          'tipo': 'display',
          'cliente_id': 5,
          'ruta_local': f.path,
          'estado': estado,
          'intentos': estado == 'error' ? 5 : 1,
          'creado_en': hace8,
          'actualizado_en': hace8,
        });
      }

      await sembrar('b13-error', 'error');
      await sembrar('b13-ok', 'completada');
      // Recién creada en error: tampoco se toca, obviamente.
      final fNueva = File('${fotosDir.path}/b13-nueva.jpg');
      await fNueva.writeAsBytes([4]);
      await db.insert('fotos_cola', {
        'op_uuid': 'b13-nueva',
        'tipo': 'display',
        'cliente_id': 5,
        'ruta_local': fNueva.path,
        'estado': 'error',
        'intentos': 5,
        'creado_en': ahora,
        'actualizado_en': ahora,
      });

      await FotosColaService.instance.limpiarHuerfanos();

      final quedan = await db.query('fotos_cola',
          columns: ['op_uuid'], orderBy: 'op_uuid ASC');
      expect(quedan.map((r) => r['op_uuid']).toList(),
          ['b13-error', 'b13-nueva'],
          reason: 'la completada vieja sale; las de error quedan '
              'con su fila');
      expect(
          await File('${fotosDir.path}/b13-error.jpg').exists(),
          isTrue,
          reason: 'el archivo de la foto en error es su única '
              'copia: no puede borrarse en silencio');
      expect(await File('${fotosDir.path}/b13-ok.jpg').exists(),
          isFalse,
          reason: 'la completada sí se purga (está en Storage)');
    });

    test('la reactivación desde la Cola cubre el estado error '
        '(estructural, base 1.30)', () {
      final cola = File('lib/ui/cola.dart').readAsStringSync();
      expect(cola, contains('reintentarTodasFotosCola'));
      expect(cola, contains("estado IN ('pendiente', 'error')"),
          reason: 'el reintento masivo dejó de cubrir las fotos '
              'en error');
    });
  });

  group('A-6 · autocura del espejo corrupto', () {
    test('la causa probable nombra la corrupción primero', () {
      final conCorrupcion = causaProbableEspejoVacio(
          haySyncOk: true, opsPendientes: 0, filasCorruptas: 3);
      expect(conCorrupcion, contains('dañados'));
      expect(conCorrupcion, contains('3'));
      // Sin corrupción, las ramas de siempre quedan intactas.
      final sinSync = causaProbableEspejoVacio(
          haySyncOk: false, opsPendientes: 0);
      expect(sinSync, contains('no registra ninguna'));
    });

    test('el consumidor traduce mirror_corruptas_* en '
        'forzar_redescarga_* solo en tablas del pull', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      await db.setMeta('mirror_corruptas_clientes', '2');
      await db.setMeta('mirror_corruptas_pagos', '0');
      await db.setMeta('mirror_corruptas_tabla_inventada', '5');
      await SyncEngine.instance
          .marcarRedescargaPorCorruptasParaTest();
      expect(await db.getMeta('forzar_redescarga_clientes'), '1',
          reason: 'la tabla corrupta no quedó marcada para '
              're-bajarse: la corrupción seguiría eterna');
      expect(await db.getMeta('forzar_redescarga_pagos'), isNull,
          reason: 'una señal en 0 no debe forzar nada');
      expect(
          await db.getMeta('forzar_redescarga_tabla_inventada'),
          isNull,
          reason: 'una clave ajena no crea banderas huérfanas');
    });

    test('evaluarEspejoVacio diagnostica corrupción cuando el '
        'espejo «vacío» son filas dañadas', () async {
      await _abrirDbVacia();
      final d = await LocalDb.instance.db;
      // La columna data exige JSON válido (CHECK de esquema):
      // la forma «corrupta» alcanzable es un JSON que no es el
      // mapa esperado — para todo lector del espejo esa fila
      // no existe (es el criterio de conteoMirrorLegible).
      await d.insert('clientes', {
        'id': 77,
        'data': '[1,2,3]',
        'sync_seq': 9,
      });
      await LocalDb.instance
          .setMeta('clientes_previos_buenos', '4');
      await LocalDb.instance.setMeta(
          'last_pull_ok', isoHabana(ahoraHabana()));
      final diag = await evaluarEspejoVacio();
      expect(diag, isNotNull);
      expect(diag!.causaProbable, contains('dañados'),
          reason: 'el W1 volvió a culpar a la bajada de una '
              'corrupción local');
    });
  });

  group('B-24 · la purga de sesión alcanza a las solo-dueño', () {
    late Directory docs;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      docs = await Directory.systemTemp.createTemp('b24_docs');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (call) async => docs.path);
    });

    test('borra las filas confirmadas de las prohibidas, '
        'conserva las locales y resetea su watermark', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      // Congelaciones: una confirmada del dueño anterior
      // (con motivo sensible) y una local sin confirmar.
      await d.insert('cliente_congelaciones', {
        'id': 'cong-confirmada',
        'data': '{"motivo":"dato de salud"}',
        'sync_seq': 42,
      });
      await d.insert('cliente_congelaciones', {
        'id': 'cong-local',
        'data': '{"motivo":"aun no sube"}',
        'sync_seq': 0,
      });
      await d.insert('servicio_lotes', {
        'id': 7,
        'data': '{"dosis":30}',
        'sync_seq': 9,
      });
      await db.setMeta('wm_cliente_congelaciones', '42');
      await db.setMeta('wm_servicio_lotes', '9');

      await db.purgarDatosSensibles();

      final congs = await d.query('cliente_congelaciones',
          columns: ['id']);
      expect(congs.map((r) => r['id']).toList(), ['cong-local'],
          reason: 'la congelación confirmada (con el motivo) '
              'sobrevivió al cierre de sesión');
      expect(await d.query('servicio_lotes'), isEmpty,
          reason: 'los lotes confirmados sobrevivieron');
      expect(await db.getMeta('wm_cliente_congelaciones'), '0');
      expect(await db.getMeta('wm_servicio_lotes'), '0');
    });
  });

  group('B-25 · el cursor de borrados no hereda el global', () {
    test('sin meta wm_borrados, el cursor es 0 aunque el '
        'global sea alto; con meta, manda la meta', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      await db.setWatermark(9999);
      expect(await db.getWatermarkTabla('borrados'), 0,
          reason: 'el cursor de tombstones heredó el global: '
              'los borrados viejos no se re-aplicarían nunca');
      await db.setWatermarkTabla('borrados', 123);
      expect(await db.getWatermarkTabla('borrados'), 123);
      // Las demás tablas con herencia siguen heredando.
      expect(await db.getWatermarkTabla('clientes'), 9999);
    });

    test('la migración v27 escribe 0 en vez de borrar '
        '(estructural)', () {
      final localdb = File('lib/localdb.dart').readAsStringSync();
      final i = localdb.indexOf('if (oldV < 27)');
      expect(i, isNonNegative);
      final bloque = localdb.substring(i, i + 700);
      expect(bloque, contains("'wm_borrados', 'v': '0'"),
          reason: 'la migración volvió a borrar la meta: el '
              'cursor caería al global heredado');
      expect(bloque.contains("delete('meta'"), isFalse);
    });
  });

  group('B-11/B-12/C-6 · el FGS cuenta la tubería completa', () {
    test('contarCompletadas solo cuenta las que llegaron',
        () async {
      await _abrirDbVacia();
      final d = await LocalDb.instance.db;
      final ahora = isoHabana(ahoraHabana());
      for (final (uuid, estado) in [
        ('fgs-c1', 'completada'),
        ('fgs-c2', 'completada'),
        ('fgs-p1', 'pendiente'),
        ('fgs-b1', 'pendiente'), // en backoff: NO es progreso
        ('fgs-e1', 'error'),
      ]) {
        await d.insert('fotos_cola', {
          'op_uuid': uuid,
          'tipo': 'display',
          'cliente_id': 5,
          'ruta_local': '/tmp/$uuid.jpg',
          'estado': estado,
          'intentos': 0,
          'creado_en': ahora,
          'actualizado_en': ahora,
        });
      }
      expect(await FotosColaService.instance.contarCompletadas(),
          2);
    });

    test('arranque, progreso, parada y sin-sesión miran las '
        'cuentas nuevas (estructural)', () {
      final fgs =
          File('lib/fotos_foreground.dart').readAsStringSync();
      // B-12: comprobantes y fotos de incidencias en el FGS.
      expect(fgs, contains('contarComprobantesSinSubir'));
      expect(fgs, contains('contarFotosIncidenciasPendientes'));
      // B-11: progreso por delta de completadas.
      expect(fgs, contains('contarCompletadas'));
      expect(fgs.contains('reclamablesAntes - reclamablesDespues'),
          isFalse,
          reason: 'el progreso volvió a medirse por reclamables: '
              'el backoff «progresa» en falso');
      // C-6: sin sesión persistente, el servicio se detiene.
      expect(fgs, contains('SyncMotivoNoCorrio.sinSesion'));
      expect(fgs, contains('_ticksSinSesion'));
    });
  });

  group('B-22 · el no-dueño no sustituye la asignación a '
      'entrenador', () {
    test('asignadoAAlGuardar preserva la de entrenador aunque '
        'el no-dueño elija cliente', () {
      const delDueno = 'entrenador:duany:Duany';
      // El caso del defecto: existente a entrenador + elección
      // «cliente» de un no-dueño → se preserva la del dueño.
      expect(
          asignadoAAlGuardar(
            esDueno: false,
            responsableElegido: 'cliente:9:Nueve',
            tipoResponsable: 'cliente',
            asignadoExistente: delDueno,
          ),
          delDueno);
      // Sin asignación a entrenador vigente, su elección a
      // cliente sí vale.
      expect(
          asignadoAAlGuardar(
            esDueno: false,
            responsableElegido: 'cliente:9:Nueve',
            tipoResponsable: 'cliente',
            asignadoExistente: null,
          ),
          'cliente:9:Nueve');
      expect(
          asignadoAAlGuardar(
            esDueno: false,
            responsableElegido: 'cliente:9:Nueve',
            tipoResponsable: 'cliente',
            asignadoExistente: 'cliente:3:Tres',
          ),
          'cliente:9:Nueve');
      // No-dueño sin elegir cliente: nada (como antes).
      expect(
          asignadoAAlGuardar(
            esDueno: false,
            responsableElegido: null,
            tipoResponsable: null,
            asignadoExistente: null,
          ),
          isNull);
      // El dueño manda siempre con su selección.
      expect(
          asignadoAAlGuardar(
            esDueno: true,
            responsableElegido: 'cliente:9:Nueve',
            tipoResponsable: 'cliente',
            asignadoExistente: delDueno,
          ),
          'cliente:9:Nueve');
    });
  });

  group('B-16 · política única de transiciones por rol', () {
    Incidencia inc(String estado) => Incidencia(
          id: 'i1',
          descripcion: 'x',
          estado: estado,
          prioridad: 'media',
          creadaPor: 'autor',
          creadaEn: DateTime(2026, 1, 1),
          version: 1,
          syncEstado: 'synced',
        );

    test('resolver y reabrir son solo del dueño; el resto del '
        'flujo no cambia', () {
      final pendiente = inc('pendiente');
      expect(
          pendiente.puedeTransicionarAConRol('resuelta',
              esDueno: false),
          isFalse,
          reason: 'el detalle ofrecía Resolver a cualquier rol');
      expect(
          pendiente.puedeTransicionarAConRol('resuelta',
              esDueno: true),
          isTrue);
      expect(
          pendiente.puedeTransicionarAConRol('en_proceso',
              esDueno: false),
          isTrue);
      expect(
          pendiente.puedeTransicionarAConRol('bloqueada',
              esDueno: false),
          isTrue);
      final resuelta = inc('resuelta');
      expect(
          resuelta.puedeTransicionarAConRol('en_proceso',
              esDueno: false),
          isFalse,
          reason: 'la reapertura es solo del dueño');
      expect(
          resuelta.puedeTransicionarAConRol('en_proceso',
              esDueno: true),
          isTrue);
      // La máquina de estados sigue mandando debajo del rol.
      expect(
          pendiente.puedeTransicionarAConRol('pendiente',
              esDueno: true),
          isFalse);
    });

    test('detalle y lote consumen la política (estructural)',
        () {
      final detalle = File('lib/ui/incidencias/detalle_incidencia.dart')
          .readAsStringSync();
      expect(detalle, contains('puedeTransicionarAConRol'));
      final lista = File('lib/ui/incidencias/lista_incidencias.dart')
          .readAsStringSync();
      expect(lista, contains("destino == 'resuelta' && !AuthService().isOwner"),
          reason: 'la acción en lote quedó sin la guarda de rol');
    });
  });

  group('B-15 · el fallo de carga se VE en las 3 superficies '
      'de incidencias (estructural)', () {
    void esperaErrorVisible(String ruta, String nombre) {
      final s = File(ruta).readAsStringSync();
      expect(s, contains('_errorCarga'),
          reason: '$nombre no tiene estado de error de carga');
      expect(s, contains('EstadoError('),
          reason: '$nombre no pinta el error con el widget de '
              'la casa');
      expect(s, contains('onReintentar: _cargar'),
          reason: '$nombre no ofrece Reintentar');
      expect(s, contains('mensajeErrorAmable'),
          reason: '$nombre no traduce el error a lenguaje llano');
    }

    test('incidencias_sync (la prioritaria: mentía en '
        'silencio)', () {
      esperaErrorVisible(
          'lib/ui/incidencias_sync.dart', 'incidencias_sync');
      final s =
          File('lib/ui/incidencias_sync.dart').readAsStringSync();
      expect(s, contains("AppLog.error('incidencias_sync', 'carga_fallo'"),
          reason: 'su _cargar sigue sin bitácora (no recibió '
              'la familia R2-X1)');
    });

    test('lista de incidencias', () {
      esperaErrorVisible('lib/ui/incidencias/lista_incidencias.dart',
          'lista');
    });

    test('detalle de incidencia (no más «No encontrada» falso)',
        () {
      esperaErrorVisible(
          'lib/ui/incidencias/detalle_incidencia.dart', 'detalle');
    });
  });

  group('B-23 · «en turno» del W5 cruza el espejo', () {
    test('telegramIdsConTurnoAbierto une la tabla local con '
        'las aperturas del espejo sin cierre', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      final h = ahoraHabana();
      String dos(int n) => n.toString().padLeft(2, '0');
      final hoy = '${h.year}-${dos(h.month)}-${dos(h.day)}';
      // Apertura del espejo SIN cierre (otro teléfono): en turno.
      await d.insert('turnos_apertura', {
        'id': 'ap-espejo-viva',
        'data': jsonEncode({
          'turno_id': 't-viva',
          'fecha_turno': hoy,
          'turno': 'manana',
          'telegram_id': 222,
          'entrenador_nombre': 'Gabriel',
        }),
        'sync_seq': 10,
      });
      // Apertura del espejo YA cerrada en el espejo: no cuenta.
      await d.insert('turnos_apertura', {
        'id': 'ap-espejo-cerrada',
        'data': jsonEncode({
          'turno_id': 't-cerrada',
          'fecha_turno': hoy,
          'turno': 'tarde',
          'telegram_id': 333,
          'entrenador_nombre': 'Duany',
        }),
        'sync_seq': 11,
      });
      await d.insert('turnos_cierre', {
        'id': 'ci-espejo',
        'data': jsonEncode({
          'turno_id': 't-cerrada',
          'fecha': hoy,
          'turno': 'tarde',
          'telegram_id': 333,
        }),
        'sync_seq': 12,
      });
      // Apertura de AYER en el espejo: no es de hoy.
      final ayerDate = h.subtract(const Duration(days: 1));
      final ayer =
          '${ayerDate.year}-${dos(ayerDate.month)}-${dos(ayerDate.day)}';
      await d.insert('turnos_apertura', {
        'id': 'ap-ayer',
        'data': jsonEncode({
          'turno_id': 't-ayer',
          'fecha_turno': ayer,
          'turno': 'manana',
          'telegram_id': 444,
          'entrenador_nombre': 'Otro',
        }),
        'sync_seq': 9,
      });
      // Y la local de este teléfono sigue contando.
      await d.insert('turnos', {
        'turno_id': 'turno-local',
        'fecha_turno': hoy,
        'turno': 'manana',
        'hora_apertura': '${hoy}T07:00:00-05:00',
        'estado': 'abierto_local',
        'telegram_id': 111,
      });

      final enTurno = await db.telegramIdsConTurnoAbierto(hoy);
      expect(enTurno, {111, 222},
          reason: 'local (111) + espejo viva (222); la cerrada '
              '(333) y la de ayer (444) quedan fuera');
    });
  });

  group('B-27 · la foto de atascos no esconde atascos', () {
    test('cuenta comprobantes sin subir (también error) y '
        'fotos subiendo con lease vencido', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      final ahora = isoHabana(ahoraHabana());
      for (final (uuid, estado) in [
        ('comp-p', 'pendiente'),
        ('comp-e', 'error'),
        ('comp-s', 'subido'),
      ]) {
        await d.insert('comprobantes_pago', {
          'comprobante_uuid': uuid,
          'ruta_local': '/tmp/$uuid.jpg',
          'estado': estado,
          'creado_en': ahora,
        });
      }
      final vencido = isoHabana(
          ahoraHabana().subtract(const Duration(minutes: 30)));
      final vigente = isoHabana(
          ahoraHabana().add(const Duration(minutes: 30)));
      for (final (uuid, estado, lease) in [
        ('f-pend', 'pendiente', null),
        ('f-sub-vencida', 'subiendo', vencido),
        ('f-sub-vigente', 'subiendo', vigente),
        ('f-error', 'error', null),
      ]) {
        await d.insert('fotos_cola', {
          'op_uuid': uuid,
          'tipo': 'display',
          'cliente_id': 5,
          'ruta_local': '/tmp/$uuid.jpg',
          'estado': estado,
          'intentos': 1,
          'lease_hasta': lease,
          'creado_en': ahora,
          'actualizado_en': ahora,
        });
      }

      final foto = await capturarAtascos();
      expect(foto.comprobantesPendientes, 2,
          reason: 'el comprobante en error desapareció de la '
              'foto (se contaba solo pendiente)');
      expect(foto.fotosPendientes, 2,
          reason: 'pendiente + subiendo con lease vencido; la '
              'de lease vigente está en manos de su worker');
      expect(foto.fotosError, 1);
    });

    test('el hallazgo de ops avisa de las ops ajenas del '
        'teléfono compartido', () {
      const foto = FotoAtascos(
        opsPendientes: 3,
        opsEnviadas: 0,
        opsError: 1,
        opsRechazadas: 0,
        opsRevision: 0,
        fotosPendientes: 0,
        fotosError: 0,
        fotosIncidenciasPendientes: 0,
        comprobantesPendientes: 0,
        tablasPorRedescargar: 0,
        manifiestoSinVerificar: [],
        espejoVacioSospechoso: false,
        clientesPrevios: 0,
        lecturasFallidas: 0,
      );
      final hallazgos = clasificarHallazgos(foto);
      final deOps = hallazgos
          .where((x) => x.detalle.contains('otra cuenta'))
          .toList();
      expect(deOps, hasLength(2),
          reason: 'los hallazgos «auto» de ops (pendientes y '
              'error) no avisan de las ops de otra cuenta');
    });
  });

  group('C-11 · refrescarMirrorCliente refresca el FTS', () {
    test('tras el refresco puntual, el índice trae el nombre '
        'y el teléfono NUEVOS', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      await db.upsertMirror('clientes', 31,
          {'nombre': 'Nombre Viejo', 'telefono': '11112222'}, 5);
      var fts = await d.query('clientes_fts',
          columns: ['nombre_norm', 'telefonos'],
          where: 'id = ?',
          whereArgs: [31]);
      expect(fts, hasLength(1));
      expect(fts.first['nombre_norm'], contains('viejo'));

      final ok = await db.refrescarMirrorCliente(
          31,
          jsonEncode(
              {'nombre': 'Nombre Nuevo', 'telefono': '33334444'}),
          6);
      expect(ok, isTrue);
      fts = await d.query('clientes_fts',
          columns: ['nombre_norm', 'telefonos'],
          where: 'id = ?',
          whereArgs: [31]);
      expect(fts, hasLength(1),
          reason: 'el refresco dejó dos filas o ninguna en el '
              'índice');
      expect(fts.first['nombre_norm'], contains('nuevo'));
      expect(fts.first['nombre_norm'], isNot(contains('viejo')),
          reason: 'el buscador seguiría encontrándolo por el '
              'nombre viejo hasta el próximo pull');
      expect('${fts.first['telefonos']}', contains('33334444'));
    });
  });

  group('C-8 · la poda de reservas no la condena una fila '
      'ilegible', () {
    test('purgarReservasLocalesViejas borra la ilegible aparte '
        'y poda las legibles', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      final vieja = isoHabana(
          ahoraHabana().subtract(const Duration(days: 100)));
      final hoyTxt = isoHabana(ahoraHabana());
      Future<void> sembrar(int id, String data, int seq) =>
          d.insert('reservas',
              {'id': id, 'data': data, 'sync_seq': seq});
      // Legible, terminal y vieja: se poda (paso 2).
      await sembrar(
          1,
          jsonEncode({'estado': 'pagada', 'creada_ts': vieja}),
          5);
      // Ilegible del servidor: se borra aparte (paso 1) y NO
      // bloquea al resto — antes el DELETE entero moría con
      // ella y la poda devolvía −1 para siempre.
      await sembrar(2, 'esto no es json', 5);
      // Legible no terminal: se queda.
      await sembrar(
          3,
          jsonEncode({'estado': 'confirmada', 'creada_ts': vieja}),
          5);
      // Legible terminal pero reciente: se queda.
      await sembrar(
          4,
          jsonEncode({'estado': 'pagada', 'creada_ts': hoyTxt}),
          5);
      // Ilegible LOCAL (sync_seq 0): no es del espejo, se queda.
      await sembrar(5, 'tampoco es json', 0);

      final n = await db.purgarReservasLocalesViejas();
      expect(n, 2,
          reason: 'la poda no devolvió el total (ilegible + '
              'legible vieja) o volvió a condenarse a −1');
      final quedan = await d.query('reservas',
          columns: ['id'], orderBy: 'id ASC');
      expect(quedan.map((r) => r['id']).toList(), [3, 4, 5]);
    });
  });

  group('Cola de bajas · C-1/C-2/C-9/C-10/B-26/B-8', () {
    test('C-1 · un error técnico en minúsculas no pasa por '
        'motivo de negocio', () {
      final tecnico = explicacionOp(
          estado: 'rechazada',
          error: 'http 409: duplicate key value violates');
      expect(tecnico.motivo, isNot(contains('duplicate key')));
      final tecnico2 = explicacionOp(
          estado: 'rechazada', error: 'clientexception: boom');
      expect(tecnico2.motivo, isNot(contains('clientexception')));
      // Control positivo: un motivo de negocio en español SÍ
      // se muestra tal cual.
      final negocio = explicacionOp(
          estado: 'rechazada',
          error: 'El cliente ya tiene una reserva ese día');
      expect(negocio.motivo,
          'El cliente ya tiene una reserva ese día');
    });

    test('C-2 · el núcleo En de auditoría compone en la '
        'transacción del llamador (rollback total)', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      // Composición feliz: evento + lectura de hashes dentro
      // de UNA transacción.
      late String idOk;
      await d.transaction((txn) async {
        idOk = await db.auditoriaInsertEn(txn,
            actorId: 'u1',
            actorNombre: 'Dueño',
            accion: 'prueba_c2',
            objetoTipo: 'cliente',
            objetoId: '1',
            dispositivoId: 'dev');
        final propia = await db.auditoriaPorId(idOk, txn: txn);
        expect(propia, isNotNull);
        expect(propia!['hash_propio'], isNotNull);
      });
      expect(await db.auditoriaPorId(idOk), isNotNull);
      // Si la transacción del llamador muere tras el insert,
      // el evento NO queda (antes: evento local sin su op).
      await expectLater(
        d.transaction((txn) async {
          await db.auditoriaInsertEn(txn,
              actorId: 'u1',
              actorNombre: 'Dueño',
              accion: 'prueba_c2_falla',
              objetoTipo: 'cliente',
              objetoId: '2',
              dispositivoId: 'dev');
          throw StateError('muerte simulada a mitad');
        }),
        throwsStateError,
      );
      final filas = await d.query('auditoria_local',
          where: 'accion=?', whereArgs: ['prueba_c2_falla']);
      expect(filas, isEmpty,
          reason: 'el evento quedó sin su op: la transacción '
              'no fue atómica');
      // Y el cableado del motor usa la composición.
      final syncSrc = File('lib/sync.dart').readAsStringSync();
      final cuerpo = syncSrc.substring(
          syncSrc.indexOf('Future<String> registrarAuditoria'));
      expect(
          cuerpo.substring(0, cuerpo.indexOf('\n  }\n') + 4),
          contains('auditoriaInsertEn'));
    });

    test('C-9 · las cáscaras eliminado no cuentan como '
        'legibles y el conteo se memoiza', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      await db.upsertMirror('clientes', 1,
          {'nombre': 'Ana', 'estado': 'activo'}, 5);
      await db.upsertMirror('clientes', 2,
          {'nombre': 'Cliente eliminado', 'estado': 'eliminado'},
          6);
      final d = await db.db;
      await d.insert('clientes',
          {'id': 3, 'data': '[1,2,3]', 'sync_seq': 7});
      final c = await db.conteoMirrorLegible('clientes');
      expect(c.total, 3);
      expect(c.legibles, 1,
          reason: 'la cáscara contó como persona legible');
      expect(c.carcaras, 1);
      expect(c.corruptas, 1);
      // Memo: segunda llamada, mismo resultado.
      final c2 = await db.conteoMirrorLegible('clientes');
      expect(c2.legibles, 1);
      // La huella cambia (fila nueva con seq mayor): recount.
      await db.upsertMirror(
          'clientes', 4, {'nombre': 'Beto', 'estado': 'activo'}, 8);
      final c3 = await db.conteoMirrorLegible('clientes');
      expect(c3.legibles, 2);
    });

    test('C-10 · seqFilaMirror distingue error de ausencia',
        () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      await db.upsertMirror('clientes', 9, {'nombre': 'Ana'}, 42);
      final presente = await db.seqFilaMirror('clientes', '9');
      expect(presente.ok, isTrue);
      expect(presente.seq, 42);
      final ausente = await db.seqFilaMirror('clientes', '999');
      expect(ausente.ok, isTrue);
      expect(ausente.seq, isNull);
      final error = await db.seqFilaMirror('tabla_inexistente', '1');
      expect(error.ok, isFalse,
          reason: 'un error de lectura se disfrazó de ausencia');
      expect(error.seq, isNull);
    });

    test('B-26 · mirrorPorFecha usa el día Habana también en '
        'la rama SQL', () async {
      await _abrirDbVacia();
      final db = LocalDb.instance;
      final d = await db.db;
      // 2026-11-09T01:30Z = 2026-11-08 21:30 en La Habana:
      // el día de negocio es el 8, no el 9 del prefijo UTC.
      await d.insert('reservas', {
        'id': 1,
        'data': jsonEncode(
            {'creada_ts': '2026-11-09T01:30:00.000Z', 'estado': 'pagada'}),
        'sync_seq': 5,
      });
      final del8 = await db.mirrorPorFecha(
          'reservas', 'creada_ts', '2026-11-08', '2026-11-08');
      expect(del8.map((m) => m['id']), contains(1),
          reason: 'la rama SQL lo buscó por el prefijo UTC y '
              'lo perdió');
      final del9 = await db.mirrorPorFecha(
          'reservas', 'creada_ts', '2026-11-09', '2026-11-09');
      expect(del9.map((m) => m['id']), isNot(contains(1)));
    });

    test('B-8 · la persistencia declarada manda sobre la '
        'estima por tipo de error', () {
      // Red: el clasificador estima «guardado»…
      final red = traducirErrorSync(
          Exception('SocketException: Connection failed'));
      expect(red.datosGuardadosLocalmente, isTrue);
      // …pero si el llamador declara que NO hubo escritura
      // local previa, su palabra manda.
      final redSinPersistir = traducirErrorSync(
          Exception('SocketException: Connection failed'),
          persistenciaConfirmada: false);
      expect(redSinPersistir.datosGuardadosLocalmente, isFalse);
      expect(redSinPersistir.codigo, red.codigo,
          reason: 'solo cambia la persistencia, no la clase');
      // Y al revés: un error que el clasificador marca «no
      // guardado» con persistencia confirmada → guardado.
      final conPersistencia = traducirErrorSync(
          Exception('DatabaseException: disk full'),
          persistenciaConfirmada: true);
      expect(conPersistencia.datosGuardadosLocalmente, isTrue);
    });

    test('C-4/C-5/C-7/C-12 · incidencias: catch en guardar, '
        'version_base, selector seguro y build sin IO', () {
      final editar =
          File('lib/ui/incidencias/editar_incidencia.dart')
              .readAsStringSync();
      final detalle =
          File('lib/ui/incidencias/detalle_incidencia.dart')
              .readAsStringSync();
      final tipos = File('lib/ui/incidencias/tipos_incidencia.dart')
          .readAsStringSync();
      final comprobantes =
          File('lib/comprobantes.dart').readAsStringSync();
      // C-4: _guardar atrapa y avisa (antes solo finally).
      final guardar = editar.substring(
          editar.indexOf('Future<void> _guardar()'));
      expect(guardar, contains('guardar_fallo'));
      expect(guardar, contains('mensajeErrorAmable'));
      // C-7: el selector no se construye si el valor no tiene
      // segmento visible para el rol.
      expect(editar,
          contains("_esDueno || _tipoResponsable != 'entrenador'"));
      // C-5: AMBAS ops de cambio de estado llevan OCC.
      expect("'version_base': _inc!.version"
          .allMatches(detalle)
          .length, 2);
      // C-12: el build del detalle no hace IO síncrona ni crea
      // futures; _reordenar no muta la lista dentro de la
      // transacción; el barrido de huérfanos tiene tope 24 h.
      expect(detalle, isNot(contains('file.existsSync()')));
      expect(detalle, contains('_futurasRemotas[f.storagePath]'));
      expect(tipos, isNot(contains('_tipos.removeAt(oldIndex)')));
      expect(tipos, contains('List<TipoIncidencia>.of(_tipos)'));
      expect(comprobantes, contains('_ultimoBarridoHuerfanos'));
    });

    test('B-6 · el resultado declara el corte por lock', () {
      const r = SyncResultado(corrio: true, cortadoPorLock: true);
      expect(r.cortadoPorLock, isTrue);
      const normal = SyncResultado(corrio: true);
      expect(normal.cortadoPorLock, isFalse);
      const nc = SyncResultado.noCorrio(SyncMotivoNoCorrio.enCurso);
      expect(nc.cortadoPorLock, isFalse);
      final syncSrc = File('lib/sync.dart').readAsStringSync();
      expect('cortadoPorLock = true'.allMatches(syncSrc).length,
          greaterThanOrEqualTo(3),
          reason: 'run/push/pull deben marcar el corte');
      expect(syncSrc, contains('cortado: cortadoScope'));
    });
  });
}
