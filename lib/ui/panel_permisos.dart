// lib/ui/panel_permisos.dart
// v1.3.9 Sprint 1 (#14): panel de permisos para entrenadores.
// Solo el dueño (Jc) puede acceder.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../auth.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

class EntrenadorPermiso {
  final String email;
  final String nombre;
  bool activo;
  Map<String, bool> permisos;

  EntrenadorPermiso({
    required this.email,
    required this.nombre,
    required this.activo,
    required this.permisos,
  });

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
}

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
    _cargar();
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
    setState(() => _cargando = true);
    try {
      // Autoauditoría 1.22 #2: lectura con timeout (12 s): sin
      // tope, una conexión colgada dejaba el panel en «cargando»
      // eterno (un cuelgue no es un error; el catch no corría).
      final res = await Supabase.instance.client
          .from('entrenadores_autorizados')
          .select('email, activo, permisos')
          .order('email')
          .timeout(const Duration(seconds: 12));
      final lista = (res as List).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        final email = m['email']?.toString() ?? '';
        final perms = m['permisos'];
        final map = <String, bool>{};
        if (perms is Map) {
          for (final k in EntrenadorPermiso.permisosDisponibles) {
            map[k.$1] = (perms as Map)[k.$1] == true;
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
      if (mounted) {
        setState(() {
          _entrenadores = lista;
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cargando = false);
        mostrarSnack(context, 'Error al cargar: $e', significado: SignificadoChip.error);
      }
    }
  }

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
      setState(() {
        ent.activo = m['activo'] == true;
        // Reconstrucción completa (panel de código): una clave
        // ausente en la respuesta vale false (fail-closed), no se
        // conserva el valor anterior.
        for (final k in EntrenadorPermiso.permisosDisponibles) {
          ent.permisos[k.$1] = perms is Map ? perms[k.$1] == true : false;
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
      final anterior = ent.permisos[key] ?? false;
      if (mounted) setState(() => ent.permisos[key] = valor);
      try {
        await Supabase.instance.client.rpc(
          'actualizar_permiso_entrenador',
          params: {
            'p_email': ent.email,
            'p_permiso_key': key,
            'p_valor': valor,
          },
        );
        final verificado = await _releerEntrenador(ent);
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
        // Revertir
        if (mounted) {
          setState(() => ent.permisos[key] = anterior);
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
              child: const Text('CANCELAR'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(
                  foregroundColor: Colors.red),
              child: const Text('SUSPENDER'),
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
      if (ent.activo == objetivo) return;
      final nuevo = objetivo;
      if (mounted) setState(() => ent.activo = nuevo);
      try {
        await Supabase.instance.client.rpc(
          'suspender_entrenador',
          params: {'p_email': ent.email, 'p_activo': nuevo},
        );
        // v1.4.4 (Permisos nivel 1): confirmación visible en AMBOS
        // sentidos + relectura de la fila real.
        final verificado = await _releerEntrenador(ent);
        if (mounted) {
          mostrarSnack(
              context,
              verificado
                  ? (nuevo
                      ? '${ent.nombre} reactivado'
                      : 'Acceso de ${ent.nombre} suspendido')
                  : 'Guardado, pero no se pudo verificar el estado',
              significado: verificado
                  ? SignificadoChip.exito
                  : SignificadoChip.alerta,
              duracion: const Duration(seconds: 2));
        }
      } catch (e) {
        if (mounted) {
          setState(() => ent.activo = !nuevo);
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

    final contenido = _cargando
        ? const EstadoCargando(texto: 'Cargando permisos…')
        : _entrenadores.isEmpty
            ? const Center(
                child: Text('No hay entrenadores registrados.'))
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
            onPressed: _cargar,
          ),
        ],
      ),
      body: contenido,
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
                        style: AppTexto.metadato.copyWith(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
                // Toggle maestro ACTIVO
                Column(
                  children: [
                    Text(
                      ent.activo ? 'ACTIVO' : 'SUSPENDIDO',
                      style: AppTexto.minuscula.copyWith(color: ent.activo
                            ? Colors.green
                            : Colors.red, fontWeight: FontWeight.bold),
                    ),
                    Switch(
                      value: ent.activo,
                      activeColor: Colors.green,
                      onChanged: (_) => _toggleActivo(ent),
                    ),
                  ],
                ),
              ],
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
            if (expandido)
              ...EntrenadorPermiso.permisosDisponibles.map(
                (p) => SwitchListTile(
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
              ),
          ],
        ),
      ),
    );
  }
}
