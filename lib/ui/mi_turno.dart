/// Mi turno: resumen del entrenador.
///
/// Cobrado hoy, historial diario, pendiente a entregar con desglose y la
/// aclaración explícita de que el pendiente SOLO se reinicia cuando Jc
/// confirma que recibió el dinero.
library;

import 'package:flutter/material.dart';

import 'dart:convert';

import '../app_log.dart';
import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../permisos_entrenador.dart';
import '../servicios.dart' as svc;
import '../sync.dart';
import '../tiempo.dart';
import '../turno_service.dart';
import '../turnos_resolucion.dart';
import 'app_bar.dart';
import 'cierre_turno.dart';
import 'servicios.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'permisos_ui.dart';
import 'ficha.dart';
import 'pendiente.dart';
import 'widgets.dart';

/// Yunque 3 (K5-1): filtro PURO de «Mis vencimientos» sobre las
/// filas del espejo de clientes: solo los atribuidos al
/// entrenador ([mios]), activos y con `pagado_hasta` dentro de
/// la ventana (<= [limite]). NUNCA una Cuenta a la Casa — no
/// vence nunca, aunque su `pagado_hasta` guardado ya pasó (al
/// revocar manda él) — ni un protegido para quien no es dueño:
/// es el mismo par de exclusiones que la pantalla hermana del
/// panel (`panel_bloque2`) ya aplicaba en su bucle; esta lista
/// propia era la única superficie de vencimientos sin ellas y
/// el entrenador podía salir a cobrarle a quien no debe nada.
/// [esDueno] solo lo fijan los tests; la pantalla lo omite y
/// se resuelve la sesión.
List<Map<String, dynamic>> filtrarMisVencimientos(
  List<Map<String, dynamic>> clientes,
  Set<int> mios, {
  required String hoy,
  required String limite,
  bool? esDueno,
}) {
  final out = <Map<String, dynamic>>[];
  for (final c in clientes) {
    final id = (c['id'] as num?)?.toInt();
    if (id == null || !mios.contains(id)) continue;
    if ('${c['estado'] ?? 'activo'}' != 'activo') continue;
    if (esCuentaCasa(c)) continue;
    if (esVistaProtegida(c, esDueno: esDueno)) continue;
    final ph = '${c['pagado_hasta'] ?? ''}';
    if (ph.isEmpty || ph.compareTo(limite) > 0) continue;
    out.add({
      'id': id,
      'nombre': '${c['nombre'] ?? 'Cliente $id'}',
      'pagado_hasta': ph.length >= 10 ? ph.substring(0, 10) : ph,
      'vencido': ph.compareTo(hoy) < 0,
    });
  }
  out.sort((a, b) =>
      '${a['pagado_hasta']}'.compareTo('${b['pagado_hasta']}'));
  return out;
}

class MiTurnoScreen extends StatefulWidget {
  const MiTurnoScreen({super.key});
  @override
  State<MiTurnoScreen> createState() => _MiTurnoScreenState();
}

class _MiTurnoScreenState extends State<MiTurnoScreen> {
  // 1.25 T119 (F3-09): «Mis vencimientos» mostraba 10 y el
  // resto era invisible; ahora se despliega la lista entera.
  bool _verTodosVencimientos = false;
  double _cobrado = 0;
  // Yunque B (YB-TRA-08): ops de hoy que miTurnoHoy no pudo
  // sumar (payload ilegible): si > 0, el «Cobrado hoy» se
  // avisa como incompleto en vez de presentarse definitivo.
  int _sumaIncompleta = 0;
  double _efectivoHoy = 0;
  double _transferHoy = 0;
  double _pendiente = 0;
  double _pendienteUsd = 0;
  double _cobradoMes = 0;
  Map<String, dynamic>? _ultimaEntrega;
  List<Map<String, dynamic>> _historial = [];
  List<Map<String, dynamic>> _pendMens = [];
  List<Map<String, dynamic>> _pendDiarios = [];
  List<Map<String, dynamic>> _pendServicios = [];
  List<Map<String, dynamic>> _pendSuplementos = [];
  List<Map<String, dynamic>> _pendAdelantos = [];
  List<(String, double)> _pendOps = [];
  // 1.22 T-02: arrastre vigente de la liquidación parcial (su
  // línea en el desglose por día, para que el desglose cuadre
  // con el total canónico de arriba).
  double _arrastreCup = 0;
  String? _arrastreFecha;
  // v1.0.16: mejoras para entrenadores
  List<Map<String, dynamic>> _vencimientos = [];
  double _cobradoAyer = 0;
  double _semanaAnt = 0;
  bool _cerrado = false; // v1.1.1: turno actual ya cerrado
  // 1.26 (auditoría de botones, MEDIA 1): guardas
  // anti-doble-toque del cierre. Sin ellas, un doble toque
  // abría dos diálogos de cierre y, en el camino legado,
  // encolaba DOS ops cierre_turno con UUID distinto.
  bool _cierreEnCurso = false;
  bool _confirmandoCierre = false;
  // 1.25 T84: la primera carga pinta un estado de carga,
  // no la pantalla en ceros; y el chip de cabecera sale
  // del turno REAL de hoy (turnoVisible), no del reloj.
  bool _cargando = true;
  // SL-11 (G12-1): la carga fallida se DICE con EstadoError:
  // antes el fallo se tragaba y la pantalla pintaba
  // «Cobrado hoy 0 CUP» (dinero) como si fuera el dato.
  bool _errorCarga = false;
  Map<String, dynamic>? _turnoVisible;
  // 1.28 (M3-B6): el último turno propio cerrado
  // automáticamente (olvidado) aún no reconocido: su aviso
  // encabeza la pantalla hasta que el entrenador lo ve.
  Map<String, dynamic>? _autocierre;
  // 1.28 (M3-B8): la última venta de dosis de este teléfono
  // (meta que guarda Servicios al vender), para el botón
  // «Otra igual».
  Map<String, dynamic>? _ultimaVenta;
  bool _repitiendo = false;
  final _auth = AuthService();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      await _cargarDatos();
      if (mounted) setState(() => _errorCarga = false);
    } catch (e) {
      // SL-11 (G12-1): el fallo NO se disfraza de ceros:
      // queda en bitácora y la pantalla muestra el error.
      AppLog.error('mi_turno', 'carga_fallo', d: '$e');
      if (mounted) setState(() => _errorCarga = true);
    } finally {
      // 1.25 T84: la carga inicial termina siempre,
      // también si la lectura falla a mitad.
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final tid = _auth.telegramId;
    final t = await miTurnoHoy(tid);
    final hist = await historialTurno(tid, dias: 60);
    final ult = await ultimaEntregaConfirmada(tid);
    final mes = await cobradoMes(tid);
    final (pm, pd, ps, pSup) = await detallePendiente(tid);
    // (1.22 T-04: fuera la variable `cubiertos` muerta que aquí
    // se calculaba sin usarse: detallePendiente ya excluye lo
    // liquidado por dentro, AR-01.)
    // Argón 1.21 AR-C03: op_uuid ya presentes en el espejo; la
    // cola local no debe re-sumar lo que el pull ya bajó
    // (ventana push→pull, mismo cruce que B-03 en negocio).
    // 1.22 T-05: el cruce ignora uuid nulo/vacío (un 'null'
    // convertido a texto colisionaba entre filas sin uuid).
    final uuidsEspejo = <String>{
      for (final f in [...pm, ...pd, ...ps, ...pSup])
        if ('${f['op_uuid'] ?? ''}'.trim().isNotEmpty)
          '${f['op_uuid']}'.trim(),
    };
    // 1.15-turnos (#9): el detalle por día cubre también servicios,
    // suplementos, adelantos y la cola local (misma cobertura que
    // pendienteEntrega, salvo el USD que va en su propia línea).
    // Argón Dinero #12: los suplementos ya vienen de
    // detallePendiente (su cuarta lista, con el mismo filtro);
    // aquí solo se anotan sus uuids para el cruce de la cola.
    final sup = pSup;
    for (final v in sup) {
      final u = '${v['op_uuid'] ?? ''}'.trim();
      if (u.isNotEmpty) uuidsEspejo.add(u);
    }
    // 1.22 T-02: arrastre vigente (liquidación parcial CUP) con
    // su fecha: entra como línea del desglose por día.
    var arrastreCup = 0.0;
    String? arrastreFecha;
    if (tid != null) {
      for (final l
          in await LocalDb.instance.allMirror('liquidaciones_caja')) {
        if (LocalDb.normalizarTelegramId(l['entrenador_telegram_id']) !=
            tid) {
          continue;
        }
        if ((l['estado'] as String?) != 'parcial') continue;
        if ((l['moneda'] as String?) == 'USD') continue;
        final a = (l['saldo_arrastre'] as num?)?.toDouble() ?? 0;
        // Mismo criterio que pendienteEntrega: se suman TODAS
        // las parciales CUP (en la práctica el servidor deja
        // como 'parcial' solo la vigente por entrenador/moneda:
        // al registrar otra liquidación, las anteriores pasan
        // a 'liquidado' con su arrastre absorbido).
        if (a == 0) continue;
        arrastreCup += a;
        // Panel Pieza 2: la fecha de la línea es la de la
        // parcial MÁS RECIENTE por creada_en (determinista;
        // el orden del espejo no se garantiza).
        final f = '${l['creada_en'] ?? ''}';
        if (f.length >= 10 &&
            (arrastreFecha == null ||
                f.substring(0, 10).compareTo(arrastreFecha!) >= 0)) {
          arrastreFecha = f.substring(0, 10);
        }
      }
    }
    final adel = <Map<String, dynamic>>[];
    for (final a in await LocalDb.instance.allMirror('adelantos')) {
      if (LocalDb.normalizarTelegramId(a['descuenta_a']) == tid &&
          (a['en_pendiente'] as num?)?.toInt() == 1) {
        adel.add(a);
      }
    }
    final opsDia = <(String, double)>[];
    final pr = await preciosVigentes();
    // Autoauditoría 1.22 #1: pendingOpsLectura (incluye
    // 'enviada'), no pendingOps: el total de arriba sale de
    // pendienteEntrega, que SÍ cuenta las ops en vuelo; con la
    // lista corta, una op recién enviada desaparecía del
    // desglose por día pero no del total.
    for (final op in await LocalDb.instance.pendingOpsLectura()) {
      // Argón 1.21 AR-C03: si la op ya bajó al espejo, la
      // cuentan las listas de espejo; re-sumarla aquí duplicaba
      // el desglose por día frente al total superior.
      // 1.22 T-05: uuid nulo/vacío no cruza (no es identidad).
      final opUuid = '${op['op_uuid'] ?? ''}'.trim();
      if (opUuid.isNotEmpty && uuidsEspejo.contains(opUuid)) {
        continue;
      }
      try {
        final payload =
            jsonDecode(op['payload'] as String) as Map<String, dynamic>;
        // Argón 1.21 AR-C03: en venta_servicio el beneficiario
        // es el responsable del efectivo del payload, no
        // necesariamente el autor de la op (misma regla que
        // pendienteEntrega en negocio.dart).
        if ('${op['tipo']}' == 'venta_servicio') {
          final resp = LocalDb.normalizarTelegramId(
                  payload['responsable_efectivo_id']) ??
              LocalDb.normalizarTelegramId(op['telegram_id']);
          if (resp != tid) continue;
          // 1.22 T-05: el telegram_id se normaliza en TODAS las
          // ramas (antes solo en venta_servicio: una op con el
          // id como texto no casaba con el tid numérico y su
          // dinero desaparecía del desglose).
        } else if (LocalDb.normalizarTelegramId(op['telegram_id']) !=
            tid) {
          continue;
        }
        final fecha =
            (payload['fecha'] as String?)?.substring(0, 10) ?? '';
        opsDia.add((fecha, montoEfectivoOp(op, pr)));
      } catch (_) {}
    }
    final pendUsd = await pendienteEntregaUsd(tid);
    double ef = 0, tr = 0;
    if (hist.isNotEmpty) {
      final hoy = hist.firstWhere(
          (h) => h['fecha'] == _hoy(),
          orElse: () => <String, dynamic>{});
      ef = (hoy['efectivo'] as num?)?.toDouble() ?? 0;
      tr = (hoy['transferencia'] as num?)?.toDouble() ?? 0;
    }
    // v1.0.16: tendencia (ayer y semana anterior) y vencimientos
    final ayer = _ayerIso();
    double cobradoAyer = 0;
    double semanaAnt = 0;
    // 1.24 B2: fechas límite por aritmética de fecha pura
    // (sumarDiasIso), no por Duration sobre el wall-clock.
    final f8 = sumarDiasIso(_hoy(), -8);
    final f15 = sumarDiasIso(_hoy(), -15);
    for (final h in hist) {
      final f = '${h['fecha'] ?? ''}';
      final c = (h['cobrado'] as num?)?.toDouble() ?? 0;
      if (f == ayer) cobradoAyer = c;
      if (f.compareTo(f15) >= 0 && f.compareTo(f8) < 0) {
        semanaAnt += c;
      }
    }
    final vencimientos = await _misVencimientos(tid);
    // v1.1.1: ¿el turno actual ya se cerró?
    final cerrado = await _turnoCerrado();
    // 1.25 T84: el turno real de hoy para el chip.
    Map<String, dynamic>? visible;
    try {
      visible = await TurnoService.instance.turnoVisible();
    } catch (_) {}
    // 1.28 (M3-B6): el aviso del auto-cierre pendiente de
    // reconocer (si lo hay).
    Map<String, dynamic>? autocierre;
    try {
      autocierre =
          await TurnoService.instance.ultimoAutocierreSinAvisar();
    } catch (_) {}
    // 1.28 (M3-B8): la última venta registrada en este
    // teléfono, para «Otra igual».
    Map<String, dynamic>? ultimaVenta;
    try {
      final raw =
          await LocalDb.instance.getMeta('ultima_venta_servicio');
      if (raw != null && raw.isNotEmpty) {
        final d = jsonDecode(raw);
        if (d is Map) ultimaVenta = Map<String, dynamic>.from(d);
      }
    } catch (_) {}
    if (mounted) {
      setState(() {
        _cobrado = t.$1;
        _sumaIncompleta = noCalculadasCaja;
        _pendiente = t.$2;
        _efectivoHoy = ef;
        _transferHoy = tr;
        _cobradoMes = mes;
        _ultimaEntrega = ult;
        _historial = hist;
        _pendMens = pm;
        _pendDiarios = pd;
        _pendServicios = ps;
        _pendSuplementos = sup;
        _pendAdelantos = adel;
        _pendOps = opsDia;
        _arrastreCup = arrastreCup;
        _arrastreFecha = arrastreFecha;
        _pendienteUsd = pendUsd;
        _cobradoAyer = cobradoAyer;
        _semanaAnt = semanaAnt;
        _vencimientos = vencimientos;
        _cerrado = cerrado;
        _turnoVisible = visible;
        _autocierre = autocierre;
        _ultimaVenta = ultimaVenta;
      });
    }
  }

  // ----------------------------------------------------------
  // 1.28 (M3-B6): aviso del auto-cierre de un turno olvidado.
  // ----------------------------------------------------------

  Future<void> _reconocerAutocierre() async {
    final a = _autocierre;
    if (a == null) return;
    await TurnoService.instance
        .marcarAutocierreAvisado('${a['turno_id']}');
    if (mounted) setState(() => _autocierre = null);
  }

  Future<void> _verDetalleAutocierre() async {
    final a = _autocierre;
    if (a == null) return;
    final snap = (a['snapshot'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final total = (snap['total_cobrado'] as num?)?.toDouble();
    final pendN = (snap['pendientes_count'] as num?)?.toInt() ?? 0;
    final pendCup = (snap['pendientes_cup'] as num?)?.toDouble() ?? 0;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cierre automático tardío'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Turno del ${fmtFecha('${a['fecha_turno']}')} '
                '(${a['turno'] == 'tarde' ? 'tarde' : 'mañana'}).'),
            Text(
                'Se cerró a las '
                '${horaCorta('${snap['hora_cierre'] ?? a['hora_cierre'] ?? ''}')}.'),
            if (total != null)
              Text('Total cobrado ese día: ${fmtMonto(total)} CUP.'),
            if (pendN > 0)
              Text('Quedaron $pendN cobros por entregar '
                  '(${fmtMonto(pendCup)} CUP): siguen en tu '
                  'pendiente, no se perdieron.'),
            const SizedBox(height: 8),
            const Text(
              'El sistema cierra solo los turnos olvidados '
              'para que el día no quede abierto. La próxima '
              'vez, cierra tu turno al terminar.',
              style: AppTexto.secundario,
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
    await _reconocerAutocierre();
  }

  Widget _tarjetaAutocierre() {
    final a = _autocierre!;
    return Tarjeta(
      color: AppColores.alerta.withValues(alpha: 0.10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.schedule_rounded,
                  color: AppColores.alerta, size: 20),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: Text(
                  'Tu turno del ${fmtFecha('${a['fecha_turno']}')} '
                  'se cerró automáticamente porque no lo '
                  'cerraste.',
                  style: AppTexto.cuerpo
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Row(
            children: [
              OutlinedButton(
                onPressed: _verDetalleAutocierre,
                child: const Text('Ver detalle'),
              ),
              const SizedBox(width: AppEspacio.sm),
              TextButton(
                onPressed: _reconocerAutocierre,
                child: const Text('Entendido'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------
  // 1.28 (M3-B8): «Otra igual» — repetir la última venta.
  // ----------------------------------------------------------

  String _etiquetaUltimaVenta() {
    final u = _ultimaVenta!;
    final String base;
    if ('${u['forma'] ?? 'simple'}' == 'multiple') {
      final n = (u['dosis_n'] as num?)?.toInt() ?? 0;
      final m = (u['pomos_m'] as num?)?.toInt() ?? 0;
      base = '$n dosis${m > 0 ? ' ($m con agua)' : ''}';
    } else {
      final cant = (u['cantidad'] as num?)?.toInt() ?? 1;
      base = switch ('${u['tipo'] ?? ''}') {
        'dosis_con_agua' => cant > 1 ? '$cant dosis con agua' : 'Dosis con agua',
        'agua_suelta' => cant > 1 ? '$cant pomos de agua' : 'Agua',
        _ => cant > 1 ? '$cant dosis' : 'Dosis',
      };
    }
    if (u['casa'] == true) return '$base · Casa';
    return switch ('${u['metodo'] ?? ''}') {
      'transferencia' => '$base · Transferencia',
      'efectivo' => '$base · Efectivo',
      _ => base,
    };
  }

  Future<void> _repetirVenta() async {
    final u = _ultimaVenta;
    if (u == null || _repitiendo) return;
    // Yunque B (YB-SER-01): repetir una venta también es
    // vender — el servidor exige can_vender_suplementos
    // para venta_servicio y rebotaría la op tras enseñar
    // «Venta repetida». Guarda dentro del flujo (H-02).
    if (!await permisoOperativoOkConRefresco(context,
        () => PermisosEntrenador().canVenderSuplementos,
        'vender servicios')) {
      return;
    }
    if (!mounted) return;
    setState(() => _repitiendo = true);
    try {
      final agua = await svc.stockAguaLocal();
      await svc.repetirUltimaVentaServicio(u,
          topePomosAgua: agua.saldo, actorEsDueno: _auth.isOwner);
      if (!mounted) return;
      mostrarSnack(context, 'Venta repetida: ${_etiquetaUltimaVenta()}');
      await _cargar();
    } catch (e) {
      if (!mounted) return;
      mostrarSnack(context,
          '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _repitiendo = false);
    }
  }

  /// Clientes que vencen en los próximos 7 días o ya vencidos,
  /// atribuidos al entrenador (los que él inscribió o les cobró).
  Future<List<Map<String, dynamic>>> _misVencimientos(
      int? tid) async {
    if (tid == null) return [];
    final hoy = _hoy();
    final limite = sumarDiasIso(hoy, 7);
    // Clientes que el entrenador inscribió o a los que cobró
    final mios = <int>{};
    for (final c in await LocalDb.instance.allMirror('clientes')) {
      if (LocalDb.normalizarTelegramId(c['registrado_por']) == tid) {
        final id = (c['id'] as num?)?.toInt();
        if (id != null) mios.add(id);
      }
    }
    // v1.3.4 (ítem 2): columna `telegram_user_id` indexada en vez
    // de allMirror + filtro en Dart.
    for (final p in await LocalDb.instance.pagosPorEntrenador(tid)) {
      final id = LocalDb.normalizarTelegramId(p['cliente_id']);
      if (id != null) mios.add(id);
    }
    return filtrarMisVencimientos(
      await LocalDb.instance.allMirror('clientes'),
      mios,
      hoy: hoy,
      limite: limite,
    );
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String _ayerIso() =>
      _iso(ahoraHabana().subtract(const Duration(days: 1)));

  /// Turno actual según la hora.
  /// 1.22 T-07: franja CANÓNICA de turnos_resolucion (mañana
  /// 6-12, sáb 7-12; tarde 14-20, sáb sin tarde; domingo sin
  /// franja; hueco 12-14 sin franja; NO existe «noche»). El
  /// reloj propio anterior (5-12/12-18/resto noche) cerraba
  /// como «noche» un turno de tarde a las 18:05 y la etiqueta
  /// mentía. Sin franja vigente, el token 'sin_franja' sirve
  /// solo para la clave/meta del camino legado.
  String _turnoId() =>
      franjaDeInstante(ahoraHabana()) ?? 'sin_franja';

  /// Clave del cierre del turno actual (por día, turno y entrenador).
  String _claveCierre() =>
      'cierre_turno_${_hoy()}_${_turnoId()}_${_auth.telegramId}';

  /// Estado de cierre: primero el turno canónico de TurnoService
  /// (Argón P1#10); la meta legada solo como respaldo cuando nunca
  /// se abrió un turno por el flujo de Home.
  Future<bool> _turnoCerrado() async {
    try {
      final visible = await TurnoService.instance.turnoVisible();
      if ('${visible?['estado'] ?? ''}'.startsWith('cerrado')) {
        return true;
      }
    } catch (_) {}
    return (await LocalDb.instance.getMeta(_claveCierre())) != null;
  }

  String _turnoActual() {
    // 1.22 T-07: misma franja canónica que _turnoId.
    return switch (franjaDeInstante(ahoraHabana())) {
      'manana' => 'Turno de mañana',
      'tarde' => 'Turno de tarde',
      _ => 'Fuera de franja de turno',
    };
  }

  /// 1.25 T119 (F3-10): etiqueta del chip de cabecera: la
  /// franja del reloj Y el estado conocido del turno — antes
  /// el chip decía «Turno de mañana» a secas aunque ese turno
  /// ya estuviera cerrado. (El estado de apertura vive en el
  /// flujo de cierre que unifica T84.)
  String _etiquetaTurnoChip() {
    // 1.25 T84: el estado REAL manda sobre el reloj: si
    // hoy hay un turno abierto, el chip nombra ESE turno
    // y dice «abierto» aunque el reloj ya haya cruzado
    // de franja (mismo criterio que el Home en T08).
    final v = _turnoVisible;
    final estadoV = '${v?['estado'] ?? ''}';
    if (v != null && estadoV.startsWith('abierto')) {
      final nombre = switch ('${v['turno'] ?? ''}') {
        'manana' => 'Turno de mañana',
        'tarde' => 'Turno de tarde',
        _ => _turnoActual(),
      };
      return '$nombre · abierto';
    }
    final base = _turnoActual();
    if (_cerrado && base != 'Fuera de franja de turno') {
      return '$base · cerrado';
    }
    return base;
  }

  /// Icono según el turno actual.
  IconData _iconoTurno() {
    return switch (franjaDeInstante(ahoraHabana())) {
      'manana' => Icons.wb_sunny_rounded,
      'tarde' => Icons.wb_twilight_rounded,
      _ => Icons.schedule_rounded,
    };
  }

  /// Total cobrado en los últimos 7 días (incluye hoy).
  double _cobradoSemana() {
    final hace7 = sumarDiasIso(_hoy(), -7);
    double t = 0;
    for (final h in _historial) {
      final f = '${h['fecha'] ?? ''}';
      if (f.compareTo(hace7) >= 0) {
        t += (h['cobrado'] as num?)?.toDouble() ?? 0;
      }
    }
    return t;
  }

  /// Fila de tendencia con flecha ↑/↓/= (v1.0.16).
  Widget _filaTendencia(String etiqueta, double antes, double ahora) {
    final textoSuave = AppColores.textoSecundario(context);
    String flecha;
    Color color;
    String pct = '';
    if (antes <= 0 && ahora <= 0) {
      flecha = '=';
      color = textoSuave;
    } else if (antes <= 0) {
      flecha = '↑';
      color = AppColores.exito;
    } else {
      final d = (ahora - antes) / antes;
      if (d > 0.02) {
        flecha = '↑';
        color = AppColores.exito;
      } else if (d < -0.02) {
        flecha = '↓';
        color = AppColores.error;
      } else {
        flecha = '=';
        color = textoSuave;
      }
      pct = ' (${(d * 100).toStringAsFixed(0)}%)';
    }
    return Row(
      children: [
        Expanded(
            child: Text(etiqueta,
                style: AppTexto.cuerpo)),
        Text('$flecha ${fmtMonto(ahora)} CUP$pct',
            style: AppTexto.cuerpo.copyWith(color: color, fontWeight: FontWeight.bold)),
      ],
    );
  }

  /// Diálogo de cierre de turno con resumen del día (v1.0.16, idea 1).
  /// v1.2.5 (2.4): cierre protegido. Antes de cerrar, verifica ops
  /// pendientes/error; si hay, muestra el detalle con "reintentar" y
  /// "sincronizar ahora". Permite cerrar con pendientes bajo
  /// confirmación explícita del riesgo.
  Future<void> _cierreTurno() async {
    // 1.26 (MEDIA 1): check-and-set SÍNCRONO antes del
    // primer await: un segundo toque mientras se verifica
    // el permiso o se cargan los pendientes no abre otro
    // diálogo. La guarda vive hasta que el diálogo cierra.
    if (_cierreEnCurso) return;
    _cierreEnCurso = true;
    try {
      await _cierreTurnoInterno();
    } finally {
      _cierreEnCurso = false;
    }
  }

  Future<void> _cierreTurnoInterno() async {
    // 1.24 Bloque 3: cerrar turno cuelga de can_gestionar_turnos.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canGestionarTurnos, 'gestionar turnos')) {
      return;
    }
    final nOps = _historial.isNotEmpty
        ? ((_historial
                    .firstWhere((h) => h['fecha'] == _hoy(),
                        orElse: () => <String, dynamic>{})['ops']
                as List?)?.length ??
            0)
        : 0;
    // v1.2.5 (2.4): ops del turno sin sincronizar.
    // 1.23 (auditoría extra #5, delta panel A2): misma política
    // que TurnoService.desglosePendientes — este diálogo SUMA
    // dinero como «pendiente del turno», así que solo cuenta lo
    // PROPIO: pendientes estrictamente del usuario (sin el OR
    // user_id IS NULL del push, que le atribuía las ops sin
    // autor), revisión solo de su usuario (la ajena y la sin
    // autor ya no inflan su cierre en teléfono compartido) y
    // forzar: true (informar lo pendiente aunque esté en
    // backoff, igual que el desglose).
    final pendientes = await LocalDb.instance.pendientesParaEnvio(
        _auth.userId,
        forzar: true,
        soloPropias: true);
    final bloqueadas =
        await LocalDb.instance.opsNecesitanRevision(userId: _auth.userId);
    // v1.2.6 (Gemini): desglose financiero de lo pendiente.
    final montoPendiente =
        await montoEfectivoOps([...pendientes, ...bloqueadas]);
    // 1.28 (M3-B7): las ventas de servicios del turno entran
    // en el diálogo: cerrar con el pendiente a la vista
    // incluye QUÉ servicios se vendieron y cuánto efectivo
    // de servicios queda en la mano (ya dentro del total).
    Map<String, dynamic>? cuadreServ;
    try {
      final tidC = _auth.telegramId;
      if (tidC != null) {
        cuadreServ = await svc.cuadreServiciosDia(tidC, _hoy());
      }
    } catch (_) {}
    if (!mounted) return;
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cierre de turno'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(fmtFecha(_hoy())),
            Text(_turnoActual()),
            const Divider(),
            Text('Cobrado hoy: ${fmtMonto(_cobrado)} CUP'),
            Text('   Efectivo: ${fmtMonto(_efectivoHoy)} CUP'),
            Text('   Transferencia: ${fmtMonto(_transferHoy)} CUP'),
            Text('   Operaciones: $nOps'),
            // 1.28 (M3-B7): los servicios del turno, con su
            // efectivo ya dentro del pendiente de abajo.
            if (cuadreServ != null &&
                (((cuadreServ['dosis_sin_agua'] as num?)?.toInt() ??
                        0) +
                    ((cuadreServ['dosis_con_agua'] as num?)
                            ?.toInt() ??
                        0) +
                    ((cuadreServ['agua_suelta'] as num?)?.toInt() ??
                        0) >
                    0)) ...[
              Text(
                  'Servicios hoy: '
                  '${((cuadreServ['dosis_sin_agua'] as num?)?.toInt() ?? 0) + ((cuadreServ['dosis_con_agua'] as num?)?.toInt() ?? 0)} dosis '
                  '(${(cuadreServ['dosis_sin_agua'] as num?)?.toInt() ?? 0} sin agua · '
                  '${(cuadreServ['dosis_con_agua'] as num?)?.toInt() ?? 0} con agua) y '
                  '${(cuadreServ['agua_suelta'] as num?)?.toInt() ?? 0} pomos de agua'),
              Text(
                  '   Su efectivo: ${fmtMonto((cuadreServ['efectivo'] as num?)?.toDouble() ?? 0)} CUP '
                  '(ya está dentro del total a entregar)'),
            ],
            const Divider(),
            Text(
              'Total a entregar a Jc: ${fmtMonto(_pendiente)} CUP',
              style: AppTexto.titulo,
            ),
            Text(
              'Es lo que quedará en tu mano al cerrar: cerrar '
              'el turno no lo reinicia.',
              style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(ctx)),
            ),
            const SizedBox(height: 8),
            Text(
              'Revisa que todo esté bien antes de irte. '
              'El pendiente solo se reinicia cuando Jc confirme '
              'que recibió el dinero.',
              style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(ctx)),
            ),
            // v1.2.5 (2.4): aviso si hay ops sin sincronizar.
            if (!_cerrado &&
                (pendientes.isNotEmpty || bloqueadas.isNotEmpty)) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(AppEspacio.md),
                decoration: BoxDecoration(
                  color: AppColores.alerta
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadio.md),
                  border: Border.all(
                      color: AppColores.alerta
                          .withValues(alpha: 0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: AppColores.alerta,
                            size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${pendientes.length + bloqueadas.length} '
                            'cambio${pendientes.length + bloqueadas.length == 1 ? '' : 's'} '
                            'sin sincronizar'
                            // v1.2.6 (Gemini): desglose en efectivo.
                            '${montoPendiente > 0 ? ' por un total de ${fmtMonto(montoPendiente)} CUP' : ''}',
                            style: AppTexto.secundario.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Se guardaron en este teléfono. Si cierras ahora, '
                      'se enviarán cuando haya conexión.',
                      style: AppTexto.metadato,
                    ),
                    if (bloqueadas.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${bloqueadas.length} necesitan revisión manual.',
                        style: AppTexto.metadato.copyWith(color: AppColores.error, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ],
                ),
              ),
            ],
            if (_cerrado) ...[
              const SizedBox(height: 8),
              const Row(
                children: [
                  Icon(Icons.check_circle_rounded,
                      color: AppColores.exito, size: 16),
                  SizedBox(width: 8),
                  Text('Este turno ya está cerrado',
                      style: TextStyle(
                          color: AppColores.exito,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child:
                Text(_cerrado ? 'Cerrar' : 'Cancelar'),
          ),
          // v1.2.5 (2.4): sincronizar antes de cerrar.
          if (!_cerrado &&
              (pendientes.isNotEmpty || bloqueadas.isNotEmpty))
            TextButton.icon(
              icon: const Icon(Icons.sync_rounded, size: 18),
              label: const Text('Sincronizar ahora'),
              // Argón 1.26 MEDIA: solo sale con la señal;
              // el sync y la reapertura ocurren fuera del
              // diálogo (ver el final de _cierreTurnoInterno).
              onPressed: () => Navigator.of(ctx).pop('sync'),
            ),
          if (!_cerrado)
            ElevatedButton.icon(
              icon: const Icon(Icons.done_all_rounded, size: 18),
              label: Text(pendientes.isNotEmpty || bloqueadas.isNotEmpty
                  ? 'Cerrar de todos modos'
                  : 'Confirmar cierre'),
              onPressed: () async {
                // 1.26 (MEDIA 1): guarda síncrona — un
                // segundo toque mientras corre el cierre
                // no vuelve a encolar la op (camino legado).
                if (_confirmandoCierre) return;
                _confirmandoCierre = true;
                try {
                  // v1.2.5 (2.4): confirmación explícita del riesgo.
                  if ((pendientes.isNotEmpty ||
                          bloqueadas.isNotEmpty) &&
                      ctx.mounted) {
                    final confirma = await showDialog<bool>(
                      context: ctx,
                      builder: (c2) => AlertDialog(
                        title: const Text('¿Cerrar con pendientes?'),
                        content: Text(
                            '${pendientes.length + bloqueadas.length} '
                            'cambio${pendientes.length + bloqueadas.length == 1 ? '' : 's'} '
                            'aún no se sincronizaron'
                            '${montoPendiente > 0 ? ' (${fmtMonto(montoPendiente)} CUP en efectivo)' : ''}. '
                            'Quedarán guardados '
                            'en este teléfono.'),
                        actions: [
                          TextButton(
                              onPressed: () =>
                                  Navigator.pop(c2, false),
                              child: const Text('Volver')),
                          FilledButton(
                              onPressed: () =>
                                  Navigator.pop(c2, true),
                              child:
                                  const Text('Sí, cerrar')),
                        ],
                      ),
                    );
                    if (confirma != true) return;
                  }
                  // Argón P1#10: delegar en TurnoService cuando hay un
                  // turno abierto: confirmarCierre() ya encola el mismo
                  // registrarCierreTurno (reporte a admin preservado)
                  // y marca el turno cerrado en la tabla `turnos`.
                  // Sin turno abierto no hay nada que delegar: se
                  // conserva el camino legado para no perder el reporte.
                  final turnoAbierto =
                      await TurnoService.instance.turnoActual();
                  if (turnoAbierto != null) {
                    // 1.25 T84: la ejecución del cierre es
                    // LA compartida (cierre_turno.dart); esta
                    // hoja solo aporta su forzado y sus
                    // avisos. T-08: si la ejecución falla, se
                    // muestra el motivo y NO se cae al camino
                    // legado (antes se «cerraba de mentira»).
                    final r = await ejecutarCierreTurno(
                      forzado: pendientes.isNotEmpty ||
                          bloqueadas.isNotEmpty,
                    );
                    if (!r.ok) {
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      if (mounted) {
                        mostrarSnack(
                            context, motivoErrorCierre(r.error),
                            significado: SignificadoChip.error);
                      }
                      return;
                    }
                    await vibrarConfirmacion();
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    if (mounted) {
                      setState(() => _cerrado = true);
                      mostrarSnack(context,
                          'Turno cerrado. ¡Buen trabajo!',
                          significado: SignificadoChip.exito);
                    }
                    return;
                  }
                  // v1.2.5-rev5 (Gemini): encolar el cierre para sincronizar.
                  // El admin ve el historial de todos los entrenadores.
                  // v1.2.5-rev6: pagos_count = operaciones de pago reales de
                  // hoy (el número que muestra este diálogo), no la longitud
                  // de la cola sin sincronizar.
                  // G#7 (Hy4): el encolado va PRIMERO y la
                  // meta de «cerrado» solo se marca si la op
                  // quedó en la cola — antes la meta se
                  // sellaba antes, el catch tragaba el fallo
                  // del encolado y el snack decía éxito: el
                  // cierre quedaba marcado local para
                  // siempre y ningún camino lo re-encolaba.
                  try {
                    await SyncEngine.instance.registrarCierreTurno(
                      fecha: _hoy(),
                      turno: _turnoId(),
                      totalCobrado: _cobrado,
                      pagosCount: nOps,
                    );
                  } catch (e) {
                    AppLog.error('mi_turno', 'cierre_legado_sin_encolar',
                        d: '$e');
                    if (ctx.mounted) Navigator.of(ctx).pop();
                    if (mounted) {
                      mostrarSnack(context,
                          'No se pudo registrar el cierre del turno. Inténtalo de nuevo.',
                          significado: SignificadoChip.error);
                    }
                    return;
                  }
                  await LocalDb.instance.setMeta(
                      _claveCierre(),
                      isoHabana(ahoraHabana()));
                  // v1.2.5 (3.2): vibra TRAS la confirmación real.
                  await vibrarConfirmacion();
                  if (ctx.mounted) Navigator.of(ctx).pop();
                  if (mounted) {
                    setState(() => _cerrado = true);
                    mostrarSnack(context, 'Turno cerrado. ¡Buen trabajo!', significado: SignificadoChip.exito);
                  }
                } finally {
                  _confirmandoCierre = false;
                }
              },
            ),
        ],
      ),
    );
    // Argón 1.26 MEDIA: con el diálogo YA cerrado y la
    // guarda _cierreEnCurso aún tomada por _cierreTurno,
    // se sincroniza y se reabre el diálogo con los
    // pendientes frescos. Antes la reapertura se pedía
    // desde dentro del onPressed: si el sync retornaba
    // en milisegundos (sin sesión/red), la guarda seguía
    // tomada y el toque se perdía en silencio.
    if (accion == 'sync' && mounted) {
      await SyncEngine.instance.run(forzar: true);
      if (mounted) await _cierreTurnoInterno();
    }
  }

  String _hoy() => hoyHabanaIso();

  /// Pendiente agrupado por día (para el detalle).
  /// 1.15-turnos (#9): antes solo sumaba mensuales y diarios; ahora
  /// cubre servicios, suplementos, adelantos (restan) y ops en cola.
  Map<String, double> get _pendPorDia {
    final m = <String, double>{};
    void suma(String? f, double v) {
      final d = (f ?? '').length >= 10 ? f!.substring(0, 10) : '—';
      m[d] = (m[d] ?? 0) + v;
    }

    for (final p in _pendMens) {
      suma(p['fecha'] as String?, (p['monto'] as num?)?.toDouble() ?? 0);
    }
    for (final d in _pendDiarios) {
      suma(d['fecha'] as String?, (d['total'] as num?)?.toDouble() ?? 0);
    }
    for (final v in _pendServicios) {
      suma(
          v['fecha'] as String?,
          ((v['precio_unitario'] as num?)?.toDouble() ?? 0) *
              ((v['cantidad'] as num?)?.toDouble() ?? 0));
    }
    for (final v in _pendSuplementos) {
      suma(v['fecha'] as String?, totalVentaCup(v));
    }
    for (final a in _pendAdelantos) {
      suma(a['fecha'] as String?,
          -((a['monto'] as num?)?.toDouble() ?? 0));
    }
    for (final o in _pendOps) {
      suma(o.$1, o.$2);
    }
    // 1.22 T-02: el arrastre de la parcial es una línea del día
    // de la liquidación; sin ella el desglose no cuadraba con
    // el total canónico (que sí lo suma, pendienteEntrega).
    if (_arrastreCup > 0) {
      suma(_arrastreFecha, _arrastreCup);
    }
    final dias = m.keys.toList()..sort((a, b) => b.compareTo(a));
    return {for (final d in dias) d: m[d]!};
  }

  /// Agrupa el historial por semana (lunes a domingo) para vista compacta.
  /// Devuelve lista de {titulo, total, dias}.
  List<Map<String, dynamic>> _agruparPorSemana(
      List<Map<String, dynamic>> hist) {
    final porSemana = <String, List<Map<String, dynamic>>>{};
    for (final h in hist) {
      final f = '${h['fecha'] ?? ''}';
      if (f.length < 10) continue;
      final dt = DateTime.tryParse(f.substring(0, 10));
      if (dt == null) continue;
      final lunes =
          dt.subtract(Duration(days: dt.weekday - 1));
      final clave = _iso(lunes);
      porSemana.putIfAbsent(clave, () => []).add(h);
    }
    final claves = porSemana.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final k in claves)
        {
          'titulo':
              'Semana del ${fmtFecha(k)}',
          'total': porSemana[k]!
              .fold<double>(
                  0,
                  (t, h) =>
                      t +
                      ((h['cobrado'] as num?)?.toDouble() ??
                          0)),
          'dias': porSemana[k]!,
        }
    ];
  }

  @override
  Widget build(BuildContext context) {
    // v1.0.16: para el dueño es "Mis cobros" (no trabaja turnos);
    // se oculta todo lo de pendiente/entregas que no le aplica.
    // 1.22 T-10: esDueno unificado a isOwner (antes isAdmin: un
    // admin que no es el dueño veía la vista del dueño).
    final esDueno = _auth.isOwner;
    return Scaffold(
      appBar: appBarIron(context, esDueno ? 'Mis cobros' : 'Mi turno'),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: _cargando
                ? const EstadoCargando(
                    texto: 'Cargando tu turno…')
                : _errorCarga
                    ? EstadoError(
                        detalle: 'No se pudieron cargar los datos '
                            'de tu turno. Lo que haya cobrado hoy '
                            'no se puede mostrar hasta que la '
                            'lectura funcione.',
                        onReintentar: _cargar,
                      )
                    : RefrescoIron(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  Tarjeta(
                    child: Column(
                      children: [
                        const Row(
                          mainAxisAlignment:
                              MainAxisAlignment.center,
                          children: [
                            Icon(Icons.payments_rounded,
                                color: AppColores.exito,
                                size: 28),
                            SizedBox(
                                width: AppEspacio.sm),
                            Text('Cobrado hoy',
                                style: AppTexto.subtitulo),
                          ],
                        ),
                        const SizedBox(
                            height: AppEspacio.sm),
                        Text('${fmtMonto(_cobrado)} CUP',
                            style: AppTexto.displayPequeno.copyWith(
                                color:
                                    AppColores.naranja)),
                        const SizedBox(height: 4),
                        Text(
                          'Efectivo: ${fmtMonto(_efectivoHoy)} · '
                          'Transferencia: ${fmtMonto(_transferHoy)}',
                          style: AppTexto.secundario,
                        ),
                        // Yunque B (YB-TRA-08): suma incompleta
                        // visible junto a la cifra que afecta.
                        if (_sumaIncompleta > 0) ...[
                          const SizedBox(height: 4),
                          Text(
                            '⚠ $_sumaIncompleta operación(es) de '
                            'hoy no se pudieron sumar: el total '
                            'puede estar incompleto.',
                            style: AppTexto.secundario.copyWith(
                                color: AppColores.alerta),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!esDueno) ...[
                    // v1.0.16: turno actual según la hora
                    Center(
                      child: Chip(
                        avatar: Icon(
                            _iconoTurno(),
                            size: 18,
                            color: AppColores.textoSecundario(context)),
                        label: Text(_etiquetaTurnoChip(),
                            style: AppTexto.secundario),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 1.28 (M3-B6): el aviso del auto-cierre de
                    // un turno olvidado, hasta reconocerlo.
                    if (_autocierre != null) ...[
                      _tarjetaAutocierre(),
                      const SizedBox(height: AppEspacio.md),
                    ],
                    // v1.0.16: qué tengo que entregar (idea 2)
                    // 1.25 T84: UNA sola tarjeta de
                    // «qué tengo que entregar» — antes la
                    // cifra vivía aquí Y en el ListTile de
                    // debajo; la tarjeta entera abre el
                    // detalle de Pendiente a entregar.
                    Tarjeta(
                      onTap: () => Navigator.of(context)
                          .push(RutaIron(
                              builder: (_) =>
                                  const PendienteScreen()))
                          .then((_) => _cargar()),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.outbox_rounded,
                                  color: AppColores.info,
                                  size: 20),
                              SizedBox(
                                  width: AppEspacio.sm),
                              Expanded(
                                child: Text(
                                    'Qué tengo que entregar',
                                    style: AppTexto.subtitulo),
                              ),
                              Icon(Icons.chevron_right_rounded,
                                  color: AppColores.naranja),
                            ],
                          ),
                          const SizedBox(
                              height: AppEspacio.sm),
                          Text(
                              'Hoy cobraste ${fmtMonto(_efectivoHoy)} CUP en efectivo '
                              '(+ ${fmtMonto(_transferHoy)} por transferencia, que va directo).',
                              style: AppTexto.cuerpo),
                          const SizedBox(height: 4),
                          Text(
                            'Total a entregar a Jc: ${fmtMonto(_pendiente)} CUP',
                            style: AppTexto.subtitulo.copyWith(
                                color: AppColores.naranja),
                          ),
                          if (_pendienteUsd > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Total USD a entregar: ${_pendienteUsd.toStringAsFixed(2)} USD',
                              style: AppTexto.subtitulo.copyWith(
                                  color: AppColores.naranja),
                            ),
                          ],
                        ],
                      ),
                    ),
                    // 1.25 T79: la venta rápida de dosis vive AQUÍ,
                    // en Mi Turno (es una acción del turno),
                    // no en Mi Nómina (que es un informe).
                    // C3: venta rápida de dosis (mismo flujo).
                    Tarjeta(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Venta rápida de dosis',
                              style: AppTexto.subtitulo),
                          const SizedBox(height: AppEspacio.sm),
                          Wrap(
                            spacing: AppEspacio.sm,
                            runSpacing: AppEspacio.sm,
                            children: [
                              FilledButton.icon(
                                icon: const Icon(Icons.local_drink_rounded,
                                    size: 18),
                                label: const Text('Dosis'),
                                onPressed: () => Navigator.of(context).push(
                                  RutaIron(
                                    builder: (_) => const ServiciosScreen(
                                        tipoInicial: 'dosis_sin_agua'),
                                  ),
                                ),
                              ),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.water_drop_rounded,
                                    size: 18),
                                label: const Text('Dosis con agua'),
                                onPressed: () => Navigator.of(context).push(
                                  RutaIron(
                                    builder: (_) => const ServiciosScreen(
                                        tipoInicial: 'dosis_con_agua'),
                                  ),
                                ),
                              ),
                              // 1.28 (M3-B8): «Otra igual» —
                              // repite la última venta (mismo
                              // producto, pomo, método y
                              // cantidad) en un toque, para el
                              // siguiente cliente del mostrador.
                              if (_ultimaVenta != null)
                                OutlinedButton.icon(
                                  icon: _repitiendo
                                      ? const SizedBox(
                                          width: 16,
                                          height: 16,
                                          child:
                                              CircularProgressIndicator(
                                                  strokeWidth: 2),
                                        )
                                      : const Icon(Icons.replay_rounded,
                                          size: 18),
                                  label: Text(
                                      'Otra igual: ${_etiquetaUltimaVenta()}'),
                                  onPressed:
                                      _repitiendo ? null : _repetirVenta,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppEspacio.md),
                    const SizedBox(height: 8),
                    Tarjeta(
                      color: AppColores.info
                          .withValues(alpha: 0.08),
                      child: const Row(
                        children: [
                          Icon(Icons.info_rounded,
                              color: AppColores.info),
                          SizedBox(
                              width: AppEspacio.sm),
                          Expanded(
                            child: Text(
                              'El "Pendiente a entregar" SOLO se reinicia cuando '
                              'Jc confirma que recibió el dinero. Registrar más '
                              'cobros no lo reduce: lo aumenta.',
                              style: AppTexto.secundario,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_pendPorDia.isNotEmpty) ...[
                      const EncabezadoSeccion(
                          titulo:
                              'Detalle del pendiente por día'),
                      for (final e in _pendPorDia.entries)
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.calendar_today_rounded, size: 20, color: AppColores.textoSecundario(context)),
                          title: Text(fmtFecha(e.key)),
                          trailing: Text(
                              '${fmtMonto(e.value)} CUP',
                              style: const TextStyle(
                                  fontWeight:
                                      FontWeight.bold)),
                        ),
                    ],
                    const SizedBox(height: 12),
                    Tarjeta(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        leading: const Icon(Icons.inventory_2_rounded,
                            size: 28, color: AppColores.info),
                        title: const Text(
                            'Última entrega confirmada'),
                        subtitle: Text(_ultimaEntrega ==
                                null
                            ? 'Aún no hay entregas confirmadas'
                            : '${fmtFecha(_ultimaEntrega!['fecha'] as String?)}'
                                ' — ${fmtMonto(_ultimaEntrega!['monto'])} CUP'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // v1.0.16: mi tendencia (idea 4)
                    Tarjeta(
                      child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.trending_up_rounded,
                                    color: AppColores.textoSecundario(context),
                                    size: 20),
                                SizedBox(
                                    width: AppEspacio.sm),
                                Text('Mi tendencia',
                                    style:
                                        AppTexto.subtitulo),
                              ],
                            ),
                            const SizedBox(
                                height: AppEspacio.sm),
                            _filaTendencia('Hoy vs ayer',
                                _cobradoAyer, _cobrado),
                            const SizedBox(height: 4),
                            // F3-10: la ventana es de 7 días
                            // RODANTES (no la semana natural
                            // del historial): el rótulo lo dice.
                            _filaTendencia(
                                'Últimos 7 días vs anteriores',
                                _semanaAnt,
                                _cobradoSemana()),
                          ],
                        ),
                    ),
                    const SizedBox(height: 12),
                    // v1.0.16: mis vencimientos (idea 3)
                    Tarjeta(
                      child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.alarm_rounded,
                                    color:
                                        AppColores.alerta,
                                    size: 20),
                                const SizedBox(
                                    width: AppEspacio.sm),
                                Text(
                                    'Mis vencimientos (${_vencimientos.length})',
                                    style:
                                        AppTexto.subtitulo),
                              ],
                            ),
                            const SizedBox(
                                height: AppEspacio.sm),
                            if (_vencimientos.isEmpty)
                              Text(
                                  'Nada por vencer en 7 días.',
                                  style: AppTexto.secundario.copyWith(color: AppColores
                                          .textoSecundario(context))),
                            for (final v in (_verTodosVencimientos
                                ? _vencimientos
                                : _vencimientos.take(10)))
                              ListTile(
                                dense: true,
                                contentPadding:
                                    EdgeInsets.zero,
                                leading: Icon(Icons.circle_rounded,
                                    size: 12,
                                    color: (v['vencido'] == true)
                                        ? AppColores.error
                                        : AppColores.alerta),
                                title: Text(
                                    '${v['nombre']}',
                                    style: AppTexto.cuerpo),
                                subtitle: Text(
                                    (v['vencido'] == true)
                                        ? 'Venció: ${fmtFecha(v['pagado_hasta'])}'
                                        : 'Vence: ${fmtFecha(v['pagado_hasta'])}',
                                    style:
                                        AppTexto.metadato),
                                onTap: () {
                                  final cid =
                                      v['id'] as int?;
                                  if (cid == null) {
                                    return;
                                  }
                                  Navigator.of(context)
                                      .push(RutaIron(
                                          builder: (_) =>
                                              FichaScreen(
                                                  clienteId:
                                                      cid)));
                                },
                              ),
                            if (_vencimientos.length > 10)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  icon: Icon(_verTodosVencimientos
                                      ? Icons.expand_less_rounded
                                      : Icons.expand_more_rounded),
                                  label: Text(_verTodosVencimientos
                                      ? 'Ver menos'
                                      : 'Ver todos (${_vencimientos.length})'),
                                  onPressed: () => setState(() =>
                                      _verTodosVencimientos =
                                          !_verTodosVencimientos),
                                ),
                              ),
                          ],
                        ),
                    ),
                    const SizedBox(height: 12),
                    // v1.0.16: cierre de turno (idea 1)
                    // v1.1.1: cierre real por turno, sin requerir pagos diarios
                    SizedBox(
                      width: double.infinity,
                      child: _cerrado
                          ? OutlinedButton.icon(
                              icon: const Icon(
                                  Icons.check_circle_rounded,
                                  color: AppColores.exito),
                              label: Text(
                                  'Turno cerrado (${_turnoActual().toLowerCase()})'),
                              // 1.15-turnos (#3): un turno cerrado no
                              // se vuelve a cerrar (botón deshabilitado).
                              onPressed: null,
                            )
                          : ElevatedButton.icon(
                              icon:
                                  const Icon(Icons.done_all_rounded),
                              label: const Text(
                                  'Cerrar mi turno'),
                              onPressed: _cierreTurno,
                            ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Tarjeta(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(Icons.calendar_month_rounded,
                          size: 28, color: AppColores.textoSecundario(context)),
                      title: const Text('Cobrado este mes'),
                      trailing: Text('${fmtMonto(_cobradoMes)} CUP',
                          style: AppTexto.titulo),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const EncabezadoSeccion(
                      titulo: 'Historial diario'),
                  if (_historial.isEmpty)
                    Text(
                        'Sin cobros registrados en los últimos 60 días.',
                        style: TextStyle(
                            color: AppColores
                                .textoSecundario(context))),
                  // v1.0.16: agrupado por semana (idea 8)
                  for (final sem
                      in _agruparPorSemana(_historial))
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: AppEspacio.xs),
                      child: Tarjeta(
                        padding: EdgeInsets.zero,
                        child: ExpansionTile(
                        leading: Icon(Icons.calendar_month_rounded,
                            size: 22, color: AppColores.textoSecundario(context)),
                        title: Text(sem['titulo'] as String,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        trailing: Text(
                            '${fmtMonto(sem['total'])} CUP',
                            style: const TextStyle(
                                fontWeight: FontWeight.bold)),
                        subtitle: Text(
                            '${(sem['dias'] as List).length} días con cobros',
                            style: AppTexto.metadato),
                        children: [
                          for (final h in sem['dias']
                              as List<Map<String, dynamic>>)
                            ExpansionTile(
                              dense: true,
                              leading: Icon(Icons.calendar_today_rounded,
                                  size: 18, color: AppColores.textoSecundario(context)),
                              title: Text(
                                  fmtFecha(
                                      h['fecha'] as String?),
                                  style: AppTexto.cuerpo.copyWith(fontWeight: FontWeight.bold)),
                              trailing: Text(
                                  '${fmtMonto(h['cobrado'])} CUP',
                                  style: AppTexto.cuerpo.copyWith(fontWeight: FontWeight.bold)),
                              subtitle: Text(
                                  'Efectivo: ${fmtMonto(h['efectivo'])} · '
                                  'Transf.: ${fmtMonto(h['transferencia'])}',
                                  style: AppTexto.metadato),
                              children: [
                                for (final op in (h['ops']
                                        as List<
                                            Map<String,
                                                String>>))
                                  ListTile(
                                    dense: true,
                                    title: Text(
                                        op['etiqueta'] ?? '',
                                        style:
                                            AppTexto.secundario),
                                    trailing: Text(
                                        '${op['monto']} CUP',
                                        style:
                                            AppTexto.secundario),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
