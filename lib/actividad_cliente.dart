/// 1.29 (Oleada 8, FB-23 · Auditoría Total): la actividad
/// que la app de Clientes deja registrada en el SERVIDOR,
/// consultable solo por el dueño.
///
/// El servidor unifica las TRES fuentes que ya dejan rastro
/// en Supabase detrás de la RPC `admin_actividad_cliente`
/// (guarda `es_admin()` DENTRO de la propia función: la
/// autorización vive en el servidor, no en esta pantalla):
///   · `auditoria` — privado.cliente_app_auditoria
///     (activaciones y accesos; el detalle sale del servidor
///     ya saneado por LISTA BLANCA: ip, nombre, teléfono y
///     modelo de dispositivo nunca bajan),
///   · `sesion` — sesiones de entreno subidas (rutina,
///     duración y conteo de ejercicios; el contenido de las
///     series no viaja),
///   · `vale` — vales de Premios leídos de la tabla base.
/// `accesos_app_avisos` queda FUERA por diseño (A2-1/P-08):
/// es la cola transitoria de PINs en claro que se borra al
/// enviarse; no es una fuente de auditoría.
///
/// Caché (decisión P-08): NO es un espejo de sync ni entra
/// en el manifiesto. Vive en metadatos, acotada a 200
/// filas por persona consultada y 20 personas retenidas
/// (sale la consulta menos reciente), y se PURGA al cerrar
/// sesión (higiene en teléfono compartido: se engancha en
/// la purga general de LocalDb.purgaAlCerrarSesion).
library;

import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'localdb.dart';
import 'tiempo.dart';

/// Una fila de actividad tal como la devuelve la RPC
/// (detalle ya saneado en el servidor).
class ActividadCliente {
  final String fuente; // auditoria | sesion | vale
  final int idOrigen;
  final String? actor;
  final String accion;
  final Map<String, dynamic> detalle;
  final DateTime creadoEn; // instante UTC

  const ActividadCliente({
    required this.fuente,
    required this.idOrigen,
    required this.actor,
    required this.accion,
    required this.detalle,
    required this.creadoEn,
  });

  factory ActividadCliente.desdeRpc(Map<String, dynamic> f) {
    var det = <String, dynamic>{};
    final d = f['detalle'];
    if (d is Map) det = Map<String, dynamic>.from(d);
    if (d is String && d.isNotEmpty) {
      try {
        final dec = jsonDecode(d);
        if (dec is Map) det = Map<String, dynamic>.from(dec);
      } catch (_) {}
    }
    return ActividadCliente(
      fuente: '${f['fuente'] ?? ''}',
      idOrigen: (f['id_origen'] as num?)?.toInt() ?? 0,
      actor: f['actor'] as String?,
      accion: '${f['accion'] ?? ''}',
      detalle: det,
      creadoEn:
          parseFecha('${f['creado_en'] ?? ''}') ?? DateTime.utc(1970),
    );
  }

  Map<String, dynamic> aJson() => {
        'fuente': fuente,
        'id_origen': idOrigen,
        'actor': actor,
        'accion': accion,
        'detalle': detalle,
        // El instante se guarda en UTC: la caché no debe
        // reinterpretarlo al leer en otra zona.
        'creado_en': creadoEn.toUtc().toIso8601String(),
      };

  factory ActividadCliente.desdeCache(Map<String, dynamic> f) =>
      ActividadCliente.desdeRpc(f);

  /// La terna del cursor compuesto del servidor
  /// (creado_en, fuente, id_origen): la última fila de un
  /// bloque es el cursor del siguiente.
  ({DateTime ts, String fuente, int id}) get cursor =>
      (ts: creadoEn, fuente: fuente, id: idOrigen);
}

/// Traducción de la acción técnica a lenguaje humano.
/// Función pura.
String tituloActividadCliente(ActividadCliente a) {
  switch (a.accion) {
    case 'auto_activacion':
      return 'Activación de la app';
    case 'auto_activacion_completada':
      return 'Activación completada';
    case 'cerrar_sesion':
      return 'Cerró sesión en la app';
    case 'conversion_canje':
      return 'Invitado convertido en cliente';
    case 'reactivar':
      return 'Acceso reactivado';
    case 'resetear_pin':
      return 'PIN de acceso restablecido';
    case 'revocar':
      return 'Acceso revocado';
    case 'turno_manual_guardar':
      return 'Turno manual guardado';
    case 'turno_manual_borrar':
      return 'Turno manual borrado';
    case 'sesion_subida':
      return 'Sesión de entreno subida';
    default:
      if (a.accion.startsWith('vale_')) {
        return 'Vale de premio: '
            '${a.accion.substring(5).replaceAll('_', ' ')}';
      }
      return a.accion.replaceAll('_', ' ');
  }
}

/// Línea de detalle legible de una fila (solo claves de la
/// lista blanca del servidor; cualquier otra clave que un
/// día aparezca NO se pinta: la pantalla no inventa campos).
/// Función pura.
String detalleActividadCliente(ActividadCliente a) {
  final d = a.detalle;
  final partes = <String>[];
  void agrega(String etiqueta, Object? v) {
    final t = '${v ?? ''}'.trim();
    if (t.isNotEmpty && t != 'null') partes.add('$etiqueta: $t');
  }

  agrega('Origen', d['origen']);
  agrega('Versión de la app', d['app_version']);
  agrega('Convertido el', d['convertido_en']);
  agrega('Rutina', d['rutina']);
  final dur = (d['duracion_seg'] as num?)?.toInt();
  if (dur != null && dur > 0) {
    partes.add('Duración: ${dur ~/ 60} min');
  }
  final nEj = (d['ejercicios'] as num?)?.toInt();
  if (nEj != null) {
    partes.add(nEj == 1 ? '1 ejercicio' : '$nEj ejercicios');
  }
  agrega('Logro', d['logro']);
  final dias = (d['premio_dias'] as num?)?.toInt();
  if (dias != null) {
    partes.add(dias == 1 ? 'Premio: 1 día' : 'Premio: $dias días');
  }
  agrega('Fecha', d['fecha']);
  // 1.32 (B1-H9): las filas de SESIÓN de la RPC viva
  // emiten la fecha como `fecha_sesion`; sin leerla, la
  // sesión salía sin fecha en su detalle. Solo una de las
  // dos claves vendrá no vacía por fuente.
  agrega('Fecha', d['fecha_sesion']);
  agrega('Turno', d['turno']);
  agrega('Entrenador', d['entrenador_id']);
  agrega('Nota', d['nota']);
  final actor = (a.actor ?? '').trim();
  if (actor.isNotEmpty) partes.add('Por: $actor');
  return partes.join(' · ');
}

/// La foto cacheada de UNA persona: sus filas (máx. 200,
/// el tope que también impone la RPC) y cuándo se descargó.
class CacheActividadCliente {
  final int clienteId;
  final List<ActividadCliente> filas;
  final DateTime descargadoEn; // instante UTC

  const CacheActividadCliente({
    required this.clienteId,
    required this.filas,
    required this.descargadoEn,
  });
}

/// Servicio de la actividad en la app de clientes: la RPC
/// con su timeout de 12 s y la caché acotada en metadatos.
class ActividadClienteService {
  static const int maxFilasPorPersona = 200;
  static const int maxPersonas = 20;
  static const String _prefijo = 'fb23_cache_';

  final LocalDb _db;
  final Future<List<ActividadCliente>> Function(
      ActividadClienteParams p)? _rpcParaTest;

  ActividadClienteService(
      {LocalDb? db,
      Future<List<ActividadCliente>> Function(ActividadClienteParams p)?
          rpcParaTest})
      : _db = db ?? LocalDb.instance,
        _rpcParaTest = rpcParaTest;

  /// La llamada real a la RPC (timeout de 12 s, el de la
  /// casa). Lanza si la red o el servidor fallan: quien
  /// llama decide la honestidad (caché fechada o vacío).
  Future<List<ActividadCliente>> _rpcReal(ActividadClienteParams p) async {
    final params = <String, dynamic>{
      'p_cliente_id': p.clienteId,
      'p_limite': p.limite,
    };
    if (p.desde != null) {
      params['p_desde'] = p.desde!.toUtc().toIso8601String();
    }
    if (p.hasta != null) {
      params['p_hasta'] = p.hasta!.toUtc().toIso8601String();
    }
    if (p.cursor != null) {
      params['p_cursor_ts'] = p.cursor!.ts.toUtc().toIso8601String();
      params['p_cursor_fuente'] = p.cursor!.fuente;
      params['p_cursor_id'] = p.cursor!.id;
    }
    final res = await Supabase.instance.client
        .rpc('admin_actividad_cliente', params: params)
        .timeout(const Duration(seconds: 12));
    final filas = <ActividadCliente>[];
    // Yunque R3-M6-7: una respuesta que NO es una lista es un
    // fallo de contrato, no «sin actividad»: devolver [] aquí
    // lo cacheaba el llamador como actividad vacía real con
    // _sinConexion=false (error disfrazado de vacío). Se
    // lanza, como hacen marcas_cliente y panel_premios con la
    // respuesta malformada, y el catch del llamador lo pinta
    // como lo que es: no se pudo consultar.
    if (res is! List) {
      throw StateError(
          'admin_actividad_cliente: respuesta no es una lista');
    }
    for (final f in res) {
      if (f is Map) {
        filas.add(ActividadCliente.desdeRpc(
            Map<String, dynamic>.from(f)));
      }
    }
    return filas;
  }

  Future<List<ActividadCliente>> consultar(ActividadClienteParams p) =>
      (_rpcParaTest ?? _rpcReal)(p);

  /// Lee la caché de una persona (null si nunca se
  /// descargó). Una caché corrupta se trata como ausente,
  /// nunca como error que bloquee la pantalla.
  Future<CacheActividadCliente?> leerCache(int clienteId) async {
    final crudo = await _db.getMeta('$_prefijo$clienteId');
    if (crudo == null || crudo.isEmpty) return null;
    try {
      final dec = jsonDecode(crudo);
      if (dec is! Map) return null;
      final filasCrudas = dec['filas'];
      if (filasCrudas is! List) return null;
      return CacheActividadCliente(
        clienteId: clienteId,
        filas: [
          for (final f in filasCrudas)
            if (f is Map)
              ActividadCliente.desdeCache(
                  Map<String, dynamic>.from(f)),
        ],
        descargadoEn: parseFecha('${dec['descargado_en'] ?? ''}') ??
            DateTime.utc(1970),
      );
    } catch (_) {
      return null;
    }
  }

  /// Guarda la foto de una persona aplicando la cota:
  /// máx. 200 filas (las más recientes: la RPC ya viene
  /// ordenada) y máx. 20 personas (sale la consulta menos
  /// reciente). La escritura va en UNA transacción del
  /// almacén de metadatos: la foto y el índice quedan
  /// consistentes o no queda nada.
  Future<void> guardarCache(int clienteId,
      List<ActividadCliente> filas, DateTime descargadoEnUtc) async {
    final recorte = filas.length > maxFilasPorPersona
        ? filas.sublist(0, maxFilasPorPersona)
        : filas;
    final repo = _RepositorioCacheActividad(_db);
    final indice = await repo.leerIndice();
    final orden = <int>[
      for (final id in indice)
        if (id != clienteId) id,
      clienteId,
    ];
    final sobran = orden.length - maxPersonas;
    final expulsadas = sobran > 0 ? orden.sublist(0, sobran) : <int>[];
    final queda = sobran > 0 ? orden.sublist(sobran) : orden;
    final valor = jsonEncode({
      'descargado_en': descargadoEnUtc.toUtc().toIso8601String(),
      'filas': [for (final f in recorte) f.aJson()],
    });
    await repo.guardarFoto(
      clienteId: clienteId,
      valor: valor,
      expulsadas: expulsadas,
      indiceFinal: queda,
    );
  }

  /// Borra la caché de una persona y la saca del índice.
  Future<void> purgarPersona(int clienteId) async {
    final repo = _RepositorioCacheActividad(_db);
    final indice = await repo.leerIndice();
    await repo.guardarFoto(
      clienteId: clienteId,
      valor: null,
      expulsadas: [clienteId],
      indiceFinal: [for (final id in indice) if (id != clienteId) id],
    );
  }

  /// Purga TODA la caché (cierre de sesión): la actividad
  /// de clientes no queda legible en el teléfono cuando
  /// entra otra cuenta. La invoca la purga general de
  /// LocalDb al cerrar sesión.
  Future<void> purgarTodo() async {
    final claves = await _db.metasConPrefijo(_prefijo);
    if (claves.isEmpty) return;
    final repo = _RepositorioCacheActividad(_db);
    await repo.borrarClaves(claves);
  }
}

/// Parámetros de una consulta a la RPC (la costura pura de
/// la llamada: persona, rango opcional, cursor opcional y
/// tamaño de bloque).
class ActividadClienteParams {
  final int clienteId;
  final DateTime? desde; // instante UTC, inclusivo
  final DateTime? hasta; // instante UTC, exclusivo
  final ({DateTime ts, String fuente, int id})? cursor;
  final int limite;

  const ActividadClienteParams({
    required this.clienteId,
    this.desde,
    this.hasta,
    this.cursor,
    this.limite = ActividadClienteService.maxFilasPorPersona,
  });
}

/// Repositorio de la caché sobre el almacén de metadatos:
/// el índice de personas retenidas vive en su propia clave
/// y cada foto en la suya. Toda escritura pasa por UNA
/// transacción de la conexión (nunca se lee por el getter
/// de la conexión principal dentro de ella).
class _RepositorioCacheActividad {
  final LocalDb _db;
  const _RepositorioCacheActividad(this._db);

  static const String _claveIndice = 'fb23_indice';
  static const String _prefijo = ActividadClienteService._prefijo;

  Future<List<int>> leerIndice() async {
    final crudo = await _db.getMeta(_claveIndice);
    if (crudo == null || crudo.isEmpty) return const [];
    try {
      final dec = jsonDecode(crudo);
      if (dec is List) {
        return [for (final e in dec) if (e is num) e.toInt()];
      }
    } catch (_) {}
    return const [];
  }

  /// valor == null borra la foto de [clienteId].
  Future<void> guardarFoto({
    required int clienteId,
    required String? valor,
    required List<int> expulsadas,
    required List<int> indiceFinal,
  }) async {
    final d = await _db.db;
    await d.transaction((txn) async {
      for (final id in expulsadas) {
        await txn.delete('meta', where: 'k = ?', whereArgs: ['$_prefijo$id']);
      }
      if (valor == null) {
        await txn.delete('meta',
            where: 'k = ?', whereArgs: ['$_prefijo$clienteId']);
      } else {
        await _db.setMetaEn(txn, '$_prefijo$clienteId', valor);
      }
      await _db.setMetaEn(txn, _claveIndice, jsonEncode(indiceFinal));
    });
  }

  Future<void> borrarClaves(List<String> claves) async {
    final d = await _db.db;
    await d.transaction((txn) async {
      for (final k in claves) {
        await txn.delete('meta', where: 'k = ?', whereArgs: [k]);
      }
    });
  }
}
