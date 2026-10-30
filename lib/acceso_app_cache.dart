import 'package:supabase_flutter/supabase_flutter.dart';

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

  factory AccesoCliente.fromJson(Map<String, dynamic> j) {
    DateTime? parseFecha(dynamic v) {
      if (v == null) return null;
      // Argón P3#7: hora de La Habana, no la del dispositivo.
      final parsed = DateTime.tryParse('$v');
      return parsed == null ? null : aHabana(parsed);
    }

    return AccesoCliente(
      clienteId: (j['cliente_id'] as num).toInt(),
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
                  parseFecha(j['bloqueado_hasta'])!
                      .isAfter(ahoraHabana()))),
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
  /// revocado > bloqueado > pin pendiente > activo.
  String get estado {
    if (revocado || !activo) return 'revocado';
    if (estaBloqueado || bloqueoManualVigente) return 'bloqueado';
    return 'activo';
  }

  bool get pinPendiente => debeCambiarPin || forzarCambioPin;
}

class AccesoAppCache {
  AccesoAppCache._();
  static final AccesoAppCache instance = AccesoAppCache._();

  Map<int, AccesoCliente>? _porCliente;
  bool _cargando = false;

  /// true si el caché ya se cargó en esta sesión (aunque esté vacío).
  bool get cargado => _porCliente != null;

  /// Todos los accesos (para el panel F2/F8). null si no cargado.
  List<AccesoCliente>? get todos =>
      _porCliente?.values.toList();

  /// Carga el caché desde el servidor. Retorna true si tuvo éxito.
  /// Si falla (offline), deja el caché como estaba y retorna false.
  Future<bool> cargar() async {
    if (_cargando) return false;
    _cargando = true;
    try {
      final res = await Supabase.instance.client
          .rpc('listar_accesos_clientes');
      final lista = (res as List)
          .map((e) => AccesoCliente.fromJson(
              Map<String, dynamic>.from(e as Map)))
          .toList();
      _porCliente = {for (final a in lista) a.clienteId: a};
      return true;
    } catch (_) {
      return false;
    } finally {
      _cargando = false;
    }
  }

  /// Obtiene el acceso de un cliente. null = sin acceso o no cargado.
  AccesoCliente? obtener(int clienteId) => _porCliente?[clienteId];

  /// Invalidación inmediata tras generar/revocar (Argón).
  /// Si se pasa el acceso actualizado, lo reemplaza; si es null, lo elimina.
  void actualizar(int clienteId, AccesoCliente? acceso) {
    final m = _porCliente;
    if (m == null) return;
    if (acceso == null) {
      m.remove(clienteId);
    } else {
      m[clienteId] = acceso;
    }
  }

  /// Limpia el caché (al cerrar sesión).
  void limpiar() {
    _porCliente = null;
  }
}
