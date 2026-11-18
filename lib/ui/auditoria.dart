/// Auditoría (v1.3.7): registro útil de quién hizo qué.
///
/// Rediseño: los tipos técnicos de operación se traducen a lenguaje
/// humano, siempre se muestra la persona afectada, y las operaciones
/// se agrupan por día con encabezados.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../actividad_cliente.dart' show ActividadClienteService;
import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'actividad_cliente.dart';
import 'app_bar.dart';
import 'auditoria_persona.dart';
import 'cola.dart' show etiquetaEstadoOp;
import 'diseno.dart';
import 'ficha.dart';
import 'componentes.dart';
import 'skeleton.dart';
import 'widgets.dart';
import '../app_log.dart';

/// v1.6.0 (pedido de Jc): filtro de la Auditoría. La pantalla ABRE
/// en [otrosYAlertas]: lo de OTROS actores más las operaciones
/// sensibles o rechazadas vengan de donde vengan; lo rutinario
/// propio no ocupa la vista inicial, pero queda a un toque en
/// «Todo» o «Solo mías».
enum FiltroAuditoria { otrosYAlertas, todo, soloMias }

/// SL-X2 (G08-7): la etiqueta de estado de una op en la
/// Auditoría. Las cuatro conocidas de esta pantalla
/// conservan su texto; TODAS las demás pasan por el
/// traductor de la casa ([etiquetaEstadoOp], en cola.dart)
/// — antes la rama por defecto devolvía la clave cruda
/// (`enviada`, `necesita_revision` salían tal cual a
/// pantalla). Lo que ni el traductor conoce se lee
/// «Estado registrado», nunca la clave.
String etiquetaEstadoAuditoria(String estado) {
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
      final traducida = etiquetaEstadoOp(estado);
      return traducida == estado ? 'Estado registrado' : traducida;
  }
}

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

/// 1.32 (Oleada 2 Fase 2 · G-80): resumen de la cabecera de
/// día de la Auditoría, con la plantilla del Día de Servicios:
/// cuántas operaciones VISIBLES trae el grupo y cuántas de
/// ellas son alerta (tipo sensible o estado de fallo, según
/// [esOpAlerta]). Función pura.
({int operaciones, int alertas}) resumenDiaAuditoria(
    List<Map<String, dynamic>> ops) {
  var alertas = 0;
  for (final op in ops) {
    if (esOpAlerta(op)) alertas++;
  }
  return (operaciones: ops.length, alertas: alertas);
}

/// Texto de totales de la cabecera de día (plantilla):
/// «N operaciones» y, solo si las hay, «· M alertas», con su
/// singular cuando toca. Función pura.
String textoTotalesDiaAuditoria(
    ({int operaciones, int alertas}) r) {
  final ops = r.operaciones == 1
      ? '1 operación'
      : '${r.operaciones} operaciones';
  if (r.alertas == 0) return ops;
  return '$ops · ${r.alertas} '
      'alerta${r.alertas == 1 ? '' : 's'}';
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
  // 1.25 T112: embebida = pestaña del Centro de control.
  final bool embebida;

  /// 1.29 (Oleada 8, FB-23): servicio de la sección
  /// «Actividad en la app de clientes» (costura de test;
  /// por defecto, el real contra la RPC).
  final ActividadClienteService? servicioActividad;
  const AuditoriaScreen(
      {super.key, this.embebida = false, this.servicioActividad});

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

  /// (1.36 H-B4 136-1019) existencia de la foto PRECARGADA
  /// en la carga (async), no existsSync por tarjeta en el
  /// build.
  final Set<int> _fotosExisten = {};
  // cliente_id de clientes protegidos (Ronda 17 M1-H2): de ellos
  // no se precarga nombre ni foto y _detalle no muestra datos.
  final Set<int> _protegidosIds = {};
  // Nombres normalizados (minúsculas) de clientes protegidos del
  // espejo: para ops cuyo payload NO trae cliente_id (inscribir),
  // donde la máscara por id no puede cubrir (Argón Gmail_1-14 #1).
  final Set<String> _protegidosNombres = {};
  // Espejo de clientes por id, cargado una vez por _cargar y
  // reutilizado por los bloques siguientes («Ver más»).
  Map<int, Map<String, dynamic>> _porId = {};
  bool _esDueno = false;

  // 1.29 (Oleada 6, FB-16): el río se carga POR BLOQUES con
  // cursor estable (creada_ts + rowid, LocalDb.opsAuditoriaBloque)
  // en vez del techo fijo de 100 de recentOps: en un día con
  // más de 100 operaciones, la mañana quedaba inalcanzable y
  // el contador de la tarjeta contaba solo lo cargado como si
  // fuera el día entero. [_totalHoy] es el denominador real.
  static const int _tamBloque = 100;
  ({String ts, int rowid})? _cursor;
  bool _hayMas = false;
  bool _cargandoMas = false;
  int _totalHoy = 0;

  // 1.29 (Oleada 6, FB-16): búsqueda por nombre de cliente o
  // tipo dentro de lo CARGADO (no promete lo que aún no bajó:
  // el botón «Ver más antiguas» amplía el universo buscable).
  final _busquedaCtrl = TextEditingController();
  String _busqueda = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
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
    _esDueno = false;
    try {
      _esDueno = AuthService().isOwner;
    } catch (_) {
      _esDueno = false;
    }
    // Precargar nombres y fotos de clientes mencionados
    final clientes = await LocalDb.instance.allMirror('clientes');
    _porId = <int, Map<String, dynamic>>{
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
    // FB-16: el denominador de hoy, sobre el universo visible
    // de esta pantalla (para el no-dueño, solo SUS ops de hoy:
    // la firma de actor no es SQL, se cuenta en Dart).
    final hoy = hoyHabanaIso();
    if (_esDueno) {
      _totalHoy = await LocalDb.instance.contarOpsDelDia(hoy);
    } else {
      final delDia = await LocalDb.instance.opsDelDia(hoy);
      _totalHoy = delDia
          .where((o) => esOpMia(o,
              miActor: _miActor, miTelegramId: _miTelegramId))
          .length;
    }
    _ops = [];
    _cursor = null;
    _hayMas = false;
    await _cargarBloque();
    if (mounted) {
      setState(() {
        if (!_esDueno) _filtro = FiltroAuditoria.soloMias;
        _cargando = false;
      });
    }
  }

  /// FB-16: trae el siguiente bloque del río y lo ANEXA a lo
  /// cargado. El cursor avanza sobre el río CRUDO (antes del
  /// recorte del no-dueño): si avanzara sobre lo visible, un
  /// bloque entero de ops ajenas dejaría el cursor quieto y
  /// «Ver más» giraría en vacío.
  Future<void> _cargarBloque() async {
    final crudas = await LocalDb.instance
        .opsAuditoriaBloque(cursor: _cursor, limite: _tamBloque);
    if (crudas.isNotEmpty) {
      final ultima = crudas.last;
      _cursor = (
        ts: '${ultima['creada_ts'] ?? ''}',
        rowid: (ultima['_rowid'] as num?)?.toInt() ?? 0,
      );
    }
    _hayMas = crudas.length >= _tamBloque;
    // Recorte en carga para no-dueños: así ni los contadores
    // cuentan operaciones ajenas.
    final visibles = _esDueno
        ? crudas
        : crudas
            .where((o) => esOpMia(o,
                miActor: _miActor, miTelegramId: _miTelegramId))
            .toList();
    _precargarNombres(visibles);
    await _refrescarExistenciaFotos();
    _ops = [..._ops, ...visibles];
  }

  Future<void> _verMas() async {
    if (_cargandoMas || !_hayMas) return;
    setState(() => _cargandoMas = true);
    await _cargarBloque();
    if (mounted) setState(() => _cargandoMas = false);
  }

  /// (1.36 H-B4 136-1019) verifica en disco (async) las
  /// fotos precargadas que aún no se han comprobado.
  Future<void> _refrescarExistenciaFotos() async {
    for (final e in _fotos.entries) {
      final ruta = e.value;
      if (ruta == null || ruta.isEmpty) continue;
      if (_fotosExisten.contains(e.key)) continue;
      try {
        if (await File(ruta).exists()) _fotosExisten.add(e.key);
      } catch (_) {}
    }
  }

  /// Precarga nombre/foto de los clientes que mencionan las
  /// ops [ops] (las de un bloque recién llegado).
  void _precargarNombres(List<Map<String, dynamic>> ops) {
    for (final op in ops) {
      final p = _payload(op);
      final cid = _clienteId(p, '${op['tipo']}');
      if (cid != null &&
          !_nombres.containsKey(cid) &&
          !_protegidosIds.contains(cid)) {
        final c = _porId[cid];
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
        // 1.25 Panel 9: con foto «antes», la fila enseña el
        // cambio con valores (antes → después).
        final lineasAD = lineasAntesDespues(p);
        if (lineasAD.isNotEmpty) {
          final q = ' (${lineasAD.join('; ')})';
          return nombre != null ? 'Editó a $nombre$q' : 'Edición$q';
        }
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

  // 1.34 (C-48 · G-01): los filtros de la Auditoría van
  // PLEGADOS — regla de diseño de Jc: nada de regueros de
  // opciones sueltas ocupando espacio permanente. Las dos
  // filas de chips (alcance + recortes) se resumen en UN botón
  // en la fila del buscador que nombra el estado vigente y
  // abre la hoja de filtros (molde de Actividad).
  String _etiquetaAlcance(FiltroAuditoria f) => switch (f) {
        FiltroAuditoria.otrosYAlertas => 'Otros y alertas',
        FiltroAuditoria.todo => 'Todo',
        FiltroAuditoria.soloMias => 'Solo mías',
      };

  String _resumenFiltrosAuditoria() => resumenFiltrosAuditoriaTxt(
        alcance: _etiquetaAlcance(_filtro),
        soloHoy: _soloHoy,
        actor: _actorFiltro,
      );

  Widget _botonFiltrosAuditoria(bool esDueno) {
    return OutlinedButton.icon(
      icon: const Icon(Icons.filter_list_rounded, size: 16),
      // Yunque 1.34 (C2-5): la etiqueta-resumen admite 2
      // líneas en los seis botones de filtros plegados — a
      // 360 dp con texto 1.3 la cola (rango, actor) se
      // elidía y el botón dejaba de nombrar el estado.
      label: Text(_resumenFiltrosAuditoria(),
          style: AppTexto.metadato,
          maxLines: 2,
          overflow: TextOverflow.ellipsis),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.md, vertical: AppEspacio.sm),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadio.lg),
        ),
      ),
      onPressed: () => _abrirFiltrosAuditoria(esDueno),
    );
  }

  Future<void> _abrirFiltrosAuditoria(bool esDueno) async {
    final actores = <String>{};
    for (final o in _ops) {
      final a = _usuario(o);
      if (a.isNotEmpty) actores.add(a);
    }
    final r = await showModalBottomSheet<
        ({FiltroAuditoria alcance, bool soloHoy, String? actor})>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadio.xl)),
      ),
      builder: (ctx) => _HojaFiltrosAuditoria(
        alcance: _filtro,
        soloHoy: _soloHoy,
        actor: _actorFiltro,
        esDueno: esDueno,
        actores: actores.toList()..sort(),
        miActor: _miActor,
      ),
    );
    if (r == null || !mounted) return;
    setState(() {
      _soloHoy = r.soloHoy;
      _actorFiltro = r.actor;
      // Argón Gmail_1-14 #3: «Solo mías» + otro entrenador =
      // lista vacía sin explicación; al filtrar por otro
      // actor el alcance pasa a «Todo». Yunque 2.34 (F-8):
      // la hoja ya resuelve A LA VISTA con esta misma regla
      // (alcanceAlElegirActor); esto queda como segunda
      // puerta, no como corrección silenciosa.
      _filtro = alcanceAlElegirActor(
          alcance: r.alcance, actorElegido: r.actor, miActor: _miActor);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hoy = hoyHabanaIso();
    // Ronda 17 M1-H1: un no-dueño solo ve «Solo mías».
    // (1.36 H-B4 136-1017) manda el _esDueno calculado en
    // la carga, no una re-lectura de sesión en cada build.
    final esDueno = _esDueno;
    final opsHoy = _ops.where((o) => _diaOp(o) == hoy).length;
    final pendientes =
        _ops.where((o) => '${o['estado']}' == 'pendiente').length;

    // v1.6.0: la lista respeta el filtro elegido (por defecto
    // «Otros y alertas»); esto solo filtra la presentación por
    // ACTOR (mías vs. de otro), no por dispositivo. 1.29
    // (FB-16): _ops crece POR BLOQUES con «Ver más antiguas»
    // (ya no hay techo de 100) y la búsqueda mira dentro de
    // lo cargado (detalle con el nombre del cliente y la
    // descripción del tipo).
    final busq = _busqueda.trim().toLowerCase();
    final visibles = _ops
        .where((o) => opVisibleEnAuditoria(o, _filtro,
            miActor: _miActor, miTelegramId: _miTelegramId))
        .where((o) => !_soloHoy || _diaOp(o) == hoy)
        .where((o) => _actorFiltro == null || _usuario(o) == _actorFiltro)
        .where((o) =>
            busq.isEmpty ||
            _detalle(o).toLowerCase().contains(busq) ||
            _descripcionOp('${o['tipo']}').toLowerCase().contains(busq))
        .toList();

    // Agrupar por día manteniendo el orden (ya viene DESC).
    final grupos = <String, List<Map<String, dynamic>>>{};
    for (final op in visibles) {
      final d = _diaOp(op);
      (grupos[d] ??= []).add(op);
    }
    final dias = grupos.keys.toList(); // ya en orden DESC

    return Scaffold(
      appBar: widget.embebida
          ? null
          : appBarIron(
        context,
        'Auditoría',
        acciones: [
          // v1.8.0: vista por persona (turnos, dinero, sensibles).
          IconButton(
            icon: const Icon(Icons.person_search_rounded),
            tooltip: 'Por persona',
            onPressed: () => Navigator.of(context).push(
              RutaIron(
                builder: (_) => const AuditoriaPersonaScreen(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
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
                    IconoModuloBadge.naranja(Icons.fact_check_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        // 1.29 (FB-16): contador HONESTO —
                        // «viendo N de M de hoy»: N = las de
                        // hoy ya cargadas, M = las de hoy que
                        // existen. Antes decía «N operaciones
                        // hoy» contando solo las 100 cargadas.
                        'Viendo $opsHoy de $_totalHoy de hoy · '
                        '$pendientes pendientes de sync',
                        style: AppTexto.subtitulo,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 1.29 (Oleada 6, FB-16): búsqueda por nombre de
          // cliente o tipo dentro de lo cargado.
          if (!_cargando && _ops.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                controller: _busquedaCtrl,
                decoration: InputDecoration(
                  hintText: 'Buscar por cliente o tipo…',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _busqueda.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () {
                            _busquedaCtrl.clear();
                            setState(() => _busqueda = '');
                          },
                        ),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _busqueda = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(child: _botonFiltrosAuditoria(esDueno)),
                ],
              ),
            ),
          Expanded(
            // 1.29 (Oleada 8, FB-23): con el registro vacío
            // o filtrado a cero, la sección de actividad del
            // servidor va BAJO el estado vacío en un scroll
            // propio (con filas vive como último ítem de la
            // lista del registro: un solo scroll, sin
            // anidados).
            // 1.34 Campo 2 (P-7): el RefrescoIron envuelve
            // TODAS las ramas (vacío incluido): antes solo
            // la lista con filas lo tenía y en los vacíos
            // el gesto moría sin indicador ni recarga.
            child: RefrescoIron(
              onRefresh: _cargar,
              child: _sinFilasVisibles(_cargando, visibles)
                ? SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Sin acotar: el estado vacío se pinta
                        // a su alto natural DENTRO del scroll
                        // (acotarlo en un SizedBox desbordaba
                        // su Column interna).
                        _cuerpoRegistroVacio(),
                        if (esDueno)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                                12, 12, 12, 24),
                            child: SeccionActividadAppClientes(
                              servicio: widget.servicioActividad,
                            ),
                          ),
                      ],
                    ),
                  )
                : _cargando
                // 1.25 T114: esqueleto con la forma de la lista.
                // (Las ramas vacías de esta cadena ya no se
                // alcanzan — las captura _sinFilasVisibles —
                // pero se conservan como red de seguridad.)
                ? const Padding(
                    padding: EdgeInsets.all(AppEspacio.lg),
                    child: SkeletonLista(items: 4))
                : _ops.isEmpty
                    ? EstadoVacio(
                        icono: Icons.fact_check_rounded,
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
                        : ListView.builder(
                          // FB-16: los primeros ítems son los
                          // grupos por día; después, mientras
                          // el río tenga más bloques, el botón
                          // «Ver más antiguas» y, al final de
                          // todo, la sección FB-23 de actividad
                          // del servidor (solo dueño): vive
                          // DENTRO de esta lista para heredar su
                          // único scroll — un scroll exterior
                          // con la lista acotada dentro dejaba
                          // el botón fuera del área desplazable
                          // y los toques caían en la tarjeta.
                          itemCount: dias.length +
                              (_hayMas ? 1 : 0) +
                              (esDueno ? 1 : 0),
                          itemBuilder: (ctx, gi) {
                            if (gi < dias.length) {
                              final dia = dias[gi];
                              final items = grupos[dia]!;
                              return Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  // G-80: cabecera de día de
                                  // la plantilla de Servicios —
                                  // el día a la izquierda y los
                                  // totales del grupo visible a
                                  // la derecha.
                                  Padding(
                                    padding:
                                        const EdgeInsets.fromLTRB(
                                            16, 12, 16, 4),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.baseline,
                                      textBaseline:
                                          TextBaseline.alphabetic,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            _etiquetaDia(dia),
                                            style: AppTexto.subtitulo,
                                          ),
                                        ),
                                        Text(
                                          textoTotalesDiaAuditoria(
                                              resumenDiaAuditoria(
                                                  items)),
                                          style: AppTexto.metadato,
                                        ),
                                      ],
                                    ),
                                  ),
                                  for (final op in items)
                                    _tarjetaOp(ctx, op),
                                ],
                              );
                            }
                            if (_hayMas && gi == dias.length) {
                              return Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    16, 8, 16, 24),
                                child: OutlinedButton.icon(
                                  onPressed:
                                      _cargandoMas ? null : _verMas,
                                  icon: _cargandoMas
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child:
                                              CircularProgressIndicator(
                                                  strokeWidth: 2))
                                      : const Icon(Icons
                                          .expand_more_rounded),
                                  label: const Text('Ver más antiguas'),
                                  style: OutlinedButton.styleFrom(
                                    minimumSize:
                                        const Size.fromHeight(48),
                                  ),
                                ),
                              );
                            }
                            // FB-23: la actividad que la app de
                            // Clientes deja en el SERVIDOR, como
                            // sección propia al final del
                            // registro local. Solo dueño (la
                            // sección misma también se guarda)
                            // y sin bloquear nada del registro:
                            // es otra fuente.
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  12, 12, 12, 24),
                              child: SeccionActividadAppClientes(
                                servicio: widget.servicioActividad,
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  /// ¿El registro no tiene filas que listar? (cargando, sin
  /// ops o filtro sin resultados): la rama vacía y la de
  /// filas pintan árboles distintos — esta decide cuál, y
  /// [_cuerpoRegistroVacio] pinta la vacía.
  bool _sinFilasVisibles(
          bool cargando, List<Map<String, dynamic>> visibles) =>
      cargando || _ops.isEmpty || visibles.isEmpty;

  /// El cuerpo del registro cuando no hay filas que listar:
  /// esqueleto cargando, vacío total o vacío por filtro,
  /// con los textos de siempre.
  Widget _cuerpoRegistroVacio() {
    if (_cargando) {
      // 1.25 T114: esqueleto con la forma de la lista.
      return const Padding(
          padding: EdgeInsets.all(AppEspacio.lg),
          child: SkeletonLista(items: 4));
    }
    if (_ops.isEmpty) {
      return EstadoVacio(
        icono: Icons.fact_check_rounded,
        titulo: 'Sin operaciones registradas',
        textoAccion: 'Actualizar',
        onAccion: _cargar,
      );
    }
    final esDueno = _esDueno;
    return EstadoVacio(
      icono: Icons.filter_alt_off_rounded,
      titulo: 'Nada con este filtro',
      // El texto describe el filtro ACTIVO, no siempre el
      // de por defecto.
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
      onAccion: (_filtro == FiltroAuditoria.todo || !esDueno)
          ? null
          : () => setState(() => _filtro = FiltroAuditoria.todo),
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
    // (1.36 H-B4 136-1019) existencia precargada en carga.
    final tieneFoto = cid != null && _fotosExisten.contains(cid);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppEspacio.md, vertical: AppEspacio.sm),
      child: Tarjeta(
        padding: EdgeInsets.zero,
        // 1.29 (Oleada 6): Material propio y transparente —
        // el ListTile quedaba bajo el DecoratedBox de la
        // Tarjeta sin un Material intermedio: su tinta no
        // se pintaba y el chequeo del framework lo marca
        // como error.
        child: Material(
          type: MaterialType.transparency,
          child: ListTile(
          // (1.36 H-B4 136-1019) el leading es SIEMPRE el
          // actor (su inicial): la foto del cliente va como
          // chip aparte a la derecha, no le roba el sitio.
          leading: CircleAvatar(
            child: Text(
              usuario.isNotEmpty
                  ? usuario[0].toUpperCase()
                  : '?',
            ),
          ),
          trailing: tieneFoto
              ? Tooltip(
                  message: 'Cliente',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Image.file(
                      File(fotoPath!),
                      width: 32,
                      height: 32,
                      cacheWidth: 96,
                      fit: BoxFit.cover,
                      // Si el archivo desapareció tras la
                      // precarga, el chip se retira solo.
                      errorBuilder: (_, __, ___) =>
                          const SizedBox.shrink(),
                    ),
                  ),
                )
              : null,
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
      ),
    );
  }

  void _abrirOp(BuildContext ctx, Map<String, dynamic> op, int? cid) {
    if (cid != null && !_protegidosIds.contains(cid)) {
      Navigator.of(ctx).push(
        RutaIron(builder: (_) => FichaScreen(clienteId: cid)),
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

  String _etiquetaEstado(String estado) =>
      etiquetaEstadoAuditoria(estado);

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

/// 1.25 Panel 9: líneas «campo: antes → después» de una op
/// editar_cliente cuyo payload trae la foto 'antes'
/// (capturada al editar con [antesEdicionCliente]). Las ops
/// viejas no la traen: sin líneas, la fila se describe como
/// siempre. Valores vacíos se leen «—»; los largos se
/// recortan (la fila no es sitio para una nota entera).
List<String> lineasAntesDespues(Map<String, dynamic> payload) {
  final antes = payload['antes'];
  if (antes is! Map) return const [];
  const etiquetas = {
    'nombre': 'nombre',
    'telefono': 'teléfono',
    'carnet': 'carnet',
    'sexo': 'sexo',
    'notas': 'notas',
    'pagado_hasta': 'vencimiento',
  };
  String fmt(Object? v) {
    final t = '${v ?? ''}'.trim();
    if (t.isEmpty) return '—';
    return t.length > 40 ? '${t.substring(0, 40)}…' : t;
  }

  return [
    for (final e in etiquetas.entries)
      if (antes.containsKey(e.key))
        '${e.value}: ${fmt(antes[e.key])} → ${fmt(payload[e.key])}',
  ];
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

/// 1.34 (C-48 · G-01): hoja de filtros de la Auditoría.
/// Trabaja sobre una copia temporal: nada se aplica hasta
/// tocar «Aplicar» (que devuelve el trío por el Navigator);
/// «Limpiar» devuelve la copia a los valores por defecto.
class _HojaFiltrosAuditoria extends StatefulWidget {
  final FiltroAuditoria alcance;
  final bool soloHoy;
  final String? actor;
  final bool esDueno;
  final List<String> actores;
  final String? miActor;

  const _HojaFiltrosAuditoria({
    required this.alcance,
    required this.soloHoy,
    required this.actor,
    required this.esDueno,
    required this.actores,
    required this.miActor,
  });

  @override
  State<_HojaFiltrosAuditoria> createState() =>
      _HojaFiltrosAuditoriaState();
}

class _HojaFiltrosAuditoriaState extends State<_HojaFiltrosAuditoria> {
  late FiltroAuditoria _alcance = widget.alcance;
  late bool _soloHoy = widget.soloHoy;
  late String? _actor = widget.actor;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppEspacio.lg, AppEspacio.md, AppEspacio.lg, AppEspacio.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Filtros', style: AppTexto.subtitulo),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  tooltip: 'Cerrar',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            const Text('Alcance', style: AppTexto.etiqueta),
            RadioGroup<FiltroAuditoria>(
              groupValue: _alcance,
              // Yunque 3 (K3-3): la regla de F-8 también al
              // revés — si con un actor ajeno elegido se toca
              // el radio «Solo mías», el actor se limpia A LA
              // VISTA (el chip «Todos» se marca en el acto);
              // antes la contradicción quedaba visible y el
              // padre la corregía en silencio al Aplicar.
              onChanged: (v) => setState(() {
                if (v == null) return;
                final r = alcanceAlElegirAlcance(
                    nuevoAlcance: v,
                    actorElegido: _actor,
                    miActor: widget.miActor);
                _alcance = r.alcance;
                _actor = r.actor;
              }),
              child: Column(
                children: [
                  if (widget.esDueno) ...[
                    const RadioListTile<FiltroAuditoria>(
                      value: FiltroAuditoria.otrosYAlertas,
                      title: Text('Otros y alertas'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                    const RadioListTile<FiltroAuditoria>(
                      value: FiltroAuditoria.todo,
                      title: Text('Todo'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                  const RadioListTile<FiltroAuditoria>(
                    value: FiltroAuditoria.soloMias,
                    title: Text('Solo mías'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppEspacio.md),
            const Text('Recorte', style: AppTexto.etiqueta),
            SwitchListTile(
              value: _soloHoy,
              onChanged: (v) => setState(() => _soloHoy = v),
              title: const Text('Solo hoy'),
              dense: true,
              contentPadding: EdgeInsets.zero,
            ),
            if (widget.esDueno && widget.actores.isNotEmpty) ...[
              const SizedBox(height: AppEspacio.sm),
              const Text('Entrenador', style: AppTexto.etiqueta),
              const SizedBox(height: AppEspacio.sm),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Todos'),
                    selected: _actor == null,
                    onSelected: (_) => setState(() => _actor = null),
                  ),
                  for (final a in widget.actores)
                    ChoiceChip(
                      label: Text(a),
                      selected: _actor == a,
                      // Yunque 2.34 (F-8): al elegir un actor
                      // ajeno con «Solo mías» puesto, el
                      // alcance pasa a «Todo» A LA VISTA (el
                      // radio se mueve en el acto): antes la
                      // hoja devolvía la combinación imposible
                      // y el padre la corregía en silencio al
                      // aplicar.
                      onSelected: (_) => setState(() {
                        _actor = a;
                        _alcance = alcanceAlElegirActor(
                            alcance: _alcance,
                            actorElegido: a,
                            miActor: widget.miActor);
                      }),
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppEspacio.lg),
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(() {
                    _alcance = widget.esDueno
                        ? FiltroAuditoria.otrosYAlertas
                        : FiltroAuditoria.soloMias;
                    _soloHoy = false;
                    _actor = null;
                  }),
                  child: const Text('Limpiar'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop((
                    alcance: _alcance,
                    soloHoy: _soloHoy,
                    actor: _actor,
                  )),
                  child: const Text('Aplicar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Yunque 2.34 (F-7): resumen del botón de filtros de
/// Auditoría con gramática corta — el actor entra por su
/// primera palabra (un nombre completo se comía la cola a
/// 360 dp × 1.3 y el resumen dejaba de nombrar el estado).
/// PURO.
String resumenFiltrosAuditoriaTxt({
  required String alcance,
  required bool soloHoy,
  required String? actor,
}) {
  // Yunque 3 (K3-5): con actor en el resumen, «Otros y
  // alertas» se acorta a «Otros» — con la categoría larga el
  // actor caía a una 3ª línea y se elidía. Sin actor, la
  // categoría va entera.
  final alcanceTxt =
      (actor != null && alcance == 'Otros y alertas') ? 'Otros' : alcance;
  final partes = <String>['Filtrar', alcanceTxt];
  if (soloHoy) partes.add('Hoy');
  if (actor != null) {
    // Yunque 3 (K3-6): los actores sintéticos de actorDeOp
    // («Este dispositivo» / «Otro usuario») van ENTEROS —
    // su primera palabra («Este» / «Otro») se lee como el
    // nombre de una persona y no nombra el estado real.
    // Yunque 4 (L3-3): con «Hoy» además, el sintético
    // entero no cabe a escala 1,3 en las 2 líneas del botón
    // (medido: 251/227 px contra 232 de presupuesto) y el
    // ellipsis se comía justo la palabra salvada por K3-6;
    // solo en esa combinación el sintético se abrevia —
    // sin «Hoy» sigue entero.
    final sintetico =
        actor == 'Este dispositivo' || actor == 'Otro usuario';
    if (sintetico && soloHoy) {
      partes.add(
          actor == 'Este dispositivo' ? 'Este disp.' : 'Otro usu.');
    } else {
      partes.add(sintetico ? actor : primeraPalabraResumen(actor));
    }
  }
  return partes.join(' · ');
}

/// Yunque 2.34 (F-8): la regla «Solo mías» + actor ajeno =
/// «Todo», en UN solo sitio. La usan la hoja de filtros (a
/// la vista, al tocar el chip del actor) y la pantalla (como
/// segunda puerta al aplicar). PURO.
FiltroAuditoria alcanceAlElegirActor({
  required FiltroAuditoria alcance,
  required String? actorElegido,
  required String? miActor,
}) {
  if (actorElegido != null &&
      actorElegido.isNotEmpty &&
      actorElegido != miActor &&
      alcance == FiltroAuditoria.soloMias) {
    return FiltroAuditoria.todo;
  }
  return alcance;
}

/// Yunque 3 (K3-3): la dirección inversa de
/// [alcanceAlElegirActor] — al elegir el ALCANCE por el
/// radio, si el nuevo alcance es «Solo mías» y hay un actor
/// AJENO elegido, el actor se limpia (null = chip «Todos»);
/// con el actor propio o sin actor, la elección se respeta
/// tal cual. PURO.
({FiltroAuditoria alcance, String? actor}) alcanceAlElegirAlcance({
  required FiltroAuditoria nuevoAlcance,
  required String? actorElegido,
  required String? miActor,
}) {
  if (nuevoAlcance == FiltroAuditoria.soloMias &&
      actorElegido != null &&
      actorElegido.isNotEmpty &&
      actorElegido != miActor) {
    return (alcance: nuevoAlcance, actor: null);
  }
  return (alcance: nuevoAlcance, actor: actorElegido);
}
