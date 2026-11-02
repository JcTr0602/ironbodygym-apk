import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

/// 1.21 — Panel del candado de acceso (solo dueño).
///
/// Pone y quita pausas de acceso: global, por app, por rol o
/// por persona. Cada cambio viaja como op `acceso_bloqueo_set`
/// (SOLO_ADMIN en el servidor) y el estado baja a todos los
/// teléfonos por el espejo `acceso_bloqueos`. Quitar un candado
/// es una baja lógica (activo=0): el historial queda en el
/// servidor. La sesión de nadie se cierra: al reactivar, cada
/// quien continúa donde estaba y sus ops retenidas salen solas.
class PanelCandadoScreen extends StatefulWidget {
  const PanelCandadoScreen({super.key});

  @override
  State<PanelCandadoScreen> createState() => _PanelCandadoScreenState();
}

class _PanelCandadoScreenState extends State<PanelCandadoScreen> {
  final _db = LocalDb.instance;
  bool _cargando = true;
  bool _guardando = false;
  List<Map<String, dynamic>> _activos = [];
  List<({String tid, String nombre})> _entrenadores = [];
  final Map<String, String> _nombresPersonas = {};

  String _alcance = 'global';
  String _app = 'ambas';
  String _rol = 'entrenador';
  String _personaTipo = 'entrenador';
  String? _personaTid;
  final _clienteIdCtrl = TextEditingController();
  final _mensajeCtrl = TextEditingController();
  int _horasCaducidad = 0;
  String _nombreClienteId = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _clienteIdCtrl.dispose();
    _mensajeCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    if (mounted) setState(() => _cargando = true);
    try {
      final filas = await _db.allMirror('acceso_bloqueos');
      final activos = filas
          .where((f) => f['activo'] == 1 || f['activo'] == true)
          .toList()
        ..sort((a, b) => '${b['creada_ts'] ?? ''}'
            .compareTo('${a['creada_ts'] ?? ''}'));
      // Nombres de entrenadores (meta usuarios_apk, sin el dueño).
      final entrenadores = <({String tid, String nombre})>[];
      _nombresPersonas.clear();
      try {
        final raw = await _db.getMeta('usuarios_apk');
        if (raw != null && raw.isNotEmpty) {
          for (final u in jsonDecode(raw) as List) {
            final m = Map<String, dynamic>.from(u as Map);
            final tid = '${m['telegram_id'] ?? ''}';
            // Argón Acceso #11: el dueño se excluye por SU
            // telegram id de sesión, no por un id escrito a mano.
            if (tid.isEmpty ||
                tid == '${AuthService().telegramId}') {
              continue;
            }
            final nombre = '${m['nombre'] ?? m['username'] ?? tid}';
            entrenadores.add((tid: tid, nombre: nombre));
            _nombresPersonas[tid] = nombre;
          }
        }
      } catch (_) {}
      // Nombres de clientes para resolver objetivos por id.
      try {
        for (final c in await _db.allMirror('clientes')) {
          final id = '${c['id'] ?? ''}';
          if (id.isNotEmpty) {
            _nombresPersonas[id] = '${c['nombre'] ?? id}';
          }
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _activos = activos;
        _entrenadores = entrenadores;
        _cargando = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  String _tituloFila(Map<String, dynamic> f) {
    final objetivo = f['objetivo']?.toString();
    switch ('${f['alcance'] ?? ''}') {
      case 'global':
        return 'Todos · ambas apps';
      case 'app':
        return 'App: ${f['app'] == 'gestion' ? 'Gestión' : 'Clientes'}';
      case 'rol':
        return 'Rol: ${objetivo ?? ''}';
      case 'persona':
        final nombre = objetivo == null
            ? null
            : (_nombresPersonas[objetivo] ?? objetivo);
        return 'Persona: $nombre';
      default:
        return '${f['alcance'] ?? ''}';
    }
  }

  String _detalleFila(Map<String, dynamic> f) {
    final partes = <String>[];
    final mensaje = '${f['mensaje'] ?? ''}'.trim();
    if (mensaje.isNotEmpty) partes.add('«$mensaje»');
    final expira = DateTime.tryParse('${f['expira_ts'] ?? ''}');
    if (expira != null) {
      final h = aHabana(expira);
      partes.add('caduca el ${h.day.toString().padLeft(2, '0')}/'
          '${h.month.toString().padLeft(2, '0')} '
          '${h.hour.toString().padLeft(2, '0')}:'
          '${h.minute.toString().padLeft(2, '0')}');
    } else {
      partes.add('sin caducidad');
    }
    return partes.join(' · ');
  }

  Future<void> _enviarOp(Map<String, dynamic> payload) async {
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'acceso_bloqueo_set',
      payload: payload,
    );
    try {
      await SyncEngine.instance.push();
    } catch (_) {}
  }

  Future<void> _crear() async {
    String? objetivo;
    if (_alcance == 'rol') {
      objetivo = _rol;
    } else if (_alcance == 'persona') {
      objetivo = _personaTipo == 'entrenador'
          ? _personaTid
          : _clienteIdCtrl.text.trim();
      if (objetivo == null || objetivo.isEmpty) {
        mostrarSnack(context, 'Elige la persona del candado.',
            significado: SignificadoChip.alerta);
        return;
      }
    }
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Aplicar candado',
      mensaje: 'Se pausará el acceso según el alcance elegido. '
          'Nadie pierde su sesión ni su trabajo pendiente: al '
          'quitar el candado, todo continúa.',
      aceptar: 'Aplicar',
      icono: Icons.lock_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _guardando = true);
    try {
      final mensaje = _mensajeCtrl.text.trim();
      await _enviarOp({
        'id': const Uuid().v4(),
        'alcance': _alcance,
        'app': _alcance == 'global' ? 'ambas' : _app,
        if (objetivo != null) 'objetivo': objetivo,
        if (mensaje.isNotEmpty) 'mensaje': mensaje,
        'activo': 1,
        if (_horasCaducidad > 0)
          'expira_ts': isoHabana(
              ahoraHabana().add(Duration(hours: _horasCaducidad))),
      });
      if (!mounted) return;
      _mensajeCtrl.clear();
      mostrarSnack(context, 'Candado aplicado. Llegará a cada '
          'teléfono cuando sincronice.');
      await _cargar();
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _quitar(Map<String, dynamic> f) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Quitar candado',
      mensaje: 'Se reactivará el acceso de «${_tituloFila(f)}» '
          'en cuanto cada teléfono sincronice. Las operaciones '
          'retenidas saldrán solas.',
      aceptar: 'Quitar',
      icono: Icons.lock_open_rounded,
    );
    if (!ok) return;
    await _enviarOp({
      'id': '${f['id']}',
      'alcance': '${f['alcance'] ?? 'global'}',
      'app': '${f['app'] ?? 'ambas'}',
      if (f['objetivo'] != null) 'objetivo': '${f['objetivo']}',
      if ((f['mensaje']?.toString() ?? '').isNotEmpty)
        'mensaje': '${f['mensaje']}',
      'activo': 0,
    });
    if (!mounted) return;
    mostrarSnack(context, 'Candado retirado.');
    await _cargar();
  }

  Future<void> _resolverNombreClienteId(String texto) async {
    final id = texto.trim();
    if (id.isEmpty) {
      setState(() => _nombreClienteId = '');
      return;
    }
    final nombre = _nombresPersonas[id];
    setState(() => _nombreClienteId =
        nombre != null ? 'Cliente: $nombre' : 'Sin cliente con ese id');
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Candado de acceso')),
        body: const Center(
            child: Text('Solo el dueño puede gestionar el candado.')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Candado de acceso')),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando candados…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                Text(
                  'Pausa temporal del acceso sin cerrar sesiones. '
                  'El candado llega a cada teléfono cuando '
                  'sincroniza; el servidor además retiene las '
                  'operaciones de quien esté pausado.',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(context)),
                ),
                const SizedBox(height: AppEspacio.lg),
                const EncabezadoSeccion(titulo: 'Candados activos'),
                const SizedBox(height: AppEspacio.sm),
                if (_activos.isEmpty)
                  const EstadoVacio(
                    icono: Icons.lock_open_rounded,
                    titulo: 'Ningún candado activo',
                    subtitulo:
                        'Todas las apps están abiertas ahora mismo.',
                  )
                else
                  for (final f in _activos)
                    Tarjeta(
                      child: Row(
                        children: [
                          const Icon(Icons.lock_rounded),
                          const SizedBox(width: AppEspacio.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(_tituloFila(f),
                                    style: AppTexto.subtitulo),
                                Text(_detalleFila(f),
                                    style: AppTexto.metadato.copyWith(
                                        color: AppColores.textoSecundario(
                                            context))),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: 128,
                            child: BotonSecundario(
                              texto: 'Quitar',
                              icono: Icons.lock_open_rounded,
                              onPressed: () => _quitar(f),
                            ),
                          ),
                        ],
                      ),
                    ),
                const SizedBox(height: AppEspacio.xl),
                const EncabezadoSeccion(titulo: 'Aplicar un candado'),
                const SizedBox(height: AppEspacio.sm),
                Tarjeta(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: _alcance,
                        decoration: const InputDecoration(
                            labelText: 'Alcance'),
                        items: const [
                          DropdownMenuItem(
                              value: 'global',
                              child: Text('Todos (ambas apps)')),
                          DropdownMenuItem(
                              value: 'app', child: Text('Una app')),
                          DropdownMenuItem(
                              value: 'rol', child: Text('Por rol')),
                          DropdownMenuItem(
                              value: 'persona',
                              child: Text('Una persona')),
                        ],
                        onChanged: (v) =>
                            setState(() => _alcance = v ?? 'global'),
                      ),
                      if (_alcance != 'global') ...[
                        const SizedBox(height: AppEspacio.md),
                        DropdownButtonFormField<String>(
                          initialValue: _app,
                          decoration: const InputDecoration(
                              labelText: 'App'),
                          items: const [
                            DropdownMenuItem(
                                value: 'ambas',
                                child: Text('Ambas apps')),
                            DropdownMenuItem(
                                value: 'gestion',
                                child: Text('Solo Gestión')),
                            DropdownMenuItem(
                                value: 'clientes',
                                child: Text('Solo Clientes')),
                          ],
                          onChanged: (v) =>
                              setState(() => _app = v ?? 'ambas'),
                        ),
                      ],
                      if (_alcance == 'rol') ...[
                        const SizedBox(height: AppEspacio.md),
                        DropdownButtonFormField<String>(
                          initialValue: _rol,
                          decoration:
                              const InputDecoration(labelText: 'Rol'),
                          items: const [
                            DropdownMenuItem(
                                value: 'entrenador',
                                child: Text('Entrenadores')),
                            DropdownMenuItem(
                                value: 'cliente',
                                child: Text('Clientes')),
                            DropdownMenuItem(
                                value: 'invitado',
                                child: Text('Invitados')),
                          ],
                          onChanged: (v) =>
                              setState(() => _rol = v ?? 'entrenador'),
                        ),
                      ],
                      if (_alcance == 'persona') ...[
                        const SizedBox(height: AppEspacio.md),
                        DropdownButtonFormField<String>(
                          initialValue: _personaTipo,
                          decoration: const InputDecoration(
                              labelText: 'Tipo de persona'),
                          items: const [
                            DropdownMenuItem(
                                value: 'entrenador',
                                child: Text('Entrenador (Gestión)')),
                            DropdownMenuItem(
                                value: 'cliente',
                                child:
                                    Text('Cliente o invitado (Clientes)')),
                          ],
                          onChanged: (v) => setState(
                              () => _personaTipo = v ?? 'entrenador'),
                        ),
                        const SizedBox(height: AppEspacio.md),
                        if (_personaTipo == 'entrenador')
                          DropdownButtonFormField<String>(
                            initialValue: _personaTid,
                            decoration: const InputDecoration(
                                labelText: 'Entrenador'),
                            items: [
                              for (final e in _entrenadores)
                                DropdownMenuItem(
                                    value: e.tid, child: Text(e.nombre)),
                            ],
                            onChanged: (v) =>
                                setState(() => _personaTid = v),
                          )
                        else ...[
                          CampoTexto(
                            controller: _clienteIdCtrl,
                            etiqueta:
                                'Id del cliente o invitado (el de su ficha)',
                            teclado: TextInputType.number,
                            onChanged: _resolverNombreClienteId,
                          ),
                          if (_nombreClienteId.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(
                                  top: AppEspacio.xs),
                              child: Text(_nombreClienteId,
                                  style: AppTexto.metadato.copyWith(
                                      color: AppColores.textoSecundario(
                                          context))),
                            ),
                        ],
                      ],
                      const SizedBox(height: AppEspacio.md),
                      CampoTexto(
                        controller: _mensajeCtrl,
                        etiqueta: 'Mensaje que verán (opcional)',
                      ),
                      const SizedBox(height: AppEspacio.md),
                      DropdownButtonFormField<int>(
                        initialValue: _horasCaducidad,
                        decoration: const InputDecoration(
                            labelText: 'Caducidad'),
                        items: const [
                          DropdownMenuItem(
                              value: 0, child: Text('Sin caducidad')),
                          DropdownMenuItem(
                              value: 1, child: Text('1 hora')),
                          DropdownMenuItem(
                              value: 4, child: Text('4 horas')),
                          DropdownMenuItem(
                              value: 24, child: Text('24 horas')),
                        ],
                        onChanged: (v) =>
                            setState(() => _horasCaducidad = v ?? 0),
                      ),
                      const SizedBox(height: AppEspacio.lg),
                      BotonPrimario(
                        texto: 'Aplicar candado',
                        icono: Icons.lock_rounded,
                        cargando: _guardando,
                        onPressed: _guardando ? null : _crear,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
