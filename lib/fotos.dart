/// Caché local de fotos de clientes.
///
/// Las fotos subidas a Supabase Storage (bucket `fotos-clientes`) se
/// descargan bajo demanda con la sesión del entrenador y se guardan en
/// el almacenamiento de la app. En las listas solo se usa el caché
/// (sin descargas automáticas); la ficha descarga si hace falta.
///
/// 1.31 (campo 2026-11-09): la cabecera vuelve a ser verdad. Las
/// listas pintan SOLO desde disco (foto_local → caché) y piden la
/// red a través de la cola de precarga de [FotoCache] (concurrencia
/// baja, timeout corto, caché negativa con backoff, deduplicación
/// en vuelo); [FotoCache.obtener] queda para la ficha, que es la
/// descarga deliberada. Antes la fila descargaba con un GET de
/// 30 s relanzado en cada reconstrucción: con 3G de 1–5 KB/s la
/// foto moría a mitad de cuerpo y el avatar quedaba en iniciales
/// toda la sesión, inundando además el enlace malo.
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
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

/// Fuente ÚNICA de la foto de un suplemento (tarjeta y
/// detalle): la foto local recién tomada manda si existe
/// en disco; si no, manda la remota vía FotoCache. Es
/// compartida a propósito: el Hero de T2 solo vuela sin
/// parpadeo si AMBOS extremos construyen el FileImage
/// desde el MISMO archivo; si cada pantalla eligiera por
/// su lado y las rutas difirieran, el vuelo mostraría
/// otra imagen (panel delta-2, Media).
File? archivoFotoLocalSuplemento(Map<String, dynamic> sup) {
  final local = sup['foto_local'] as String?;
  if (local != null && local.isNotEmpty && File(local).existsSync()) {
    return File(local);
  }
  return null;
}

/// La foto vigente de un suplemento: local si existe;
/// si no, la de FotoCache (o null si tampoco hay remota).
Future<File?> resolverFotoSuplemento(
    Map<String, dynamic> sup) async {
  final local = archivoFotoLocalSuplemento(sup);
  if (local != null) return local;
  final storage = sup['foto_storage'] as String?;
  if (storage == null || storage.isEmpty) return null;
  return FotoCache.instance.obtener(storage);
}

/// Cola ÚNICA de precarga de fotos (1.31, campo 2026-11-09):
/// las descargas que piden las LISTAS pasan por aquí, nunca
/// directas desde la fila. Política:
/// - concurrencia baja ([concurrencia], 3 por defecto): la
///   lista no inunda el enlace;
/// - timeout corto por descarga ([timeoutDescarga], 10 s):
///   en red «en negro» el intento muere rápido en vez de
///   quemar 30 s a mitad de cuerpo;
/// - deduplicación en vuelo: la misma ruta no se descarga
///   dos veces a la vez ni se encola dos veces;
/// - caché negativa con backoff ([backoffFallo], 3 min): una
///   foto que falló no se reintenta hasta que el backoff
///   pasa — el scroll dejaba de relanzar intentos condenados;
/// - aviso de aterrizaje ([aterrizajes]): cuando una foto
///   llega, las filas visibles repintan por escucha.
/// La descarga real la inyecta FotoCache; la política se
/// prueba sola, sin red ni disco.
class ColaPrecargaFotos {
  ColaPrecargaFotos({
    required Future<File?> Function(String ruta, Duration timeout)
        descargador,
    this.concurrencia = 3,
    this.timeoutDescarga = const Duration(seconds: 10),
    this.backoffFallo = const Duration(minutes: 3),
    DateTime Function()? ahora,
  })  : _descargador = descargador,
        _ahora = ahora ?? DateTime.now;

  final Future<File?> Function(String ruta, Duration timeout)
      _descargador;
  final int concurrencia;
  final Duration timeoutDescarga;
  final Duration backoffFallo;
  final DateTime Function() _ahora;

  final _cola = <String>[];
  final _enCurso = <String, Future<File?>>{};
  final _falloEn = <String, DateTime>{};
  final _avisos = StreamController<String>.broadcast();

  /// Rutas cuya foto acaba de aterrizar en la caché.
  Stream<String> get aterrizajes => _avisos.stream;

  /// ¿La ruta falló hace menos que el backoff?
  bool enBackoff(String ruta) {
    final f = _falloEn[ruta];
    return f != null && _ahora().difference(f) < backoffFallo;
  }

  /// ¿La ruta está encolada o descargándose ahora mismo?
  bool pendiente(String ruta) =>
      _enCurso.containsKey(ruta) || _cola.contains(ruta);

  /// Registra un fallo venido de fuera de la cola (la ficha
  /// con obtener): las listas tampoco reintentan esa ruta
  /// hasta que pase el backoff.
  void registrarFallo(String ruta) => _falloEn[ruta] = _ahora();

  /// Olvida el fallo de una ruta (foto nueva o invalidación
  /// explícita): el próximo encolado puede reintentar ya.
  void olvidarFallo(String ruta) => _falloEn.remove(ruta);

  void encolar(Iterable<String> rutas) {
    for (final r in rutas) {
      if (r.isEmpty || pendiente(r) || enBackoff(r)) continue;
      _cola.add(r);
    }
    _bombear();
  }

  void _bombear() {
    while (_enCurso.length < concurrencia && _cola.isNotEmpty) {
      final ruta = _cola.removeAt(0);
      final fut = _descargarUna(ruta);
      _enCurso[ruta] = fut;
      fut.whenComplete(() {
        _enCurso.remove(ruta);
        _bombear();
      });
    }
  }

  Future<File?> _descargarUna(String ruta) async {
    File? f;
    try {
      f = await _descargador(ruta, timeoutDescarga);
    } catch (_) {
      f = null;
    }
    if (f != null) {
      _falloEn.remove(ruta);
      if (!_avisos.isClosed) _avisos.add(ruta);
    } else {
      _falloEn[ruta] = _ahora();
    }
    return f;
  }
}

class FotoCache {
  FotoCache._();
  static final FotoCache instance = FotoCache._();

  /// v1.2.8: límite de 200MB (~2,500 fotos display WebP).
  static const int maxBytes = 200 * 1024 * 1024;

  final _auth = AuthService();
  final _memoria = <String, File>{};
  // Fix Luna 8: lock simple para evitar evicciones concurrentes.
  bool _evictando = false;

  /// 1.31: descargas de red en vuelo, por ruta (deduplicación:
  /// la ficha y la cola nunca descargan lo mismo a la vez).
  final _enVuelo = <String, Future<File?>>{};

  /// 1.31: la cola de precarga de las listas (ver su doc). Su
  /// descargador mira primero la caché (la ruta pudo aterrizar
  /// por otra vía entre el encolado y el turno) y luego baja
  /// con el timeout corto de la cola.
  late final ColaPrecargaFotos _colaPrecarga = ColaPrecargaFotos(
    descargador: (String ruta, Duration t) async {
      final File? c = await enCache(ruta);
      if (c != null) return c;
      return _descargaCompartida(ruta, timeout: t);
    },
  );

  /// Rutas cuya foto acaba de aterrizar (las filas repintan
  /// por escucha al llegar la suya).
  Stream<String> get aterrizajes => _colaPrecarga.aterrizajes;

  /// 1.31: pide la descarga de fondo de [rutas] para las
  /// listas (sin esperar nada: el resultado llega por
  /// [aterrizajes] y por la caché). Respeta la caché
  /// negativa y la deduplicación de la cola.
  void precargar(Iterable<String> rutas) => _colaPrecarga.encolar(rutas);

  /// 1.23 (Delta Argón 3ª#7): tope de entradas del índice en
  /// memoria. El Map conserva el orden de inserción y
  /// [_recordar] reinserta al final en cada uso: el índice es
  /// un LRU y al pasar del tope cae la entrada más vieja (el
  /// ARCHIVO sigue en disco; solo se olvida el atajo).
  static const int _maxEntradasMemoria = 300;

  void _recordar(String storagePath, File f) {
    _memoria.remove(storagePath);
    _memoria[storagePath] = f;
    while (_memoria.length > _maxEntradasMemoria) {
      _memoria.remove(_memoria.keys.first);
    }
  }

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    // NOTA: 'fotos_cache' es distinto de 'fotos/' (cola de subida).
    // El LRU nunca toca el directorio de la cola (Fix Luna 9).
    final d = Directory('${base.path}/fotos_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  String _nombreArchivo(String storagePath) =>
      storagePath.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');

  /// v1.3.3: extrae la extensión real del storagePath (.webp, .png).
  /// Por defecto .jpg para rutas sin extensión reconocible.
  String _extDeStorage(String storagePath) {
    final p = storagePath.toLowerCase();
    if (p.endsWith('.webp')) return '.webp';
    if (p.endsWith('.png')) return '.png';
    return '.jpg';
  }

  /// v1.3.3: construye el File del caché preservando la extensión
  /// original (no fuerza .jpg, para no romper con archivos .webp).
  File _archivoCache(Directory d, String storagePath) =>
      File('${d.path}/${_nombreArchivo(storagePath)}${_extDeStorage(storagePath)}');

  /// Foto ya descargada (sin red). Null si no está en caché.
  /// v1.2.8: hace touch para LRU real.
  Future<File?> enCache(String? storagePath) async {
    if (storagePath == null || storagePath.isEmpty) return null;
    final mem = _memoria[storagePath];
    if (mem != null && await mem.exists()) {
      // Argón #8-6: un caché truncado (0 bytes) no vale: forzar
      // re-descarga en vez de devolverlo siempre.
      if (await mem.length() > 0) {
        _recordar(storagePath, mem); // LRU 3ª#7: uso = más reciente.
        await _tocar(mem);
        return mem;
      }
      _memoria.remove(storagePath);
      try {
        await mem.delete();
      } catch (_) {}
    }
    final d = await _dir();
    final f = _archivoCache(d, storagePath);
    if (await f.exists()) {
      if (await f.length() > 0) {
        _recordar(storagePath, f);
        await _tocar(f);
        return f;
      }
      try {
        await f.delete();
      } catch (_) {}
    }
    return null;
  }

  /// Descarga la foto si no está en caché. Null si falla.
  /// v1.0.9: mejor manejo de errores.
  /// v1.2.8: aplica LRU tras guardar.
  /// 1.31: SOLO para descargas deliberadas (la ficha): las
  /// listas usan [precargar]. Deduplica en vuelo con la cola
  /// y alimenta su caché negativa si falla (las listas no
  /// deben reintentar tras el fallo de la ficha).
  Future<File?> obtener(String? storagePath) async {
    final ya = await enCache(storagePath);
    if (ya != null || storagePath == null || storagePath.isEmpty) {
      return ya;
    }
    final f = await _descargaCompartida(storagePath,
        timeout: const Duration(seconds: 30));
    if (f != null) {
      _colaPrecarga.olvidarFallo(storagePath);
    } else {
      _colaPrecarga.registrarFallo(storagePath);
    }
    return f;
  }

  /// Descarga compartida en vuelo: si la ruta ya se está
  /// bajando (la ficha o la cola), el llamador se une a ESE
  /// futuro en vez de abrir otra descarga (manda el timeout
  /// del que llegó primero). Null si falla.
  Future<File?> _descargaCompartida(String storagePath,
      {required Duration timeout}) {
    final enVuelo = _enVuelo[storagePath];
    if (enVuelo != null) return enVuelo;
    final fut = _descargarRed(storagePath, timeout: timeout);
    _enVuelo[storagePath] = fut;
    fut.whenComplete(() => _enVuelo.remove(storagePath));
    return fut;
  }

  /// La descarga de red en sí (sin caché previa ni negativa:
  /// de eso se encargan [obtener] y la cola). Null si falla.
  Future<File?> _descargarRed(String storagePath,
      {required Duration timeout}) async {
    try {
      final token = _auth.session?.accessToken ?? '';
      final r = await http.get(
        Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
            '${AppConfig.bucketFotos}/$storagePath'),
        headers: {
          'apikey': AppConfig.anonKey,
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
      ).timeout(timeout);
      if (r.statusCode != 200 || r.bodyBytes.isEmpty) {
        // AA2: a la bitácora, no print (queda en diagnóstico).
        AppLog.error('fotos', 'cache_http',
            d: 'HTTP ${r.statusCode} para $storagePath');
        return null;
      }
      final d = await _dir();
      // v1.3.3: preservar la extensión original (el servidor sube .webp).
      final f = _archivoCache(d, storagePath);
      // Argón #8-6: escritura atómica (tmp + rename) o un corte a
      // mitad dejaba un archivo truncado que enCache devolvía siempre.
      final tmp = File(
          '${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await tmp.writeAsBytes(r.bodyBytes, flush: true);
      await tmp.rename(f.path);
      _recordar(storagePath, f);
      await _aplicarLRU();
      return f;
    } catch (e) {
      AppLog.error('fotos', 'cache_descarga',
          d: 'error descargando $storagePath: $e');
      return null;
    }
  }

  /// Invalida el caché para una ruta (fuerza re-descarga).
  /// v1.3.3: preserva la extensión original al buscar el archivo.
  Future<void> invalidar(String? storagePath) async {
    if (storagePath == null || storagePath.isEmpty) return;
    _memoria.remove(storagePath);
    // 1.31: una foto invalidada (nueva en la misma ruta) no
    // hereda el backoff de la anterior.
    _colaPrecarga.olvidarFallo(storagePath);
    try {
      final d = await _dir();
      final f = _archivoCache(d, storagePath);
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
  /// Fix Luna 8: lock anti-reentrancia. Fix Luna 9: solo archivos del
  /// caché (nunca toca otros directorios). v1.3.3: .jpg, .webp y .png.
  Future<void> _aplicarLRU() async {
    if (_evictando) return;
    _evictando = true;
    try {
      final d = await _dir();
      if (!await d.exists()) return;
      final entities = await d.list().toList();
      final items = <_CacheItem>[];
      int totalBytes = 0;

      // Escaneo O(N) único. Solo archivos del caché (Fix Luna 9).
      // v1.3.3: también .webp y .png (preservamos la extensión original).
      for (final entity in entities) {
        if (entity is File &&
            (entity.path.endsWith('.jpg') ||
                entity.path.endsWith('.webp') ||
                entity.path.endsWith('.png'))) {
          try {
            final stat = await entity.stat();
            totalBytes += stat.size;
            items.add(_CacheItem(entity, stat.size, stat.modified));
          } catch (_) {}
        } else if (entity is File && entity.path.endsWith('.tmp')) {
          // SB-09 (auditoría sync 1.21): los .tmp de escrituras
          // atómicas interrumpidas quedaban fuera del LRU para
          // siempre (no cuentan ni se expulsan): se borran los
          // de más de 24 h en este mismo barrido.
          try {
            final stat = await entity.stat();
            if (DateTime.now().difference(stat.modified).inHours >=
                24) {
              await entity.delete();
            }
          } catch (_) {}
        }
      }

      if (totalBytes <= maxBytes) return;

      items.sort((a, b) => a.lastAccessed.compareTo(b.lastAccessed));

      // 1.23 (Delta Argón 3ª#7): mapa inverso ruta→clave UNA
      // vez (O(N) total); antes cada expulsión hacía un
      // removeWhere O(N) sobre el índice en memoria.
      final clavePorRuta = <String, String>{
        for (final e in _memoria.entries) e.value.path: e.key,
      };
      for (final item in items) {
        if (totalBytes <= maxBytes) break;
        totalBytes -= item.size;
        try {
          // Verificar que aún existe antes de borrar (Fix Luna 8:
          // otro proceso pudo haberlo tocado).
          if (await item.file.exists()) {
            await item.file.delete();
          }
        } catch (_) {}
        final clave = clavePorRuta[item.file.path];
        if (clave != null) _memoria.remove(clave);
      }
    } catch (_) {}
    finally {
      _evictando = false;
    }
  }
}
