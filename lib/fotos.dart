/// Caché local de fotos de clientes.
///
/// Las fotos subidas a Supabase Storage (bucket `fotos-clientes`) se
/// descargan bajo demanda con la sesión del entrenador y se guardan en
/// el almacenamiento de la app. En las listas solo se usa el caché
/// (sin descargas automáticas); la ficha descarga si hace falta.
library;

import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'auth.dart';
import 'config.dart';

/// v1.2.8 (Paso 3): LRU real con límite de 200MB.
/// Corrección Gemini: escaneo O(N) único de metadatos (no statSync en el
/// comparador), tocar() en cada lectura para LRU real (no FIFO).
class _CacheItem {
  final File file;
  final int size;
  final DateTime lastAccessed;
  _CacheItem(this.file, this.size, this.lastAccessed);
}

class FotoCache {
  FotoCache._();
  static final FotoCache instance = FotoCache._();

  /// v1.2.8: límite de 200MB (~2,500 fotos display WebP).
  static const int maxBytes = 200 * 1024 * 1024;

  final _auth = AuthService();
  final _memoria = <String, File>{};

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/fotos_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _nombreArchivo(String storagePath) =>
      storagePath.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

  /// Foto ya descargada (sin red). Null si no está en caché.
  /// v1.2.8: hace touch para LRU real.
  Future<File?> enCache(String? storagePath) async {
    if (storagePath == null || storagePath.isEmpty) return null;
    final mem = _memoria[storagePath];
    if (mem != null && await mem.exists()) {
      await _tocar(mem);
      return mem;
    }
    final d = await _dir();
    final f = File('${d.path}/${_nombreArchivo(storagePath)}.jpg');
    if (await f.exists()) {
      _memoria[storagePath] = f;
      await _tocar(f);
      return f;
    }
    return null;
  }

  /// Descarga la foto si no está en caché. Null si falla.
  /// v1.0.9: mejor manejo de errores.
  /// v1.2.8: aplica LRU tras guardar.
  Future<File?> obtener(String? storagePath) async {
    final ya = await enCache(storagePath);
    if (ya != null || storagePath == null || storagePath.isEmpty) return ya;
    try {
      final token = _auth.session?.accessToken ?? '';
      final r = await http.get(
        Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
            '${AppConfig.bucketFotos}/$storagePath'),
        headers: {
          'apikey': AppConfig.anonKey,
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 30));
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) {
        // Log para diagnóstico (no rompe la app)
        // ignore: avoid_print
        print('FotoCache: HTTP ${r.statusCode} para $storagePath');
        return null;
      }
      final d = await _dir();
      final f = File('${d.path}/${_nombreArchivo(storagePath)}.jpg');
      await f.writeAsBytes(r.bodyBytes);
      _memoria[storagePath] = f;
      await _aplicarLRU();
      return f;
    } catch (e) {
      // ignore: avoid_print
      print('FotoCache: error descargando $storagePath: $e');
      return null;
    }
  }

  /// Invalida el caché para una ruta (fuerza re-descarga).
  Future<void> invalidar(String? storagePath) async {
    if (storagePath == null || storagePath.isEmpty) return;
    _memoria.remove(storagePath);
    try {
      final d = await _dir();
      final f = File('${d.path}/${_nombreArchivo(storagePath)}.jpg');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Actualiza la marca de tiempo (para LRU real por acceso).
  Future<void> _tocar(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {}
  }

  /// Expulsa los archivos más viejos hasta estar bajo maxBytes.
  /// Corrección Gemini: un solo escaneo O(N), sort en memoria sin I/O.
  Future<void> _aplicarLRU() async {
    try {
      final d = await _dir();
      if (!await d.exists()) return;
      final entities = await d.list().toList();
      final items = <_CacheItem>[];
      int totalBytes = 0;

      // Escaneo O(N) único de metadatos, fuera del sort.
      for (final entity in entities) {
        if (entity is File) {
          try {
            final stat = await entity.stat();
            totalBytes += stat.size;
            items.add(_CacheItem(entity, stat.size, stat.modified));
          } catch (_) {}
        }
      }

      if (totalBytes <= maxBytes) return;

      // Sort en memoria, sin I/O.
      items.sort((a, b) => a.lastAccessed.compareTo(b.lastAccessed));

      for (final item in items) {
        if (totalBytes <= maxBytes) break;
        totalBytes -= item.size;
        try {
          await item.file.delete();
        } catch (_) {}
        // Limpiar también de la memoria.
        _memoria.removeWhere((k, v) => v.path == item.file.path);
      }
    } catch (_) {}
  }
}
