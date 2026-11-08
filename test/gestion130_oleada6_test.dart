/// Gestión 1.30 · Oleada 6 (§8, GY-03): que quitar la imagen
/// de un artículo GymPedia borre el objeto del bucket.
///
/// Contrato que se fija (plan §8.2 y §8.3, con BAJA-01):
/// · Quitar la imagen y publicar → en la MISMA operación se
///   pide el borrado del objeto `<slug>.webp` (la ruta sale
///   del propio artículo) y la op de publicación se encola.
/// · Reemplazar la imagen → la nueva sube primero (upsert
///   sobre el MISMO objeto) y NO se pide ningún borrado: la
///   vieja muere al aterrizar la nueva y borrar tras subir
///   mataría la imagen nueva.
/// · Si el borrado falla → 1 reintento inmediato (2 intentos
///   en total) y, si persiste, el aviso «El artículo se
///   guardó; la imagen anterior se limpiará en el próximo
///   barrido» con la operación principal dada por buena (el
///   artículo SÍ se guardó y la op SÍ se encoló).
/// · Sin imagen previa o sin tocar la imagen → el almacén no
///   recibe ninguna llamada.
/// · Fuente (BAJA-01): no nace ninguna tabla/cola de
///   reintento nueva para este borrado.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/gympedia_almacen.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/gympedia_editor.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _slug = 'articulo-o6';

/// Almacén falso (§8.3): registra las llamadas en orden y deja
/// guionizar el resultado de la subida y del borrado.
class _AlmacenFalso implements AlmacenImagenesGympedia {
  final List<String> llamadas = [];
  int codigoSubida = 200;
  bool borraOk = true;
  int intentosBorrado = 0;

  @override
  Future<int> subir(String slug, List<int> bytes) async {
    llamadas.add('subir:$slug');
    return codigoSubida;
  }

  @override
  Future<bool> borrar(String slug) async {
    intentosBorrado++;
    llamadas.add('borrar:$slug');
    return borraOk;
  }
}

Map<String, dynamic> _publicado({required bool conImagen}) => {
      'id': _slug,
      'titulo': 'Artículo de la oleada 6',
      'categoria': 'tecnica',
      'lo_esencial': 'Resumen corto y claro.',
      'explicacion_md': 'Texto de explicación del artículo.',
      'pasos': ['Paso uno', 'Paso dos'],
      'errores': ['Error frecuente'],
      'referencias': [
        {
          'titulo': 'Estudio A',
          'fuente': 'Revista 2020',
          'url': 'https://a.org/1'
        },
        {
          'titulo': 'Estudio B',
          'fuente': 'Revista 2021',
          'url': 'https://b.org/2'
        },
      ],
      'sello': 'verde',
      'nivel': 'esencial',
      'related_ids': <String>[],
      'tiene_imagen': conImagen,
      'imagen_cambiada': false,
      'revision': 3,
      'imagen_rev': conImagen ? 2 : 0,
    };

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
}

String _jwtFalso(String email, int telegramId) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000dd',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {'telegram_id': telegramId, 'provider': 'email'},
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _fijarSesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token': _jwtFalso('jc@ironbody.local', 735772141),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000dd',
      'aud': 'authenticated',
      'email': 'jc@ironbody.local',
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

/// Asienta el árbol mezclando tiempo real (la BD ffi) y tiempo
/// falso (el backoff de 600 ms del reintento) hasta que
/// [condicion] se cumple o se agota el presupuesto.
Future<void> _asentarHasta(
    WidgetTester tester, bool Function() condicion) async {
  for (var i = 0; i < 60 && !condicion(); i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump();
}

bool _editorFuera() =>
    find.byType(GympediaEditorScreen).evaluate().isEmpty;

Future<List<Map<String, Object?>>> _opsEncoladas() async {
  final db = await LocalDb.instance.db;
  return db.rawQuery(
      "SELECT tipo, payload FROM ops_queue WHERE tipo = "
      "'gympedia_upsert_publicado'");
}

void _mockAppLinks() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockStreamHandler(
          const EventChannel('com.llfbandit.app_links/events'),
          MockStreamHandler.inline(onListen: (args, events) {}));
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/messages'),
          (call) async => null);
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
    } catch (_) {}
  });

  group('Oleada 6 · borrado del objeto al quitar la imagen (§8.3)', () {
    testWidgets(
        'quitar + publicar: se pide el borrado de la ruta vieja '
        'y la op se encola', (tester) async {
      final almacen = _AlmacenFalso();
      _mockAppLinks();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.upsertMirrorTexto(
            'gympedia_articulos', _slug, _publicado(conImagen: true), 0);
      });
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          home: GympediaEditorScreen(
              publicado: _publicado(conImagen: true),
              slugsPublicados: const {_slug},
              almacen: almacen)));
      await _asentarHasta(
          tester, () => find.widgetWithText(TextButton, 'Quitar').evaluate().isNotEmpty);
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Quitar'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Quitar'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Publicar'));
      await _asentarHasta(tester, _editorFuera);
      expect(_editorFuera(), isTrue,
          reason: 'el editor no cerró tras publicar');
      // La misma operación pidió el borrado del objeto viejo,
      // una sola vez (a la primera), y de la ruta del artículo.
      expect(almacen.llamadas, ['borrar:$_slug']);
      expect(almacen.intentosBorrado, 1);
      // Sin aviso de barrido: el borrado salió bien.
      expect(find.textContaining('próximo barrido'), findsNothing);
      // La op de publicación quedó encolada SIN imagen.
      final ops = await tester.runAsync(_opsEncoladas);
      expect(ops, hasLength(1));
      final payload = jsonDecode('${ops!.single['payload']}');
      expect(payload['tiene_imagen'], isFalse);
    });

    testWidgets(
        'reemplazar: la nueva sube primero y NO se pide borrado '
        'de la ruta viva', (tester) async {
      final almacen = _AlmacenFalso();
      _mockAppLinks();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final rutaLocal =
          p.join(Directory.systemTemp.path, 'o6_reemplazo.webp');
      File(rutaLocal).writeAsBytesSync([1, 2, 3, 4]);
      final publicado = _publicado(conImagen: true);
      final borrador = {
        'slug': _slug,
        'titulo': publicado['titulo'],
        'categoria': publicado['categoria'],
        'lo_esencial': publicado['lo_esencial'],
        'explicacion_md': publicado['explicacion_md'],
        'pasos': jsonEncode(publicado['pasos']),
        'errores': jsonEncode(publicado['errores']),
        'referencias': jsonEncode(publicado['referencias']),
        'sello': 'verde',
        'nivel': 'esencial',
        'related_ids': '[]',
        'tiene_imagen': 1,
        'imagen_cambiada': 1,
        'imagen_local': rutaLocal,
        'base_revision': 3,
        'actualizado_ts': '2026-11-08T00:00:00',
      };
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.upsertMirrorTexto(
            'gympedia_articulos', _slug, publicado, 0);
      });
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          home: GympediaEditorScreen(
              borrador: borrador,
              slugsPublicados: const {_slug},
              almacen: almacen)));
      await _asentarHasta(
          tester, () => find.widgetWithText(OutlinedButton, 'Cambiar imagen').evaluate().isNotEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Publicar'));
      await _asentarHasta(tester, _editorFuera);
      expect(_editorFuera(), isTrue,
          reason: 'el editor no cerró tras publicar');
      // Orden y contenido exactos: solo la subida del objeto
      // (upsert sobre la misma ruta). Un borrado aquí mataría
      // la imagen recién subida.
      expect(almacen.llamadas, ['subir:$_slug']);
      expect(almacen.intentosBorrado, 0);
      final ops = await tester.runAsync(_opsEncoladas);
      expect(ops, hasLength(1));
      final payload = jsonDecode('${ops!.single['payload']}');
      expect(payload['tiene_imagen'], isTrue);
      expect(payload['imagen_cambiada'], isTrue);
    });

    testWidgets(
        'borrado que falla: 1 reintento (2 intentos), aviso del '
        'barrido y el artículo SÍ se guardó', (tester) async {
      final almacen = _AlmacenFalso()..borraOk = false;
      _mockAppLinks();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.upsertMirrorTexto(
            'gympedia_articulos', _slug, _publicado(conImagen: true), 0);
      });
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          home: GympediaEditorScreen(
              publicado: _publicado(conImagen: true),
              slugsPublicados: const {_slug},
              almacen: almacen)));
      await _asentarHasta(
          tester, () => find.widgetWithText(TextButton, 'Quitar').evaluate().isNotEmpty);
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Quitar'));
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, 'Quitar'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Publicar'));
      var avisoVisto = false;
      await _asentarHasta(tester, () {
        if (find.textContaining('próximo barrido').evaluate().isNotEmpty) {
          avisoVisto = true;
        }
        return _editorFuera();
      });
      expect(_editorFuera(), isTrue,
          reason: 'el editor no cerró tras publicar');
      // 1 intento + 1 reintento inmediato, ni uno más.
      expect(almacen.intentosBorrado, 2);
      expect(almacen.llamadas, ['borrar:$_slug', 'borrar:$_slug']);
      // El aviso claro de §8.2.2 se enseñó (nunca silencioso).
      expect(avisoVisto, isTrue,
          reason: 'no se enseñó el aviso «se limpiará en el '
              'próximo barrido»');
      // La operación principal se dio por buena: op encolada.
      final ops = await tester.runAsync(_opsEncoladas);
      expect(ops, hasLength(1));
    });

    testWidgets(
        'publicar sin tocar la imagen: el almacén no recibe '
        'ninguna llamada', (tester) async {
      final almacen = _AlmacenFalso();
      _mockAppLinks();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
        await LocalDb.instance.upsertMirrorTexto(
            'gympedia_articulos', _slug, _publicado(conImagen: true), 0);
      });
      await _fijarSesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
          home: GympediaEditorScreen(
              publicado: _publicado(conImagen: true),
              slugsPublicados: const {_slug},
              almacen: almacen)));
      await _asentarHasta(
          tester, () => find.widgetWithText(TextButton, 'Quitar').evaluate().isNotEmpty);
      await tester.tap(find.widgetWithText(FilledButton, 'Publicar'));
      await _asentarHasta(tester, _editorFuera);
      expect(_editorFuera(), isTrue,
          reason: 'el editor no cerró tras publicar');
      expect(almacen.llamadas, isEmpty);
      expect(almacen.intentosBorrado, 0);
    });
  });

  group('Oleada 6 · fuente (BAJA-01)', () {
    test('sin tabla ni cola de reintento nueva para GymPedia', () {
      final localdb = File('lib/localdb.dart').readAsStringSync();
      final tablas = RegExp(r'CREATE TABLE IF NOT EXISTS (\w+)')
          .allMatches(localdb)
          .map((m) => m.group(1)!)
          .where((t) => t.contains('gympedia'))
          .toSet();
      // Las dos de siempre (espejo y borradores): el borrado
      // de §8 no crea estado persistente de reintento.
      expect(tablas, {'gympedia_articulos', 'gympedia_borradores'});
      final almacen = File('lib/gympedia_almacen.dart').readAsStringSync();
      expect(almacen.contains('CREATE TABLE'), isFalse);
      expect(almacen.contains('queueOp'), isFalse);
    });

    test('el aviso del barrido y el reintento único están en el editor',
        () {
      final editor =
          File('lib/ui/gympedia_editor.dart').readAsStringSync();
      expect(editor.contains('El artículo se guardó'), isTrue);
      expect(
          editor.contains('se limpiará en el próximo barrido.'), isTrue);
      expect(editor.contains('_borrarObjetoImagen'), isTrue);
      // La ruta borrada sale del slug del propio artículo.
      expect(editor.contains('teniaImagenPublicada && !_tieneImagen'),
          isTrue);
    });
  });
}
