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
///
/// 1.33 (campo 2026-11-12, vaivén de fotos): la política de la
/// cola se rehace a la altura del enlace real — el timeout por
/// descarga pasa a ser el de la ficha (30 s: una foto de 36 KB
/// a 2,5 KB/s necesita ~15 s y con 10 s NUNCA aterrizaba), el
/// backoff por fallo baja de 3 min a 45 s y una ruta recién
/// aterrizada no se re-descarga en una ventana de 3 min. Y dos
/// defensas de la caché: la invalidación entre variantes de la
/// MISMA foto (display→original) ya no borra la copia buena
/// hasta que la nueva variante esté en disco, y al arrancar se
/// migran los nombres de archivo anteriores al 2026-10-15
/// (siempre .jpg) al nombre canónico con su extensión real.
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
/// - timeout por descarga ([timeoutDescarga]): 10 s en la
///   1.31; 1.33 lo sube a 30 s, el presupuesto de la ficha —
///   a 2,5 KB/s (campo real) una foto de 36 KB tarda ~15 s
///   y con 10 s la cola la mataba SIEMPRE, así que la lista
///   jamás la mostraba aunque la ficha sí pudiera;
/// - deduplicación en vuelo: la misma ruta no se descarga
///   dos veces a la vez ni se encola dos veces;
/// - deduplicación por aterrizaje ([ventanaAterrizaje],
///   3 min): una ruta que acaba de aterrizar no se vuelve
///   a descargar si una fila la re-pide enseguida (la sirve
///   la caché); pasada la ventana, la ruta se puede re-pedir
///   con normalidad (p. ej. si el LRU expulsó el archivo);
/// - caché negativa con backoff corto ([backoffFallo]):
///   3 min en la 1.31; 1.33 lo baja a 45 s — una fila que
///   sigue visible y re-pide no queda castigada minutos
///   por un fallo de cuando el enlace estaba en negro;
/// - aviso de aterrizaje ([aterrizajes]): cuando una foto
///   llega, las filas visibles repintan por escucha.
/// La descarga real la inyecta FotoCache; la política se
/// prueba sola, sin red ni disco.
class ColaPrecargaFotos {
  ColaPrecargaFotos({
    required Future<File?> Function(String ruta, Duration timeout)
        descargador,
    this.concurrencia = 3,
    this.timeoutDescarga = const Duration(seconds: 30),
    this.backoffFallo = const Duration(seconds: 45),
    this.ventanaAterrizaje = const Duration(minutes: 3),
    DateTime Function()? ahora,
    bool Function(String ruta)? esFalloSinCastigo,
  })  : _descargador = descargador,
        _ahora = ahora ?? DateTime.now,
        _esFalloSinCastigo = esFalloSinCastigo;

  final Future<File?> Function(String ruta, Duration timeout)
      _descargador;
  final bool Function(String ruta)? _esFalloSinCastigo;
  final int concurrencia;
  final Duration timeoutDescarga;
  final Duration backoffFallo;
  final Duration ventanaAterrizaje;
  final DateTime Function() _ahora;

  final _cola = <String>[];
  final _enCurso = <String, Future<File?>>{};
  final _falloEn = <String, DateTime>{};
  final _aterrizadaEn = <String, DateTime>{};
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

  /// ¿La ruta aterrizó hace menos que la ventana de
  /// aterrizaje? Entonces re-pedirla no descarga nada: la
  /// foto está en la caché y la fila debe resolver de disco.
  bool recienAterrizada(String ruta) {
    final a = _aterrizadaEn[ruta];
    return a != null && _ahora().difference(a) < ventanaAterrizaje;
  }

  /// Registra que la ruta ya está en la caché (la bajó la
  /// propia cola o la ficha con obtener): limpia su fallo
  /// y abre la ventana de aterrizaje.
  void registrarAterrizaje(String ruta) {
    _falloEn.remove(ruta);
    _aterrizadaEn[ruta] = _ahora();
  }

  /// Olvida el aterrizaje de una ruta (invalidación
  /// explícita o expulsión del LRU): la próxima vez que una
  /// fila la pida, la cola puede volver a descargarla.
  void olvidarAterrizaje(String ruta) => _aterrizadaEn.remove(ruta);

  void encolar(Iterable<String> rutas) {
    for (final r in rutas) {
      if (r.isEmpty || pendiente(r) || enBackoff(r) || recienAterrizada(r)) {
        continue;
      }
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
      registrarAterrizaje(ruta);
      if (!_avisos.isClosed) _avisos.add(ruta);
    } else if (!(_esFalloSinCastigo?.call(ruta) ?? false)) {
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

  /// 1.31 (IMP-18, yunque de app): rutas cuyo último fallo
  /// de red fue un 401 (JWT vencido). Un 401 NO es un
  /// fallo de la foto: la sesión puede refrescarse
  /// enseguida, así que esas rutas NO entran en la caché
  /// negativa (_falloEn) del llamador.
  final _fallo401 = <String>{};

  /// 1.33: invalidaciones DIFERIDAS por cambio de variante
  /// (ruta vieja → ruta nueva): cuando el pull cambia
  /// foto_storage entre variantes de la MISMA foto
  /// (display→original), la copia vieja NO se borra hasta
  /// que la nueva esté en disco (ver [invalidarCambioFoto]).
  final _invalidacionesDiferidas = <String, String>{};

  /// 1.31: la cola de precarga de las listas (ver su doc). Su
  /// descargador mira primero la caché (la ruta pudo aterrizar
  /// por otra vía entre el encolado y el turno) y luego baja
  /// con el timeout de la cola (30 s desde la 1.33).
  late final ColaPrecargaFotos _colaPrecarga = ColaPrecargaFotos(
    descargador: (String ruta, Duration t) async {
      // Fase 1 (FOTOS-01): el chequeo de la cola es DIRECTO:
      // con la caída de enCache, la variante vieja preservada
      // haría las veces de «ya está» y la nueva no bajaría
      // nunca por esta vía (la caída es para PINTAR, no para
      // dar por descargada la ruta vigente).
      final File? c = await _enCacheDirecto(ruta);
      if (c != null) return c;
      return _descargaCompartida(ruta, timeout: t);
    },
    // IMP-18: un fallo por 401 (JWT vencido) no entra en
    // la caché negativa de la cola.
    esFalloSinCastigo: (String ruta) => _fallo401.contains(ruta),
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
    // 1.33: si esta ruta era la variante nueva que una
    // invalidación diferida esperaba, la variante vieja ya
    // sobra: se invalida ahora, con la nueva SÍ en disco.
    final cumplidas = <String>[
      for (final e in _invalidacionesDiferidas.entries)
        if (e.value == storagePath) e.key,
    ];
    for (final vieja in cumplidas) {
      _invalidacionesDiferidas.remove(vieja);
      unawaited(invalidar(vieja));
    }
  }

  /// 1.33: la migración de nombres legados corre una sola
  /// vez por proceso, en el primer acceso al directorio.
  bool _migracionLegadoHecha = false;

  Future<Directory> _dir() async {
    final base = await getApplicationDocumentsDirectory();
    // NOTA: 'fotos_cache' es distinto de 'fotos/' (cola de subida).
    // El LRU nunca toca el directorio de la cola (Fix Luna 9).
    final d = Directory('${base.path}/fotos_cache');
    if (!await d.exists()) await d.create(recursive: true);
    if (!_migracionLegadoHecha) {
      _migracionLegadoHecha = true;
      await _migrarNombresLegado(d);
    }
    return d;
  }

  /// 1.33: el nombre canónico de un archivo legado, o null
  /// si [nombre] no es un legado con extensión distinta.
  /// Antes del 2026-10-15 (commit 7d4cc31) todo archivo de
  /// la caché se guardaba como <saneado>.jpg; desde entonces
  /// se busca <saneado>.<extensión real>. Para rutas .jpg
  /// ambos nombres coinciden; para .webp/.png el archivo
  /// viejo quedaba invisible para [enCache] pese a estar en
  /// el teléfono.
  String? _nombreCanonicoDesdeLegado(String nombre) {
    if (!nombre.endsWith('.jpg')) return null;
    final sinExt = nombre.substring(0, nombre.length - '.jpg'.length);
    if (sinExt.endsWith('_webp')) return '$sinExt.webp';
    if (sinExt.endsWith('_png')) return '$sinExt.png';
    return null;
  }

  /// 1.33: el nombre legado (<saneado>.jpg) de una ruta, o
  /// null si coincide con el canónico (rutas .jpg).
  String? _nombreLegado(String storagePath) {
    final legado = '${_nombreArchivo(storagePath)}.jpg';
    final canonico =
        '${_nombreArchivo(storagePath)}${_extDeStorage(storagePath)}';
    return legado == canonico ? null : legado;
  }

  /// 1.33: barrido único que renombra los archivos legados
  /// a su nombre canónico cuando el destino no existe. Lo
  /// que el barrido no alcance lo cubre el rescate puntual
  /// de [enCache].
  Future<void> _migrarNombresLegado(Directory d) async {
    try {
      await for (final e in d.list()) {
        if (e is! File) continue;
        final nombre = e.path.split(Platform.pathSeparator).last;
        final canonico = _nombreCanonicoDesdeLegado(nombre);
        if (canonico == null) continue;
        final destino = File('${d.path}/$canonico');
        if (await destino.exists()) continue;
        try {
          await e.rename(destino.path);
        } catch (_) {}
      }
    } catch (_) {}
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
  ///
  /// Fase 1 (FOTOS-01): si la ruta pedida es la variante
  /// NUEVA de un cambio de foto_storage aún no aterrizado
  /// (hay una invalidación diferida que la espera), la
  /// resolución cae a la copia VIEJA preservada: la
  /// superficie pinta la foto que el teléfono SÍ tiene en
  /// vez de las iniciales mientras la nueva baja. Sin esta
  /// caída, la diferida conservaba el archivo pero ninguna
  /// superficie lo pintaba (todas resuelven por la ruta
  /// vigente) y el vaivén seguía visible.
  Future<File?> enCache(String? storagePath) async {
    final directo = await _enCacheDirecto(storagePath);
    if (directo != null ||
        storagePath == null ||
        storagePath.isEmpty) {
      return directo;
    }
    for (final e in _invalidacionesDiferidas.entries) {
      if (e.value == storagePath) {
        final vieja = await _enCacheDirecto(e.key);
        if (vieja != null) return vieja;
      }
    }
    return null;
  }

  /// La resolución directa de una ruta (memoria → nombre
  /// canónico → rescate legado), SIN la caída a la variante
  /// preservada de [enCache]. La usa invalidarCambioFoto
  /// para saber si la variante nueva está en disco DE
  /// VERDAD (con la caída, la vieja haría las veces de
  /// nueva y la diferida se cancelaría antes de tiempo).
  Future<File?> _enCacheDirecto(String? storagePath) async {
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
    // 1.33: rescate del nombre legado (descargas anteriores
    // al 2026-10-15, siempre .jpg): si el canónico no está
    // pero el legado sí, se renombra al canónico y vale —
    // la foto estaba en el teléfono y no se veía.
    final legadoNombre = _nombreLegado(storagePath);
    if (legadoNombre != null) {
      final legado = File('${d.path}/$legadoNombre');
      if (await legado.exists()) {
        if (await legado.length() > 0) {
          try {
            await legado.rename(f.path);
          } catch (_) {}
          if (await f.exists()) {
            _recordar(storagePath, f);
            await _tocar(f);
            return f;
          }
          _recordar(storagePath, legado);
          return legado;
        }
        try {
          await legado.delete();
        } catch (_) {}
      }
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
      // 1.33: la ficha deja la ruta marcada como aterrizada
      // en la cola (limpia el fallo y abre la ventana de
      // aterrizaje: las listas no la re-descargan).
      _colaPrecarga.registrarAterrizaje(storagePath);
    } else if (!_fallo401.contains(storagePath)) {
      // IMP-18: un 401 no castiga la ruta.
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
    _fallo401.remove(storagePath);
    try {
      Future<http.Response> pedir(String token) => http.get(
            Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
                '${AppConfig.bucketFotos}/$storagePath'),
            headers: {
              'apikey': AppConfig.anonKey,
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
          ).timeout(timeout);
      var r = await pedir(_auth.session?.accessToken ?? '');
      // 1.31 (IMP-18): ante un 401 (JWT vencido), refrescar
      // la sesión y reintentar UNA vez — el patrón _reqAuth
      // de sync. Si el refresh falla (sin red), se conserva
      // la respuesta original: un fallo de red no es un
      // vencimiento.
      if (r.statusCode == 401) {
        try {
          final res =
              await Supabase.instance.client.auth.refreshSession();
          final nuevo = res.session?.accessToken ?? '';
          if (nuevo.isNotEmpty) {
            r = await pedir(nuevo);
          }
        } catch (_) {}
      }
      if (r.statusCode == 401) {
        _fallo401.add(storagePath);
      }
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
    // 1.33: una invalidación directa cancela la diferida
    // que hubiera pendiente sobre esta misma ruta.
    // Fase 1 (FOTOS-06c): también las diferidas donde esta
    // ruta es la variante ESPERADA (el valor): si la nueva
    // se invalida, la vieja deja de estar «preservada para
    // ella» y su borrado ya no espera a un aterrizaje que
    // nadie quiere.
    _invalidacionesDiferidas
        .removeWhere((k, v) => k == storagePath || v == storagePath);
    _memoria.remove(storagePath);
    // 1.31: una foto invalidada (nueva en la misma ruta) no
    // hereda el backoff de la anterior.
    _colaPrecarga.olvidarFallo(storagePath);
    // 1.33: tampoco hereda la ventana de aterrizaje: si la
    // ruta se invalida, la cola debe poder re-descargarla.
    _colaPrecarga.olvidarAterrizaje(storagePath);
    try {
      final d = await _dir();
      final f = _archivoCache(d, storagePath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 1.33: ¿[a] y [b] son dos variantes de la MISMA foto?
  /// Las variantes de una foto cuelgan del mismo foto_uuid
  /// (`clientes/<id>/<uuid>_display.jpg`, `..._original.jpg`,
  /// `..._thumb.jpg`): coinciden si al quitar la extensión y
  /// el sufijo de variante queda la misma raíz. Una foto
  /// DISTINTA (otro uuid, otra carpeta) nunca coincide.
  static bool _esVarianteDeLaMismaFoto(String a, String b) {
    String raiz(String p) {
      var s = p.toLowerCase();
      s = s.replaceFirst(RegExp(r'\.(jpg|jpeg|png|webp)$'), '');
      s = s.replaceFirst(RegExp(r'_(display|original|thumb)$'), '');
      return s;
    }

    return a != b && raiz(a) == raiz(b);
  }

  /// 1.33: invalidación al cambiar foto_storage en un pull
  /// (la llaman los tres sitios de localdb y el de
  /// suplementos en sync, con la ruta vieja y la nueva).
  ///
  /// - Si vieja y nueva son variantes de la MISMA foto, la
  ///   copia vieja NO se borra: sigue sirviendo hasta que la
  ///   nueva variante esté descargada y verificada en disco;
  ///   al aterrizar, [_recordar] ejecuta la invalidación
  ///   diferida. Así el cliente nunca se queda sin foto por
  ///   un cambio de enlace entre variantes — el vaivén de
  ///   la 1.32: el servidor promovía display→original y el
  ///   pull borraba la display ya descargada, dejando la
  ///   fila a merced de bajar la original por un enlace malo.
  /// - Si la nueva ya está en disco, la vieja sobra ya.
  /// - Cualquier otro cambio (otra foto, foto quitada) se
  ///   comporta como [invalidar] de siempre.
  Future<void> invalidarCambioFoto(String? vieja, String? nueva) async {
    if (vieja == null || vieja.isEmpty || vieja == nueva) return;
    if (nueva != null &&
        nueva.isNotEmpty &&
        _esVarianteDeLaMismaFoto(vieja, nueva)) {
      // La ruta que manda ahora nunca puede quedar como
      // víctima de una invalidación diferida anterior.
      _invalidacionesDiferidas.remove(nueva);
      // Fase 1 (FOTOS-01): la comprobación es DIRECTA — con
      // la caída de enCache, la copia vieja de OTRA diferida
      // haría las veces de «la nueva ya está» y esta se
      // invalidaría sin estar en disco.
      if (await _enCacheDirecto(nueva) != null) {
        await invalidar(vieja);
        return;
      }
      _invalidacionesDiferidas[vieja] = nueva;
      return;
    }
    await invalidar(vieja);
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
        if (clave != null) {
          _memoria.remove(clave);
          // 1.33: el archivo expulsado ya no está en disco;
          // la cola olvida su aterrizaje para poder re-bajarlo.
          _colaPrecarga.olvidarAterrizaje(clave);
        }
      }
    } catch (_) {}
    finally {
      _evictando = false;
    }
  }
}
