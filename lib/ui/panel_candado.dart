import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../invitados.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'app_bar.dart';
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
  // Campo 2026-11-03 (Jc): la persona de Clientes se ELIGE en un
  // buscador por nombre; teclear el id de la ficha queda solo
  // como vía manual de respaldo (p. ej. sin conexión, cuando la
  // lista de invitados no puede bajar).
  PersonaCandado? _personaElegida;
  bool _idManual = false;
  final _idManualCtrl = TextEditingController();
  final _mensajeCtrl = TextEditingController();
  int _horasCaducidad = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _idManualCtrl.dispose();
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
      // Fase 2 (sin bloquear la pintura): nombres de invitados
      // para que un candado por invitado se lea con su nombre y
      // no con el id crudo en la lista de activos.
      unawaited(_cargarNombresInvitados());
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _cargarNombresInvitados() async {
    try {
      final lista =
          await InvitadosService().listar(filtro: 'todos', limite: 500);
      if (!mounted) return;
      var cambio = false;
      for (final inv in lista) {
        if (inv.id.isNotEmpty &&
            _nombresPersonas[inv.id] != inv.nombre) {
          _nombresPersonas[inv.id] = inv.nombre;
          cambio = true;
        }
      }
      if (cambio && mounted) setState(() {});
    } catch (_) {
      // Sin conexión: los candados de invitados se quedan con
      // el id en la lista; el resto del panel no se entera.
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
    // 1.23 (auditoría extra P3): sin await — no congelar la UI.
    // Delta panel M2: helper compartido (consume el error
    // asíncrono; el try/catch de antes no lo veía).
    SyncEngine.instance.pushEnSegundoPlano();
  }

  Future<void> _crear() async {
    String? objetivo;
    if (_alcance == 'rol') {
      objetivo = _rol;
    } else if (_alcance == 'persona') {
      objetivo = _personaTipo == 'entrenador'
          ? _personaTid
          : (_idManual
              ? _idManualCtrl.text.trim()
              : _personaElegida?.id);
      if (objetivo == null || objetivo.isEmpty) {
        mostrarSnack(context, 'Elige la persona del candado.',
            significado: SignificadoChip.alerta);
        return;
      }
      // Delta del panel (H1): el objetivo de Clientes se valida
      // ANTES de encolar la op. El servidor casa el objetivo
      // contra telegram_id, cliente_id e invitado_id a la vez,
      // así que: (a) el id tecleado a mano debe ser de un
      // cliente o invitado conocido — un dígito mal puesto no
      // debe pausar a un desconocido ni quedarse en silencio
      // sin pausar a nadie —; y (b) NINGÚN objetivo de esta vía
      // (buscador o manual) puede coincidir con el telegram_id
      // de un entrenador o del dueño, porque el servidor lo
      // casaría también contra esa identidad y pausaría al
      // entrenador. La solución de fondo (tipo_objetivo
      // explícito en el protocolo) queda registrada en el
      // inventario de servidor de la 1.23.
      if (_personaTipo != 'entrenador') {
        final telegramIds = <String>[
          for (final e in _entrenadores) e.tid,
          if (AuthService().telegramId != null)
            '${AuthService().telegramId}',
        ];
        if (objetivoCandadoColisiona(objetivo, telegramIds)) {
          mostrarSnack(
              context,
              'Ese id coincide con el Telegram de un '
              'entrenador: no se aplica el candado para no '
              'pausarlo por error.',
              significado: SignificadoChip.alerta);
          return;
        }
        if (_idManual) {
          final conocidas = await _idsPersonasConocidas();
          if (!mounted) return;
          if (!conocidas.contains(objetivo)) {
            mostrarSnack(
                context,
                'Ese id no es de ningún cliente ni invitado '
                'conocido. Revisa el número o usa el buscador.',
                significado: SignificadoChip.alerta);
            return;
          }
        }
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

  /// Ids que el panel reconoce como personas de Clientes
  /// (clientes del espejo + invitados vivos), leídos frescos al
  /// confirmar. NUNCA se mezclan los telegram_id de
  /// entrenadores: un id de entrenador tecleado en la vía de
  /// Clientes no debe validar (con app «ambas» el servidor lo
  /// casaría contra el telegram_id y pausaría al entrenador).
  Future<Set<String>> _idsPersonasConocidas() async {
    try {
      final clientes = await listaClientes('');
      var invitados = const <InvitadoResumen>[];
      try {
        invitados = await InvitadosService()
            .listar(filtro: 'todos', limite: 500);
      } catch (_) {}
      return personasCandadoFiltradas(
              clientes: clientes, invitados: invitados, consulta: '')
          .map((p) => p.id)
          .toSet();
    } catch (_) {
      // Respaldo: los ids de cliente del espejo, tal cual.
      try {
        return {
          for (final c in await _db.allMirror('clientes'))
            '${c['id'] ?? ''}'
        }..remove('');
      } catch (_) {
        return <String>{};
      }
    }
  }

  Future<void> _abrirBuscadorPersona() async {
    final sel = await showDialog<PersonaCandado>(
      context: context,
      builder: (_) => const _BuscadorPersonaCandado(),
    );
    if (sel == null || !mounted) return;
    setState(() => _personaElegida = sel);
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Candado de acceso'),
        body: const Center(
            child: Text('Solo el dueño puede gestionar el candado.')),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Candado de acceso'),
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
                          if (!_idManual) ...[
                            InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Cliente o invitado',
                                border: OutlineInputBorder(),
                              ),
                              child: InkWell(
                                onTap: _abrirBuscadorPersona,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _personaElegida == null
                                            ? 'Toca para buscar por nombre…'
                                            : _personaElegida!.nombre,
                                        style: _personaElegida == null
                                            ? AppTexto.secundario.copyWith(
                                                color: AppColores
                                                    .textoSecundario(
                                                        context))
                                            : AppTexto.cuerpo,
                                      ),
                                    ),
                                    if (_personaElegida != null)
                                      Text(
                                        _personaElegida!.esInvitado
                                            ? 'Invitado'
                                            : 'Cliente '
                                                '#${_personaElegida!.id}',
                                        style: AppTexto.metadato.copyWith(
                                            color: AppColores
                                                .textoSecundario(context)),
                                      ),
                                    const SizedBox(width: AppEspacio.sm),
                                    if (_personaElegida != null)
                                      IconButton(
                                        icon: const Icon(
                                            Icons.close_rounded),
                                        tooltip: 'Quitar selección',
                                        onPressed: () => setState(
                                            () => _personaElegida = null),
                                      )
                                    else
                                      const Icon(Icons.search_rounded),
                                  ],
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: () =>
                                    setState(() => _idManual = true),
                                child: const Text(
                                    '¿No aparece? Escribir el id a mano'),
                              ),
                            ),
                          ] else ...[
                            CampoTexto(
                              controller: _idManualCtrl,
                              etiqueta:
                                  'Id del cliente o invitado (el de su ficha)',
                            ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton(
                                onPressed: () =>
                                    setState(() => _idManual = false),
                                child: const Text('Volver al buscador'),
                              ),
                            ),
                          ],
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

/// ¿El objetivo de un candado de Clientes coincide con el
/// telegram_id de un entrenador o del dueño? El servidor casa
/// el objetivo contra los tres dominios de identidad a la vez;
/// si coincide, aplicar el candado pausaría también al
/// entrenador (delta del panel, residual de H1).
bool objetivoCandadoColisiona(
        String objetivo, Iterable<String> telegramIds) =>
    telegramIds.contains(objetivo);

/// Persona elegible para un candado de alcance «persona» en la
/// app de Clientes: un cliente del espejo local o un invitado de
/// la bandeja. El `id` es EXACTAMENTE el objetivo que evalúa el
/// servidor (cliente_id o invitado_id, como texto).
class PersonaCandado {
  final String id;
  final String nombre;
  final bool esInvitado;
  final String detalle;

  const PersonaCandado({
    required this.id,
    required this.nombre,
    required this.esInvitado,
    required this.detalle,
  });
}

/// Normalización de búsqueda de la casa (la misma de
/// negocio._norm): minúsculas y sin tildes ni ñ.
String _normCandado(String s) {
  var n = s.toLowerCase().trim();
  const conTilde = 'áéíóúüñ';
  const sinTilde = 'aeiouun';
  for (var i = 0; i < conTilde.length; i++) {
    n = n.replaceAll(conTilde[i], sinTilde[i]);
  }
  return n;
}

/// Solo los dígitos de un texto: así un teléfono o un id
/// pegado con espacios, guiones o prefijo +53 encuentra su
/// fila igual (delta del panel, H2).
String _digitosCandado(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

/// Une clientes e invitados en la lista del buscador y filtra
/// por la consulta (nombre normalizado; teléfono e id por sus
/// dígitos). Un invitado ya convertido NO entra: su identidad
/// viva es la de cliente y se le bloquea desde la lista de
/// clientes.
List<PersonaCandado> personasCandadoFiltradas({
  required List<Map<String, dynamic>> clientes,
  required List<InvitadoResumen> invitados,
  required String consulta,
}) {
  final q = _normCandado(consulta);
  final qDigitos = _digitosCandado(consulta);
  bool coincide(String nombre, String telefono, String id) {
    if (q.isEmpty) return true;
    if (_normCandado(nombre).contains(q)) return true;
    if (qDigitos.length >= 3) {
      final telDigitos = _digitosCandado(telefono);
      // En las dos direcciones: la consulta puede venir con el
      // prefijo 53 pegado (la fila guarda los 8 dígitos limpios)
      // o la fila puede traerlo y la consulta no.
      if (telDigitos.contains(qDigitos) ||
          (telDigitos.length >= 7 && qDigitos.contains(telDigitos))) {
        return true;
      }
      if (_digitosCandado(id) == qDigitos) return true;
    }
    return false;
  }

  final res = <PersonaCandado>[];
  for (final c in clientes) {
    final id = '${c['id'] ?? ''}';
    if (id.isEmpty) continue;
    final nombre = '${c['nombre'] ?? id}';
    final tel = '${c['telefono'] ?? c['movil'] ?? ''}';
    if (!coincide(nombre, tel, id)) continue;
    res.add(PersonaCandado(
      id: id,
      nombre: nombre,
      esInvitado: false,
      detalle: 'Cliente #$id',
    ));
  }
  for (final inv in invitados) {
    if (inv.id.isEmpty || inv.estado == 'convertido') continue;
    if (!coincide(inv.nombre, inv.telefono, inv.id)) continue;
    res.add(PersonaCandado(
      id: inv.id,
      nombre: inv.nombre,
      esInvitado: true,
      detalle: 'Invitado',
    ));
  }
  return res;
}

/// Buscador de persona para el candado: clientes desde el espejo
/// local (al instante, sin conexión) e invitados desde la bandeja
/// (RPC; si falla, se avisa dentro del propio diálogo y los
/// clientes siguen disponibles).
class _BuscadorPersonaCandado extends StatefulWidget {
  const _BuscadorPersonaCandado();

  @override
  State<_BuscadorPersonaCandado> createState() =>
      _BuscadorPersonaCandadoState();
}

class _BuscadorPersonaCandadoState
    extends State<_BuscadorPersonaCandado> {
  final _filtro = TextEditingController();
  List<Map<String, dynamic>> _clientes = [];
  List<InvitadoResumen> _invitados = [];
  bool _cargandoClientes = true;
  bool _invitadosError = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _filtro.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    try {
      final clientes = await listaClientes('');
      if (mounted) {
        setState(() {
          _clientes = clientes;
          _cargandoClientes = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargandoClientes = false);
    }
    try {
      final invitados =
          await InvitadosService().listar(filtro: 'todos', limite: 500);
      if (mounted) setState(() => _invitados = invitados);
    } catch (_) {
      if (mounted) setState(() => _invitadosError = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibles = personasCandadoFiltradas(
      clientes: _clientes,
      invitados: _invitados,
      consulta: _filtro.text,
    );
    return DialogoApp(
      titulo: 'Buscar cliente o invitado',
      iconoTitulo: Icons.person_search_rounded,
      contenido: SizedBox(
        width: double.maxFinite,
        height: 440,
        child: Column(
          children: [
            TextField(
              controller: _filtro,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Nombre, teléfono o id',
                prefixIcon: Icon(Icons.search_rounded),
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppEspacio.sm),
            Expanded(
              child: _cargandoClientes
                  ? const EstadoCargando(texto: 'Cargando personas…')
                  : ListView(
                      children: [
                        if (_invitadosError)
                          Padding(
                            padding: const EdgeInsets.only(
                                bottom: AppEspacio.sm),
                            child: Text(
                              'Invitados no disponibles sin conexión: '
                              'se muestran solo los clientes.',
                              style: AppTexto.metadato.copyWith(
                                  color: AppColores.textoSecundario(
                                      context)),
                            ),
                          ),
                        if (visibles.isEmpty)
                          const EstadoVacio(
                            icono: Icons.person_off_rounded,
                            titulo: 'Nadie con ese criterio',
                            subtitulo:
                                'Prueba con otro nombre o usa la vía '
                                'manual del id.',
                          )
                        else
                          for (final p in visibles)
                            ListTile(
                              dense: true,
                              leading: Icon(p.esInvitado
                                  ? Icons.person_outline_rounded
                                  : Icons.person_rounded),
                              title: Text(p.nombre),
                              subtitle: Text(p.detalle),
                              onTap: () =>
                                  Navigator.pop(context, p),
                            ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancelar'),
        ),
      ],
    );
  }
}
