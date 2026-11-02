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

  // Argón Acceso #1 (CRÍTICO): las claves de caché llevan el
  // usuario dueño de la foto. Antes eran GLOBALES: el dueño
  // entraba en el teléfono, su foto (todo en true) quedaba
  // guardada, y el entrenador que entraba después sin red la
  // heredaba entera. Ahora cada usuario tiene SU caché y al
  // cerrar sesión la memoria se limpia (limpiar()).
  static String get _kPrefsPermisos =>
      'cache_permisos_entrenador_json@${AuthService().username}';
  static String get _kPrefsActivo =>
      'cache_entrenador_activo@${AuthService().username}';
  static String get _kPrefsHabilitado =>
      'cache_entrenador_habilitado@${AuthService().username}';
  // Claves viejas (globales, pre-1.21): solo se usan UNA vez
  // para migrar la foto al primer usuario que cargue tras la
  // actualización (en los teléfonos de los entrenadores es su
  // propia foto; sin migración, un entrenador offline tras
  // actualizar quedaría bloqueado sin culpa).
  static const _kGlobalPermisos = 'cache_permisos_entrenador_json';
  static const _kGlobalActivo = 'cache_entrenador_activo';
  static const _kGlobalHabilitado = 'cache_entrenador_habilitado';

  Map<String, dynamic> _permisos = {};
  // Argón Acceso #2 (CRÍTICO): defaults FAIL-CLOSED. Antes
  // _activo/_habilitado nacían en true y con la caché vacía o
  // corrupta un entrenador sin habilitar (o suspendido) cuyo
  // refresco fallaba entraba a la interfaz principal.
  bool _activo = false;
  // v1.4.4: ¿existe la fila del entrenador en
  // entrenadores_autorizados? Sin fila NO es un suspendido: es una
  // cuenta aún no habilitada (la RPC vieja devolvía activo=false
  // para ambos casos y la app lo llamaba «suspendido»).
  bool _habilitado = false;
  bool _cargado = false;
  // ¿cargar() ya corrió para el usuario actual? Sin foto tras
  // intentar cargar, un no-dueño se trata como «sin habilitar»
  // (fail-closed): su primera carga con red siembra la foto.
  bool _cargaIntentada = false;
  String _ultimoUsername = '';

  PermisosEntrenador._internal() {
    // Al perder la sesión (signOut en cualquier ruta), la
    // memoria se limpia sola: ninguna foto sobrevive al cambio
    // de usuario aunque cargar() tarde en correr.
    try {
      Supabase.instance.client.auth.onAuthStateChange.listen((d) {
        if (d.session == null) limpiar();
      });
    } catch (_) {
      // Sin Supabase inicializado (tests): la limpieza por
      // cambio de usuario en cargar() sigue activa.
    }
  }

  /// Limpia la foto en memoria (la caché persistida es por
  /// usuario y se conserva para SU próximo ingreso offline).
  void limpiar() {
    _permisos = {};
    _activo = false;
    _habilitado = false;
    _cargado = false;
    _cargaIntentada = false;
    _ultimoUsername = '';
  }

  /// Carga los permisos desde Supabase (llamar en login/sync).
  /// Primero levanta caché local (offline), luego refresca desde Supabase.
  Future<void> cargar() async {
    final prefs = await SharedPreferences.getInstance();

    // Argón Acceso #1: si cambió el usuario desde la última
    // carga, la foto anterior se descarta ANTES de leer nada.
    final usuarioActual = AuthService().username;
    if (usuarioActual != _ultimoUsername) {
      limpiar();
      _ultimoUsername = usuarioActual;
    }
    _cargaIntentada = true;

    // Migración única de las claves globales a las del usuario
    // (solo si este usuario aún no tiene foto propia).
    if (!prefs.containsKey(_kPrefsPermisos) &&
        prefs.containsKey(_kGlobalPermisos)) {
      final rawG = prefs.getString(_kGlobalPermisos);
      if (rawG != null) {
        await prefs.setString(_kPrefsPermisos, rawG);
      }
      final actG = prefs.getBool(_kGlobalActivo);
      if (actG != null) await prefs.setBool(_kPrefsActivo, actG);
      final habG = prefs.getBool(_kGlobalHabilitado);
      if (habG != null) {
        await prefs.setBool(_kPrefsHabilitado, habG);
      }
      await prefs.remove(_kGlobalPermisos);
      await prefs.remove(_kGlobalActivo);
      await prefs.remove(_kGlobalHabilitado);
    }

    // 1. Primero levantar caché local por si estamos offline
    // (SOLO la foto de ESTE usuario; defaults fail-closed).
    if (!_cargado) {
      _activo = prefs.getBool(_kPrefsActivo) ?? false;
      _habilitado = prefs.getBool(_kPrefsHabilitado) ?? false;
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
          'can_ver_ranking_servicios': true,
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
  /// suspensión: nadie la ha habilitado todavía). Argón Acceso
  /// #2: también cuenta como «sin habilitar» el no-dueño SIN
  /// foto tras intentar cargar (caché vacía/corrupta y refresco
  /// fallido): fail-closed, no entra a la interfaz principal.
  bool get sinHabilitar =>
      !AuthService().isOwner &&
      _cargaIntentada &&
      !_habilitado &&
      (_cargado || _permisos.isEmpty);

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

  /// post-1.8.0 (ítem 9): ranking de compradores de Servicios.
  /// Apagado por defecto: sin la clave en su JSONB, no.
  bool get canVerRankingServicios =>
      _check('can_ver_ranking_servicios');
}
