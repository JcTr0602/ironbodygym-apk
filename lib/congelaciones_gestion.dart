/// Congelación de mensualidad (0.5) — lado Gestión.
///
/// Modelo + servicio de las solicitudes de congelación. La
/// bandeja y la ficha leen el ESPEJO local
/// `cliente_congelaciones` (solo baja en el teléfono del dueño:
/// RLS es_dueno() + manifiesto + tablasProhibidasEntrenador —
/// el motivo puede traer datos de salud). Resolver y cerrar
/// van por RPC directa con timeout de 12 s
/// (admin_resolver_congelacion / admin_cerrar_congelacion):
/// la aprobación exige es_dueno() en el servidor; el cierre
/// admite dueño o entrenador (es_staff()) pero la UI de esta
/// pieza solo lo ofrece donde el diseño lo fija.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import 'errores_sync.dart';
import 'localdb.dart';

/// Categorías del motivo (las mismas claves que valida el
/// servidor en cliente_congelaciones.motivo_categoria).
const Map<String, String> kCategoriasCongelacion = {
  'viaje': 'Viaje',
  'enfermedad_lesion': 'Enfermedad o lesión',
  'trabajo': 'Trabajo',
  'otro': 'Otro',
};

String etiquetaCategoriaCongelacion(String? clave) =>
    kCategoriasCongelacion[clave] ?? 'Otro';

/// Yunque Exhaustivo P-01: ramas amables ÚNICAS para los
/// fallos de las RPC de congelaciones en la bandeja. El
/// error del servidor (res['error']) y las excepciones
/// NUNCA se pintan crudos — códigos PostgREST/SQL y claves
/// internas no son texto para el dueño —: la rama amable
/// es la misma para todos los fallos de cada operación,
/// con el mismo patrón que mensajeCierreCongelacionFallido
/// de la ficha (lib/ui/ficha_congelacion.dart, SL-2
/// G03-11). Viven aquí, en la capa de servicio, porque la
/// ficha importa la bandeja (congelaciones.dart) y no al
/// revés: así ambas pantallas pueden usarlas sin ciclo.
/// El detalle técnico lo conserva quien llama si lo
/// registra en bitácora (AppLog), nunca la pantalla.
String mensajeListarCongelacionesFallido(Object? errorServidor) =>
    'No se pudieron cargar las congelaciones. '
    'Inténtalo de nuevo.';

String mensajeResolverCongelacionFallido(Object? errorServidor) =>
    'No se pudo resolver la solicitud. Inténtalo de nuevo.';

String mensajeCerrarCongelacionFallido(Object? errorServidor) =>
    'No se pudo cerrar la congelación. Inténtalo de nuevo.';

/// Días de un rango cerrado [desde, hasta] contando por
/// componentes UTC (inmune al DST de La Habana).
int diasRangoCongelacion(DateTime desde, DateTime hasta) {
  final d = DateTime.utc(desde.year, desde.month, desde.day);
  final h = DateTime.utc(hasta.year, hasta.month, hasta.day);
  return h.difference(d).inDays + 1;
}

DateTime? _fecha(Object? v) {
  if (v == null) return null;
  final s = '$v';
  if (s.length < 10) return null;
  return DateTime.tryParse(s.substring(0, 10));
}

class CongelacionGestion {
  final String id;
  final int clienteId;
  final String? clienteNombre;
  final String? clienteTelefono;
  final String? clientePagadoHasta;
  final String motivoCategoria;
  final String motivo;
  final String estado; // pendiente|aprobada|rechazada|cancelada
  final DateTime? desde;
  final DateTime? hasta;
  final DateTime? inicioEfectivo;
  final DateTime? hastaEfectivo;
  final String? creadoEn;
  final String? resueltoEn;
  final String? resueltoPorNombre;
  final String? motivoResolucion;
  final bool excepcionDueno;
  final String? cerradoPorNombre;
  final String? cerradoEn;
  final int? diasAExtender;
  final int? diasMaterializados;

  const CongelacionGestion({
    required this.id,
    required this.clienteId,
    this.clienteNombre,
    this.clienteTelefono,
    this.clientePagadoHasta,
    required this.motivoCategoria,
    required this.motivo,
    required this.estado,
    this.desde,
    this.hasta,
    this.inicioEfectivo,
    this.hastaEfectivo,
    this.creadoEn,
    this.resueltoEn,
    this.resueltoPorNombre,
    this.motivoResolucion,
    this.excepcionDueno = false,
    this.cerradoPorNombre,
    this.cerradoEn,
    this.diasAExtender,
    this.diasMaterializados,
  });

  factory CongelacionGestion.fromJson(Map<String, dynamic> m) {
    return CongelacionGestion(
      id: '${m['id'] ?? ''}',
      clienteId: (m['cliente_id'] as num?)?.toInt() ?? 0,
      clienteNombre: m['cliente_nombre'] as String?,
      clienteTelefono: m['cliente_telefono'] as String?,
      clientePagadoHasta: m['cliente_pagado_hasta'] as String?,
      motivoCategoria: '${m['motivo_categoria'] ?? 'otro'}',
      motivo: '${m['motivo'] ?? ''}',
      estado: '${m['estado'] ?? 'pendiente'}',
      desde: _fecha(m['desde']),
      hasta: _fecha(m['hasta']),
      inicioEfectivo: _fecha(m['inicio_efectivo']),
      hastaEfectivo: _fecha(m['hasta_efectivo']),
      creadoEn: m['creado_en'] as String?,
      resueltoEn: m['resuelto_en'] as String?,
      resueltoPorNombre: m['resuelto_por_nombre'] as String?,
      motivoResolucion: m['motivo_resolucion'] as String?,
      excepcionDueno: m['excepcion_dueno'] == true,
      cerradoPorNombre: m['cerrado_por_nombre'] as String?,
      cerradoEn: m['cerrado_en'] as String?,
      diasAExtender: (m['dias_a_extender'] as num?)?.toInt(),
      diasMaterializados: (m['dias_materializados'] as num?)?.toInt(),
    );
  }

  bool get esPendiente => estado == 'pendiente';
  bool get esAprobada => estado == 'aprobada';

  /// Fecha en la que la pausa termina según lo aprobado
  /// (el cierre anticipado manda sobre lo pedido).
  DateTime? get finEfectivo => hastaEfectivo ?? hasta;

  /// ¿La pausa está corriendo en `hoy`? (aprobada, ya empezó
  /// y aún no terminó). Una programada NO cuenta: su
  /// pagado_hasta aún no llegó al inicio.
  bool enCursoEn(DateTime hoy) {
    if (!esAprobada || inicioEfectivo == null) return false;
    final h = DateTime.utc(hoy.year, hoy.month, hoy.day);
    final i = DateTime.utc(
        inicioEfectivo!.year, inicioEfectivo!.month, inicioEfectivo!.day);
    final f = finEfectivo;
    if (f == null) return false;
    final fu = DateTime.utc(f.year, f.month, f.day);
    return !h.isBefore(i) && !h.isAfter(fu);
  }

  bool get materializada => diasMaterializados != null;

  /// Etiqueta de estado para las listas (M2): la aprobada se
  /// desdobla en programada / en curso / terminada según el
  /// reloj, sin tocar el estado guardado.
  String etiquetaEstado(DateTime hoy) {
    switch (estado) {
      case 'pendiente':
        return 'Pendiente';
      case 'rechazada':
        return 'Rechazada';
      case 'cancelada':
        return 'Cancelada';
      case 'aprobada':
        if (materializada) return 'Terminada · días aplicados';
        if (inicioEfectivo == null) return 'Aprobada';
        final h = DateTime.utc(hoy.year, hoy.month, hoy.day);
        final i = DateTime.utc(inicioEfectivo!.year,
            inicioEfectivo!.month, inicioEfectivo!.day);
        if (h.isBefore(i)) return 'Programada';
        if (enCursoEn(hoy)) return 'En curso';
        return 'Terminada · sincronizando días';
      default:
        return estado;
    }
  }
}

/// ¿Hay una congelación en curso entre [filas] para este
/// cliente en `hoy`? (helper puro del cortocircuito de
/// listados: congelado ⇒ no vencido).
bool clienteCongeladoEnCurso(
    Iterable<CongelacionGestion> filas, int clienteId, DateTime hoy) {
  for (final f in filas) {
    if (f.clienteId == clienteId && f.enCursoEn(hoy)) return true;
  }
  return false;
}

class CongelacionesService {
  CongelacionesService._();
  static final CongelacionesService instance = CongelacionesService._();

  static const _timeout = Duration(seconds: 12);

  /// Lee el espejo local (triestado de la casa: ok=false es
  /// FALLO de lectura, jamás «no hay solicitudes»).
  Future<({bool ok, List<CongelacionGestion> datos})> leerEspejo() async {
    try {
      final filas =
          await LocalDb.instance.allMirror('cliente_congelaciones');
      final out = [for (final f in filas) CongelacionGestion.fromJson(f)];
      out.sort((a, b) => (b.creadoEn ?? '').compareTo(a.creadoEn ?? ''));
      return (ok: true, datos: out);
    } catch (_) {
      return (ok: false, datos: const <CongelacionGestion>[]);
    }
  }

  Future<List<CongelacionGestion>> deCliente(int clienteId) async {
    final r = await leerEspejo();
    if (!r.ok) return const [];
    return [for (final f in r.datos) if (f.clienteId == clienteId) f];
  }

  /// Clientes con pausa EN CURSO hoy según el espejo. En el
  /// teléfono de un entrenador el espejo está vacío por
  /// diseño (prohibido): el conjunto sale vacío y sus
  /// listados no cambian (la exclusión es cosa del dueño).
  Future<Set<int>> idsCongeladosEnCurso(DateTime hoy) async {
    final r = await leerEspejo();
    if (!r.ok) return const {};
    return {
      for (final f in r.datos)
        if (f.enCursoEn(hoy)) f.clienteId,
    };
  }

  /// Desenvuelve el sobre de `admin_listar_congelaciones`.
  /// Contrato fijado contra la definición viva de la RPC:
  /// devuelve jsonb_build_object('ok', …, 'lista', […],
  /// 'hoy', …) — la lista viaja bajo la clave 'lista', NO
  /// 'congelaciones' (el Yunque Cruzado 2026-11-11 cazó que
  /// aquí se leía la clave inexistente y la bandeja del
  /// dueño se vaciaba con ok=true). Función pura para que
  /// el test de contrato la ejercite sin red.
  static ({bool ok, List<CongelacionGestion> datos, String? error})
      parsearRespuestaListar(Object? res) {
    if (res is Map && res['ok'] == true) {
      final lista = (res['lista'] as List?) ?? const [];
      return (
        ok: true,
        datos: [
          for (final e in lista)
            if (e is Map)
              CongelacionGestion.fromJson(Map<String, dynamic>.from(e)),
        ],
        error: null,
      );
    }
    return (
      ok: false,
      datos: const <CongelacionGestion>[],
      // El error del sobre {ok:false} del servidor viaja
      // tal cual: son mensajes de dominio escritos para
      // el usuario («Solo el dueño ve las congelaciones.»)
      // y su paso directo es contrato fijado por
      // test/congelacion_gestion_test.dart. El saneado
      // genérico de esta rama quedó probado en el Yunque
      // Exhaustivo (P-01) y espera decisión en el paquete
      // de contratos; las EXCEPCIONES de la RPC sí salen
      // traducidas (ver listarRemoto).
      error: res is Map
          ? '${res['error'] ?? 'Error del servidor'}'
          : 'Error del servidor',
    );
  }

  /// Lista enriquecida del servidor (nombre, teléfono y
  /// pagado_hasta ACTUAL del cliente). Devuelve ok=false con
  /// el error si la RPC falla: la pantalla distingue el fallo
  /// del vacío.
  Future<({bool ok, List<CongelacionGestion> datos, String? error})>
      listarRemoto() async {
    try {
      final res = await Supabase.instance.client
          .rpc('admin_listar_congelaciones')
          .timeout(_timeout);
      return parsearRespuestaListar(res);
    } catch (e) {
      // P-01: antes aquí salía '$e' — la excepción de la
      // RPC con su código PostgREST en inglés — y la
      // bandeja lo pintaba tal cual como subtítulo. Sale
      // ya traducido por el traductor amable de la casa
      // (errores_sync.dart, sin ciclo: ese módulo no
      // importa esta capa ni Supabase).
      return (
        ok: false,
        datos: const <CongelacionGestion>[],
        error: mensajeErrorAmable(e),
      );
    }
  }

  /// La congelación aprobada vigente de un cliente, SIN
  /// motivo ni categoría (RPC congelacion_vigente_staff):
  /// la vía del entrenador en la ficha — puede ver la pausa
  /// y cerrarla, jamás el porqué. null = sin aprobada o sin
  /// conexión (la sección simplemente no se pinta).
  Future<Map<String, dynamic>?> vigenteStaff(int clienteId) async {
    try {
      final res = await Supabase.instance.client.rpc(
        'congelacion_vigente_staff',
        params: {'p_cliente_id': clienteId},
      ).timeout(_timeout);
      if (res is Map && res['ok'] == true) {
        final a = res['aprobada'];
        if (a is Map) return Map<String, dynamic>.from(a);
      }
    } catch (_) {}
    return null;
  }

  /// Aprueba o rechaza. El servidor revalida TODO en
  /// transacción y devuelve el resultado SIN lanzar por
  /// reglas: {ok:false, error:'Fuera de reglas: …',
  /// reglas_rotas:[...]} cuando el rango confirmado rompe
  /// alguna — la UI ofrece entonces «Aprobar como excepción».
  /// Puede devolver ya_resuelta:true con lo persistido si
  /// otro dispositivo resolvió primero (no es un error).
  Future<Map<String, dynamic>> resolver({
    required String id,
    required bool aprobar,
    DateTime? desde,
    DateTime? hasta,
    String? motivoResolucion,
    bool forzarExcepcion = false,
  }) async {
    String iso(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final res = await Supabase.instance.client.rpc(
      'admin_resolver_congelacion',
      params: {
        'p_id': id,
        'p_aprobar': aprobar,
        'p_desde': desde == null ? null : iso(desde),
        'p_hasta': hasta == null ? null : iso(hasta),
        'p_motivo_resolucion': motivoResolucion,
        'p_forzar_excepcion': forzarExcepcion,
      },
    ).timeout(_timeout);
    if (res is Map) return Map<String, dynamic>.from(res);
    return {'ok': false, 'error': 'Respuesta inesperada del servidor'};
  }

  /// Cierra una congelación aprobada (la pausa termina ayer;
  /// si aún no empezaba, la cancela con 0 días). Devuelve el
  /// resultado del servidor.
  Future<Map<String, dynamic>> cerrar({
    required String id,
    required String cerradoPorNombre,
  }) async {
    final res = await Supabase.instance.client.rpc(
      'admin_cerrar_congelacion',
      params: {'p_id': id, 'p_cerrado_por_nombre': cerradoPorNombre},
    ).timeout(_timeout);
    if (res is Map) return Map<String, dynamic>.from(res);
    return {'ok': false, 'error': 'Respuesta inesperada del servidor'};
  }
}
