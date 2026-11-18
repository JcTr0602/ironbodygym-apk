import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'localdb.dart';
import 'tiempo.dart';

/// v1.3.9 (F1/F2): caché en memoria de los accesos a la App de Clientes.
/// Se carga una vez por sesión vía el RPC `listar_accesos_clientes`
/// (solo dueño). Indexado por cliente_id para consulta O(1) desde ficha.dart.
///
/// Reglas (Argón):
/// - Invalidación inmediata: tras generar/revocar un acceso, llamar a
///   [invalidar] o [actualizar] en ese mismo instante.
/// - Tolerancia offline: si no hay conexión y el caché está vacío,
///   [obtener] retorna null y la UI muestra "Sin conexión para verificar".
class AccesoCliente {
  final int clienteId;
  final String nombre;
  final String telefono;
  final bool activo;
  final int intentosFallidos;
  final DateTime? bloqueadoHasta;
  final bool estaBloqueado;
  final DateTime? ultimoAccesoEn;
  final DateTime? createdAt;

  // v1.4.0 Paso 2 (Control de Acceso): campos nuevos del RPC extendido.
  // Todos con default seguro si el servidor aún devuelve el JSON viejo.
  final bool debeCambiarPin;
  final bool forzarCambioPin;
  final bool bloqueadoManual;
  // Auditoría OpenCode 2026-10-20: el servidor ahora separa
  // 'esta_bloqueado' (semántica desplegada) de 'bloqueo_manual_vigente'.
  // Si el JSON no trae la clave nueva, se deriva localmente.
  final bool bloqueoManualVigente;
  final String? motivoBloqueo;
  final bool revocado;
  final DateTime? revocadoEn;
  final int totalAccesos;
  final String? ultimoDispositivo;
  final String? ultimaAppVersion;
  final DateTime? pinCambiadoEn;
  final DateTime? ultimoIntentoFallidoEn;
  final int tokenVersion;
  final bool tieneSesion;
  final String? creadoPor;

  AccesoCliente({
    required this.clienteId,
    required this.nombre,
    required this.telefono,
    required this.activo,
    required this.intentosFallidos,
    required this.bloqueadoHasta,
    required this.estaBloqueado,
    required this.ultimoAccesoEn,
    required this.createdAt,
    this.debeCambiarPin = false,
    this.forzarCambioPin = false,
    this.bloqueadoManual = false,
    this.bloqueoManualVigente = false,
    this.motivoBloqueo,
    this.revocado = false,
    this.revocadoEn,
    this.totalAccesos = 0,
    this.ultimoDispositivo,
    this.ultimaAppVersion,
    this.pinCambiadoEn,
    this.ultimoIntentoFallidoEn,
    this.tokenVersion = 1,
    this.tieneSesion = false,
    this.creadoPor,
  });

  /// 1.28 (M4-A6/R1M4-B8): parseo TOLERANTE por fila. Antes
  /// `(j['cliente_id'] as num)` lanzaba si el id venía como
  /// texto y UNA fila mala tumbaba la carga ENTERA (las
  /// pantallas lo traducían como «sin conexión»). Devuelve
  /// null si la fila no trae un cliente_id utilizable: el
  /// llamador la salta y sigue con las demás.
  static AccesoCliente? intentarDesdeJson(Map<String, dynamic> j) {
    final crudo = j['cliente_id'];
    final id = crudo is num
        ? crudo.toInt()
        : (crudo is String ? int.tryParse(crudo.trim()) : null);
    if (id == null || id <= 0) return null;
    try {
      return AccesoCliente.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  factory AccesoCliente.fromJson(Map<String, dynamic> j) {
    DateTime? parseFecha(dynamic v) {
      if (v == null) return null;
      // Argón P3#7: hora de La Habana, no la del dispositivo.
      final parsed = DateTime.tryParse('$v');
      return parsed == null ? null : aHabana(parsed);
    }

    // 1.28 (M4-A6): el id acepta num o texto numérico (la
    // guarda dura vive en intentarDesdeJson).
    final crudoId = j['cliente_id'];
    return AccesoCliente(
      clienteId: crudoId is num
          ? crudoId.toInt()
          : (int.tryParse('${crudoId ?? ''}') ?? 0),
      nombre: '${j['nombre'] ?? ''}',
      telefono: '${j['telefono'] ?? ''}',
      activo: j['activo'] == true,
      intentosFallidos: (j['intentos_fallidos'] as num?)?.toInt() ?? 0,
      bloqueadoHasta: parseFecha(j['bloqueado_hasta']),
      estaBloqueado: j['esta_bloqueado'] == true,
      ultimoAccesoEn: parseFecha(j['ultimo_acceso_en']),
      createdAt: parseFecha(j['created_at']),
      debeCambiarPin: j['debe_cambiar_pin'] == true,
      forzarCambioPin: j['forzar_cambio_pin'] == true,
      bloqueadoManual: j['bloqueado'] == true,
      bloqueoManualVigente: j['bloqueo_manual_vigente'] != null
          ? j['bloqueo_manual_vigente'] == true
          : (j['bloqueado'] == true &&
              (parseFecha(j['bloqueado_hasta']) == null ||
                  // 1.24 Bloque 2 (auditoría de reloj, hallazgo 2):
                  // bloqueado_hasta es un INSTANTE (el servidor lo
                  // manda con zona) y se compara contra el instante
                  // real, no contra el wall-clock de ahoraHabana():
                  // mezclarlos desplazaba la vigencia del bloqueo
                  // por la diferencia de zonas del teléfono (podía
                  // expirar horas antes o durar horas de más).
                  // 1.24.1 (Argón G-03): la comparación se hace con
                  // el instante CRUDO en UTC — parseFecha devuelve
                  // el wall-clock Habana (isUtc=false) y Dart lo
                  // reinterpretaba en la zona del SO al compararlo
                  // con ahoraUtcReal(), deshaciendo el arreglo.
                  DateTime.tryParse('${j['bloqueado_hasta']}')!
                      .toUtc()
                      .isAfter(ahoraUtcReal()))),
      motivoBloqueo: j['motivo_bloqueo']?.toString(),
      revocado: j['revocado'] == true,
      revocadoEn: parseFecha(j['revocado_en']),
      totalAccesos: (j['total_accesos'] as num?)?.toInt() ?? 0,
      ultimoDispositivo: j['ultimo_dispositivo']?.toString(),
      ultimaAppVersion: j['ultima_app_version']?.toString(),
      pinCambiadoEn: parseFecha(j['pin_cambiado_en']),
      ultimoIntentoFallidoEn: parseFecha(j['ultimo_intento_fallido_en']),
      tokenVersion: (j['token_version'] as num?)?.toInt() ?? 1,
      tieneSesion: j['tiene_sesion'] == true,
      creadoPor: j['creado_por']?.toString(),
    );
  }

  /// Estado principal para chips y filtros del panel.
  /// revocado > bloqueado > inactivo > activo.
  /// 1.28 (M4-A6): «revocado» es SOLO el revocado de verdad.
  /// Antes todo acceso simplemente inactivo se etiquetaba
  /// 'revocado' y las pantallas ofrecían «reactivar» lo que
  /// nunca se revocó (y lo contaban como revocado).
  String get estado {
    if (revocado) return 'revocado';
    if (estaBloqueado || bloqueoManualVigente) return 'bloqueado';
    if (!activo) return 'inactivo';
    return 'activo';
  }

  bool get pinPendiente => debeCambiarPin || forzarCambioPin;
}

class AccesoAppCache {
  AccesoAppCache._() {
    // Yunque B (YB-SER-04): al perderse la sesión por
    // CUALQUIER vía (vencimiento incluido, no solo el
    // «Cerrar sesión» de signOut), la foto de accesos se
    // limpia sola — el mismo patrón que PermisosEntrenador.
    // Sin esto, en el teléfono compartido la lista
    // solo-dueño sobrevivía al vencimiento de la sesión del
    // dueño y el siguiente usuario la veía en las fichas.
    //
    // Cierre de la oleada (regresión cazada por la suite
    // completa, test P3 de permisos_115b): la limpieza va
    // SOLO en la TRANSICIÓN sesión → sin sesión (el mismo
    // criterio que la raíz en main.dart). El stream emite
    // su evento inicial con sesión null al arrancar sin
    // sesión guardada; limpiar ahí subía la generación y
    // abortaba cualquier cargar() en vuelo (devolvía
    // false), rompiendo la carga legítima sin sesión
    // previa que perder.
    var huboSesion = false;
    try {
      Supabase.instance.client.auth.onAuthStateChange.listen((d) {
        if (d.session != null) {
          huboSesion = true;
        } else if (huboSesion) {
          huboSesion = false;
          limpiar();
        }
      });
    } catch (_) {
      // Sin Supabase inicializado (tests): la limpieza por
      // signOut() explícito sigue activa.
    }
  }
  static final AccesoAppCache instance = AccesoAppCache._();

  Map<int, AccesoCliente>? _porCliente;

  /// Carga en curso, si la hay: quien llame a cargar()
  /// mientras otra pantalla ya está cargando ESPERA esa
  /// misma carga y recibe su resultado real. Antes devolvía
  /// false («falló») aunque la carga concurrente terminara
  /// bien, y un llamador podía marcar «sin conexión» por
  /// error (panel Terra por Zen, 2026-11-02).
  Future<bool>? _enCurso;

  /// 1.28 (M4-A6): generación de los DATOS. Sube con cada
  /// mutación ([actualizar], [invalidar], [limpiar]). Un
  /// vuelo de carga captura la suya: si al aterrizar ya no
  /// coincide, su foto es ANTERIOR a una mutación y se
  /// descarta — antes una recarga pedida tras generar un PIN
  /// podía unirse al vuelo previo y aplicar la foto vieja, y
  /// la pantalla enseñaba el acceso como si nada hubiera
  /// cambiado. Y [cargar] solo se une al vuelo en curso si
  /// su generación sigue vigente.
  int _genDatos = 0;
  int _genEnCurso = -1;

  /// 1.28 (M4-A14): persistencia de la última lista VERIFICADA
  /// en la meta de LocalDb, para pintar Control de Acceso y
  /// las fichas en frío y sin conexión, con su sello.
  static const String _kMeta = 'acceso_app_cache_v1';
  DateTime? _verificadoEn;
  bool _esPersistido = false;

  /// 1.36 H-C1 (136-450): el motivo del ÚLTIMO fallo de
  /// carga (la excepción tal cual), expuesto para quien
  /// quiera decirlo en vez del genérico «sin conexión».
  /// null si la última carga salió bien o aún no hubo.
  Object? _ultimoErrorCarga;
  Object? get ultimoErrorCarga => _ultimoErrorCarga;

  /// true si el caché ya se cargó en esta sesión (aunque esté vacío).
  bool get cargado => _porCliente != null;

  /// Cuándo se verificó la lista contra el servidor (de esta
  /// sesión o de la persistida). null si nunca.
  DateTime? get verificadoEn => _verificadoEn;

  /// true si lo cargado es la foto persistida y aún no se ha
  /// verificado en esta sesión: la UI lo rotula («verificado
  /// hace X») en vez de presentarlo como dato fresco.
  bool get esPersistido => _esPersistido && _porCliente != null;

  /// Todos los accesos (para el panel F2/F8). null si no cargado.
  List<AccesoCliente>? get todos =>
      _porCliente?.values.toList();

  /// Carga el caché desde el servidor. Retorna true si tuvo éxito.
  /// Si falla (offline), deja el caché como estaba y retorna false.
  Future<bool> cargar() {
    final enCurso = _enCurso;
    if (enCurso != null && _genEnCurso == _genDatos) return enCurso;
    final gen = _genDatos;
    final f = _cargarInterno(gen);
    _enCurso = f;
    _genEnCurso = gen;
    f.whenComplete(() {
      if (identical(_enCurso, f)) _enCurso = null;
    });
    return f;
  }

  Future<bool> _cargarInterno(int gen) async {
    // A14: en frío (sin foto en memoria), la persistida pinta
    // ya; la red refresca encima en esta misma llamada.
    if (_porCliente == null) {
      await _restaurarPersistido();
      // Corrección A3-X1 (auditorías 1.28): si limpiar() (o
      // una mutación) ganó la carrera DURANTE la
      // restauración, la foto restaurada es de la vida
      // anterior y no puede repoblar la caché recién
      // limpiada: se deshace la restauración y este vuelo
      // se descarta, como ya hacía el chequeo de
      // generación tras la RPC.
      if (gen != _genDatos) {
        _porCliente = null;
        _verificadoEn = null;
        _esPersistido = false;
        return false;
      }
    }
    try {
      // Timeout propio (12 s, la norma de lectura de
      // Gestión desde la 1.32): sin conexión, una RPC sin
      // timeout puede no devolver nunca, y hay llamadores que
      // la esperan para pintar (la ficha lo hacía y se quedaba
      // en el spinner; reporte de Jc 2026-11-02). Al vencer,
      // TimeoutException cae en el catch y devuelve false.
      final res = await Supabase.instance.client
          .rpc('listar_accesos_clientes')
          .timeout(const Duration(seconds: 12));
      // A6/R1M4-B8: fila a fila tolerante — una fila mala se
      // salta; no tumba la carga ni se disfraza de «sin
      // conexión».
      final lista = <AccesoCliente>[];
      for (final e in (res as List)) {
        try {
          final a = AccesoCliente.intentarDesdeJson(
              Map<String, dynamic>.from(e as Map));
          if (a != null) lista.add(a);
        } catch (_) {}
      }
      // A6: si una mutación ganó la carrera mientras esta
      // carga volaba, la foto es vieja: se descarta y este
      // llamador recibe false (el llamador post-mutación ya
      // lanzó su propio vuelo con la generación nueva).
      if (gen != _genDatos) return false;
      _porCliente = {for (final a in lista) a.clienteId: a};
      _verificadoEn = ahoraHabana();
      _esPersistido = false;
      _ultimoErrorCarga = null;
      unawaited(_persistir(res));
      return true;
    } catch (e) {
      // 1.36 H-C1 (136-450): el motivo queda expuesto.
      _ultimoErrorCarga = e;
      return false;
    }
  }

  /// A14: guarda la respuesta cruda verificada + su instante.
  Future<void> _persistir(dynamic resCrudo) async {
    try {
      await LocalDb.instance.setMeta(
        _kMeta,
        jsonEncode({
          'verificado_en': isoHabana(ahoraHabana()),
          'filas': resCrudo,
        }),
      );
    } catch (_) {}
  }

  /// A14: restaura la última lista verificada (arranque en
  /// frío). Nunca lanza: sin meta o con meta sucia, el caché
  /// queda como estaba.
  Future<void> _restaurarPersistido() async {
    // Corrección A3-X1: si un limpiar() está borrando la
    // foto persistida, se espera a que el borrado aterrice
    // antes de leer: sin esto, una restauración de la
    // sesión NUEVA podía leer la foto de la anterior.
    final borrado = _borradoPersistido;
    if (borrado != null) {
      await borrado;
      if (identical(_borradoPersistido, borrado)) {
        _borradoPersistido = null;
      }
    }
    try {
      final crudo = await LocalDb.instance.getMeta(_kMeta);
      if (crudo == null || crudo.isEmpty) return;
      final j = jsonDecode(crudo);
      if (j is! Map) return;
      final filas = j['filas'];
      if (filas is! List) return;
      final mapa = <int, AccesoCliente>{};
      for (final e in filas) {
        try {
          final a = AccesoCliente.intentarDesdeJson(
              Map<String, dynamic>.from(e as Map));
          if (a != null) mapa[a.clienteId] = a;
        } catch (_) {}
      }
      _porCliente = mapa;
      final v = j['verificado_en'];
      _verificadoEn = v is String ? DateTime.tryParse(v) : null;
      _esPersistido = true;
    } catch (_) {}
  }

  /// Yunque R3-M6-3: restaura la foto PERSISTIDA sin red,
  /// para que una pantalla pueda pintar al instante y luego
  /// enriquezca con [cargar]. Si ya hay foto en memoria, es
  /// no-op. La guarda de generación de _cargarInterno no
  /// aplica aquí a propósito: esto SOLO lee el persistido
  /// (nunca escribe sobre datos más nuevos que la foto) y
  /// respeta un borrado en curso, como _restaurarPersistido.
  Future<void> restaurarPersistidoSiFalta() async {
    if (_porCliente != null) return;
    await _restaurarPersistido();
  }

  /// Obtiene el acceso de un cliente. null = sin acceso o no cargado.
  AccesoCliente? obtener(int clienteId) => _porCliente?[clienteId];

  /// Invalidación inmediata tras generar/revocar (Argón).
  /// Si se pasa el acceso actualizado, lo reemplaza; si es null, lo elimina.
  void actualizar(int clienteId, AccesoCliente? acceso) {
    _genDatos++;
    final m = _porCliente;
    if (m == null) return;
    if (acceso == null) {
      m.remove(clienteId);
    } else {
      m[clienteId] = acceso;
    }
  }

  /// 1.28 (M4-A6): invalida sin tocar la foto en memoria —
  /// para DESPUÉS de una mutación (generar/revocar PIN,
  /// bloquear…): el próximo [cargar] NO se une a un vuelo
  /// anterior a la mutación ni aplica su resultado.
  void invalidar() {
    _genDatos++;
  }

  /// Corrección A3-X1: el borrado de la foto persistida
  /// que [limpiar] deja en curso; [_restaurarPersistido]
  /// lo espera antes de leer la meta.
  Future<void>? _borradoPersistido;

  /// Limpia el caché (al cerrar sesión): memoria, foto
  /// persistida y vuelos en curso quedan invalidados — la
  /// sesión siguiente no hereda un aterrizaje zombi como
  /// dato suyo (A6).
  void limpiar() {
    _genDatos++;
    _porCliente = null;
    _enCurso = null;
    _genEnCurso = -1;
    _verificadoEn = null;
    _esPersistido = false;
    _borradoPersistido = () async {
      try {
        await LocalDb.instance.setMeta(_kMeta, '');
      } catch (_) {}
    }();
    unawaited(_borradoPersistido!);
  }
}
