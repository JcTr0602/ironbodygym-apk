/// Auditoría (v1.3.7): registro útil de quién hizo qué.
///
/// Rediseño: los tipos técnicos de operación se traducen a lenguaje
/// humano, siempre se muestra la persona afectada, y las operaciones
/// se agrupan por día con encabezados.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'auditoria_persona.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'componentes.dart';
import 'widgets.dart';

/// v1.6.0 (pedido de Jc): filtro de la Auditoría. La pantalla ABRE
/// en [otrosYAlertas]: lo de OTROS actores más las operaciones
/// sensibles o rechazadas vengan de donde vengan; lo rutinario
/// propio no ocupa la vista inicial, pero queda a un toque en
/// «Todo» o «Solo mías».
enum FiltroAuditoria { otrosYAlertas, todo, soloMias }

/// Decodifica el payload (JSON) de una op de la cola local.
Map<String, dynamic> payloadDeOp(Map<String, dynamic> op) {
  try {
    final p = op['payload'];
    if (p is String) return Map<String, dynamic>.from(jsonDecode(p));
    if (p is Map) return Map<String, dynamic>.from(p);
  } catch (_) {}
  return {};
}

/// Actor que la lista ya muestra. PRECEDENCIA (Ronda 17 M1-H3):
/// la firma NUMÉRICA manda sobre el texto: una op con
/// registrado_por numérico de OTRA sesión es «Otro usuario»
/// aunque traiga un campo de texto con un nombre. Sin firma
/// numérica ajena, se muestra el nombre guardado en el payload
/// (registrado_por/registrado_por_nombre/usuario/username).
/// «Este dispositivo» solo cuando la op no trae actor (nació
/// en este teléfono).
String actorDeOp(Map<String, dynamic> op, {int? miTelegramId}) {
  final p = payloadDeOp(op);
  final idNum = actorIdNumericoDeOp(op);
  if (idNum != null && miTelegramId != null && idNum != miTelegramId) {
    return 'Otro usuario';
  }
  for (final k
      in ['registrado_por', 'registrado_por_nombre', 'usuario', 'username']) {
    final v = p[k];
    if (v is String && v.isNotEmpty) return v;
  }
  return 'Este dispositivo';
}

/// Normaliza un nombre de actor para COMPARAR: recorta espacios,
/// pasa a minúsculas y quita un sufijo « (APK)» si el dato lo trae
/// pegado al nombre (así se compara la firma de la op contra el
/// nombre de la sesión sin que un sufijo arruine la igualdad).
String normalizarActor(String actor) {
  var a = actor.trim().toLowerCase();
  const sufijo = ' (apk)';
  if (a.endsWith(sufijo)) {
    a = a.substring(0, a.length - sufijo.length).trim();
  }
  return a;
}

/// La firma de actor que la op TRAE en su payload: el valor con el
/// que la app estampa quién la creó — `registrado_por` cuando es
/// texto, o `registrado_por_nombre` (p. ej. venta de suplemento con
/// inscripción). `registrado_por` numérico (telegram_id) no es un
/// nombre: no cuenta como firma de TEXTO aquí (ver
/// [actorIdNumericoDeOp] para la firma numérica). Devuelve null si
/// la op no trae firma de texto.
String? actorFirmaDeOp(Map<String, dynamic> op) {
  final p = payloadDeOp(op);
  for (final k in ['registrado_por', 'registrado_por_nombre']) {
    final v = p[k];
    if (v is String && v.trim().isNotEmpty) return v;
  }
  return null;
}

/// La firma NUMÉRICA de actor que la op trae en su payload: el
/// telegram_id con el que la app estampa quién la creó (p. ej.
/// `pago_diario` guarda `registrado_por` numérico). Solo cuenta
/// `registrado_por` como int/num; un String en esa clave es un
/// nombre (lo cubre [actorFirmaDeOp]). Devuelve null si la op no
/// trae firma numérica.
int? actorIdNumericoDeOp(Map<String, dynamic> op) {
  final v = payloadDeOp(op)['registrado_por'];
  if (v is int) return v;
  if (v is num) return v.toInt();
  return null;
}

/// ¿La op es «mía»? La cola local (ops_queue) SOLO contiene ops
/// nacidas en este teléfono, así que «de otro dispositivo» no se
/// puede inferir: la distinción real es por ACTOR.
///
/// - Con firma de texto: es mía si coincide con [miActor] — el nombre
///   con el que la sesión de este teléfono firma sus ops
///   (AuthService.displayName, el mismo valor que la app estampa en
///   `registrado_por_nombre`). Si la op trae actor y no hay sesión
///   con quién comparar (miActor null), no se puede acreditar como
///   mía: cuenta como de otro.
/// - Con firma numérica (telegram_id): es mía SOLO si coincide con
///   [miTelegramId], la identidad numérica de la sesión actual
///   (AuthService.telegramId). La sesión puede haber cambiado en el
///   mismo teléfono con ops pendientes en la cola (el cierre de
///   sesión las conserva a propósito), así que un id numérico que no
///   coincide es de OTRO actor aunque la op haya nacido aquí. Si no
///   hay identidad numérica de sesión con la que comparar
///   (miTelegramId null), no se acredita como propia: cuenta como
///   de otro (conservador: visible en «Otros y alertas», nunca
///   oculta).
/// - Sin firma alguna: la op nació sin actor en este teléfono → mía.
bool esOpMia(Map<String, dynamic> op, {String? miActor, int? miTelegramId}) {
  // Ronda 17 M1-H3: la firma numérica manda. Si la op trae
  // telegram_id, decide él solo: un texto con mi nombre no
  // convierte en mía una op firmada por otro id.
  final idNum = actorIdNumericoDeOp(op);
  if (idNum != null) {
    if (miTelegramId == null) return false;
    return idNum == miTelegramId;
  }
  final firma = actorFirmaDeOp(op);
  if (firma != null) {
    if (miActor == null || miActor.trim().isEmpty) return false;
    return normalizarActor(firma) == normalizarActor(miActor);
  }
  return true;
}

/// ¿La op es de OTRO actor? (trae una firma distinta de la mía).
bool esOpDeOtro(Map<String, dynamic> op,
        {String? miActor, int? miTelegramId}) =>
    !esOpMia(op, miActor: miActor, miTelegramId: miTelegramId);

/// Tipos sensibles para el dueño: dinero, vencimientos y
/// eliminaciones. (La edición de cliente solo cuenta como alerta
/// cuando toca el vencimiento — ver [esOpAlerta].)
const tiposOpSensibles = <String>{
  // Dinero
  'pago_mensual',
  'pago_diario',
  'editar_pago',
  'anular_pago',
  'editar_pago_diario',
  'anular_pago_diario',
  'gasto',
  'venta_suplemento',
  'anular_venta_suplemento',
  'inscripcion_venta_suplemento',
  'confirmar_entrega',
  'liquidar_caja',
  // Vencimientos / estado de la membresía
  'cambiar_estado',
  'regalar_mes_cumpleanos',
  // Eliminaciones
  'eliminar_cliente',
  'eliminar_foto',
  'eliminar_suplemento',
};

/// ¿Es una «alerta» para el dueño? Tipo sensible, edición que toca
/// el vencimiento (pagado_hasta) u op rechazada/error del servidor.
bool esOpAlerta(Map<String, dynamic> op) {
  final estado = '${op['estado']}';
  if (estado == 'rechazada' ||
      estado == 'error' ||
      estado == 'necesita_revision') {
    return true;
  }
  final tipo = '${op['tipo']}';
  if (tiposOpSensibles.contains(tipo)) return true;
  if (tipo == 'editar_cliente' &&
      payloadDeOp(op).containsKey('pagado_hasta')) {
    return true;
  }
  return false;
}

/// Visibilidad de una op según el filtro elegido y el actor de la
/// sesión ([miActor]: AuthService.displayName; [miTelegramId]:
/// AuthService.telegramId). Función pura.
/// ¿El nombre de un payload pertenece a un cliente protegido?
/// (Top-level, testeable.) Los nombres se normalizan a minúsculas
/// sin espacios extremos; la comparación es exacta tras normalizar.
/// Un nombre compartido por un protegido y un no protegido se
/// enmascara en ambos: ante la duda, la privacidad manda.
bool esNombreProtegido(String? nombre, Set<String> protegidos) {
  if (nombre == null) return false;
  final n = nombre.trim().toLowerCase();
  return n.isNotEmpty && protegidos.contains(n);
}

bool opVisibleEnAuditoria(Map<String, dynamic> op, FiltroAuditoria filtro,
    {String? miActor, int? miTelegramId}) {
  switch (filtro) {
    case FiltroAuditoria.todo:
      return true;
    case FiltroAuditoria.soloMias:
      return esOpMia(op, miActor: miActor, miTelegramId: miTelegramId);
    case FiltroAuditoria.otrosYAlertas:
      return esOpDeOtro(op, miActor: miActor, miTelegramId: miTelegramId) ||
          esOpAlerta(op);
  }
}

class AuditoriaScreen extends StatefulWidget {
  const AuditoriaScreen({super.key});

  @override
  State<AuditoriaScreen> createState() => _AuditoriaScreenState();
}

class _AuditoriaScreenState extends State<AuditoriaScreen> {
  List<Map<String, dynamic>> _ops = [];
  bool _cargando = true;
  // v1.6.0 (Jc): la vista inicial es «Otros y alertas».
  FiltroAuditoria _filtro = FiltroAuditoria.otrosYAlertas;

  /// Módulo 6 (1.19): filtros rápidos — solo hoy y por entrenador
  /// (el dueño elige el actor; sin elegir, todos). Se combinan con
  /// [_filtro]: primero el filtro de actor base, luego estos.
  bool _soloHoy = false;
  String? _actorFiltro;
  // Nombre con el que la sesión de ESTE teléfono firma sus ops
  // (AuthService.displayName): contra él se clasifica cada op como
  // «mía» o «de otro» (la cola local solo trae ops de este
  // teléfono; la distinción es por actor, no por dispositivo).
  String? _miActor;
  // Identidad numérica (telegram_id) de la sesión actual: contra
  // ella se comparan las ops firmadas solo con registrado_por
  // numérico (p. ej. pago_diario). Sin ella, una firma numérica no
  // se acredita como propia.
  int? _miTelegramId;
  // cliente_id -> nombre (caché)
  final Map<int, String> _nombres = {};
  // cliente_id -> foto_path local (caché)
  final Map<int, String?> _fotos = {};
  // cliente_id de clientes protegidos (Ronda 17 M1-H2): de ellos
  // no se precarga nombre ni foto y _detalle no muestra datos.
  final Set<int> _protegidosIds = {};
  // Nombres normalizados (minúsculas) de clientes protegidos del
  // espejo: para ops cuyo payload NO trae cliente_id (inscribir),
  // donde la máscara por id no puede cubrir (Argón Gmail_1-14 #1).
  final Set<String> _protegidosNombres = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    // El actor de la sesión: el mismo displayName que la app
    // estampa como registrado_por_nombre al crear ops, y el
    // telegram_id numérico con el que estampa registrado_por.
    try {
      _miActor = AuthService().displayName;
      _miTelegramId = AuthService().telegramId;
    } catch (_) {
      _miActor = null;
      _miTelegramId = null;
    }
    // Ronda 17 M1-H1 (decisión Jc 2026-10-28): un no-dueño solo
    // ve lo suyo. Fail-closed: sin dueño confirmado, se recorta.
    var esDueno = false;
    try {
      esDueno = AuthService().isOwner;
    } catch (_) {
      esDueno = false;
    }
    final ops = await LocalDb.instance.recentOps(limit: 100);
    // Recorte en carga para no-dueños: así ni los contadores
    // (opsHoy, pendientes) cuentan operaciones ajenas.
    final opsVisibles = esDueno
        ? ops
        : ops
            .where((o) => esOpMia(o,
                miActor: _miActor, miTelegramId: _miTelegramId))
            .toList();
    // Precargar nombres y fotos de clientes mencionados
    final clientes = await LocalDb.instance.allMirror('clientes');
    final porId = <int, Map<String, dynamic>>{
      for (final c in clientes) (c['id'] as int): c,
    };
    _protegidosIds.clear();
    _protegidosNombres.clear();
    // Argón Gmail_1-14 #1: el set de nombres protegidos se arma
    // de TODO el espejo, no solo de las ops visibles: una
    // inscripción no trae cliente_id y solo el nombre la delata.
    for (final c in clientes) {
      if (esVistaProtegida(c)) {
        final n = '${c['nombre'] ?? ''}'.trim().toLowerCase();
        if (n.isNotEmpty) _protegidosNombres.add(n);
      }
    }
    for (final op in opsVisibles) {
      final p = _payload(op);
      final cid = _clienteId(p, '${op['tipo']}');
      if (cid != null &&
          !_nombres.containsKey(cid) &&
          !_protegidosIds.contains(cid)) {
        final c = porId[cid];
        if (c != null) {
          // Ronda 17 M1-H2: de un protegido no se precarga ni
          // nombre ni foto (la fila mostraría su avatar).
          if (esVistaProtegida(c)) {
            _protegidosIds.add(cid);
          } else {
            _nombres[cid] = '${c['nombre'] ?? 'Cliente $cid'}';
            _fotos[cid] = c['foto_local'] as String?;
          }
        }
      }
    }
    if (mounted) {
      setState(() {
        _ops = opsVisibles;
        if (!esDueno) _filtro = FiltroAuditoria.soloMias;
        _cargando = false;
      });
    }
  }

  Map<String, dynamic> _payload(Map<String, dynamic> op) =>
      payloadDeOp(op);

  int? _clienteId(Map<String, dynamic> p, String tipo) {
    for (final k in ['cliente_id', 'id', 'cliente']) {
      final v = p[k];
      if (v is int) return v;
      if (v is String) {
        final n = int.tryParse(v);
        if (n != null) return n;
      }
    }
    return null;
  }

  /// v1.3.7: traduce el tipo técnico a lenguaje humano.
  /// Delegada a [descripcionOp] (top-level, testeable).
  String _descripcionOp(String tipo) => descripcionOp(tipo);

  /// Describe la operación en lenguaje humano, con la persona afectada.
  String _detalle(Map<String, dynamic> op) {
    final tipo = '${op['tipo']}';
    final p = _payload(op);
    final cid = _clienteId(p, tipo);
    // Ronda 17 M1-H2: de un cliente protegido no se muestra
    // ni nombre, ni monto, ni método, ni campos editados.
    if (cid != null && _protegidosIds.contains(cid)) {
      return 'Cliente protegido';
    }
    final nombre = cid != null ? (_nombres[cid] ?? 'Cliente $cid') : null;

    switch (tipo) {
      case 'editar_cliente':
        final campos = {
          'nombre': 'nombre',
          'telefono': 'teléfono',
          'carnet': 'carnet',
          'notas': 'notas',
          'sexo': 'sexo',
          'pagado_hasta': 'vencimiento',
        };
        final cambiados = [
          for (final k in p.keys)
            if (campos.containsKey(k)) campos[k]!
        ];
        final q = cambiados.isEmpty ? '' : ' (${cambiados.join(', ')})';
        return nombre != null ? 'Editó a $nombre$q' : 'Edición$q';
      case 'pago_mensual':
      case 'pago_diario':
        final monto = p['monto'];
        final metodo = p['metodo'] ?? 'efectivo';
        final etiqueta =
            tipo == 'pago_mensual' ? 'mensualidad' : 'pago diario';
        return nombre != null
            ? '$nombre pagó $etiqueta: ${monto ?? '?'} CUP ($metodo)'
            : 'Pago de $etiqueta: ${monto ?? '?'} CUP ($metodo)';
      case 'inscribir':
        final n = '${p['nombre'] ?? nombre ?? ''}'.trim();
        if (n.isEmpty) return 'Nueva inscripción';
        // Argón Gmail_1-14 #1: el payload de inscribir NO trae
        // cliente_id, así que la máscara por id de arriba no lo
        // cubre y el nombre real se filtraba en la lista y en el
        // diálogo. Se compara contra los nombres protegidos.
        if (esNombreProtegido(n, _protegidosNombres)) {
          return 'Cliente protegido';
        }
        return 'Se inscribió a $n';
      case 'regalar_mes_cumpleanos':
        return nombre != null
            ? 'Se le regaló el mes a $nombre (cumpleaños)'
            : 'Mes de cumpleaños regalado';
      case 'confirmar_entrega':
        final monto = p['monto'];
        final quien = '${p['entrenador'] ?? p['nombre'] ?? ''}';
        return quien.isNotEmpty
            ? 'Entrega de $quien confirmada${monto != null ? ': $monto CUP' : ''}'
            : 'Entrega de efectivo confirmada';
      case 'liquidar_caja':
        final quien = '${p['entrenador_nombre'] ?? ''}';
        return quien.isNotEmpty
            ? 'Caja de $quien liquidada (arqueo)'
            : 'Caja liquidada (arqueo)';
      case 'gasto':
        return 'Gasto: ${p['concepto'] ?? '—'} (${p['monto'] ?? '?'} CUP)';
      case 'venta_suplemento':
        final prod = '${p['suplemento'] ?? p['nombre'] ?? ''}';
        return nombre != null && prod.isNotEmpty
            ? '$nombre compró $prod'
            : (prod.isNotEmpty ? 'Se vendió $prod' : 'Venta de suplemento');
      case 'cierre_turno':
        return 'Se cerró el turno (${p['turno'] ?? ''})'.trim();
      case 'apertura_turno':
        return 'Se abrió el turno (${p['turno'] ?? ''})'.trim();
      case 'admin_usuario':
        return '${p['accion'] ?? '?'}: ${p['username'] ?? '?'}';
      default:
        // Para el resto: descripción + persona si la hay.
        final desc = _descripcionOp(tipo);
        return nombre != null ? '$desc — $nombre' : desc;
    }
  }

  String _usuario(Map<String, dynamic> op) =>
      actorDeOp(op, miTelegramId: _miTelegramId);

  /// Día ISO (yyyy-MM-dd) de la operación.
  String _diaOp(Map<String, dynamic> op) {
    final s = '${op['creada_ts'] ?? ''}';
    return s.length >= 10 ? s.substring(0, 10) : s;
  }

  /// Encabezado humano del día: Hoy, Ayer o fecha dd/mm/yyyy.
  String _etiquetaDia(String diaIso) {
    final hoy = hoyHabanaIso();
    if (diaIso == hoy) return 'Hoy';
    final ayer = isoHabana(ahoraHabana().subtract(const Duration(days: 1)))
        .substring(0, 10);
    if (diaIso == ayer) return 'Ayer';
    if (diaIso.length >= 10) {
      return '${diaIso.substring(8, 10)}/${diaIso.substring(5, 7)}/${diaIso.substring(0, 4)}';
    }
    return diaIso;
  }

  @override
  Widget build(BuildContext context) {
    final hoy = hoyHabanaIso();
    // Ronda 17 M1-H1: un no-dueño solo ve «Solo mías».
    final esDueno = AuthService().isOwner;
    final opsHoy = _ops.where((o) => _diaOp(o) == hoy).length;
    final pendientes =
        _ops.where((o) => '${o['estado']}' == 'pendiente').length;

    // v1.6.0: la lista respeta el filtro elegido (por defecto
    // «Otros y alertas»). La DETECCIÓN no cambia: _ops trae las
    // mismas 100 ops de siempre; esto solo filtra la presentación
    // por ACTOR (mías vs. de otro), no por dispositivo.
    final visibles = _ops
        .where((o) => opVisibleEnAuditoria(o, _filtro,
            miActor: _miActor, miTelegramId: _miTelegramId))
        .where((o) => !_soloHoy || _diaOp(o) == hoy)
        .where((o) => _actorFiltro == null || _usuario(o) == _actorFiltro)
        .toList();

    // Agrupar por día manteniendo el orden (ya viene DESC).
    final grupos = <String, List<Map<String, dynamic>>>{};
    for (final op in visibles) {
      final d = _diaOp(op);
      (grupos[d] ??= []).add(op);
    }
    final dias = grupos.keys.toList(); // ya en orden DESC

    return Scaffold(
      appBar: AppBar(
        title: const Text('Auditoría'),
        actions: [
          // v1.8.0: vista por persona (turnos, dinero, sensibles).
          IconButton(
            icon: const Icon(Icons.person_search_rounded),
            tooltip: 'Por persona',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AuditoriaPersonaScreen(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          // Tarjeta resumen.
          if (!_cargando && _ops.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Tarjeta(
                child: Row(
                  children: [
                    IconoModuloBadge.naranja(Icons.fact_check),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '$opsHoy operaciones hoy · $pendientes pendientes de sync',
                        style: AppTexto.subtitulo,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // v1.6.0 (Jc): selector de filtro, visible y cambiable
          // en un toque. La vista inicial es «Otros y alertas».
          if (!_cargando && _ops.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (esDueno) ...[
                      ChoiceChip(
                        label: const Text('Otros y alertas'),
                        selected:
                            _filtro == FiltroAuditoria.otrosYAlertas,
                        onSelected: (_) => setState(
                            () => _filtro = FiltroAuditoria.otrosYAlertas),
                      ),
                      const SizedBox(width: 8),
                      ChoiceChip(
                        label: const Text('Todo'),
                        selected: _filtro == FiltroAuditoria.todo,
                        onSelected: (_) =>
                            setState(() => _filtro = FiltroAuditoria.todo),
                      ),
                      const SizedBox(width: 8),
                    ],
                    ChoiceChip(
                      label: const Text('Solo mías'),
                      selected: _filtro == FiltroAuditoria.soloMias,
                      onSelected: (_) => setState(
                          () => _filtro = FiltroAuditoria.soloMias),
                    ),
                  ],
                ),
              ),
            ),
          // Módulo 6 (1.19): filtros rápidos — hoy y por entrenador.
          // Se combinan con el filtro de actor de arriba.
          if (!_cargando && _ops.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ChoiceChip(
                      label: const Text('Hoy'),
                      selected: _soloHoy,
                      onSelected: (_) =>
                          setState(() => _soloHoy = !_soloHoy),
                    ),
                    if (esDueno) ...[
                      const SizedBox(width: 8),
                      Builder(
                        builder: (chipCtx) => ChoiceChip(
                          label: Text(_actorFiltro ?? 'Por entrenador'),
                          selected: _actorFiltro != null,
                          onSelected: (_) async {
                            final actores = <String>{};
                            for (final o in _ops) {
                              final a = _usuario(o);
                              if (a.isNotEmpty) actores.add(a);
                            }
                            // Argón Gmail_1-14 #5: el menú se ancla
                            // al chip (RenderBox), no a una
                            // coordenada fija que se desfasa si la
                            // barra superior crece.
                            var position =
                                const RelativeRect.fromLTRB(
                                    12, 200, 100, 100);
                            final boton = chipCtx.findRenderObject()
                                as RenderBox?;
                            final overlay = Overlay.of(chipCtx)
                                .context
                                .findRenderObject() as RenderBox?;
                            if (boton != null && overlay != null) {
                              position = RelativeRect.fromRect(
                                Rect.fromPoints(
                                  boton.localToGlobal(Offset.zero,
                                      ancestor: overlay),
                                  boton.localToGlobal(
                                      boton.size.bottomRight(
                                          Offset.zero),
                                      ancestor: overlay),
                                ),
                                Offset.zero & overlay.size,
                              );
                            }
                            final elegido =
                                await showMenu<String>(
                              context: context,
                              position: position,
                              items: [
                                const PopupMenuItem(
                                    value: '',
                                    child: Text('Todos')),
                                for (final a in actores.toList()..sort())
                                  PopupMenuItem(
                                      value: a, child: Text(a)),
                              ],
                            );
                            // null = menú cerrado sin elegir: no se
                            // toca el filtro. '' = «Todos» (quitarlo).
                            if (elegido != null) {
                              setState(() {
                                _actorFiltro =
                                    elegido.isEmpty ? null : elegido;
                                // Argón Gmail_1-14 #3: «Solo mías»
                                // + otro entrenador = lista vacía
                                // sin explicación. Al elegir a otro
                                // actor, el filtro base pasa a todo.
                                if (elegido.isNotEmpty &&
                                    _filtro ==
                                        FiltroAuditoria.soloMias &&
                                    elegido != _miActor) {
                                  _filtro = FiltroAuditoria.todo;
                                }
                              });
                            }
                          },
                        ),
                      ),
                      if (_actorFiltro != null) ...[
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          tooltip: 'Quitar filtro',
                          onPressed: () =>
                              setState(() => _actorFiltro = null),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          Expanded(
            child: _cargando
                ? const EstadoCargando(texto: 'Cargando auditoría…')
                : _ops.isEmpty
                    ? EstadoVacio(
                        icono: Icons.fact_check,
                        titulo: 'Sin operaciones registradas',
                        textoAccion: 'Actualizar',
                        onAccion: _cargar,
                      )
                    : visibles.isEmpty
                        ? EstadoVacio(
                            icono: Icons.filter_alt_off_rounded,
                            titulo: 'Nada con este filtro',
                            // El texto describe el filtro ACTIVO,
                            // no siempre el de por defecto.
                            subtitulo: switch (_filtro) {
                              FiltroAuditoria.otrosYAlertas =>
                                'No hay operaciones de otros ni '
                                    'alertas en el registro reciente.',
                              FiltroAuditoria.soloMias =>
                                'No hay operaciones tuyas en el '
                                    'registro reciente.',
                              FiltroAuditoria.todo =>
                                'No hay operaciones en el registro '
                                    'reciente.',
                            },
                            textoAccion:
                                (_filtro == FiltroAuditoria.todo || !esDueno)
                                    ? null
                                    : 'Ver todo',
                            onAccion: (_filtro == FiltroAuditoria.todo ||
                                    !esDueno)
                                ? null
                                : () => setState(
                                    () => _filtro = FiltroAuditoria.todo),
                          )
                        : RefreshIndicator(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          itemCount: dias.length,
                          itemBuilder: (ctx, gi) {
                            final dia = dias[gi];
                            final items = grupos[dia]!;
                            return Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 12, 16, 4),
                                  child: Text(
                                    _etiquetaDia(dia),
                                    style: AppTexto.subtitulo.copyWith(
                                      color: AppColores.naranja,
                                    ),
                                  ),
                                ),
                                for (final op
                                    in items) _tarjetaOp(ctx, op),
                              ],
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _tarjetaOp(BuildContext ctx, Map<String, dynamic> op) {
    final tipo = '${op['tipo']}';
    final estado = '${op['estado']}';
    final fecha =
        fechaCorta(op['creada_ts'], 16).replaceAll('T', ' ');
    final detalle = _detalle(op);
    final usuario = _usuario(op);
    final p = _payload(op);
    final cid = _clienteId(p, tipo);
    final fotoPath = cid != null ? _fotos[cid] : null;
    final tieneFoto = fotoPath != null &&
        fotoPath.isNotEmpty &&
        File(fotoPath).existsSync();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Tarjeta(
        padding: EdgeInsets.zero,
        child: ListTile(
          leading: tieneFoto
              ? ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.file(
                    File(fotoPath),
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                  ),
                )
              : CircleAvatar(
                  child: Text(
                    usuario.isNotEmpty
                        ? usuario[0].toUpperCase()
                        : '?',
                  ),
                ),
          // v1.3.7: título en lenguaje humano, siempre con detalle.
          title: Text(_descripcionOp(tipo), style: AppTexto.subtitulo),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (detalle.isNotEmpty)
                Text(detalle,
                    style: AppTexto.cuerpo
                        .copyWith(fontWeight: FontWeight.w500)),
              Text('$usuario · $fecha', style: AppTexto.secundario),
              Text(
                _etiquetaEstado(estado),
                style: AppTexto.etiqueta.copyWith(
                  color: _colorEstado(estado),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          // Módulo 6 (1.19): salto al registro. Con cliente
          // identificado (y no protegido) abre su ficha; si no,
          // muestra el detalle completo de la operación.
          onTap: () => _abrirOp(ctx, op, cid),
        ),
      ),
    );
  }

  void _abrirOp(BuildContext ctx, Map<String, dynamic> op, int? cid) {
    if (cid != null && !_protegidosIds.contains(cid)) {
      Navigator.of(ctx).push(
        MaterialPageRoute(builder: (_) => FichaScreen(clienteId: cid)),
      );
      return;
    }
    final tipo = '${op['tipo']}';
    showDialog<void>(
      context: ctx,
      builder: (c) => AlertDialog(
        title: Text(_descripcionOp(tipo)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Actor: ${_usuario(op)}'),
              Text('Fecha: ${fechaCorta(op['creada_ts'], 16)}'
                  .replaceAll('T', ' ')),
              Text('Estado: ${_etiquetaEstado('${op['estado']}')}'),
              if (_detalle(op).isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(_detalle(op)),
              ],
              if (cid != null) ...[
                const SizedBox(height: 8),
                const Text('Cliente protegido: su ficha no se abre '
                    'desde aquí.'),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  String _etiquetaEstado(String estado) {
    switch (estado) {
      case 'aplicada':
        return 'Sincronizada';
      case 'pendiente':
        return 'Pendiente de sync';
      case 'rechazada':
        return 'Rechazada por el servidor';
      case 'error':
        return 'Error al subir';
      default:
        return estado;
    }
  }

  Color _colorEstado(String estado) {
    switch (estado) {
      case 'aplicada':
        return AppColores.exito;
      case 'rechazada':
      case 'error':
        return AppColores.error;
      default:
        return AppColores.alerta;
    }
  }
}

/// v1.3.7: traduce un tipo de op técnico a lenguaje humano.
/// Top-level para poder testearla.
String descripcionOp(String tipo) {
    switch (tipo) {
      case 'inscribir':
        return 'Inscripción de cliente';
      case 'pago_mensual':
        return 'Pago de mensualidad';
      case 'pago_diario':
        return 'Pago diario';
      case 'cambiar_estado':
        return 'Cambio de estado';
      case 'foto':
        return 'Foto de cliente';
      case 'gasto':
        return 'Gasto registrado';
      case 'editar_cliente':
        return 'Edición de cliente';
      case 'editar_pago':
        return 'Edición de pago';
      case 'anular_pago':
        return 'Pago anulado';
      case 'editar_pago_diario':
        return 'Edición de pago diario';
      case 'anular_pago_diario':
        return 'Pago diario anulado';
      case 'eliminar_cliente':
        return 'Cliente eliminado';
      case 'eliminar_foto':
        return 'Foto eliminada';
      case 'admin_usuario':
        return 'Gestión de usuario';
      case 'confirmar_entrega':
        return 'Entrega de efectivo confirmada';
      case 'regalar_mes_cumpleanos':
        return 'Mes de cumpleaños regalado';
      case 'apertura_turno':
        return 'Apertura de turno';
      case 'cierre_turno':
        return 'Cierre de turno';
      case 'liquidar_caja':
        return 'Caja liquidada (arqueo)';
      case 'aprobar_incidencia_sync':
        return 'Incidencia de sync aprobada';
      case 'descartar_incidencia_sync':
        return 'Incidencia de sync descartada';
      case 'crear_suplemento':
        return 'Suplemento creado';
      case 'editar_suplemento':
        return 'Suplemento editado';
      case 'eliminar_suplemento':
        return 'Suplemento eliminado';
      case 'venta_suplemento':
        return 'Venta de suplemento';
      case 'anular_venta_suplemento':
        return 'Venta de suplemento anulada';
      case 'foto_suplemento':
        return 'Foto de suplemento';
      case 'inscripcion_venta_suplemento':
        return 'Inscripción + venta de suplemento';
      case 'crear_categoria':
        return 'Categoría creada';
      case 'editar_categoria':
        return 'Categoría editada';
      case 'incidencia':
      case 'crear_incidencia':
        return 'Incidencia reportada';
      case 'editar_incidencia':
        return 'Incidencia editada';
      case 'cambiar_estado_incidencia':
        return 'Estado de incidencia cambiado';
      case 'incidencia_estado':
        return 'Cambio en incidencia';
      case 'agregar_comentario_incidencia':
        return 'Comentario en incidencia';
      case 'registrar_foto_incidencia':
        return 'Foto en incidencia';
      case 'upsert_tipo_incidencia':
        return 'Tipo de incidencia guardado';
      case 'reordenar_tipos_incidencia':
        return 'Tipos de incidencia reordenados';
      case 'guardar_tipos_pago':
        return 'Tipos de pago guardados';
      case 'ajuste':
        return 'Ajuste de configuración';
      case 'auditoria':
        return 'Nota de auditoría';
      default:
        return tipo.replaceAll('_', ' ');
    }
}
