// lib/ui/panel_permisos.dart
// v1.3.9 Sprint 1 (#14): panel de permisos para entrenadores.
// Solo el dueño (Jc) puede acceder.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../auth.dart';
import '../entrenador_identidad.dart';
import '../localdb.dart';
import '../negocio.dart' show pendientePorEntrenador, fmtMonto;
import '../tiempo.dart';
import '../ultimo_sync.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

class EntrenadorPermiso {
  final String email;
  final String nombre;
  bool activo;
  Map<String, bool> permisos;

  /// 1.25 T101: telegram_id resuelto contra usuarios_apk
  /// (null si el username del correo no está en la meta):
  /// con él la tarjeta cruza turno, sync y pendiente.
  final int? telegramId;

  EntrenadorPermiso({
    required this.email,
    required this.nombre,
    required this.activo,
    required this.permisos,
    this.telegramId,
  });

  /// 1.25 T101: los 14 permisos AGRUPADOS por lo que
  /// gobiernan, cada grupo con su línea de ayuda (antes
  /// eran 14 interruptores planos que mezclaban niveles:
  /// un candado de servidor junto a una visibilidad).
  static const gruposPermisos = [
    (
      'Puede hacer',
      'Acciones que registran o cambian datos del gym; '
          'el servidor las verifica.',
      [
        'can_cobrar_pagos',
        'can_inscribir_clientes',
        'can_editar_fichas',
        'can_vender_suplementos',
        'can_registrar_gastos',
        'can_gestionar_turnos',
      ],
    ),
    (
      'Puede ver',
      'Solo visibilidad en su app: no cambia ningún dato.',
      [
        'can_view_payroll',
        'can_ver_todos_pagos',
        'can_ver_cifras',
        'can_ver_ranking_servicios',
        'can_view_progress',
      ],
    ),
    (
      'App de clientes',
      'Lo que afecta a la app de los clientes: sus '
          'accesos y lo que ven de su progreso.',
      [
        'can_generate_pin',
        'can_edit_nutrition',
        'can_record_measurements',
      ],
    ),
  ];

  static const permisosDisponibles = [
    ('can_generate_pin', 'Generar PIN app', 'Crear accesos para clientes'),
    ('can_edit_nutrition', 'Editar nutrición', 'Asignar planes nutricionales'),
    ('can_record_measurements', 'Registrar mediciones', 'Medir a clientes en el gym'),
    ('can_view_progress', 'Ver progreso', 'Ver mediciones de clientes'),
    ('can_view_payroll', 'Ver nómina', 'Ver su acumulado del mes'),
    // Niveles 2+3 (v1.4.5): las 6 primeras son candados duros
    // en el servidor (permisos_ops); las 2 últimas son de
    // visibilidad (interfaz y consultas). Clave ausente = no.
    ('can_cobrar_pagos', 'Cobrar pagos', 'Registrar pagos y mensualidades'),
    ('can_inscribir_clientes', 'Inscribir clientes', 'Dar de alta clientes nuevos'),
    ('can_editar_fichas', 'Editar fichas', 'Modificar datos, fotos y notas del cliente'),
    ('can_vender_suplementos', 'Vender suplementos', 'Registrar ventas y reservas de suplementos'),
    ('can_registrar_gastos', 'Registrar gastos', 'Anotar gastos del gimnasio'),
    ('can_gestionar_turnos', 'Gestionar turnos', 'Marcar y corregir turnos de apertura'),
    ('can_ver_todos_pagos', 'Ver todos los pagos', 'Ver pagos registrados por otros entrenadores'),
    ('can_ver_cifras', 'Ver cifras', 'Ver totales de dinero del panel'),
    ('can_ver_ranking_servicios', 'Ver ranking de Servicios', 'Ver quién compra más dosis y agua del gym'),
  ];

  /// La tupla (clave, título, ayuda) de un permiso por
  /// su clave, para pintar los grupos sin re-recorrer.
  static final porClave = {
    for (final p in permisosDisponibles) p.$1: p,
  };
}

/// 1.29 (fijo de campo): clave de la meta con la foto
/// local de la nómina (la última lista buena que el
/// servidor devolvió). La pantalla la pinta al instante
/// al abrir y la refresca en segundo plano: la red deja
/// de ser la puerta del primer pintado.
const kMetaCachePermisos = 'panel_permisos_cache';

/// Serializa la nómina tal como se muestra (email =
/// identidad de la fila, activo y el mapa de permisos
/// ya resuelto) con su marca de frescura en hora Habana.
/// El nombre real y el telegram_id NO se duplican aquí:
/// viven en la meta usuarios_apk y se cruzan al pintar,
/// igual que con la lista del servidor.
String codificarCachePermisos(
    List<EntrenadorPermiso> lista, DateTime ahora) {
  return jsonEncode({
    'guardada_en': isoHabana(ahora),
    'filas': [
      for (final e in lista)
        {
          'email': e.email,
          'activo': e.activo,
          'permisos': e.permisos,
        },
    ],
  });
}

/// Decodifica la foto local a filas crudas (misma forma
/// que devuelve el servidor) para construir la lista con
/// el mismo constructor. null = no hay foto (meta ausente
/// o ilegible). Degradación fila a fila (patrón 1.28
/// M5-A5): una fila rara se salta, no tumba la foto.
List<Map<String, dynamic>>? decodificarCachePermisos(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  try {
    final dec = jsonDecode(raw);
    if (dec is! Map) return null;
    final filas = dec['filas'];
    if (filas is! List) return null;
    return [
      for (final f in filas)
        if (f is Map) Map<String, dynamic>.from(f),
    ];
  } catch (_) {
    return null;
  }
}

/// Construye la lista pintable desde las filas crudas
/// (del servidor o de la foto local: misma forma) y la
/// identidad local de usuarios_apk. PURO.
List<EntrenadorPermiso> construirListaPermisos(
  List<dynamic> filas,
  List<Map<String, dynamic>> usuarios,
) {
  final lista = filas.map((e) {
    final m = Map<String, dynamic>.from(e as Map);
    final email = m['email']?.toString() ?? '';
    final perms = m['permisos'];
    final map = <String, bool>{};
    if (perms is Map) {
      for (final k in EntrenadorPermiso.permisosDisponibles) {
        map[k.$1] = perms[k.$1] == true;
      }
    }
    // Nombre bonito del email
    final nombre = email.split('@').first;
    final nombreCap = nombre.isNotEmpty
        ? nombre[0].toUpperCase() + nombre.substring(1)
        : email;
    return EntrenadorPermiso(
      email: email,
      nombre: nombreCap,
      activo: m['activo'] == true,
      permisos: map,
    );
  }).toList();
  // 1.25 T101: el nombre REAL y el telegram_id salen
  // de usuarios_apk (por el username del correo); el
  // nombre fabricado del correo queda solo de
  // respaldo cuando la meta no lo resuelve.
  for (var i = 0; i < lista.length; i++) {
    final id = identidadPorEmail(lista[i].email, usuarios);
    if (id != null) {
      lista[i] = EntrenadorPermiso(
        email: lista[i].email,
        nombre: id.nombre,
        activo: lista[i].activo,
        permisos: lista[i].permisos,
        telegramId: id.telegramId,
      );
    }
  }
  return lista;
}

/// La lectura de la nómina en el servidor (la única
/// dependencia de red de la pantalla), aislada como
/// función para que el test la sustituya por
/// [leerNominaPermisosParaTest].
Future<List<dynamic>> _leerNominaServidor() async {
  // Autoauditoría 1.22 #2: lectura con timeout (12 s): sin
  // tope, una conexión colgada dejaba el panel en «cargando»
  // eterno (un cuelgue no es un error; el catch no corría).
  final res = await Supabase.instance.client
      .from('entrenadores_autorizados')
      .select('email, activo, permisos')
      .order('email')
      .timeout(const Duration(seconds: 12));
  return res as List<dynamic>;
}

/// Costura de test: si no es null, sustituye a la
/// lectura real de la nómina en el servidor.
@visibleForTesting
Future<List<dynamic>> Function()? leerNominaPermisosParaTest;

class PanelPermisos extends StatefulWidget {
  /// v1.4.0 Paso 2: [embebido] = true cuando vive dentro de la pestaña
  /// "Entrenadores" de Control de Acceso (sin Scaffold/AppBar propios).
  final bool embebido;
  const PanelPermisos({super.key, this.embebido = false});

  @override
  State<PanelPermisos> createState() => _PanelPermisosState();
}

class _PanelPermisosState extends State<PanelPermisos> {
  List<EntrenadorPermiso> _entrenadores = [];
  bool _cargando = true;
  // 1.29 (fijo de campo): el error de carga como estado
  // PROPIO, separado del vacío: un fallo de red ya no se
  // pinta como «No hay entrenadores registrados» (eso
  // solo se afirma con una lectura OK de cero filas).
  String? _errorCarga;

  // 1.29 (fijo de campo): generación del refresco en
  // curso: una respuesta que llega tras un refresco más
  // nuevo (o tras dispose) se descarta, no pisa.
  int _generacion = 0;
  // 1.25 T101: la foto viva del equipo (espejo local, sin
  // red): última sync por telegram_id, quién tiene el
  // turno abierto hoy y el pendiente a entregar. Si la
  // lectura local falla, quedan vacíos y la tarjeta
  // simplemente no pinta la fila (nada inventado).
  Map<int, String> _syncPorTid = {};
  Set<int> _enTurnoHoy = {};
  Map<int, double> _pendientePorTid = {};

  /// 1.15 (campo): entrenadores con la lista de permisos
  /// desplegada. Por defecto todo colapsado: la tarjeta muestra
  /// solo cabecera + ACTIVO y una fila «Permisos · N de 14»;
  /// los interruptores salen solo al tocar esa fila.
  final Set<String> _expandidos = {};

  /// v1.4.4 (panel de código): serializa las operaciones por
  /// entrenador. Sin esto, dos toques rápidos sobre el mismo
  /// entrenador se solapaban y la relectura/reversión de la operación
  /// vieja podía pisar el estado de la nueva.
  final Map<String, Future<void>> _colas = {};

  Future<void> _enSerie(
      String email, Future<void> Function() op) async {
    final anterior = _colas[email] ?? Future<void>.value();
    final actual = anterior.then((_) => op());
    _colas[email] = actual;
    try {
      await actual;
    } finally {
      if (identical(_colas[email], actual)) {
        _colas.remove(email);
      }
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_inicio());
  }

  @override
  void dispose() {
    // Una respuesta en vuelo tras dispose se descarta
    // por generación (y por mounted al aplicarla).
    _generacion++;
    super.dispose();
  }

  /// 1.29 (fijo de campo): arranque offline-first — la
  /// foto local pinta AL INSTANTE (sin spinner bloqueante
  /// ni espera de red) y el refresco va detrás, en
  /// segundo plano. Sin foto local, manda _cargar().
  Future<void> _inicio() async {
    // P-1: guarda de método (ver _cargar).
    if (!AuthService().isOwner) {
      if (mounted) setState(() => _cargando = false);
      return;
    }
    await _pintarFotoLocal();
    await _cargar();
  }

  /// Pinta la última nómina buena guardada en la meta
  /// local (si existe), cruzando la identidad con
  /// usuarios_apk en local. Tolerante: una foto ilegible
  /// equivale a no tener foto.
  Future<void> _pintarFotoLocal() async {
    final gen = _generacion;
    try {
      final raw =
          await LocalDb.instance.getMeta(kMetaCachePermisos);
      final filas = decodificarCachePermisos(raw);
      if (filas == null) return;
      final usuarios = await usuariosApk();
      // Si un refresco arrancó mientras leíamos (o la
      // pantalla murió), la foto ya no manda.
      if (!mounted || gen != _generacion) return;
      setState(() {
        _entrenadores = construirListaPermisos(filas, usuarios);
        _cargando = false;
      });
      unawaited(_cargarDatosVivos());
    } catch (_) {
      // Sin foto pintable: el refresco de red manda.
    }
  }

  Future<void> _cargar() async {
    // Autoauditoría 1.22 #2 (P-1): la guarda de dueño también
    // en el MÉTODO, no solo en build (defensa en profundidad:
    // el estándar de la casa en admin/control_acceso/ficha es
    // guardar en ambos sitios).
    if (!AuthService().isOwner) {
      setState(() => _cargando = false);
      return;
    }
    final gen = ++_generacion;
    if (mounted) {
      setState(() {
        _cargando = true;
        _errorCarga = null;
      });
    }
    try {
      // 1.28 (M5-A1/R2M5-H06): un refresco con guardados
      // en vuelo dejaba las relecturas y reversiones de
      // esos guardados escribiendo sobre los objetos que
      // la lista nueva acababa de sustituir: el cambio
      // «desaparecía» de la pantalla sin haber fallado.
      // Se drenan las colas por entrenador ANTES de
      // aplicar la lista nueva.
      if (_colas.isNotEmpty) {
        for (final f in _colas.values.toList()) {
          try {
            await f;
          } catch (_) {}
        }
      }
      // 1.29 (fijo de campo): la identidad local se lee
      // EN PARALELO con la lectura de red, no detrás de
      // su await: antes, un timeout de la lectura dejaba
      // también sin leer lo que ya estaba en el teléfono.
      final futuroUsuarios = usuariosApk();
      final res = await (leerNominaPermisosParaTest ??
          _leerNominaServidor)();
      final usuarios = await futuroUsuarios;
      // Guarda de generación: una respuesta vieja no
      // pisa a la del refresco más nuevo.
      if (!mounted || gen != _generacion) return;
      final lista = construirListaPermisos(res, usuarios);
      setState(() {
        _entrenadores = lista;
        _cargando = false;
        _errorCarga = null;
      });
      // La foto local se renueva con cada lista buena
      // (si el guardado falla, queda la anterior: la
      // pantalla ya pintó la verdad del servidor).
      try {
        await LocalDb.instance.setMeta(kMetaCachePermisos,
            codificarCachePermisos(lista, ahoraHabana()));
      } catch (_) {}
      unawaited(_cargarDatosVivos());
    } catch (e) {
      if (!mounted || gen != _generacion) return;
      setState(() => _cargando = false);
      if (_entrenadores.isNotEmpty) {
        // 1.29 (fijo de campo): con la lista ya pintada
        // (foto local o un refresco anterior), el fallo
        // se anuncia discreto y la lista QUEDA: jamás se
        // convierte en el falso vacío.
        mostrarSnack(context,
            'No se pudo actualizar. Se muestra la última lista guardada.',
            significado: SignificadoChip.alerta);
      } else {
        // Sin nada que mostrar: el error es el estado
        // (patrón de las pantallas hermanas), con vía de
        // reintento; nunca «No hay entrenadores».
        setState(() => _errorCarga =
            'Sin conexión. No se pudo cargar la lista.');
      }
    }
  }

  /// 1.25 T101: la foto viva del equipo desde el espejo
  /// local (sin red): última sync, turno abierto hoy y
  /// pendiente a entregar, por telegram_id. Tolerante:
  /// si algo falla, las tarjetas no pintan la fila.
  Future<void> _cargarDatosVivos() async {
    try {
      final filas = await ultimoSyncPorTelefono();
      final sync = <int, String>{};
      for (final f in filas) {
        final tid =
            LocalDb.normalizarTelegramId(f['telegram_user_id']);
        if (tid != null) {
          sync[tid] = etiquetaUltimoSync(f, ahoraHabana());
        }
      }
      final enTurno = await LocalDb.instance
          .telegramIdsConTurnoAbierto(hoyHabanaIso());
      final pend = await pendientePorEntrenador();
      final pendMap = <int, double>{
        for (final e in pend)
          if ((e['id'] as num?) != null)
            (e['id'] as num).toInt():
                (e['total'] as num?)?.toDouble() ?? 0,
      };
      if (!mounted) return;
      setState(() {
        _syncPorTid = sync;
        _enTurnoHoy = enTurno;
        _pendientePorTid = pendMap;
      });
    } catch (_) {
      // Sin fila viva: la pantalla de permisos sigue.
    }
  }

  /// 1.28 (M5-A1/R2M5-H06): la instancia de la lista que
  /// la pantalla está pintando para este entrenador (un
  /// refresco pudo sustituir los objetos: el que traiga
  /// un llamador viejo puede ser un huérfano invisible).
  EntrenadorPermiso _instanciaViva(EntrenadorPermiso ent) =>
      _entrenadores.where((e) => e.email == ent.email).firstOrNull ??
      ent;

  /// v1.4.4 (Permisos nivel 1): tras un guardado confirmado por el
  /// servidor, relee la fila real de ese entrenador y la pinta tal
  /// cual quedó. La palabra final la tiene el servidor, no la UI
  /// optimista: si algo difiere, la pantalla muestra la verdad.
  /// Devuelve true si la fila se releyó y se aplicó; false si la
  /// relectura falló (la RPC ya confirmó el guardado: el llamador
  /// conserva el estado optimista y avisa «sin verificar»).
  Future<bool> _releerEntrenador(EntrenadorPermiso ent) async {
    // P-1: guarda de método (ver _cargar).
    if (!AuthService().isOwner) return false;
    try {
      // Autoauditoría 1.22 #2: la RELECTURA con timeout (12 s):
      // es una lectura y su llamador ya sabe tratar el false
      // («guardado, pero no se pudo verificar»); sin tope, un
      // cuelgue dejaba la cadena serializada del entrenador
      // esperando para siempre tras un guardado ya confirmado.
      final res = await Supabase.instance.client
          .from('entrenadores_autorizados')
          .select('activo, permisos')
          .eq('email', ent.email)
          .single()
          .timeout(const Duration(seconds: 12));
      final m = Map<String, dynamic>.from(res as Map);
      final perms = m['permisos'];
      if (!mounted) return false;
      // 1.28 (M5-A1/R2M5-H06): la verdad se aplica sobre
      // la instancia VIGENTE de la lista (buscada por
      // email): si un refresco sustituyó la lista mientras
      // el guardado volaba, escribir sobre el objeto
      // huérfano que traía el llamador no pintaba nada.
      final vivo = _instanciaViva(ent);
      setState(() {
        vivo.activo = m['activo'] == true;
        // Reconstrucción completa (panel de código): una clave
        // ausente en la respuesta vale false (fail-closed), no se
        // conserva el valor anterior.
        for (final k in EntrenadorPermiso.permisosDisponibles) {
          vivo.permisos[k.$1] =
              perms is Map ? perms[k.$1] == true : false;
        }
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Optimistic UI (Argón): cambia visual al instante, revierte si falla.
  /// v1.4.4 (Permisos nivel 1): el éxito ya NO es silencioso — cada
  /// cambio confirmado muestra «✓ Permiso actualizado» y se relee la
  /// fila real del servidor.
  Future<void> _togglePermiso(
      EntrenadorPermiso ent, String key, bool valor) {
    // P-1: guarda de método (ver _cargar).
    if (!AuthService().isOwner) return Future.value();
    // Serializado por entrenador (panel de código): el estado
    // anterior se lee al ejecutar la operación, no al tocar.
    return _enSerie(ent.email, () async {
      // 1.28 (M5-A1/R2M5-H06): la operación trabaja sobre
      // la instancia VIGENTE de la lista: un refresco
      // pudo sustituir los objetos mientras esta op
      // esperaba su turno en la cola.
      final vivo = _instanciaViva(ent);
      final anterior = vivo.permisos[key] ?? false;
      if (mounted) setState(() => vivo.permisos[key] = valor);
      try {
        await Supabase.instance.client
            .rpc(
              'actualizar_permiso_entrenador',
              params: {
                'p_email': vivo.email,
                'p_permiso_key': key,
                'p_valor': valor,
              },
            )
            // 1.24 Bloque 4: timeout de escritura (12 s).
            .timeout(const Duration(seconds: 12));
        final verificado = await _releerEntrenador(vivo);
        if (mounted) {
          mostrarSnack(
              context,
              verificado
                  ? 'Permiso actualizado'
                  : 'Guardado, pero no se pudo verificar el estado',
              significado: verificado
                  ? SignificadoChip.exito
                  : SignificadoChip.alerta,
              duracion: const Duration(seconds: 2));
        }
      } catch (e) {
        // 1.28 (M5-A1/R1M5-H3): un TIMEOUT no es un «no
        // llegó»: la RPC pudo aplicar el cambio y perder
        // la respuesta. Antes de revertir y anunciar
        // «Cambio revertido», se relee la fila real: si
        // ya trae el valor nuevo, se anuncia aplicado;
        // si la fila trae el anterior, el cambio no
        // llegó; y si ni releer se puede, se dice que no
        // se pudo confirmar (sin afirmar ni lo uno ni
        // lo otro).
        if (e is TimeoutException) {
          final verificado = await _releerEntrenador(vivo);
          if (!mounted) return;
          if (verificado) {
            final aplicado = vivo.permisos[key] == valor;
            mostrarSnack(
                context,
                aplicado
                    ? 'Permiso actualizado'
                    : 'El cambio no llegó al servidor.',
                significado: aplicado
                    ? SignificadoChip.exito
                    : SignificadoChip.alerta);
          } else {
            setState(() => vivo.permisos[key] = anterior);
            mostrarSnack(
                context,
                'No se pudo confirmar si el cambio se '
                'aplicó. Revisa el estado al refrescar.',
                significado: SignificadoChip.error);
          }
          return;
        }
        // Revertir
        if (mounted) {
          setState(() => vivo.permisos[key] = anterior);
          mostrarSnack(context, 'Sin conexión. Cambio revertido.',
              significado: SignificadoChip.error);
        }
      }
    });
  }

  Future<void> _toggleActivo(EntrenadorPermiso ent) async {
    // P-1: guarda de método (ver _cargar).
    if (!AuthService().isOwner) return;
    if (ent.activo) {
      // Suspender requiere confirmación (Argón)
      final confirmar = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Suspender acceso'),
          content: Text(
            '¿Suspender el acceso de ${ent.nombre}? No podrá usar la app.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(
                  foregroundColor: AppColores.error),
              child: const Text('Suspender'),
            ),
          ],
        ),
      );
      if (confirmar != true) return;
    }
    final objetivo = !ent.activo;
    // Serializado por entrenador (panel de código). Si una operación
    // anterior ya dejó la cuenta en el estado objetivo (doble toque),
    // no se repite la RPC.
    return _enSerie(ent.email, () async {
      // 1.28 (M5-A1/R2M5-H06): instancia vigente de la
      // lista, como en _togglePermiso.
      final vivo = _instanciaViva(ent);
      if (vivo.activo == objetivo) return;
      final nuevo = objetivo;
      if (mounted) setState(() => vivo.activo = nuevo);
      try {
        await Supabase.instance.client
            .rpc(
              'suspender_entrenador',
              params: {'p_email': vivo.email, 'p_activo': nuevo},
            )
            // 1.24 Bloque 4: timeout de escritura (12 s).
            .timeout(const Duration(seconds: 12));
        // v1.4.4 (Permisos nivel 1): confirmación visible en AMBOS
        // sentidos + relectura de la fila real.
        final verificado = await _releerEntrenador(vivo);
        if (mounted) {
          mostrarSnack(
              context,
              verificado
                  ? (nuevo
                      ? '${vivo.nombre} reactivado'
                      : 'Acceso de ${vivo.nombre} suspendido')
                  : 'Guardado, pero no se pudo verificar el estado',
              significado: verificado
                  ? SignificadoChip.exito
                  : SignificadoChip.alerta,
              duracion: const Duration(seconds: 2));
        }
      } catch (e) {
        // 1.28 (M5-A1/R1M5-H3): timeout honesto, como en
        // _togglePermiso: releer antes de anunciar nada.
        if (e is TimeoutException) {
          final verificado = await _releerEntrenador(vivo);
          if (!mounted) return;
          if (verificado) {
            final aplicado = vivo.activo == nuevo;
            mostrarSnack(
                context,
                aplicado
                    ? (nuevo
                        ? '${vivo.nombre} reactivado'
                        : 'Acceso de ${vivo.nombre} suspendido')
                    : 'El cambio no llegó al servidor.',
                significado: aplicado
                    ? SignificadoChip.exito
                    : SignificadoChip.alerta);
          } else {
            setState(() => vivo.activo = !nuevo);
            mostrarSnack(
                context,
                'No se pudo confirmar si el cambio se '
                'aplicó. Revisa el estado al refrescar.',
                significado: SignificadoChip.error);
          }
          return;
        }
        if (mounted) {
          setState(() => vivo.activo = !nuevo);
          mostrarSnack(context, 'Sin conexión. Cambio revertido.',
              significado: SignificadoChip.error);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Solo dueño (Argón: estándar AuthService().isOwner)
    if (!AuthService().isOwner) {
      const denegado =
          Center(child: Text('Solo el dueño puede gestionar permisos.'));
      if (widget.embebido) return denegado;
      return Scaffold(
        appBar: appBarIron(context, 'Permisos'),
        body: denegado,
      );
    }

    // 1.29 (fijo de campo): el spinner solo bloquea
    // cuando no hay NADA pintado; con la lista en
    // pantalla, un refresco en curso no la tapa. Y el
    // vacío solo se afirma sin error de carga detrás:
    // error sin datos = estado de error con reintento.
    final contenido = _cargando && _entrenadores.isEmpty
        ? const EstadoCargando(texto: 'Cargando permisos…')
        : _errorCarga != null && _entrenadores.isEmpty
            ? _estadoErrorCarga()
            : _entrenadores.isEmpty
                // 1.35 (UI-10): vacío de la casa, no una
                // frase suelta centrada.
                ? const EstadoVacio(
                    icono: Icons.badge_rounded,
                    titulo: 'No hay entrenadores registrados',
                    subtitulo:
                        'Los entrenadores se dan de alta desde '
                        'Control de Acceso.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    itemCount: _entrenadores.length,
                    itemBuilder: (ctx, i) =>
                        _buildEntrenadorCard(_entrenadores[i]),
                  );

    if (widget.embebido) return contenido;

    return Scaffold(
      appBar: appBarIron(
        context,
        'Permisos de Entrenadores',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            // (1.36 H-B4 136-891) tooltip del refresco.
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: contenido,
    );
  }

  /// 1.29 (fijo de campo): el estado de error de la
  /// carga (patrón de Control de Acceso): mensaje +
  /// «Reintentar». Solo se pinta cuando no hay NADA que
  /// mostrar: con lista pintada, el fallo va por SnackBar
  /// y la lista queda.
  Widget _estadoErrorCarga() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_errorCarga!,
                style: AppTexto.secundario,
                textAlign: TextAlign.center),
            const SizedBox(height: AppEspacio.md),
            FilledButton.icon(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Reintentar'),
              onPressed: _cargar,
            ),
          ],
        ),
      ),
    );
  }

  /// 1.25 T101: un dato vivo de la tarjeta (icono +
  /// texto corto), en la fila Wrap del entrenador.
  Widget _datoVivo(IconData icono, String texto) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icono,
            size: 14, color: AppColores.textoSecundario(context)),
        const SizedBox(width: 4),
        Text(texto, style: AppTexto.metadato),
      ],
    );
  }

  Widget _buildEntrenadorCard(EntrenadorPermiso ent) {
    // 1.15 (campo): colapsado por defecto; el conteo se lee sin abrir.
    final expandido = _expandidos.contains(ent.email);
    final activos =
        ent.permisos.values.where((v) => v).length;
    return Card(
      margin: const EdgeInsets.only(bottom: AppEspacio.lg),
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  child: Text(ent.nombre.isNotEmpty
                      ? ent.nombre[0].toUpperCase()
                      : '?'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(
                        ent.nombre,
                        style: AppTexto.titulo,
                      ),
                      Text(
                        ent.email,
                        style: AppTexto.metadato.copyWith(
                            color: AppColores.textoSecundario(context)),
                      ),
                    ],
                  ),
                ),
                // Toggle maestro ACTIVO
                Column(
                  children: [
                    // SL-9 (G09-14): el estado va en el chip de
                    // la casa y con sus tokens, no en un texto
                    // con colores crudos a pelo.
                    ChipEstado.semantico(
                      texto: ent.activo ? 'ACTIVO' : 'SUSPENDIDO',
                      significado: ent.activo
                          ? SignificadoChip.exito
                          : SignificadoChip.error,
                    ),
                    // (1.36 H-B4 136-891) el interruptor
                    // maestro se anuncia y se explica.
                    Semantics(
                      label: 'Entrenador activo',
                      toggled: ent.activo,
                      child: Tooltip(
                        message: ent.activo
                            ? 'Suspender al entrenador'
                            : 'Activar al entrenador',
                        child: Switch(
                          value: ent.activo,
                          activeColor: AppColores.exito,
                          onChanged: (_) => _toggleActivo(ent),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            // 1.25 T101: la fila viva del entrenador —
            // turno de hoy, última sync y pendiente a
            // entregar, solo si la foto local cargó.
            // 1.36 H-B3 (136-856): basta CUALQUIER dato vivo
            // (turno o pendiente también cuentan) — antes la
            // fila entera se condicionaba al mapa de sync y
            // un entrenador con turno/pendiente pero sin
            // sync no enseñaba nada; su «Sin registro de
            // sync» queda como valor parcial de la fila.
            if (ent.telegramId != null &&
                (_syncPorTid.isNotEmpty ||
                    _enTurnoHoy.isNotEmpty ||
                    _pendientePorTid.isNotEmpty))
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.sm),
                child: Wrap(
                  spacing: AppEspacio.md,
                  runSpacing: AppEspacio.xs,
                  children: [
                    _datoVivo(
                      Icons.schedule_rounded,
                      _enTurnoHoy.contains(ent.telegramId)
                          ? 'Turno abierto hoy'
                          : 'Sin turno abierto hoy',
                    ),
                    _datoVivo(
                      Icons.sync_rounded,
                      _syncPorTid[ent.telegramId] ??
                          'Sin registro de sync',
                    ),
                    if ((_pendientePorTid[ent.telegramId] ?? 0) > 0)
                      _datoVivo(
                        Icons.payments_rounded,
                        'Pendiente a entregar: '
                        '\$${fmtMonto(_pendientePorTid[ent.telegramId]!)}',
                      ),
                  ],
                ),
              ),
            const Divider(),
            InkWell(
              onTap: () => setState(() {
                if (expandido) {
                  _expandidos.remove(ent.email);
                } else {
                  _expandidos.add(ent.email);
                }
              }),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Permisos · $activos de '
                        '${EntrenadorPermiso.permisosDisponibles.length} activos',
                        style: AppTexto.cuerpo.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Icon(
                      expandido
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                  ],
                ),
              ),
            ),
            // 1.25 T101: los permisos agrupados por lo
            // que gobiernan, con la ayuda de cada grupo.
            if (expandido)
              for (final g in EntrenadorPermiso.gruposPermisos) ...[
                Padding(
                  padding:
                      const EdgeInsets.only(top: AppEspacio.md),
                  child: Text(g.$1,
                      style: AppTexto.cuerpo
                          .copyWith(fontWeight: FontWeight.w700)),
                ),
                Text(g.$2, style: AppTexto.secundario),
                // (1.36 H-B4 136-891) por qué están apagados.
                if (!ent.activo)
                  Padding(
                    padding:
                        const EdgeInsets.only(top: AppEspacio.sm),
                    child: Text(
                      'Entrenador suspendido: activa el interruptor '
                      'de arriba para cambiar sus permisos.',
                      style: AppTexto.metadato.copyWith(
                          color: AppColores.alertaTexto(context)),
                    ),
                  ),
                for (final p in [
                  for (final clave in g.$3)
                    if (EntrenadorPermiso.porClave[clave] != null)
                      EntrenadorPermiso.porClave[clave]!,
                ])
                    SwitchListTile(
                      title: Text(p.$2,
                          style: AppTexto.cuerpo),
                      subtitle: Text(p.$3,
                          style: AppTexto.metadato),
                      value: ent.permisos[p.$1] ?? false,
                      onChanged: ent.activo
                          ? (v) => _togglePermiso(ent, p.$1, v)
                          : null,
                      dense: true,
                    ),
              ],
          ],
        ),
      ),
    );
  }
}
