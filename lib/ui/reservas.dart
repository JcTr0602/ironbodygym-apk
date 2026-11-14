import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../permisos_entrenador.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'dialogo_pago.dart' show metodosAceptadosEfectivos;
import 'diseno.dart';
import '../app_log.dart';

/// Reservas v2 — bandeja del gimnasio.
///
/// Lee el espejo `reservas` (proyección que publica el puente
/// desde gym.db, la autoridad) y actúa con ops de la cola:
/// confirmar_reserva / rechazar_reserva / cancelar_reserva /
/// cobrar_reserva (las 4 mapeadas a can_vender_suplementos en
/// el servidor). El estado que se muestra es SIEMPRE el del
/// servidor: nada de escrituras optimistas en el espejo — si
/// una reserva tiene una op encolada, su tarjeta lo dice y los
/// botones se bloquean hasta que la sincronización la resuelva.

// ------------------------------------------------------------------
// Helpers puros (tests en test/reservas_test.dart)
// ------------------------------------------------------------------

class ReservaVista {
  final int id;
  final int clienteId;
  final String clienteNombre;
  final int suplementoId;
  final String suplementoNombre;
  final int cantidad;
  final double precioUnitario;
  final double? precioVigente;
  // v1.4.6: moneda snapshot de la reserva (la de la foto de
  // precio al reservar), no la del catálogo actual.
  final String moneda;
  // v1.4.6: moneda ACTUAL del suplemento en el catálogo. Si
  // difiere de [moneda] (el dueño cambió la moneda del producto
  // tras crearse la reserva), el precio vigente NO es comparable
  // con el snapshot: no hay diferencia numérica válida.
  final String monedaVigente;
  final String estado;
  final String creadaTs;
  final String? expiraEn;
  final String? notaResolucion;
  // R3 (estéticas 1.19): fotos para la tarjeta (opcionales; la
  // tarjeta muestra iniciales/icono cuando no hay).
  final String? fotoClienteLocal;
  final String? fotoClienteStorage;
  final String? fotoSuplementoLocal;
  final String? fotoSuplementoStorage;

  const ReservaVista({
    required this.id,
    required this.clienteId,
    required this.clienteNombre,
    required this.suplementoId,
    required this.suplementoNombre,
    required this.cantidad,
    required this.precioUnitario,
    required this.precioVigente,
    this.moneda = 'CUP',
    this.monedaVigente = 'CUP',
    required this.estado,
    required this.creadaTs,
    required this.expiraEn,
    required this.notaResolucion,
    this.fotoClienteLocal,
    this.fotoClienteStorage,
    this.fotoSuplementoLocal,
    this.fotoSuplementoStorage,
  });

  double get totalFoto => cantidad * precioUnitario;

  /// 1.29 (Oleada 2, D-B2-03): apartado cuyo vencimiento
  /// ya pasó pero el espejo aún lo trae como 'reservada'
  /// (el servidor lo libera en su barrido; entre tanto la
  /// fila sigue aquí). Un apartado así NO se puede cobrar:
  /// cobrarlo encolaría un cobro que el servidor va a
  /// rechazar por expirado. Solo aplica a 'reservada'
  /// (las solicitadas no tienen stock apartado).
  bool apartadoVencido(DateTime ahora) {
    if (estado != 'reservada') return false;
    final vence = expiraEn == null ? null : DateTime.tryParse(expiraEn!);
    return vence != null && vence.isBefore(ahora);
  }

  /// Yunque B (YB-SER-07): SOLICITUD cuyo plazo ya pasó pero
  /// el espejo aún la trae como 'solicitada' (el servidor la
  /// expira en su barrido). Confirmarla encolaría un
  /// confirmar_reserva condenado al rebote por expirada, con
  /// el cliente esperando respuesta — la reservada vencida
  /// tenía su defensa en tres capas (apartadoVencido) y la
  /// solicitada no tenía ninguna.
  bool solicitudVencida(DateTime ahora) {
    if (estado != 'solicitada') return false;
    final vence = expiraEn == null ? null : DateTime.tryParse(expiraEn!);
    return vence != null && vence.isBefore(ahora);
  }

  /// Diferencia total contra el precio vigente del catálogo
  /// (null si el suplemento ya no está en el espejo, o si la
  /// moneda del catálogo difiere de la snapshot: restar unidades
  /// incompatibles fabricaría una diferencia falsa).
  double? get diferenciaTotal => precioVigente == null ||
          monedaVigente != moneda
      ? null
      : (precioVigente! - precioUnitario) * cantidad;
}

class BandejaReservas {
  final List<ReservaVista> solicitadas;
  final List<ReservaVista> reservadas;
  final List<ReservaVista> historial;
  const BandejaReservas(this.solicitadas, this.reservadas, this.historial);
}

int _entero(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
double _doble(dynamic v) =>
    v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

/// Arma la bandeja desde los espejos: solicitadas en orden de
/// llegada (FIFO), reservadas por vencimiento más cercano,
/// historial (terminales) reciente primero, tope 30.
/// Argón P3#4: si no es dueño, se filtran las reservas de clientes
/// protegidos (la bandeja no debe revelar ni su existencia).
BandejaReservas construirBandeja(
  List<Map<String, dynamic>> reservas,
  List<Map<String, dynamic>> clientes,
  List<Map<String, dynamic>> suplementos, {
  bool esDueno = true,
}) {
  final clientePorId = {
    for (final c in clientes) _entero(c['id']): c,
  };
  final reservasVisibles = esDueno
      ? reservas
      : [
          for (final r in reservas)
            if (!esVistaProtegida(
                clientePorId[_entero(r['cliente_id'])] ?? {},
                esDueno: esDueno))
              r,
        ];
  final nombreCliente = {
    for (final c in clientes) _entero(c['id']): '${c['nombre'] ?? ''}',
  };
  final suplPorId = {
    for (final s in suplementos) _entero(s['id']): s,
  };
  ReservaVista vista(Map<String, dynamic> r) {
    final sid = _entero(r['suplemento_id']);
    final supl = suplPorId[sid];
    final cli = clientePorId[_entero(r['cliente_id'])];
    return ReservaVista(
      id: _entero(r['id']),
      clienteId: _entero(r['cliente_id']),
      clienteNombre:
          nombreCliente[_entero(r['cliente_id'])] ?? 'Cliente #${r['cliente_id']}',
      suplementoId: sid,
      suplementoNombre:
          supl?['nombre']?.toString() ?? 'Suplemento #$sid',
      cantidad: _entero(r['cantidad']),
      precioUnitario: _doble(r['precio_unitario']),
      // v1.4.6: moneda snapshot que trae la propia reserva.
      moneda: LocalDb.monedaDe(r),
      // v1.4.6: moneda vigente del catálogo; sin suplemento en
      // el espejo, la del snapshot (nada con qué comparar).
      monedaVigente:
          supl == null ? LocalDb.monedaDe(r) : LocalDb.monedaDe(supl),
      precioVigente:
          supl == null ? null : _doble(supl['precio_oficial']),
      estado: '${r['estado'] ?? ''}',
      creadaTs: '${r['creada_ts'] ?? ''}',
      expiraEn: r['expira_en']?.toString(),
      notaResolucion: r['nota_resolucion']?.toString(),
      // R3 (estéticas 1.19): fotos para la tarjeta.
      fotoClienteLocal: cli?['foto_local']?.toString(),
      fotoClienteStorage: cli?['foto_storage']?.toString(),
      fotoSuplementoLocal: supl?['foto_local']?.toString(),
      fotoSuplementoStorage: supl?['foto_storage']?.toString(),
    );
  }

  final todas = [for (final r in reservasVisibles) vista(r)];
  final solicitadas = [
    for (final v in todas)
      if (v.estado == 'solicitada') v
  ]..sort((a, b) => a.creadaTs.compareTo(b.creadaTs));
  final reservadas = [
    for (final v in todas)
      if (v.estado == 'reservada') v
  ]..sort((a, b) => (a.expiraEn ?? '9999').compareTo(b.expiraEn ?? '9999'));
  final historial = [
    for (final v in todas)
      if (v.estado != 'solicitada' && v.estado != 'reservada') v
  ]..sort((a, b) => b.creadaTs.compareTo(a.creadaTs));
  return BandejaReservas(
      solicitadas, reservadas, historial.take(30).toList());
}

const tiposOpReserva = {
  'confirmar_reserva',
  'rechazar_reserva',
  'cancelar_reserva',
  'cobrar_reserva',
};

/// Yunque B (YB-SER-06): conteo de reservas SOLICITADAS
/// visibles para quien mira, con el MISMO filtro de
/// protegidos de [construirBandeja]. El contador de la
/// pestaña de Suplementos contaba todas las del espejo y la
/// insignia del entrenador («3») no cuadraba con su bandeja
/// («2»): el número solo ya revelaba que existía una
/// solicitud más, de un cliente protegido. Función pura.
int contarSolicitadasVisibles(
  List<Map<String, dynamic>> reservas,
  List<Map<String, dynamic>> clientes, {
  bool esDueno = true,
}) {
  final clientePorId = {
    for (final c in clientes) _entero(c['id']): c,
  };
  return reservas.where((r) {
    if (r['estado'] != 'solicitada') return false;
    if (esDueno) return true;
    return !esVistaProtegida(
        clientePorId[_entero(r['cliente_id'])] ?? {},
        esDueno: esDueno);
  }).length;
}

/// Aviso de «precio hoy» cuando la moneda del catálogo difiere
/// de la snapshot de la reserva: el precio vigente va con SU
/// moneda y SIN diferencia numérica (unidades incompatibles), y
/// queda claro que el cobro usa el precio al reservar. Null si
/// no hay precio vigente o si las monedas coinciden (en ese caso
/// manda la diferencia normal de [ReservaVista.diferenciaTotal]).
String? avisoMonedaReserva(ReservaVista r) {
  if (r.precioVigente == null || r.monedaVigente == r.moneda) {
    return null;
  }
  return 'Precio hoy: ${fmtMonto(r.precioVigente)} '
      '${r.monedaVigente}. Se cobra el precio al reservar: '
      '${fmtMonto(r.precioUnitario)} ${r.moneda}.';
}

/// Ids de reservas con una op encolada (pendiente o en error):
/// su tarjeta se bloquea hasta que la sincronización resuelva.
Set<int> reservasConOpPendiente(List<Map<String, dynamic>> ops) {
  final ids = <int>{};
  for (final op in ops) {
    if (!tiposOpReserva.contains(op['tipo'])) continue;
    try {
      final payload = jsonDecode(op['payload'] as String) as Map;
      final rid = _entero(payload['reserva_id']);
      if (rid > 0) ids.add(rid);
    } catch (_) {
      // Payload ilegible: no bloquea nada.
    }
  }
  return ids;
}

/// Texto de vencimiento de un apartado/solicitud.
/// 1.32 (Oleada 2, Fase 3 — Momento 2C del plano): la
/// reserva VIVA de un cliente para el aviso de su
/// ficha: «Si el cliente tiene una reserva activa,
/// aparece un aviso directo en cabecera». Reutiliza la
/// bandeja entera —mismos estados vivos, misma guarda
/// de vista protegida para no-dueños y mismas defensas
/// de vencimiento (una solicitada o reservada ya
/// vencida en el espejo NO es viva: el servidor la
/// libera sola)— y devuelve la que antes vence. El
/// llamador pasa en [clientes] la fila del cliente (la
/// ficha ya la tiene): la guarda se evalúa con su fila
/// real, como en la bandeja.
ReservaVista? reservaVivaDeCliente({
  required List<Map<String, dynamic>> reservas,
  required List<Map<String, dynamic>> clientes,
  required List<Map<String, dynamic>> suplementos,
  required int clienteId,
  required DateTime ahora,
  bool esDueno = true,
}) {
  final bandeja =
      construirBandeja(reservas, clientes, suplementos, esDueno: esDueno);
  final vivas = [
    for (final v in [...bandeja.solicitadas, ...bandeja.reservadas])
      if (v.clienteId == clienteId &&
          !v.apartadoVencido(ahora) &&
          !v.solicitudVencida(ahora))
        v,
  ];
  if (vivas.isEmpty) return null;
  vivas.sort(
      (a, b) => (a.expiraEn ?? '9999').compareTo(b.expiraEn ?? '9999'));
  return vivas.first;
}

/// El texto del aviso de la ficha (la forma del
/// plano): «Tiene reservado [Producto] (vence en
/// X h) · Entregar ahora». Sin vencimiento legible,
/// el paréntesis se omite.
String textoAvisoReservaViva(ReservaVista v, DateTime ahora) {
  final producto = v.cantidad > 1
      ? '${v.cantidad} × ${v.suplementoNombre}'
      : v.suplementoNombre;
  final vence = textoVenceEn(v.expiraEn, ahora);
  return vence.isEmpty
      ? 'Tiene reservado $producto · Entregar ahora'
      : 'Tiene reservado $producto (${vence.toLowerCase()}) · '
          'Entregar ahora';
}

String textoVenceEn(String? expiraEnIso, DateTime ahora) {
  if (expiraEnIso == null || expiraEnIso.isEmpty) return '';
  final vence = DateTime.tryParse(expiraEnIso);
  if (vence == null) return '';
  final dif = vence.difference(ahora);
  if (dif.isNegative) return 'Vencida — se libera sola';
  if (dif.inHours >= 24) {
    final d = dif.inDays;
    final h = dif.inHours - d * 24;
    return 'Vence en $d d${h > 0 ? ' $h h' : ''}';
  }
  if (dif.inHours >= 1) return 'Vence en ${dif.inHours} h';
  return 'Vence en ${dif.inMinutes} min';
}

String etiquetaEstadoReserva(String estado) {
  switch (estado) {
    case 'solicitada':
      return 'Solicitada';
    case 'reservada':
      return 'Reservada';
    case 'pagada':
      return 'Pagada';
    case 'rechazada':
      return 'Rechazada';
    case 'cancelada':
      return 'Cancelada';
    case 'expirada':
      return 'Expirada';
    default:
      return estado;
  }
}

/// R1 (estéticas 1.19): color semántico del estado de reserva
/// (puro, sin contexto: el gris fijo vale en ambos modos).
Color colorEstadoReserva(String estado) {
  switch (estado) {
    case 'solicitada':
      return AppColores.alerta;
    case 'reservada':
      return AppColores.info;
    case 'pagada':
      return AppColores.exito;
    case 'rechazada':
      return AppColores.error;
    case 'cancelada':
    case 'expirada':
    default:
      return Colors.grey;
  }
}

/// V27: significado del sistema de chips para el estado de
/// reserva — el mismo reparto de color que [colorEstadoReserva]
/// (solicitada ámbar, reservada azul, pagada verde, rechazada
/// roja, resto neutro), en el vocabulario V6.
SignificadoChip significadoEstadoReserva(String estado) {
  switch (estado) {
    case 'solicitada':
      return SignificadoChip.alerta;
    case 'reservada':
      return SignificadoChip.info;
    case 'pagada':
      return SignificadoChip.exito;
    case 'rechazada':
      return SignificadoChip.error;
    default:
      return SignificadoChip.neutral;
  }
}

/// V27: ¿el vencimiento de la reserva es urgente? (vence en 24 h
/// o ya pasó). Sin fecha parseable, no es urgente.
bool venceProntoReserva(ReservaVista r, DateTime ahora) {
  final f = r.expiraEn == null ? null : DateTime.tryParse(r.expiraEn!);
  if (f == null) return false;
  return !f.isAfter(ahora.add(const Duration(hours: 24)));
}

// ------------------------------------------------------------------
// Pantalla
// ------------------------------------------------------------------

class ReservasScreen extends StatefulWidget {
  /// Acceso a la bandeja. Null = se calcula de la sesión (dueño
  /// o can_vender_suplementos, la misma clave que exige el
  /// servidor para las ops). Inyectable en tests.
  final bool? accesoPermitido;

  const ReservasScreen({super.key, this.accesoPermitido});

  @override
  State<ReservasScreen> createState() => _ReservasScreenState();
}

class _ReservasScreenState extends State<ReservasScreen> {
  BandejaReservas? _bandeja;
  Set<int> _conOpPendiente = {};

  /// Reservas con una op encolándose AHORA (panel Gestión
  /// 2026-10-21): el bloqueo es inmediato y local, antes de
  /// cualquier await — un segundo toque no puede encolar una
  /// op contradictoria mientras la primera se persiste o la
  /// sincronización corre (o falla).
  final Set<int> _enCurso = {};
  bool _cargando = true;

  bool get _puedeAcceder =>
      widget.accesoPermitido ??
      (AuthService().isOwner ||
          PermisosEntrenador().canVenderSuplementos);

  bool _bloqueada(int id) =>
      _enCurso.contains(id) || _conOpPendiente.contains(id);

  @override
  void initState() {
    super.initState();
    if (_puedeAcceder) _cargar();
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
    final reservas = await LocalDb.instance.allMirror('reservas');
    final clientes = await LocalDb.instance.allMirror('clientes');
    final suplementos = await LocalDb.instance.allMirror('suplementos');
    // 1.29 (Oleada 2, D-B2-02): lectura de DINERO
    // (pendingOpsLectura: pendiente + enviada + error),
    // no la del push. Con pendingOps, una acción de
    // reserva en estado 'enviada' (ya subida, aún sin
    // bajar el espejo) dejaba de bloquear su tarjeta y
    // el doble cobro/rechazo pasaba — la misma clase de
    // fuga que M3-A2 de la 1.28 cerró en Servicios.
    final ops = await LocalDb.instance.pendingOpsLectura();
    if (!mounted) return;
    setState(() {
      _bandeja = construirBandeja(reservas, clientes, suplementos,
          esDueno: AuthService().isOwner);
      _conOpPendiente = reservasConOpPendiente(ops);
      _cargando = false;
    });
  }

  Future<void> _refrescar() async {
    // 1.34 Campo 2 (P-7): el gesto dice la verdad y sigue
    // la regla de Jc. Fresco (≤10 min) → solo relectura
    // local. Viejo → alcance detallado y se anuncia el
    // desenlace (bajó / al día / sin conexión / no corrió
    // / parcial), como en Buscar y en Admin; antes se
    // tragaba el resultado booleano y callaba siempre.
    ResultadoScopeDetallado? r;
    var lanzo = false;
    try {
      r = await refrescoScopeIron('suplementos');
    } catch (_) {
      lanzo = true;
    }
    await _cargar();
    if (!mounted) return;
    if (lanzo) {
      mostrarSnack(context, 'Sin conexión: mostrando datos locales',
          significado: SignificadoChip.alerta);
    } else if (r == null) {
      mostrarSnack(context, 'Reservas al día, sin cambios',
          significado: SignificadoChip.exito);
    } else if (!r.corrio) {
      mostrarSnack(
          context,
          r.motivo == SyncMotivoNoCorrio.sinSesion
              ? 'Sin sesión: vuelve a iniciar sesión para sincronizar'
              : 'Ya hay una sincronización en curso',
          significado: SignificadoChip.alerta);
    } else if (r.error) {
      mostrarSnack(context, 'Sin conexión: mostrando datos locales',
          significado: SignificadoChip.alerta);
    } else if (r.parcial) {
      mostrarSnack(context,
          'Bajada parcial: ${r.fallidas} filas no bajaron; mostrando lo que hay',
          significado: SignificadoChip.alerta);
    } else if (r.bajados == 0) {
      mostrarSnack(context, 'Reservas al día, sin cambios',
          significado: SignificadoChip.exito);
    } else {
      mostrarSnack(context, 'Reservas actualizadas',
          significado: SignificadoChip.exito);
    }
  }

  Future<void> _encolar(String tipo, Map<String, dynamic> payload,
      String mensajeOk) async {
    final rid = _entero(payload['reserva_id']);
    if (rid <= 0 || _bloqueada(rid)) return;
    // Lote 2 Argón: revalidar contra el espejo ACTUAL y la cola
    // fresca. La tarjeta se renderizó antes del diálogo; mientras
    // estaba abierto, un sync puede haber cambiado el estado
    // (expirada, pagada, cancelada) o encolado otra op. Sin esto se
    // encolaba una acción sobre un estado incompatible.
    const estadosRequeridos = {
      'confirmar_reserva': {'solicitada'},
      'rechazar_reserva': {'solicitada'},
      'cancelar_reserva': {'reservada'},
      'cobrar_reserva': {'reservada'},
    };
    final requeridos = estadosRequeridos[tipo];
    if (requeridos != null) {
      final espejo = await LocalDb.instance.allMirror('reservas');
      final filas =
          espejo.where((r) => _entero(r['id']) == rid).toList();
      final estadoActual =
          filas.isEmpty ? null : '${filas.first['estado'] ?? ''}';
      // 1.29 (D-B2-02): la revalidación mira la misma
      // lectura que la carga (con 'enviada'), no la del
      // push: si no, la ventana entre subir y bajar el
      // espejo dejaba encolar la acción contradictoria.
      final opsFrescas = await LocalDb.instance.pendingOpsLectura();
      final conOp = reservasConOpPendiente(opsFrescas).contains(rid);
      if (estadoActual == null ||
          !requeridos.contains(estadoActual) ||
          conOp) {
        if (mounted) {
          mostrarSnack(context, 'La reserva cambió mientras confirmabas. '
                  'Se actualizó la bandeja; revisa su estado actual.', significado: SignificadoChip.alerta);
          await _cargar();
        }
        return;
      }
    }
    // Lote 3 (panel Luna P2): revalidar el bloqueo DESPUÉS de los
    // awaits. Dos llamados simultáneos pasaban juntos el chequeo
    // inicial; entre este punto y el setState no hay awaits, así
    // que el segundo chequeo es atómico.
    if (_bloqueada(rid)) return;
    // Bloqueo SINCRÓNICO, antes del primer await (panel).
    setState(() => _enCurso.add(rid));
    try {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: tipo,
        payload: payload,
      );
    } catch (_) {
      if (mounted) {
        setState(() => _enCurso.remove(rid));
        mostrarSnack(context, 'No se pudo guardar la acción. '
                'Inténtalo de nuevo.', significado: SignificadoChip.error);
      }
      return;
    }
    if (!mounted) return;
    // La op ya está persistida: la tarjeta queda bloqueada
    // desde ya, sin esperar a que la sincronización termine.
    setState(() {
      _enCurso.remove(rid);
      _conOpPendiente = {..._conOpPendiente, rid};
    });
    mostrarSnack(context, mensajeOk, significado: SignificadoChip.exito);
    await _refrescar();
  }

  Future<void> _confirmar(ReservaVista r) async {
    if (_bloqueada(r.id)) return;
    // Yunque B (YB-SER-07): defensa en el propio flujo, como
    // _cobrar con el apartado vencido — una solicitud vencida
    // no se confirma aunque la tarjeta se hubiera pintado
    // antes del vencimiento.
    if (r.solicitudVencida(ahoraHabana())) {
      mostrarSnack(context,
          'Esta solicitud ya venció: el servidor la expira sola y no se puede confirmar.',
          significado: SignificadoChip.alerta);
      return;
    }
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Confirmar reserva',
      mensaje: '${r.clienteNombre} aparta ${r.cantidad} × '
          '${r.suplementoNombre} a ${fmtMonto(r.precioUnitario)} ${r.moneda} '
          '(${fmtMonto(r.totalFoto)} ${r.moneda} en total).\n\n'
          'El apartado dura 72 horas: ese stock no se puede vender '
          'a nadie más hasta que pague o venza.',
      aceptar: 'Confirmar',
      icono: Icons.bookmark_added_rounded,
    );
    if (ok && mounted) {
      await _encolar('confirmar_reserva', {'reserva_id': r.id},
          'Confirmación de la reserva #${r.id} encolada');
    }
  }

  Future<void> _rechazar(ReservaVista r) async {
    if (_bloqueada(r.id)) return;
    // 1.29 (Oleada 4, barrido): el diálogo vive en un
    // StatefulWidget dueño de su controlador
    // (_DialogoRechazarReserva). Antes se creaba aquí y se
    // disponía tras resolver el showDialog, con la
    // animación de salida aún reconstruyendo el campo (el
    // defecto D-B1-08).
    final nota = await showDialog<String>(
      context: context,
      builder: (_) => _DialogoRechazarReserva(
        clienteNombre: r.clienteNombre,
        cantidad: r.cantidad,
        suplementoNombre: r.suplementoNombre,
      ),
    );
    if (nota != null && mounted) {
      await _encolar(
          'rechazar_reserva',
          {'reserva_id': r.id, if (nota.isNotEmpty) 'nota': nota},
          'Rechazo de la reserva #${r.id} encolado');
    }
  }

  Future<void> _cancelar(ReservaVista r) async {
    if (_bloqueada(r.id)) return;
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cancelar reserva',
      mensaje: 'Se cancela la reserva de ${r.clienteNombre} '
          '(${r.cantidad} × ${r.suplementoNombre})'
          '${r.estado == 'reservada' ? ' y el apartado se libera' : ''}.',
      aceptar: 'Cancelar reserva',
      icono: Icons.bookmark_remove_rounded,
      peligro: true,
    );
    if (ok && mounted) {
      await _encolar('cancelar_reserva', {'reserva_id': r.id},
          'Cancelación de la reserva #${r.id} encolada');
    }
  }

  Future<void> _cobrar(ReservaVista r) async {
    if (_bloqueada(r.id)) return;
    // 1.29 (Oleada 2, D-B2-03): defensa en el propio
    // flujo — un apartado vencido no se cobra aunque la
    // tarjeta se hubiera pintado antes del vencimiento.
    if (r.apartadoVencido(ahoraHabana())) {
      mostrarSnack(context,
          'Este apartado ya venció: se libera solo y no se puede cobrar.',
          significado: SignificadoChip.alerta);
      return;
    }
    // Lote 2 Argón: respetar los métodos aceptados del gimnasio
    // (antes ofrecía efectivo/transferencia fijos aunque el ajuste
    // H1 dijera otra cosa; mismo helper que pagoDialogo).
    final aj = await LocalDb.instance.getAjustes();
    if (!mounted) return;
    final metodos = metodosAceptadosEfectivos(aj['metodos_aceptados']);
    var metodo = metodos.efectivo ? 'efectivo' : 'transferencia';
    final dif = r.diferenciaTotal;
    final avisoMoneda = avisoMonedaReserva(r);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDlg) => DialogoApp(
          titulo: 'Cobrar reserva',
          iconoTitulo: Icons.payments_rounded,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${r.clienteNombre} · ${r.cantidad} × '
                  '${r.suplementoNombre}'),
              const SizedBox(height: 8),
              Text('Total a cobrar: ${fmtMonto(r.totalFoto)} ${r.moneda}',
                  style: AppTexto.titulo),
              Text('Precio al reservar: '
                  '${fmtMonto(r.precioUnitario)} ${r.moneda}'),
              if (avisoMoneda != null)
                Text(
                  avisoMoneda,
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.error),
                ),
              if (dif != null && dif != 0)
                Text(
                  'Precio hoy: ${fmtMonto(r.precioVigente)} ${r.moneda} — '
                  '${dif > 0 ? '+' : ''}${fmtMonto(dif)} ${r.moneda} de '
                  'diferencia. Se cobra el de la reserva.',
                  style: TextStyle(
                      color: Theme.of(ctx).colorScheme.error),
                ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: [
                  if (metodos.efectivo)
                    const ButtonSegment(
                        value: 'efectivo',
                        label: Text('Efectivo'),
                        icon: Icon(Icons.money_rounded)),
                  if (metodos.transferencia)
                    const ButtonSegment(
                        value: 'transferencia',
                        label: Text('Transferencia'),
                        icon: Icon(Icons.account_balance_rounded)),
                ],
                selected: {metodo},
                onSelectionChanged: (s) =>
                    setStateDlg(() => metodo = s.first),
              ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cobrar'),
            ),
          ],
        ),
      ),
    );
    if (ok == true && mounted) {
      await _encolar(
          'cobrar_reserva',
          {'reserva_id': r.id, 'metodo': metodo},
          'Cobro de la reserva #${r.id} encolado — se sincroniza ahora');
    }
  }

  @override
  Widget build(BuildContext context) {
    // La puerta de acceso vive TAMBIÉN en la pantalla (panel
    // Gestión 2026-10-21): el botón de Suplementos no es la
    // única ruta posible hasta aquí.
    if (!_puedeAcceder) {
      return Scaffold(
        appBar: appBarIron(context, 'Reservas'),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(AppEspacio.xl),
            child: Text(
              'No tienes permiso para ver las reservas.\n'
              'Pídele al dueño que te active «Vender suplementos».',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }
    final b = _bandeja;
    return Scaffold(
      appBar: appBarIron(
        context,
        'Reservas',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Sincronizar',
            onPressed: _refrescar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando reservas…')
          : b == null ||
                  (b.solicitadas.isEmpty &&
                      b.reservadas.isEmpty &&
                      b.historial.isEmpty)
              // 1.34 Campo 2 (P-7): el vacío también oye el
              // gesto — va dentro de una lista desplazable
              // bajo el RefrescoIron (antes el EstadoVacio
              // pelado se tragaba el tirar-para-actualizar).
              ? RefrescoIron(
                  onRefresh: _refrescar,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 120),
                      EstadoVacio(
                        icono: Icons.event_available_rounded,
                        titulo: 'Todavía no hay reservas.',
                        subtitulo:
                            'Cuando un cliente reserve un suplemento '
                            'desde su app, aparece aquí.',
                        textoAccion: 'Actualizar',
                        onAccion: _refrescar,
                      ),
                    ],
                  ),
                )
              : RefrescoIron(
                  onRefresh: _refrescar,
                  child: ListView(
                    padding: const EdgeInsets.all(AppEspacio.md),
                    children: [
                      if (b.solicitadas.isNotEmpty) ...[
                        _tituloSeccion(
                            'Solicitadas', b.solicitadas.length),
                        for (final r in b.solicitadas)
                          TarjetaReserva(
                            reserva: r,
                            bloqueada: _bloqueada(r.id),
                            onConfirmar: () => _confirmar(r),
                            onRechazar: () => _rechazar(r),
                            onCancelar: () => _cancelar(r),
                            onCobrar: () => _cobrar(r),
                          ),
                      ],
                      if (b.reservadas.isNotEmpty) ...[
                        _tituloSeccion('Reservadas', b.reservadas.length),
                        for (final r in b.reservadas)
                          TarjetaReserva(
                            reserva: r,
                            bloqueada: _bloqueada(r.id),
                            onConfirmar: () => _confirmar(r),
                            onRechazar: () => _rechazar(r),
                            onCancelar: () => _cancelar(r),
                            onCobrar: () => _cobrar(r),
                          ),
                      ],
                      if (b.historial.isNotEmpty) ...[
                        _tituloSeccion('Historial', b.historial.length),
                        for (final r in b.historial)
                          TarjetaReserva(
                            reserva: r,
                            bloqueada: _bloqueada(r.id),
                            onConfirmar: () => _confirmar(r),
                            onRechazar: () => _rechazar(r),
                            onCancelar: () => _cancelar(r),
                            onCobrar: () => _cobrar(r),
                          ),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _tituloSeccion(String titulo, int n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
      child: Text('$titulo ($n)',
          style: AppTexto.titulo),
    );
  }

}

/// R3 (estéticas 1.19): miniatura con la misma resolución que
/// la foto del catálogo (local → caché → descarga si [descargar];
/// el cliente no descarga, igual que ClienteAvatarThumb). Sin
/// foto, icono neutro en vez de un hueco vacío.
class _MiniFotoReserva extends StatefulWidget {
  final String? fotoLocal;
  final String? fotoStorage;
  final bool descargar;
  const _MiniFotoReserva({
    required this.fotoLocal,
    required this.fotoStorage,
    required this.descargar,
  });

  @override
  State<_MiniFotoReserva> createState() => _MiniFotoReservaState();
}

class _MiniFotoReservaState extends State<_MiniFotoReserva> {
  late Future<File?> _futura;

  @override
  void initState() {
    super.initState();
    _futura = _resolver();
  }

  @override
  void didUpdateWidget(_MiniFotoReserva old) {
    super.didUpdateWidget(old);
    if (old.fotoLocal != widget.fotoLocal ||
        old.fotoStorage != widget.fotoStorage) {
      _futura = _resolver();
    }
  }

  Future<File?> _resolver() async {
    final local = widget.fotoLocal;
    if (local != null && local.isNotEmpty && File(local).existsSync()) {
      return File(local);
    }
    final storage = widget.fotoStorage;
    if (storage == null || storage.isEmpty) return null;
    final enCache = await FotoCache.instance.enCache(storage);
    if (enCache != null) return enCache;
    if (!widget.descargar) return null;
    return FotoCache.instance.obtener(storage);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _futura,
      builder: (ctx, snap) {
        final f = snap.data;
        if (f != null) {
          // 1.34 Campo 2 (P-1): hueco de 48 dp — decodificar
          // acotado al ancho físico, no la foto entera.
          return Image.file(
            f,
            fit: BoxFit.cover,
            cacheWidth:
                (48 * MediaQuery.devicePixelRatioOf(ctx)).round(),
            errorBuilder: (_, __, ___) => const _SinFotoReserva(),
          );
        }
        return const _SinFotoReserva();
      },
    );
  }
}

/// 1.29 (Oleada 4, barrido de diálogos): «Rechazar reserva»
/// como StatefulWidget DUEÑO de su controlador, dispuesto
/// en dispose() — el patrón de la casa. Devuelve el motivo
/// tecleado (recortado) al confirmar; null al cancelar.
class _DialogoRechazarReserva extends StatefulWidget {
  const _DialogoRechazarReserva({
    required this.clienteNombre,
    required this.cantidad,
    required this.suplementoNombre,
  });

  final String clienteNombre;
  final int cantidad;
  final String suplementoNombre;

  @override
  State<_DialogoRechazarReserva> createState() =>
      _DialogoRechazarReservaState();
}

class _DialogoRechazarReservaState
    extends State<_DialogoRechazarReserva> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Rechazar reserva',
      iconoTitulo: Icons.bookmark_remove_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${widget.clienteNombre} · ${widget.cantidad} × '
              '${widget.suplementoNombre}'),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            decoration: const InputDecoration(
              labelText: 'Motivo (opcional, lo ve el cliente)',
              border: OutlineInputBorder(),
            ),
            maxLength: 200,
          ),
        ],
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.pop(context, _ctrl.text.trim()),
          child: const Text('Rechazar'),
        ),
      ],
    );
  }
}

class _SinFotoReserva extends StatelessWidget {
  const _SinFotoReserva();

  @override
  Widget build(BuildContext context) {
    // 1.35 (UI-14): el placeholder compartido, rellenando
    // el hueco de 48 dp (antes un gris propio con alfa).
    return const PlaceholderSuplemento(
        alto: null, tamanoIcono: 20);
  }
}

/// V27/V19: avatar del cliente de la tarjeta con el componente
/// común. Resuelve la foto como _MiniFotoReserva (local → caché,
/// SIN descargar: el cliente no descarga) y, sin foto, muestra
/// las iniciales del sistema.
class _AvatarReservaCliente extends StatefulWidget {
  final String nombre;
  final String? fotoLocal;
  final String? fotoStorage;
  const _AvatarReservaCliente({
    required this.nombre,
    required this.fotoLocal,
    required this.fotoStorage,
  });

  @override
  State<_AvatarReservaCliente> createState() =>
      _AvatarReservaClienteState();
}

class _AvatarReservaClienteState extends State<_AvatarReservaCliente> {
  late Future<File?> _futura;

  @override
  void initState() {
    super.initState();
    _futura = _resolver();
  }

  @override
  void didUpdateWidget(_AvatarReservaCliente old) {
    super.didUpdateWidget(old);
    if (old.fotoLocal != widget.fotoLocal ||
        old.fotoStorage != widget.fotoStorage) {
      _futura = _resolver();
    }
  }

  Future<File?> _resolver() async {
    final local = widget.fotoLocal;
    if (local != null && local.isNotEmpty && File(local).existsSync()) {
      return File(local);
    }
    final storage = widget.fotoStorage;
    if (storage == null || storage.isEmpty) return null;
    return FotoCache.instance.enCache(storage);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _futura,
      builder: (ctx, snap) => AvatarCliente(
        nombre: widget.nombre,
        foto: snap.data,
        tamano: TamanoAvatar.s,
      ),
    );
  }
}

/// Tarjeta de una reserva. Widget sin estado y sin dependencias
/// de BD/sync (testeable directo): la pantalla le pasa si está
/// [bloqueada] (op encolada o encolándose) y los callbacks; con
/// bloqueo muestra el chip y NINGÚN botón de acción.
class TarjetaReserva extends StatelessWidget {
  final ReservaVista reserva;
  final bool bloqueada;
  final VoidCallback onConfirmar;
  final VoidCallback onRechazar;
  final VoidCallback onCancelar;
  final VoidCallback onCobrar;

  const TarjetaReserva({
    super.key,
    required this.reserva,
    required this.bloqueada,
    required this.onConfirmar,
    required this.onRechazar,
    required this.onCancelar,
    required this.onCobrar,
  });

  @override
  Widget build(BuildContext context) {
    final r = reserva;
    final solicitada = r.estado == 'solicitada';
    final reservada = r.estado == 'reservada';
    final ahora = ahoraHabana();
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // V27/V19: avatar del cliente con el componente
              // común (foto resuelta sin descargar, o iniciales).
              _AvatarReservaCliente(
                nombre: r.clienteNombre,
                fotoLocal: r.fotoClienteLocal,
                fotoStorage: r.fotoClienteStorage,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(r.clienteNombre,
                    style: AppTexto.subtitulo
                        .copyWith(fontWeight: FontWeight.bold)),
              ),
              // V27: chip de estado del sistema V6 (el significado
              // conserva el reparto de colorEstadoReserva).
              ChipEstado.semantico(
                texto: etiquetaEstadoReserva(r.estado),
                significado: significadoEstadoReserva(r.estado),
              ),
            ],
          ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // R3: miniatura del suplemento reservado.
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadio.sm),
                    border:
                        Border.all(color: AppColores.borde(context)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(7),
                    child: _MiniFotoReserva(
                      fotoLocal: r.fotoSuplementoLocal,
                      fotoStorage: r.fotoSuplementoStorage,
                      descargar: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${r.cantidad} × ${r.suplementoNombre}',
                          style: AppTexto.cuerpo),
                      Text(
                          'Total: ${fmtMonto(r.totalFoto)} ${r.moneda} '
                          '(${fmtMonto(r.precioUnitario)} ${r.moneda} c/u al reservar)',
                          style: AppTexto.secundario),
                    ],
                  ),
                ),
              ],
            ),
            if (avisoMonedaReserva(r) != null)
              Text(avisoMonedaReserva(r)!,
                  style: AppTexto.secundario
                      .copyWith(color: AppColores.error)),
            // V27: el vencimiento va siempre en el mismo sitio
            // (línea con reloj bajo el total): en alerta si vence
            // en 24 h o ya venció; si no, en secundario.
            if (solicitada || reservada)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.xs),
                child: Row(
                  children: [
                    Icon(Icons.schedule_rounded,
                        size: 14,
                        color: venceProntoReserva(r, ahora)
                            ? AppColores.alerta
                            : AppColores.textoSecundario(context)),
                    const SizedBox(width: 4),
                    Text(textoVenceEn(r.expiraEn, ahora),
                        style: AppTexto.secundario.copyWith(
                            color: venceProntoReserva(r, ahora)
                                ? AppColores.alerta
                                : null)),
                  ],
                ),
              ),
            if (r.notaResolucion != null &&
                r.notaResolucion!.isNotEmpty)
              Text('Nota: ${r.notaResolucion}',
                  style: AppTexto.secundario),
            if (bloqueada)
              const Padding(
                padding: EdgeInsets.only(top: AppEspacio.sm),
                child: ChipEstado.semantico(
                  texto: 'Acción encolada — sincronizando',
                  significado: SignificadoChip.info,
                  icono: Icons.hourglass_top_rounded,
                ),
              ),
            if (solicitada && !bloqueada && r.solicitudVencida(ahora))
              // Yunque B (YB-SER-07): solicitud vencida que el
              // servidor aún no expira en el espejo: SIN
              // botones (confirmarla encolaría un
              // confirmar_reserva condenado al rebote), el
              // mismo tratamiento que el apartado vencido.
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.sm),
                child: Text(
                  'Solicitud vencida: el servidor la expira '
                  'sola; ya no se puede confirmar.',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.alertaTexto(context)),
                ),
              ),
            if (solicitada && !bloqueada && !r.solicitudVencida(ahora))
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: onRechazar,
                    child: const Text('Rechazar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: onConfirmar,
                    child: const Text('Confirmar'),
                  ),
                ],
              ),
            if (reservada && !bloqueada && r.apartadoVencido(ahora))
              // 1.29 (Oleada 2, D-B2-03): apartado vencido
              // que el servidor aún no libera: SIN botones
              // (cobrarlo encolaría un cobro condenado al
              // rechazo por expirado; cancelarlo es
              // innecesario, se libera solo). La línea de
              // vencimiento de arriba ya dice «Vencida —
              // se libera sola»; esta lo deja explícito
              // junto a donde estarían las acciones.
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.sm),
                child: Text(
                  'Apartado vencido: se libera solo, no se puede cobrar.',
                  style: AppTexto.secundario.copyWith(
                      color: AppColores.alertaTexto(context)),
                ),
              ),
            if (reservada && !bloqueada && !r.apartadoVencido(ahora))
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: onCancelar,
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: onCobrar,
                    child: const Text('Cobrar'),
                  ),
                ],
              ),
          ],
      ),
    );
  }
}
