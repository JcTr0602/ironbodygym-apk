import 'package:supabase_flutter/supabase_flutter.dart';

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
  });

  factory AccesoCliente.fromJson(Map<String, dynamic> j) {
    DateTime? parseFecha(dynamic v) {
      if (v == null) return null;
      return DateTime.tryParse('$v')?.toLocal();
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
    );
  }
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
