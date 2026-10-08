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

class FotoCache {
  FotoCache._();
  static final FotoCache instance = FotoCache._();

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
  Future<File?> enCache(String? storagePath) async {
    if (storagePath == null || storagePath.isEmpty) return null;
    final mem = _memoria[storagePath];
    if (mem != null && await mem.exists()) return mem;
    final d = await _dir();
    final f = File('${d.path}/${_nombreArchivo(storagePath)}.jpg');
    if (await f.exists()) {
      _memoria[storagePath] = f;
      return f;
    }
    return null;
  }

  /// Descarga la foto si no está en caché. Null si falla.
  /// v1.0.9: mejor manejo de errores.
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
}
