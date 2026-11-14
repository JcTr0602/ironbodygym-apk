/// 1.34 Campo 2 (P-3): las listas piden la variante
/// LIGERA de las fotos cuya ruta es la original.
///
/// Contratos:
/// - rutaConVariante intercambia el sufijo de variante
///   conservando carpeta y extensión; null si la ruta no
///   es de variante o ya es la pedida.
/// - La cola, con respaldo configurado (ligera →
///   original): si la ligera falla, encola la original y
///   la fila acaba con foto; el castigo de la caché
///   negativa queda SOLO sobre la ligera (la original no
///   entra en backoff por el fallo de su hermana).
/// - Si la ligera baja, la original nunca se descarga.
/// - FotoCache.enCacheParaLista: con solo la hermana en
///   disco, la resuelve; enCache (camino deliberado) NO
///   la sirve — sigue fiel a la ruta pedida.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos.dart';

String nombreVigente(String storagePath) {
  final san = storagePath.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
  final p = storagePath.toLowerCase();
  final ext = p.endsWith('.webp')
      ? '.webp'
      : p.endsWith('.png')
          ? '.png'
          : '.jpg';
  return '$san$ext';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('rutaConVariante (P-3)', () {
    test('original → display/thumb conservando todo lo demás', () {
      expect(rutaConVariante('clientes/7/u1_original.jpg', 'display'),
          'clientes/7/u1_display.jpg');
      expect(rutaConVariante('clientes/7/u1_original.webp', 'thumb'),
          'clientes/7/u1_thumb.webp');
      expect(rutaConVariante('clientes/7/u1_display.jpg', 'original'),
          'clientes/7/u1_original.jpg');
    });

    test('null si no es variante o ya es la pedida', () {
      expect(rutaConVariante('clientes/7/foto.jpg', 'display'), isNull);
      expect(rutaConVariante('usuarios/duany.jpg', 'display'), isNull);
      expect(rutaConVariante('clientes/7/u1_display.jpg', 'display'),
          isNull);
    });

    test('esRutaVarianteLigera distingue', () {
      expect(esRutaVarianteLigera('a/b_display.webp'), isTrue);
      expect(esRutaVarianteLigera('a/b_thumb.jpg'), isTrue);
      expect(esRutaVarianteLigera('a/b_original.jpg'), isFalse);
      expect(esRutaVarianteLigera('a/b.jpg'), isFalse);
    });
  });

  group('ColaPrecargaFotos con respaldo (P-3)', () {
    ColaPrecargaFotos colaCon(
            Future<File?> Function(String, Duration) d) =>
        ColaPrecargaFotos(
          descargador: d,
          respaldoDe: (r) => esRutaVarianteLigera(r)
              ? rutaConVariante(r, 'original')
              : null,
        );

    test('la ligera falla → cae a la original y la original '
        'no queda castigada', () async {
      final pedidos = <String>[];
      final cola = colaCon((ruta, t) async {
        pedidos.add(ruta);
        if (ruta.contains('_display')) return null; // no existe
        return File(ruta); // la original «baja»
      });
      final aterrizajes = <String>[];
      final sub = cola.aterrizajes.listen(aterrizajes.add);
      cola.encolar(['clientes/7/u2_display.jpg']);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(pedidos,
          ['clientes/7/u2_display.jpg', 'clientes/7/u2_original.jpg']);
      expect(aterrizajes, contains('clientes/7/u2_original.jpg'));
      expect(cola.enBackoff('clientes/7/u2_display.jpg'), isTrue);
      expect(cola.enBackoff('clientes/7/u2_original.jpg'), isFalse);
    });

    test('la ligera baja → la original nunca se pide', () async {
      final pedidos = <String>[];
      final cola = colaCon((ruta, t) async {
        pedidos.add(ruta);
        return File(ruta);
      });
      cola.encolar(['clientes/7/u3_display.webp']);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(pedidos, ['clientes/7/u3_display.webp']);
    });

    test('sin respaldo configurado, un fallo no encola nada más',
        () async {
      final pedidos = <String>[];
      final cola = ColaPrecargaFotos(descargador: (ruta, t) async {
        pedidos.add(ruta);
        return null;
      });
      cola.encolar(['clientes/7/u4_display.jpg']);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(pedidos, ['clientes/7/u4_display.jpg']);
    });
  });

  group('FotoCache.enCacheParaLista (P-3)', () {
    final docs = Directory(
        '${Directory.current.path}/.tmp-campo2-p3/documents');
    final cacheDir = Directory('${docs.path}/fotos_cache');

    setUpAll(() async {
      if (await docs.exists()) await docs.delete(recursive: true);
      await cacheDir.create(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return docs.path;
          }
          if (call.method == 'getTemporaryDirectory') return docs.path;
          return null;
        },
      );
    });

    tearDownAll(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              null);
      if (await docs.exists()) await docs.delete(recursive: true);
    });

    Future<void> sembrar(String storagePath) async {
      final f = File('${cacheDir.path}/${nombreVigente(storagePath)}');
      await f.create(recursive: true);
      await f.writeAsBytes([1, 2, 3]);
    }

    test('con solo la display en disco, la lista la recibe y '
        'el camino deliberado no', () async {
      await sembrar('clientes/9/p3a_display.jpg');
      final lista = await FotoCache.instance
          .enCacheParaLista('clientes/9/p3a_original.jpg');
      expect(lista, isNotNull);
      expect(lista!.path, contains('p3a_display'));
      // enCache sigue fiel a la ruta pedida (la ficha no
      // recibe la ligera por la puerta de atrás).
      expect(await FotoCache.instance.enCache('clientes/9/p3a_original.jpg'),
          isNull);
    });

    test('con solo la thumb en disco, cae a la thumb', () async {
      await sembrar('clientes/9/p3b_thumb.webp');
      final lista = await FotoCache.instance
          .enCacheParaLista('clientes/9/p3b_original.webp');
      expect(lista, isNotNull);
      expect(lista!.path, contains('p3b_thumb'));
    });

    test('con la original en disco, manda la original', () async {
      await sembrar('clientes/9/p3c_original.jpg');
      await sembrar('clientes/9/p3c_display.jpg');
      final lista = await FotoCache.instance
          .enCacheParaLista('clientes/9/p3c_original.jpg');
      expect(lista, isNotNull);
      expect(lista!.path, contains('p3c_original'));
    });

    test('sin ninguna variante en disco, null (sin inventar)',
        () async {
      expect(
          await FotoCache.instance
              .enCacheParaLista('clientes/9/p3d_original.jpg'),
          isNull);
    });

    test('una ruta que no es original no busca hermanas', () async {
      await sembrar('clientes/9/p3e_display.jpg');
      // Pedir la display directamente funciona; pedir una
      // ruta sin variante no deriva a nada.
      expect(
          await FotoCache.instance
              .enCacheParaLista('clientes/9/p3e_display.jpg'),
          isNotNull);
      expect(
          await FotoCache.instance.enCacheParaLista('clientes/9/otra.jpg'),
          isNull);
    });
  });
}
