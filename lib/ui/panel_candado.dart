import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../app_log.dart';
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
  // Yunque R5-M2-5: un fallo de la lectura del espejo no
  // puede pintarse como «Ningún candado activo».
  bool _falloCarga = false;

  /// 1.28 (M5-A7/R2M5-H07): candados en curso de retirada,
  /// por id: un doble toque sobre la misma fila no abre
  /// dos diálogos ni encola dos bajas.
  final Set<String> _quitandoIds = {};
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
        _falloCarga = false;
      });
      // Fase 2 (sin bloquear la pintura): nombres de invitados
      // para que un candado por invitado se lea con su nombre y
      // no con el id crudo en la lista de activos.
      unawaited(_cargarNombresInvitados());
    } catch (e) {
      // Yunque R5-M2-5: el fallo queda en bitácora y se
      // pinta como error, no como «sin candados».
      AppLog.error('ui', 'carga_fallo', d: 'panel_candado: $e');
      if (mounted) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
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

  /// 1.36 CAMPO C-1: la caducidad de una fila como pieza
  /// propia de su tarjeta (antes iba fundida en una línea
  /// de detalle con el mensaje). Misma lectura de
  /// `expira_ts` y misma conversión a hora de La Habana.
  String _caducidadFila(Map<String, dynamic> f) {
    final expira = DateTime.tryParse('${f['expira_ts'] ?? ''}');
    if (expira == null) return 'Sin caducidad';
    final h = aHabana(expira);
    return 'Caduca el ${h.day.toString().padLeft(2, '0')}/'
        '${h.month.toString().padLeft(2, '0')} · '
        '${h.hour.toString().padLeft(2, '0')}:'
        '${h.minute.toString().padLeft(2, '0')}';
  }

  /// 1.36 CAMPO C-1: la tarjeta de estado que abre la
  /// pantalla — el estado manda: si hay candado (y de
  /// quién) o si todo está abierto, antes que el
  /// formulario. Solo composición sobre el `_activos`
  /// de siempre; la mecánica no se toca.
  Widget _tarjetaEstado(BuildContext context) {
    final pausado = _activos.isNotEmpty;
    return Tarjeta(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pausado)
            IconoModuloBadge.naranja(Icons.lock_rounded)
          else
            IconoModuloBadge.verde(Icons.lock_open_rounded),
          const SizedBox(width: AppEspacio.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pausado ? 'Acceso pausado' : 'Acceso abierto',
                  style: AppTexto.titulo,
                ),
                const SizedBox(height: AppEspacio.xs),
                Text(
                  pausado
                      ? _activos.length == 1
                          ? 'Hay 1 candado activo: '
                              '${_tituloFila(_activos.first)}.'
                          : 'Hay ${_activos.length} candados '
                              'activos ahora mismo.'
                      : 'Ningún candado activo: todas las apps '
                          'están abiertas ahora mismo.',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.textoSecundario(context)),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppEspacio.sm),
          ChipEstado.semantico(
            texto: pausado ? 'Pausado' : 'Abierto',
            significado: pausado
                ? SignificadoChip.alerta
                : SignificadoChip.exito,
          ),
        ],
      ),
    );
  }

  /// 1.36 CAMPO C-1: cada candado activo como tarjeta
  /// propia — alcance como título, su mensaje, su
  /// caducidad y el levantar a un toque (el mismo
  /// `_quitar` de siempre, con su confirmación).
  Widget _tarjetaCandadoActivo(
      BuildContext context, Map<String, dynamic> f) {
    final mensaje = '${f['mensaje'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconoModuloBadge.naranja(Icons.lock_rounded),
                const SizedBox(width: AppEspacio.md),
                Expanded(
                  child: Text(_tituloFila(f),
                      style: AppTexto.subtitulo),
                ),
                const ChipEstado.semantico(
                  texto: 'Activo',
                  significado: SignificadoChip.alerta,
                ),
              ],
            ),
            if (mensaje.isNotEmpty) ...[
              const SizedBox(height: AppEspacio.sm),
              Text('«$mensaje»', style: AppTexto.cuerpo),
            ],
            const SizedBox(height: AppEspacio.sm),
            Row(
              children: [
                Icon(Icons.schedule_rounded,
                    size: 16,
                    color: AppColores.textoSecundario(context)),
                const SizedBox(width: AppEspacio.xs),
                Expanded(
                  child: Text(_caducidadFila(f),
                      style: AppTexto.metadato.copyWith(
                          color: AppColores.textoSecundario(
                              context))),
                ),
                // BotonSecundario es de ancho completo:
                // en la fila va acotado, como antes.
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
          ],
        ),
      ),
    );
  }

  Future<void> _enviarOp(Map<String, dynamic> payload) async {
    // 1.28 (M5-A7/R1M5-8): guarda de dueño en el MÉTODO
    // (defensa en profundidad, patrón P-1 de la casa): el
    // build esconde la pantalla, pero ningún camino
    // encola un candado sin ser el dueño (el servidor
    // además lo exige: la op es SOLO_ADMIN).
    if (!AuthService().isOwner) return;
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
    // 1.28 (M5-A7/R1M5-8 + R2M5-H07): guarda de dueño en
    // el método y candado anti-doble-toque tomado AL
    // ENTRAR (check-and-set síncrono): antes _guardando
    // se activaba tras la validación y el diálogo de
    // confirmación, y dos toques rápidos abrían dos
    // diálogos y encolaban dos candados. El finally lo
    // libera en TODAS las salidas de _crearReal.
    if (!AuthService().isOwner) return;
    if (_guardando) return;
    setState(() => _guardando = true);
    try {
      await _crearReal();
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  Future<void> _crearReal() async {
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
      // El id tecleado a mano debe ser de un cliente o
      // invitado conocido: un dígito mal puesto no debe pausar
      // a un desconocido ni quedarse en silencio sin pausar a
      // nadie. (El antiguo rechazo por colisión con telegram_id
      // de entrenadores se retiró en la 1.23: con tipo_objetivo
      // explícito en la op, cada evaluador casa solo dentro de
      // su dominio y la colisión numérica es inocua — veredicto
      // de Argón, condición B del diseño.)
      if (_personaTipo != 'entrenador') {
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
    // 1.36 H-B1 (136-455): la confirmación RESUME lo que se
    // va a aplicar — objetivo, app, caducidad y mensaje —
    // no una frase genérica sobre «el alcance elegido».
    final appEfectiva = _alcance == 'global'
        ? 'ambas'
        : (appForzadaCandado(
                alcance: _alcance,
                rol: _rol,
                personaTipo: _personaTipo) ??
            _app);
    final objetivoTxt = switch (_alcance) {
      'global' => 'todas las cuentas',
      'rol' => 'el rol $_rol',
      _ => _personaElegida?.nombre ?? 'la persona $objetivo',
    };
    final caducidadTxt = _horasCaducidad > 0
        ? 'Caduca en $_horasCaducidad h.'
        : 'Sin caducidad: dura hasta que lo quites.';
    final mensajePrevio = _mensajeCtrl.text.trim();
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Aplicar candado',
      mensaje: 'Objetivo: $objetivoTxt.\n'
          'App: $appEfectiva.\n'
          '$caducidadTxt\n'
          '${mensajePrevio.isNotEmpty ? 'Mensaje: «$mensajePrevio».\n' : 'Sin mensaje para el usuario.\n'}'
          '\nSe pausará el acceso según ese resumen. '
          'Nadie pierde su sesión ni su trabajo pendiente: al '
          'quitar el candado, todo continúa.',
      aceptar: 'Aplicar',
      icono: Icons.lock_rounded,
    );
    if (!ok || !mounted) return;
    final mensaje = _mensajeCtrl.text.trim();
      // 1.23 (tipo_objetivo): el dominio de la persona viaja
      // explícito en la op; cada evaluador casará solo dentro
      // de su dominio.
      final tipoObj = _alcance == 'persona' && objetivo != null
          ? tipoObjetivoCandado(
              personaTipo: _personaTipo,
              esInvitado: _personaElegida?.esInvitado ?? false,
              idManual: _idManual,
              objetivo: objetivo)
          : null;
      await _enviarOp({
        'id': const Uuid().v4(),
        'alcance': _alcance,
        // C-1: la app sale DERIVADA del objetivo (regla D), no
        // del selector libre: una combinación incoherente la
        // rechazaba el servidor en silencio tras el «Candado
        // aplicado». Sin derivación posible (alcance «app»),
        // manda el selector.
        'app': _alcance == 'global'
            ? 'ambas'
            : (appForzadaCandado(
                    alcance: _alcance,
                    rol: _rol,
                    personaTipo: _personaTipo) ??
                _app),
        if (objetivo != null) 'objetivo': objetivo,
        if (tipoObj != null) 'tipo_objetivo': tipoObj,
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
  }

  Future<void> _quitar(Map<String, dynamic> f) async {
    // 1.28 (M5-A7/R1M5-8 + R2M5-H07): guarda de dueño en
    // el método y anti-doble-toque por fila tomado ANTES
    // del diálogo (check-and-set síncrono).
    if (!AuthService().isOwner) return;
    final idFila = '${f['id']}';
    if (!_quitandoIds.add(idFila)) return;
    try {
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
        'id': idFila,
        'alcance': '${f['alcance'] ?? 'global'}',
        'app': '${f['app'] ?? 'ambas'}',
        if (f['objetivo'] != null) 'objetivo': '${f['objetivo']}',
        // El tipo viaja si la fila lo trae (si no, el servidor
        // preserva el guardado al desactivar: condición A).
        if (f['tipo_objetivo'] != null)
          'tipo_objetivo': '${f['tipo_objetivo']}',
        if ((f['mensaje']?.toString() ?? '').isNotEmpty)
          'mensaje': '${f['mensaje']}',
        'activo': 0,
      });
      if (!mounted) return;
      mostrarSnack(context, 'Candado retirado.');
      await _cargar();
    } finally {
      _quitandoIds.remove(idFila);
    }
  }

  /// Ids que el panel reconoce como personas de Clientes
  /// (clientes del espejo + invitados vivos), leídos frescos al
  /// confirmar. La validación protege del error de dedo al
  /// teclear el id a mano (que el id exista como cliente o
  /// invitado); ya no protege de colisiones entre dominios:
  /// con tipo_objetivo declarado, eso es inocuo.
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
    // C-1 (cierre 1.23): app derivada del objetivo elegido
    // cuando el servidor no acepta otra (regla D); null = el
    // selector de app queda libre (alcances «app» y «global»).
    final appForzada = appForzadaCandado(
        alcance: _alcance, rol: _rol, personaTipo: _personaTipo);
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
          : _falloCarga
              ? EstadoError(
                  titulo: 'No se pudieron cargar los candados',
                  detalle:
                      'La lectura local falló; puede haber candados activos que no se ven.',
                  onReintentar: _cargar,
                )
              : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                // 1.36 CAMPO C-1: el estado abre la pantalla
                // (tarjeta protagonista); sin candados no hay
                // sección de activos que pintar (regla de
                // Jc: lo que está en cero no aparece).
                _tarjetaEstado(context),
                if (_activos.isNotEmpty) ...[
                  const EncabezadoSeccion(
                      titulo: 'Candados activos'),
                  for (final f in _activos)
                    _tarjetaCandadoActivo(context, f),
                ],
                const EncabezadoSeccion(titulo: 'Aplicar un candado'),
                Tarjeta(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 1.36 CAMPO C-1: cabecera propia del
                      // formulario — deja de leerse como una
                      // caja genérica de campos sueltos.
                      Row(
                        children: [
                          IconoModuloBadge.naranja(
                              Icons.lock_rounded),
                          const SizedBox(width: AppEspacio.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                const Text('Nuevo candado',
                                    style: AppTexto.subtitulo),
                                Text(
                                  'Elige el alcance: a quién se le '
                                  'pausa el acceso.',
                                  style: AppTexto.secundario.copyWith(
                                      color: AppColores
                                          .textoSecundario(context)),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppEspacio.lg),
                      SelectorIronForm<String>(
                        valorInicial: _alcance,
                        etiqueta: 'Alcance',
                        opciones: const [
                          OpcionSelector('global', 'Todos (ambas apps)'),
                          OpcionSelector('app', 'Una app'),
                          OpcionSelector('rol', 'Por rol'),
                          OpcionSelector('persona', 'Una persona'),
                        ],
                        alCambiar: (v) =>
                            setState(() => _alcance = v ?? 'global'),
                      ),
                      if (_alcance != 'global') ...[
                        const SizedBox(height: AppEspacio.md),
                        SelectorIronForm<String>(
                          // C-1: con app derivada, la llave
                          // fuerza el remontaje al cambiar el
                          // objetivo y el selector queda
                          // deshabilitado con el valor forzado.
                          key: ValueKey(
                              'app-candado-${appForzada ?? 'libre'}'),
                          valorInicial: appForzada ?? _app,
                          etiqueta: 'App',
                          textoAyuda: appForzada == null
                              ? null
                              : 'Fijada por el tipo de objetivo: '
                                  'el servidor no acepta otra app '
                                  'para este candado.',
                          opciones: const [
                            OpcionSelector('ambas', 'Ambas apps'),
                            OpcionSelector('gestion', 'Solo Gestión'),
                            OpcionSelector('clientes', 'Solo Clientes'),
                          ],
                          alCambiar: appForzada == null
                              ? (v) =>
                                  setState(() => _app = v ?? 'ambas')
                              : null,
                        ),
                      ],
                      if (_alcance == 'rol') ...[
                        const SizedBox(height: AppEspacio.md),
                        SelectorIronForm<String>(
                          valorInicial: _rol,
                          etiqueta: 'Rol',
                          opciones: const [
                            OpcionSelector('entrenador', 'Entrenadores'),
                            OpcionSelector('cliente', 'Clientes'),
                            OpcionSelector('invitado', 'Invitados'),
                          ],
                          alCambiar: (v) =>
                              setState(() => _rol = v ?? 'entrenador'),
                        ),
                      ],
                      if (_alcance == 'persona') ...[
                        const SizedBox(height: AppEspacio.md),
                        SelectorIronForm<String>(
                          valorInicial: _personaTipo,
                          etiqueta: 'Tipo de persona',
                          opciones: const [
                            OpcionSelector('entrenador', 'Entrenador (Gestión)'),
                            OpcionSelector('cliente', 'Cliente o invitado (Clientes)'),
                          ],
                          alCambiar: (v) => setState(
                              () => _personaTipo = v ?? 'entrenador'),
                        ),
                        const SizedBox(height: AppEspacio.md),
                        if (_personaTipo == 'entrenador')
                          SelectorIronForm<String>(
                            valorInicial: _personaTid,
                            etiqueta: 'Entrenador',
                            opciones: [
                              for (final e in _entrenadores)
                                OpcionSelector(e.tid, e.nombre),
                            ],
                            alCambiar: (v) =>
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
                      SelectorIronForm<int>(
                        valorInicial: _horasCaducidad,
                        etiqueta: 'Caducidad',
                        opciones: const [
                          OpcionSelector(0, 'Sin caducidad'),
                          OpcionSelector(1, '1 hora'),
                          OpcionSelector(4, '4 horas'),
                          OpcionSelector(24, '24 horas'),
                        ],
                        alCambiar: (v) =>
                            setState(() => _horasCaducidad = v ?? 0),
                      ),
                      const SizedBox(height: AppEspacio.lg),
                      BotonPrimario(
                        texto: 'Aplicar candado',
                        icono: Icons.lock_rounded,
                        cargando: _guardando,
                        onPressed: _guardando ? null : _crear,
                      ),
                      const SizedBox(height: AppEspacio.md),
                      // 1.36 CAMPO C-1: la explicación de la
                      // mecánica vive al pie del formulario
                      // (era el párrafo suelto que abría la
                      // pantalla): pausa sin cerrar sesiones,
                      // retención en el servidor y salida
                      // automática al quitar el candado.
                      Text(
                        'Pausa temporal del acceso sin cerrar '
                        'sesiones. El candado llega a cada '
                        'teléfono cuando sincroniza; el servidor '
                        'además retiene las operaciones de quien '
                        'esté pausado, y al quitar el candado '
                        'salen solas.',
                        style: AppTexto.metadato.copyWith(
                            color: AppColores.textoSecundario(
                                context)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

/// 1.23 (C-1, cierre): app que el servidor ACEPTA para el
/// candado según su objetivo — la misma derivación que hace
/// el bot. Regla D del diseño tipo_objetivo: un objetivo de
/// dominio telegram (entrenador) solo admite app «gestion» (o
/// «ambas», pero el panel fuerza la precisa); un objetivo de
/// dominio cliente/invitado solo admite «clientes». Dejarla
/// libre producía candados que la UI anunciaba como aplicados
/// y el servidor rechazaba en silencio. Devuelve null cuando
/// ningún dominio ata la app (alcances «app» y «global») y el
/// selector queda libre.
String? appForzadaCandado({
  required String alcance,
  required String rol,
  required String personaTipo,
}) {
  switch (alcance) {
    case 'persona':
      return personaTipo == 'entrenador' ? 'gestion' : 'clientes';
    case 'rol':
      return rol == 'entrenador' ? 'gestion' : 'clientes';
    default:
      return null;
  }
}

/// 1.23: dominio explícito del objetivo de un candado de
/// alcance «persona» (protocolo tipo_objetivo, diseño aprobado
/// por Argón). El panel conoce el dominio al crear:
/// - entrenador → 'telegram';
/// - persona del buscador → 'invitado' o 'cliente' según su
///   clase (PersonaCandado.esInvitado);
/// - id escrito a mano → el de cliente es numérico y el de
///   invitado es un uuid: se distingue por la forma del texto.
/// (El antiguo objetivoCandadoColisiona se retiró: con el
/// dominio declarado, la colisión numérica entre dominios es
/// estructuralmente inocua.)
String tipoObjetivoCandado({
  required String personaTipo,
  required bool esInvitado,
  required bool idManual,
  required String objetivo,
}) {
  if (personaTipo == 'entrenador') return 'telegram';
  if (!idManual) return esInvitado ? 'invitado' : 'cliente';
  return RegExp(r'^\d+$').hasMatch(objetivo.trim())
      ? 'cliente'
      : 'invitado';
}

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
