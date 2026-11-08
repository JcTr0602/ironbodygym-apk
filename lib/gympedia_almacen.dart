// lib/gympedia_almacen.dart
// 1.30 Oleada 6 (§8, GY-03): costura de almacenamiento de las
// imágenes de GymPedia. El editor habla con esta interfaz y no
// con HTTP directo: en producción manda la implementación HTTP
// contra Supabase Storage; en tests manda una falsa que
// registra las llamadas (contrato §8.3: quitar la imagen → se
// pide el borrado de la ruta vieja; reemplazar → la nueva sube
// primero y NO se pide el borrado de la ruta viva).
//
// El objeto de un artículo es `<slug>.webp` en el bucket
// gympedia-imagenes (AppConfig.bucketGympedia): la ruta sale
// siempre del slug del propio artículo, nunca de texto libre.
import 'package:http/http.dart' as http;

import 'auth.dart';
import 'config.dart';

abstract class AlmacenImagenesGympedia {
  /// Sube (upsert) el objeto `<slug>.webp` con [bytes].
  /// Devuelve el código HTTP (200/201 = subido) o -1 si la
  /// petición ni siquiera salió (red caída y demás): el editor
  /// conserva así sus dos avisos históricos (con código y
  /// genérico).
  Future<int> subir(String slug, List<int> bytes);

  /// Borra el objeto `<slug>.webp`. true si el objeto quedó
  /// borrado (200, o 404: ya no existía — el objetivo está
  /// cumplido); false si el borrado falló y toca reintentar.
  Future<bool> borrar(String slug);
}

/// Implementación real contra Supabase Storage: los mismos
/// endpoints, cabeceras y timeout que el editor usaba en línea.
class AlmacenImagenesGympediaHttp implements AlmacenImagenesGympedia {
  const AlmacenImagenesGympediaHttp();

  Map<String, String> _cabeceras() {
    final token = AuthService().session?.accessToken ?? '';
    return {
      'apikey': AppConfig.anonKey,
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  @override
  Future<int> subir(String slug, List<int> bytes) async {
    try {
      final r = await http
          .post(
            Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
                '${AppConfig.bucketGympedia}/$slug.webp'),
            headers: {
              ..._cabeceras(),
              'Content-Type': 'image/webp',
              'x-upsert': 'true',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 60));
      return r.statusCode;
    } catch (_) {
      return -1;
    }
  }

  @override
  Future<bool> borrar(String slug) async {
    try {
      // DELETE de un objeto, la misma vía que el puente usa
      // para las fotos (sync_bridge.py): 404 = ya no existía.
      final r = await http
          .delete(
            Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
                '${AppConfig.bucketGympedia}/$slug.webp'),
            headers: _cabeceras(),
          )
          .timeout(const Duration(seconds: 12));
      return r.statusCode == 200 || r.statusCode == 404;
    } catch (_) {
      return false;
    }
  }
}
