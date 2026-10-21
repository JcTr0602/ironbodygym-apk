// lib/permisos_entrenador.dart
// v1.3.9 Sprint 1 (#14): permisos granulares desde Supabase.
// El dueño (Jc) siempre tiene todo. Los entrenadores dependen del JSONB.
// FIX Argón: persistencia en SharedPreferences para modo offline.
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'auth.dart';

/// Helper global de permisos granulares (v1.3.9 Sprint 1).
/// Lee el mapa cacheado; el dueño siempre retorna true.
class PermisosEntrenador {
  static final PermisosEntrenador _instance =
      PermisosEntrenador._internal();
  factory PermisosEntrenador() => _instance;
  PermisosEntrenador._internal();

  static const _kPrefsPermisos = 'cache_permisos_entrenador_json';
  static const _kPrefsActivo = 'cache_entrenador_activo';
  static const _kPrefsHabilitado = 'cache_entrenador_habilitado';

  Map<String, dynamic> _permisos = {};
  bool _activo = true;
  // v1.4.4: ¿existe la fila del entrenador en
  // entrenadores_autorizados? Sin fila NO es un suspendido: es una
  // cuenta aún no habilitada (la RPC vieja devolvía activo=false
  // para ambos casos y la app lo llamaba «suspendido»).
  bool _habilitado = true;
  bool _cargado = false;

  /// Carga los permisos desde Supabase (llamar en login/sync).
  /// Primero levanta caché local (offline), luego refresca desde Supabase.
  Future<void> cargar() async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Primero levantar caché local por si estamos offline
    if (!_cargado) {
      _activo = prefs.getBool(_kPrefsActivo) ?? true;
      _habilitado = prefs.getBool(_kPrefsHabilitado) ?? true;
      final raw = prefs.getString(_kPrefsPermisos);
      if (raw != null && raw.isNotEmpty) {
        try {
          _permisos =
              Map<String, dynamic>.from(jsonDecode(raw) as Map);
          _cargado = true;
        } catch (_) {}
      }
    }

    // 2. Intentar refrescar desde Supabase
    try {
      final res = await Supabase.instance.client
          .rpc('obtener_mis_permisos');
      final data = Map<String, dynamic>.from(res as Map);
      if (data['es_admin'] == true) {
        _permisos = {
          'can_generate_pin': true,
          'can_edit_nutrition': true,
          'can_record_measurements': true,
          'can_view_progress': true,
          'can_view_payroll': true,
          'can_cobrar_pagos': true,
          'can_inscribir_clientes': true,
          'can_editar_fichas': true,
          'can_vender_suplementos': true,
          'can_registrar_gastos': true,
          'can_gestionar_turnos': true,
          'can_ver_todos_pagos': true,
          'can_ver_cifras': true,
        };
        _activo = true;
        _habilitado = true;
      } else {
        _activo = data['activo'] == true;
        // v1.4.4: la RPC nueva trae 'habilitado'; con la vieja la
        // clave no viene y se asume habilitado (comportamiento
        // anterior) hasta que el SQL nuevo se aplique.
        _habilitado = data['habilitado'] != false;
        final p = data['permisos'];
        if (p is Map) {
          _permisos = Map<String, dynamic>.from(p);
        }
      }
      _cargado = true;
      await prefs.setBool(_kPrefsActivo, _activo);
      await prefs.setBool(_kPrefsHabilitado, _habilitado);
      await prefs.setString(
          _kPrefsPermisos, jsonEncode(_permisos));
    } catch (_) {
      // Offline: ya quedó cargado el caché de SharedPreferences del paso 1
    }
  }

  /// Si la cuenta está suspendida: TIENE fila y está desactivada
  /// (el dueño nunca está suspendido).
  bool get estaSuspendido =>
      !AuthService().isOwner && _cargado && _habilitado && !_activo;

  /// Si la cuenta aún NO tiene fila de permisos (no es una
  /// suspensión: nadie la ha habilitado todavía).
  bool get sinHabilitar =>
      !AuthService().isOwner && _cargado && !_habilitado;

  /// ¿Ya hay una foto de permisos (de la RPC o de la caché)?
  /// Los candados de visibilidad la exigen para restringir:
  /// sin foto no se bloquea la interfaz por un dato que nunca
  /// llegó (ver permisos_visibilidad.dart).
  bool get cargado => _cargado;

  bool _check(String key) {
    // El dueño siempre tiene permiso
    if (AuthService().isOwner) return true;
    return _permisos[key] == true;
  }

  bool get canGeneratePin => _check('can_generate_pin');
  bool get canEditNutrition => _check('can_edit_nutrition');
  bool get canRecordMeasurements =>
      _check('can_record_measurements');
  bool get canViewProgress => _check('can_view_progress');
  bool get canViewPayroll => _check('can_view_payroll');

  // Niveles 2+3 (v1.4.5)
  bool get canCobrarPagos => _check('can_cobrar_pagos');
  bool get canInscribirClientes => _check('can_inscribir_clientes');
  bool get canEditarFichas => _check('can_editar_fichas');
  bool get canVenderSuplementos => _check('can_vender_suplementos');
  bool get canRegistrarGastos => _check('can_registrar_gastos');
  bool get canGestionarTurnos => _check('can_gestionar_turnos');
  bool get canVerTodosPagos => _check('can_ver_todos_pagos');
  bool get canVerCifras => _check('can_ver_cifras');
}
