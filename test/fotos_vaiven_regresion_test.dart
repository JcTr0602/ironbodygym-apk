/// Regresión 1.33 (2026-11-12) — vaivén de fotos de clientes
/// en Gestión 1.32: «a veces aparecen y se desaparecen»
/// (campo de Jc). Adaptado del test de reproducción de la
/// investigación (~/workspace/wt-investiga-fotos, informe
/// ~/workspace/cola-123/gestion/investiga_fotos_vaiven.md),
/// que sobre la base 67b9091 corría +2 −2 (B1 y C en rojo);
/// con la corrección de la 1.33 corre entero en verde.
///
/// Mecanismos cubiertos:
/// A) La invalidación primitiva borra (contrato intacto),
///    pero el cambio de variante de la MISMA foto ya pasa
///    por invalidarCambioFoto: la copia buena sigue
///    sirviendo hasta que la nueva variante está en disco.
/// B) La cola de precarga con el enlace de campo de Jc
///    (2,5 KB/s): timeout de 30 s y backoff de 45 s — la
///    foto aterriza; con respiro del enlace, sin esperas
///    de minutos castigada por un backoff de 3 min.
/// C) Los archivos descargados antes del 2026-10-15 viven
///    con el nombre viejo (<sanitizado>.jpg siempre); la
///    migración/rescate de FotoCache los vuelve a ver.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos.dart';

/// Réplica del nombre de archivo vigente (lib/fotos.dart,
/// _nombreArchivo + _extDeStorage + _archivoCache).
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

/// Nombre ANTERIOR a 7d4cc31 (2026-10-15): siempre .jpg.
String nombreLegado(String storagePath) =>
    '${storagePath.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}.jpg';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final docs = Directory(
      '${Directory.current.path}/.tmp-fotos-vaiven-regresion/documents');
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
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    if (await docs.exists()) await docs.delete(recursive: true);
  });

  Future<File> sembrar(String storagePath, {bool legado = false}) async {
    final nombre =
        legado ? nombreLegado(storagePath) : nombreVigente(storagePath);
    final f = File('${cacheDir.path}/$nombre');
    await f.writeAsBytes(List<int>.filled(36 * 1024, 7), flush: true);
    return f;
  }

  group('A · el flip de variante ya no borra la copia buena', () {
    test('la primitiva invalidar() conserva su contrato: borra',
        () async {
      const display = 'clientes/9001/uuid-a_display.webp';
      final sembrada = await sembrar(display);
      expect(await FotoCache.instance.enCache(display), isNotNull,
          reason: 'control: con el nombre vigente, enCache acierta');
      await FotoCache.instance.invalidar(display);
      expect(await sembrada.exists(), isFalse,
          reason: 'invalidar() sigue borrando: el arreglo no '
              'está en la primitiva sino en el camino del pull');
    });

    test(
        'invalidarCambioFoto entre variantes: la vieja sirve '
        'hasta que la nueva está en disco', () async {
      const display = 'clientes/9001/uuid-a_display.webp';
      const original = 'clientes/9001/uuid-a_original.webp';
      final sembrada = await sembrar(display);
      // Lo que hace el pull de la 1.33 cuando foto_storage
      // cambia de variante (localdb/sync → invalidarCambioFoto):
      await FotoCache.instance.invalidarCambioFoto(display, original);
      // La copia buena NO se borró: el cliente no se queda
      // sin foto mientras la variante nueva baja.
      expect(await sembrada.exists(), isTrue,
          reason: 'la variante vieja se conserva hasta que '
              'la nueva esté en disco');
      expect(await FotoCache.instance.enCache(display), isNotNull,
          reason: 'la fila sigue pintando la foto vieja');
      expect(await FotoCache.instance.enCache(original), isNull,
          reason: 'la nueva aún no ha aterrizado');

      // La variante nueva aterriza (la descarga la dejó en
      // disco y enCache la registra): ahora sí sobra la vieja.
      final nueva = await sembrar(original);
      expect(await FotoCache.instance.enCache(original), isNotNull);
      expect(await nueva.exists(), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await sembrada.exists(), isFalse,
          reason: 'con la nueva verificada en disco, la '
              'invalidación diferida borra la vieja');
      expect(await FotoCache.instance.enCache(display), isNull);
    });

    test(
        'invalidarCambioFoto con OTRA foto (otro uuid) borra '
        'como invalidar de siempre', () async {
      const vieja = 'clientes/9003/uuid-x_display.webp';
      const otra = 'clientes/9003/uuid-y_original.webp';
      final sembrada = await sembrar(vieja);
      await FotoCache.instance.invalidarCambioFoto(vieja, otra);
      expect(await sembrada.exists(), isFalse,
          reason: 'un cambio de foto de verdad no difiere '
              'nada: la vieja sobra desde ya');
    });
  });

  group('C · nombre legado (descargas anteriores a 2026-10-15)', () {
    test('la foto está en el teléfono con el nombre viejo y se ve',
        () async {
      const ruta = 'clientes/9002/uuid-c_display.webp';
      final legado = await sembrar(ruta, legado: true);
      expect(await legado.exists(), isTrue,
          reason: 'los bytes SÍ están en el teléfono');
      // 1.33: la migración/rescate de FotoCache encuentra
      // el archivo legado y lo renombra al nombre vigente.
      expect(await FotoCache.instance.enCache(ruta), isNotNull,
          reason: 'una foto presente en disco no depende del '
              'nombre con que se descargó en su día');
      expect(
          await File('${cacheDir.path}/${nombreVigente(ruta)}')
              .exists(),
          isTrue,
          reason: 'el archivo quedó con el nombre canónico');
    });
  });

  group('B · la cola de precarga con el enlace de campo de Jc', () {
    // Foto de 36 KB (la real de Alexis Rusindo Judina, id 167:
    // 36.335 bytes en el servidor). A 2,5 KB/s (captura de Jc
    // de las 17:09) hacen falta ~15 s; la cola de la 1.32
    // daba 10 s y castigaba 3 min: NUNCA aterrizaba.
    ColaPrecargaFotos colaConReloj(
        DateTime Function() ahora, List<int> llamadas) {
      return ColaPrecargaFotos(
        ahora: ahora,
        descargador: (ruta, timeout) async {
          llamadas[0]++;
          const necesarios = Duration(seconds: 15);
          if (necesarios > timeout) {
            // Como _descargarRed cuando el .timeout() mata el
            // GET a mitad de cuerpo: devuelve null.
            return null;
          }
          return File('${cacheDir.path}/aterrizada.bin');
        },
      );
    }

    test('la política nueva: 30 s de timeout y 45 s de backoff',
        () {
      final cola = ColaPrecargaFotos(
        descargador: (ruta, timeout) async => null,
      );
      expect(cola.timeoutDescarga, const Duration(seconds: 30),
          reason: 'el presupuesto de la ficha: a 2,5 KB/s '
              'una foto de 36 KB necesita ~15 s');
      expect(cola.backoffFallo, const Duration(seconds: 45),
          reason: 'una fila visible no espera 3 min por un '
              'fallo de cuando el enlace estaba en negro');
      expect(cola.ventanaAterrizaje, const Duration(minutes: 3));
    });

    test('a 2,5 KB/s constantes la foto SÍ aterriza por la cola',
        () async {
      var ahora = DateTime(2026, 11, 12, 17, 0);
      final llamadas = [0];
      final cola = colaConReloj(() => ahora, llamadas);
      final aterrizadas = <String>[];
      final sub = cola.aterrizajes.listen(aterrizadas.add);

      const ruta = 'clientes/167/uuid-b_original.jpg';
      cola.encolar([ruta]); // la fila pinta iniciales y pide precarga
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(llamadas[0], 1);
      expect(aterrizadas, contains(ruta),
          reason: 'con 30 s de presupuesto, los ~15 s que '
              'necesita la foto a 2,5 KB/s ya caben: aterriza '
              'en el primer intento (en la 1.32 era el rojo '
              'B1 de la investigación)');

      // El usuario vuelve a la lista a los 30 s y a los 60 s:
      // la ruta está recién aterrizada y la sirve la caché;
      // la cola no la re-descarga.
      for (var i = 0; i < 2; i++) {
        ahora = ahora.add(const Duration(seconds: 30));
        cola.encolar([ruta]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(llamadas[0], 1,
            reason: 'recién aterrizada (ventana de 3 min): '
                're-pedirla no abre otra descarga');
      }
      // Pasada la ventana de aterrizaje, la ruta se puede
      // volver a pedir (p. ej. si el LRU expulsó el archivo):
      // dos re-peticiones a +3 min traen dos descargas más.
      for (var i = 0; i < 2; i++) {
        ahora = ahora.add(const Duration(minutes: 3, seconds: 1));
        cola.encolar([ruta]);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(llamadas[0], 3,
          reason: 'la ventana expirada no bloquea para '
              'siempre: la ruta se puede re-descargar');
      expect(aterrizadas, contains(ruta));
      await sub.cancel();
    });

    test('cuando el enlace respira, aparece sin castigo de minutos',
        () async {
      var ahora = DateTime(2026, 11, 12, 17, 0);
      var intentos = 0;
      final cola = ColaPrecargaFotos(
        ahora: () => ahora,
        descargador: (ruta, timeout) async {
          intentos++;
          // Intento 1: el enlace muere del todo → null.
          // Intento 2: el enlace respira → la foto baja.
          if (intentos == 1) return null;
          return File('${cacheDir.path}/aterrizada2.bin');
        },
      );
      final aterrizadas = <String>[];
      final sub = cola.aterrizajes.listen(aterrizadas.add);
      const ruta = 'clientes/174/uuid-d_original.jpg';
      cola.encolar([ruta]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(aterrizadas, isEmpty);
      expect(cola.enBackoff(ruta), isTrue);
      // Con el backoff de 45 s (no 3 min), una fila que sigue
      // visible y re-pide al minuto ya reintenta.
      ahora = ahora.add(const Duration(minutes: 1));
      expect(cola.enBackoff(ruta), isFalse,
          reason: 'a los 60 s el castigo ya pasó (antes: 3 min)');
      cola.encolar([ruta]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(aterrizadas, [ruta],
          reason: 'el reintento llega con la fila aún en '
              'pantalla, no minutos después');
      await sub.cancel();
    });
  });
}
