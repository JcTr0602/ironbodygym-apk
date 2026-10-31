// lib/ui/ficha_acceso.dart
// v1.4.0 Paso 2 (Control de Acceso, propuesta 32): ficha completa del
// acceso de un cliente a la app: datos, historial de ingresos,
// auditoría y acciones de seguridad.
// Regla de Argón: el PIN actual NUNCA se ve; "reenviar credenciales"
// genera un PIN temporal nuevo (resetear_pin_cliente) y lo comparte.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../acceso_app_cache.dart';
import '../auth.dart';
import '../negocio.dart' show tiempoRelativo;
import 'acciones_acceso.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'foto_personal_ficha.dart';
import 'componentes.dart';

class FichaAccesoScreen extends StatefulWidget {
  final int clienteId;
  const FichaAccesoScreen({super.key, required this.clienteId});

  @override
  State<FichaAccesoScreen> createState() => _FichaAccesoScreenState();
}

class _FichaAccesoScreenState extends State<FichaAccesoScreen> {
  bool _cargando = true;
  bool _ocupado = false;
  Map<String, dynamic>? _acceso;
  List<dynamic> _historial = [];
  List<dynamic> _auditoria = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  String _fmtFecha(dynamic v) {
    if (v == null) return '—';
    final dt = DateTime.tryParse('$v')?.toLocal();
    if (dt == null) return '—';
    String d2(int n) => n.toString().padLeft(2, '0');
    return '${d2(dt.day)}/${d2(dt.month)}/${dt.year} ${d2(dt.hour)}:${d2(dt.minute)}';
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'detalle_acceso_cliente',
        params: {'p_cliente_id': widget.clienteId},
      );
      final data = Map<String, dynamic>.from(res as Map);
      if (mounted) {
        setState(() {
          _acceso = Map<String, dynamic>.from(data['acceso'] as Map);
          _historial = (data['historial'] as List?) ?? [];
          _auditoria = (data['auditoria'] as List?) ?? [];
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cargando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al cargar la ficha: $e')),
        );
      }
    }
  }

  Future<void> _refrescarTodo() async {
    await AccesoAppCache.instance.cargar();
    await _cargar();
  }

  /// v1.4.1 (Pieza 2): las acciones viven en el helper compartido
  /// acciones_acceso.dart (las usa también el menú ⋮ de la lista).
  /// Este envoltorio conserva el indicador de ocupado de la ficha.
  Future<void> _conOcupado(Future<void> Function() accion) async {
    if (!mounted) return;
    setState(() => _ocupado = true);
    try {
      await accion();
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final nombre = '${_acceso?['nombre'] ?? 'Acceso del cliente'}';
    return Scaffold(
      appBar: AppBar(
        title: Text(nombre, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargando ? null : _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando acceso…')
          : _acceso == null
              ? const Center(child: Text('No se pudo cargar la ficha.'))
              : ListView(
                  padding: const EdgeInsets.all(AppEspacio.lg),
                  children: [
                    _seccionDatos(),
                    // Ítem 12: foto personal del cliente — SOLO el
                    // dueño: con otro rol el widget ni se construye.
                    if (AuthService().isOwner) ...[
                      const SizedBox(height: AppEspacio.lg),
                      SeccionFotoPersonal(clienteId: widget.clienteId),
                    ],
                    const SizedBox(height: AppEspacio.lg),
                    _seccionAcciones(),
                    const SizedBox(height: AppEspacio.lg),
                    _seccionHistorial(),
                    const SizedBox(height: AppEspacio.lg),
                    _seccionAuditoria(),
                  ],
                ),
    );
  }

  Widget _dato(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(etiqueta, style: AppTexto.secundario),
          ),
          Expanded(child: Text(valor, style: AppTexto.cuerpo)),
        ],
      ),
    );
  }

  Widget _seccionDatos() {
    final a = _acceso!;
    final estado = a['revocado'] == true || a['activo'] != true
        ? 'Revocado'
        : a['esta_bloqueado'] == true
            ? 'Bloqueado'
            : 'Activo';
    final colorEstado = estado == 'Activo'
        ? AppColores.exitoOscuro
        : estado == 'Bloqueado'
            ? AppColores.alertaOscuro
            : Colors.grey;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Datos del acceso',
                    style: AppTexto.subtitulo),
                const Spacer(),
                Chip(
                  label: Text(estado,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12)),
                  backgroundColor: colorEstado,
                ),
              ],
            ),
            _dato('Teléfono', '${a['telefono'] ?? '—'}'),
            _dato('Último acceso',
                '${tiempoRelativo(a['ultimo_acceso_en']?.toString())} (${_fmtFecha(a['ultimo_acceso_en'])})'),
            _dato('Total de accesos', '${a['total_accesos'] ?? 0}'),
            _dato('Dispositivo', '${a['ultimo_dispositivo'] ?? '—'}'),
            _dato('Versión de la app', '${a['ultima_app_version'] ?? '—'}'),
            _dato('Acceso creado',
                '${_fmtFecha(a['created_at'])} · por ${a['creado_por'] ?? '—'}'),
            _dato('PIN cambiado', _fmtFecha(a['pin_cambiado_en'])),
            _dato('PIN temporal sin cambiar',
                a['debe_cambiar_pin'] == true ? 'SÍ' : 'No'),
            _dato('Cambio de PIN forzado',
                a['forzar_cambio_pin'] == true ? 'SÍ' : 'No'),
            _dato('Intentos fallidos',
                '${a['intentos_fallidos'] ?? 0} · último: ${_fmtFecha(a['ultimo_intento_fallido_en'])}'),
            if (a['motivo_bloqueo'] != null)
              _dato('Motivo de bloqueo', '${a['motivo_bloqueo']}'),
            if (a['bloqueado_hasta'] != null)
              _dato('Bloqueado hasta', _fmtFecha(a['bloqueado_hasta'])),
            if (a['revocado_en'] != null)
              _dato('Revocado el', _fmtFecha(a['revocado_en'])),
            _dato('Sesión abierta', a['tiene_sesion'] == true
                ? 'Sí · vence ${_fmtFecha(a['sesion_expira_en'])}'
                : 'No'),
            _dato('Versión de sesión', '${a['token_version'] ?? 1}'),
            const SizedBox(height: AppEspacio.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.person, size: 18),
              label: const Text('Abrir ficha del cliente'),
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        FichaScreen(clienteId: widget.clienteId),
                  ),
                );
                if (mounted) _refrescarTodo();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _seccionAcciones() {
    final a = _acceso!;
    final revocado = a['revocado'] == true || a['activo'] != true;
    final bloqueado = a['esta_bloqueado'] == true;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Acciones', style: AppTexto.subtitulo),
            const SizedBox(height: AppEspacio.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.pin, size: 18),
                  label: const Text('Resetear PIN'),
                  onPressed: _ocupado || revocado
                      ? null
                      : () => _conOcupado(() => resetearPinAcceso(context,
                            clienteId: widget.clienteId,
                            nombre: '${a['nombre'] ?? 'el cliente'}',
                            telefono: '${a['telefono'] ?? ''}',
                            esReenvio: false,
                            alTerminar: _refrescarTodo)),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.chat, size: 18),
                  label: const Text('Reenviar credenciales'),
                  onPressed: _ocupado || revocado
                      ? null
                      : () => _conOcupado(() => resetearPinAcceso(context,
                            clienteId: widget.clienteId,
                            nombre: '${a['nombre'] ?? 'el cliente'}',
                            telefono: '${a['telefono'] ?? ''}',
                            esReenvio: true,
                            alTerminar: _refrescarTodo)),
                ),
                if (!revocado && !bloqueado)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.lock, size: 18),
                    label: const Text('Bloquear'),
                    onPressed: _ocupado
                        ? null
                        : () => _conOcupado(() => bloquearAcceso(context,
                            clienteId: widget.clienteId,
                            alTerminar: _refrescarTodo)),
                  ),
                if (!revocado && bloqueado)
                  FilledButton.icon(
                    icon: const Icon(Icons.lock_open, size: 18),
                    label: const Text('Desbloquear'),
                    onPressed: _ocupado
                        ? null
                        : () => _conOcupado(() => accionSimpleAcceso(
                              context,
                              clienteId: widget.clienteId,
                              rpc: 'desbloquear_acceso_cliente',
                              mensajeOk: 'Acceso desbloqueado.',
                              alTerminar: _refrescarTodo,
                            )),
                  ),
                if (!revocado)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.key, size: 18),
                    label: const Text('Forzar cambio de PIN'),
                    onPressed: _ocupado
                        ? null
                        : () => _conOcupado(() => accionSimpleAcceso(
                              context,
                              clienteId: widget.clienteId,
                              rpc: 'forzar_cambio_pin_cliente',
                              mensajeOk:
                                  'En su próximo ingreso deberá cambiar el PIN.',
                              confirmarAntes: true,
                              titulo: 'Forzar cambio de PIN',
                              texto:
                                  'En el próximo ingreso se le pedirá cambiar el PIN antes de entrar.',
                              alTerminar: _refrescarTodo,
                            )),
                  ),
                if (!revocado)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('Cerrar sesión remota'),
                    onPressed: _ocupado
                        ? null
                        : () => _conOcupado(() => accionSimpleAcceso(
                              context,
                              clienteId: widget.clienteId,
                              rpc: 'cerrar_sesion_cliente',
                              mensajeOk:
                                  'Sesión cerrada. Deberá entrar de nuevo.',
                              confirmarAntes: true,
                              titulo: 'Cerrar sesión remota',
                              texto:
                                  'Su sesión actual dejará de funcionar al instante.',
                              alTerminar: _refrescarTodo,
                            )),
                  ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.phone, size: 18),
                  label: const Text('Cambiar teléfono'),
                  onPressed: _ocupado || revocado
                        ? null
                        : () => _conOcupado(() => cambiarTelefonoAcceso(
                            context,
                            clienteId: widget.clienteId,
                            telefonoActual: '${a['telefono'] ?? ''}',
                            alTerminar: _refrescarTodo)),
                ),
                if (!revocado)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.block, size: 18),
                    label: const Text('Revocar acceso'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppColores.error),
                    onPressed: _ocupado
                        ? null
                        : () => _conOcupado(() => accionSimpleAcceso(
                              context,
                              clienteId: widget.clienteId,
                              rpc: 'revocar_acceso_cliente',
                              mensajeOk: 'Acceso revocado.',
                              confirmarAntes: true,
                              titulo: 'Revocar acceso',
                              texto:
                                  'El cliente ya no podrá entrar a la app. Puedes reactivarlo cuando quieras.',
                              alTerminar: _refrescarTodo,
                            )),
                  ),
                if (revocado)
                  FilledButton.icon(
                    icon: const Icon(Icons.restore, size: 18),
                    label: const Text('Reactivar acceso'),
                    onPressed: _ocupado
                        ? null
                        : () => _conOcupado(() => accionSimpleAcceso(
                              context,
                              clienteId: widget.clienteId,
                              rpc: 'reactivar_acceso_cliente',
                              mensajeOk: 'Acceso reactivado.',
                              alTerminar: _refrescarTodo,
                            )),
                  ),
              ],
            ),
            if (_ocupado)
              const Padding(
                padding: EdgeInsets.only(top: AppEspacio.md),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _seccionHistorial() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Historial de ingresos (últimos 20)',
                style: AppTexto.subtitulo),
            const SizedBox(height: AppEspacio.sm),
            if (_historial.isEmpty)
              const Text('Sin ingresos registrados todavía.',
                  style: AppTexto.secundario),
            for (final h in _historial)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.login, size: 18),
                title: Text(_fmtFecha((h as Map)['ingresado_en'])),
                subtitle: Text(
                  [
                    if (h['dispositivo'] != null) '${h['dispositivo']}',
                    if (h['app_version'] != null) 'v${h['app_version']}',
                  ].join(' · '),
                  style: AppTexto.secundario,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _seccionAuditoria() {
    const nombres = {
      'resetear_pin': 'PIN reseteado',
      'bloquear': 'Bloqueo',
      'desbloquear': 'Desbloqueo',
      'revocar': 'Acceso revocado',
      'reactivar': 'Acceso reactivado',
      'forzar_cambio_pin': 'Cambio de PIN forzado',
      'cerrar_sesion': 'Sesión cerrada',
      'cambiar_telefono': 'Teléfono cambiado',
      'generar_acceso': 'Acceso generado',
      'auto_activacion': 'Auto-activación del cliente',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Auditoría de este acceso',
                style: AppTexto.subtitulo),
            const SizedBox(height: AppEspacio.sm),
            if (_auditoria.isEmpty)
              const Text('Sin acciones registradas.',
                  style: AppTexto.secundario),
            for (final u in _auditoria)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.history, size: 18),
                title: Text(nombres['${(u as Map)['accion']}'] ??
                    '${u['accion']}'),
                subtitle: Text(
                  '${u['actor'] ?? 'sistema'} · ${_fmtFecha(u['creado_en'])}',
                  style: AppTexto.secundario,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
