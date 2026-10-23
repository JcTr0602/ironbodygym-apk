/// Administración (solo admin) — Panel del dueño desde v1.6.0.
///
/// Consola del dueño: pendientes con acción, acciones rápidas de caja,
/// resumen del mes y los módulos de siempre (estadísticas, montos,
/// usuarios APK, pendiente a entrega, gastos, cierre de caja, papelera
/// y exportar). Todo funciona offline: los cambios se encolan y suben
/// al sincronizar.
library;

import 'dart:async';
import 'dart:io';

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../invitados.dart' as invitados_svc;
import '../localdb.dart';
import '../plus_reportes.dart';
import '../negocio.dart';
import '../nomina_calc.dart';
import '../perfil.dart';
import '../permisos.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../tipos_pago.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'admin_secciones.dart';
import 'arqueo.dart';
import 'gympedia.dart';
import 'auditoria.dart';
import 'auditoria_silenciosa.dart';
import 'nomina.dart';
import 'horario_gym.dart';
import 'cumpleanos_mes.dart';
import 'riesgo.dart';
import 'papelera.dart';
import 'congelados.dart';
import 'control_acceso.dart';
import 'turnos_hub.dart';
import 'comparativa_mensual.dart';
import 'pagaron_mes.dart';
import 'pagos_por_metodo.dart';
import 'incidencias/lista_incidencias.dart';
import 'historial_caja.dart';
import 'invitados.dart';
import 'exportar_excel.dart';
import 'incidencias_sync.dart';
import 'pago.dart';
import 'reportes_plus.dart';
import 'reservas.dart';
import 'suplementos.dart';
import 'widgets.dart';

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  double _ingresos = 0;
  int _inscMes = 0;
  int _morosos = 0;
  List<Map<String, dynamic>> _pend = [];
  List<Map<String, dynamic>> _inscPorEntrenador = [];
  List<Map<String, dynamic>> _gastos = [];
  Map<String, double> _caja = {'efectivo': 0, 'transferencia': 0};
  double _gastosHoy = 0;
  final Map<String, TextEditingController> _montos = {};
  // v1.2.4: datos bancarios (strings, no montos)
  final Map<String, TextEditingController> _bancarios = {};
  bool _cargando = true;
  // Salud del sistema
  SyncDetalle _syncDet = const SyncDetalle();
  int _pendientesSubir = 0;

  // Panel del dueño (v1.6.0): datos de los bloques nuevos.
  int _pagosMes = 0;
  int _clientesActivos = 0;
  List<Map<String, dynamic>> _reservasSolicitadas = [];
  Map<String, String> _nombreSupl = {};
  List<Map<String, dynamic>> _stockCritico = [];
  List<String> _sinReporteAyer = [];
  List<String> _sinReporteHoy = [];
  int _incidenciasPend = 0;
  // Solicitudes de inscripción de invitados por atender (del
  // servicio de Invitados; vacío si no hay conexión al cargar).
  List<invitados_svc.InvitadoResumen> _solicitudesInvitados = [];
  // Panel 1.6.0: la RPC de solicitudes NO bloquea el pintado del
  // panel: _cargar pinta con los datos locales y la fila queda en
  // estado «cargando» hasta que la RPC resuelve (ver
  // _cargarSolicitudesInvitados).
  bool _solicitudesCargando = true;
  int _solicitudesGen = 0;
  // G2 (v1.7.0): reportes App Plus pendientes (misma pauta de dos
  // fases que las solicitudes: la RPC no bloquea el pintado; si
  // falla, la fila no aparece) y contador de Cuentas a la Casa
  // (consulta local al espejo, en el pase principal).
  List<ReportePlus> _reportesPlus = [];
  bool _reportesPlusCargando = true;
  int _reportesPlusGen = 0;
  int _cuentasCasa = 0;
  final PlusReportesService _plusSvc = PlusReportesService();

  List<TipoPago> _tipos = [];
  // v1.3.1: pago por cliente a entrenadores (movido desde Ajustes, solo dueño).
  int _pagoEntrenador = 150;

  static const _clavesMonto = [
    ('transferencia', 'Mensualidad por transferencia'),
    ('pago_diario', 'Pago diario'),
    // v1.2.1: precio de menores configurable (antes hardcodeado 1500).
    ('mensualidad_menores', 'Mensualidad menores'),
    // v1.2.1: tasa USD del día para mostrar precios CUP en suplementos.
    ('tasa_usd', 'Tasa USD (CUP por 1 USD)'),
    // v1.7.0 (G2): precio del App Plus (30 días). Default 1000 CUP;
    // al guardar se republica a info_publica, que es lo que lee la
    // cotización de S2 (ver _guardarMontos).
    ('precio_app_plus', 'Precio App Plus (30 días)'),
  ];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    for (final c in _montos.values) {
      c.dispose();
    }
    for (final c in _bancarios.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _cargar() async {
    final ing = await ingresosMes();
    final insc = await inscripcionesMes();
    final mor = await morosos();
    final pend = await pendientePorEntrenador();
    final inscEntrenador = await inscripcionesPorEntrenador();
    final gastos = await gastosTodos();
    final caja = await cobradoHoyPorMetodo();
    final hoy = DateTime.now();
    final hoyIso = '${hoy.year.toString().padLeft(4, '0')}-'
        '${hoy.month.toString().padLeft(2, '0')}-'
        '${hoy.day.toString().padLeft(2, '0')}';
    final gh = await gastosDe(hoyIso);
    final aj = await LocalDb.instance.getAjustes();
    final tipos = await getTiposPago(soloActivos: false);
    final pagoEnt = await PerfilService.instance.getPagoEntrenador();
    // Salud del sistema
    final det = await SyncEngine.instance.detalle();
    final pendSubir = await LocalDb.instance.countPendingOps();
    // Panel del dueño (v1.6.0): KPIs del mes y pendientes reales,
    // todos de fuentes existentes (sin cifras inventadas).
    // Panel 1.6.0 (decisión de Jc): el KPI «Pagos este mes» usa la
    // definición del dueño — la MISMA de Home y de la lista
    // (NominaCalc: descuenta a quien vence dentro del propio mes).
    // pagosRealizadosMes() conserva su sentido contable en sus
    // otros usos; aquí no se usa.
    final pagosMes = await NominaCalc.clientesQuePagaronElMes(
        NominaCalc.prefMesActual());
    final activos = await activosCount();
    final reservas = await LocalDb.instance.allMirror('reservas');
    final solicitadas = [
      for (final r in reservas)
        if (r['estado'] == 'solicitada') r,
    ]..sort((a, b) => '${a['creada_ts']}'.compareTo('${b['creada_ts']}'));
    final supls = await LocalDb.instance.allMirror('suplementos');
    final nombreSupl = {
      for (final s in supls) '${s['id']}': '${s['nombre'] ?? ''}',
    };
    // Stock crítico: mismo criterio que el chip de Suplementos
    // (activo y 0 < stock <= umbral propio, 3 por defecto).
    final criticos = <Map<String, dynamic>>[];
    for (final s in supls) {
      final act = s['activo'];
      final inactivo = act == 0 ||
          act == false ||
          s['eliminado'] == 1 ||
          s['eliminado'] == true;
      if (inactivo) continue;
      final stock = (s['stock'] as num?)?.toInt() ?? 0;
      final umbral = (s['umbral_stock'] as num?)?.toInt() ?? 3;
      if (stock > 0 && stock <= umbral) criticos.add(s);
    }
    criticos.sort((a, b) => ((a['stock'] as num?)?.toInt() ?? 0)
        .compareTo((b['stock'] as num?)?.toInt() ?? 0));
    final hoyH = ahoraHabana();
    String isoDia(DateTime d) =>
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    final sinHoy = await turnosSinReporte(isoDia(hoyH));
    final sinAyer = await turnosSinReporte(
        isoDia(hoyH.subtract(const Duration(days: 1))));
    final incidencias = await incidenciasSyncPendientes();
    // v1.7.0: contador de Cuentas a la Casa (consulta local).
    final casa = await LocalDb.instance.conteoCuentasCasa();
    // Solicitudes de invitados: la bandeja vive en el servidor y
    // su RPC ya NO se espera aquí (panel 1.6.0): con la red
    // colgada, esperar en serie retrasaba TODO el panel aunque
    // los datos locales ya estaban listos. Se pinta primero y la
    // fila se rellena cuando la RPC resuelve (_cargarSolicitudes
    // Invitados); si la RPC falla, la fila no aparece, como antes.
    if (mounted) {
      setState(() {
        _ingresos = ing;
        _inscMes = insc;
        _morosos = mor;
        _pend = pend;
        _inscPorEntrenador = inscEntrenador;
        _gastos = gastos;
        _caja = caja;
        _gastosHoy = gh;
        _syncDet = det;
        _pendientesSubir = pendSubir;
        _pagosMes = pagosMes;
        _clientesActivos = activos;
        _reservasSolicitadas = solicitadas;
        _nombreSupl = nombreSupl;
        _stockCritico = criticos;
        _sinReporteAyer = sinAyer;
        _sinReporteHoy = sinHoy;
        _incidenciasPend = incidencias.length;
        _solicitudesInvitados = [];
        _solicitudesCargando = true;
        _reportesPlus = [];
        _reportesPlusCargando = true;
        _cuentasCasa = casa;
        _tipos = tipos;
        _pagoEntrenador = pagoEnt;
        for (final (clave, _) in _clavesMonto) {
          final v = aj[clave] as num?;
          _montos
              .putIfAbsent(clave, () => TextEditingController())
              .text = v != null
                  ? '$v'
                  : (clave == 'precio_app_plus' ? '1000' : '');
        }
        // v1.2.4: cargar datos bancarios (strings)
        // v0.6.0: + titular de la cuenta (Pieza A de Clientes)
        for (final clave in ['tarjeta_bandec', 'tarjeta_bpa', 'movil_confirmacion', 'titular']) {
          _bancarios
              .putIfAbsent(clave, () => TextEditingController())
              .text = '${aj[clave] ?? ''}';
        }
        _cargando = false;
      });
    }
    // La fila de solicitudes se rellena en segundo plano, sin
    // bloquear el pintado que acaba de ocurrir.
    unawaited(_cargarSolicitudesInvitados());
    unawaited(_cargarReportesPlus());
  }

  /// G2 (v1.7.0): segundo pase — trae los reportes App Plus
  /// pendientes por RPC. Si la RPC falla, la fila no aparece (el
  /// panel sigue offline-first), como las solicitudes.
  Future<void> _cargarReportesPlus() async {
    final gen = ++_reportesPlusGen;
    List<ReportePlus> lista;
    try {
      lista = await _plusSvc.pendientes();
    } catch (_) {
      lista = [];
    }
    if (!mounted || gen != _reportesPlusGen) return;
    setState(() {
      _reportesPlus = lista;
      _reportesPlusCargando = false;
    });
  }

  /// Segundo pase de _cargar: resuelve la RPC de solicitudes de
  /// invitados y rellena su fila con un segundo setState. Si la
  /// RPC falla, la fila simplemente no aparece (el panel sigue
  /// offline-first, como antes). La generación descarta el
  /// resultado si una recarga más nueva ya pidió el suyo.
  Future<void> _cargarSolicitudesInvitados() async {
    final gen = ++_solicitudesGen;
    List<invitados_svc.InvitadoResumen> lista;
    try {
      lista =
          await invitados_svc.InvitadosService().solicitudesPendientes();
    } catch (_) {
      lista = [];
    }
    if (!mounted || gen != _solicitudesGen) return;
    setState(() {
      _solicitudesInvitados = lista;
      _solicitudesCargando = false;
    });
  }

  void _ir(Widget w) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => w))
        .then((_) => _cargar());
  }

  /// Navega a una subpantalla y recarga al volver (para las secciones).
  Future<void> _irYRecargar(Widget w) async {
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => w));
    await _cargar();
  }

  // -- montos ----------------------------------------------------------
  Future<void> _guardarMontos() async {
    final cambios = <String, double>{};
    for (final (clave, _) in _clavesMonto) {
      final v = double.tryParse(
          (_montos[clave]?.text ?? '').replaceAll(',', '.'));
      if (v != null && v > 0) cambios[clave] = v;
    }
    if (cambios.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No hay montos válidos para guardar')));
      return;
    }
    final mensaje = [
      for (final e in cambios.entries)
        '• ${_etiqueta(e.key)}: ${fmtMonto(e.value)} CUP',
      '',
      'Se aplicará en la próxima sincronización.',
    ].join('\n');
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cambiar precios',
      mensaje: mensaje,
      aceptar: 'Confirmar',
      icono: Icons.price_change,
    );
    if (ok != true || !mounted) return;
    for (final e in cambios.entries) {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': e.key, 'valor': e.value},
      );
    }
    // v1.3.1: actualización optimista del espejo local.
    final aj = await LocalDb.instance.getAjustes();
    for (final e in cambios.entries) {
      aj[e.key] = e.value;
    }
    await LocalDb.instance.setAjustes(aj);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Precios guardados (se sincronizarán)')));
    SyncEngine.instance.push();
    // v1.7.0 (G2 + panel): el precio del App Plus se REPUBLICA a
    // info_publica al guardar (patrón del horario canónico de la
    // 1.6.0): la cotización de S2 lee el precio de ahí, no del
    // ajuste local. La republicación va con reintento durable:
    // la clave queda marcada como pendiente en meta ANTES del
    // intento y el gancho de fin de sync la republica tras cada
    // sincronización exitosa hasta lograrlo — si el guardado
    // fue sin red, el precio público no queda obsoleto en
    // silencio esperando a que el dueño vuelva a guardar.
    final precioPlus = cambios['precio_app_plus'];
    if (precioPlus != null) {
      final entero = precioPlus.round();
      unawaited(invitados_svc.InvitadosService()
          .guardarInfoPublicaConReintento(
              'precio_app_plus', '$entero'));
    }
  }

  /// v1.2.4: Guardar datos bancarios (strings, no montos).
  Future<void> _guardarBancarios() async {
    // v1.2.4 (Hark): valida formato y solo envía lo que cambió.
    final aj = await LocalDb.instance.getAjustes();
    if (!mounted) return;
    final cambios = <String, String>{};
    final errores = <String>[];
    for (final clave in ['tarjeta_bandec', 'tarjeta_bpa', 'movil_confirmacion', 'titular']) {
      final v = (_bancarios[clave]?.text ?? '').trim();
      // v1.2.4: vaciar un dato bancario se decide en el servidor
      // (pendiente de aprobación); la app solo envía valores no vacíos.
      if (v.isEmpty) continue;
      // v0.6.0: el titular es un nombre, no un número: sin validación
      // de dígitos ni normalización; se envía el texto tal cual.
      if (clave == 'titular') {
        if (v.length > 80) {
          errores.add('Titular: máx. 80 caracteres');
          continue;
        }
        if (v != '${aj[clave] ?? ''}'.trim()) cambios[clave] = v;
        continue;
      }
      final digitos = v.replaceAll(RegExp(r'[\s-]'), '');
      {
        if (clave.startsWith('tarjeta') &&
            !RegExp(r'^\d{16}$').hasMatch(digitos)) {
          errores.add('${clave == 'tarjeta_bandec' ? 'BANDEC' : 'BPA'}: 16 dígitos');
          continue;
        }
        if (clave == 'movil_confirmacion' &&
            !RegExp(r'^[56]\d{7}$').hasMatch(digitos)) {
          errores.add('Móvil: 8 dígitos, empieza por 5 o 6');
          continue;
        }
      }
      final normal = clave.startsWith('tarjeta') && digitos.length == 16
          ? [for (var i = 0; i < 16; i += 4) digitos.substring(i, i + 4)].join(' ')
          : digitos;
      if (normal != '${aj[clave] ?? ''}'.trim()) cambios[clave] = normal;
    }
    if (errores.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Revisa: ${errores.join(' · ')}')));
      return;
    }
    if (cambios.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No hay cambios en los datos bancarios')));
      return;
    }
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Guardar datos bancarios',
      mensaje: 'Se actualizarán los datos de transferencia.\n'
          'Se aplicará en la próxima sincronización.',
      aceptar: 'Confirmar',
      icono: Icons.account_balance,
    );
    if (ok != true || !mounted) return;
    for (final e in cambios.entries) {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': e.key, 'valor': e.value},
      );
    }
    // v1.3.1: actualización optimista del espejo local.
    for (final e in cambios.entries) {
      aj[e.key] = e.value;
    }
    await LocalDb.instance.setAjustes(aj);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Datos bancarios guardados (se sincronizarán)')));
    SyncEngine.instance.push();
  }

  String _etiqueta(String clave) {
    for (final (c, e) in _clavesMonto) {
      if (c == clave) return e;
    }
    return clave;
  }

  // -- tipos de pago dinámicos (v1.0.16) --------------------------------
  static const _tiposFijos = {
    'mensual',
    'menores',
    'semanal',
    'quincenal'
  };
  bool _esTipoFijo(String id) => _tiposFijos.contains(id);

  Future<void> _persistirTipos() async {
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'guardar_tipos_pago',
      payload: {
        'tipos': [for (final t in _tipos) t.toJson()],
      },
    );
    // v1.3.1: optimismo local (tipos visibles al instante al cobrar).
    final aj = await LocalDb.instance.getAjustes();
    aj['tipos_pago'] = [for (final t in _tipos) t.toJson()];
    await LocalDb.instance.setAjustes(aj);
    SyncEngine.instance.push();
  }

  Future<void> _toggleTipo(TipoPago t, bool v) async {
    setState(() {
      _tipos = [
        for (final x in _tipos)
          if (x.id == t.id)
            TipoPago(
                id: x.id,
                nombre: x.nombre,
                monto: x.monto,
                dias: x.dias,
                activo: v,
                soloMenores: x.soloMenores)
          else
            x,
      ];
    });
    await _persistirTipos();
  }

  Future<void> _editarTipo(TipoPago t) async {
    final nombreCtrl = TextEditingController(text: t.nombre);
    final montoCtrl =
        TextEditingController(text: '${t.monto}');
    final diasCtrl =
        TextEditingController(text: '${t.dias}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Editar ${t.nombre}',
        iconoTitulo: Icons.edit,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CampoTexto(
                controller: nombreCtrl, etiqueta: 'Nombre'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: montoCtrl,
                etiqueta: 'Monto (CUP)',
                teclado: const TextInputType
                    .numberWithOptions(decimal: true)),
            const SizedBox(height: 8),
            CampoTexto(
                controller: diasCtrl,
                etiqueta: 'Días que cubre',
                teclado: TextInputType.number),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
              child: const Text('Guardar')),
        ],
      ),
    );
    final nombre = nombreCtrl.text.trim();
    final monto = double.tryParse(
        montoCtrl.text.trim().replaceAll(',', '.'));
    final dias = int.tryParse(diasCtrl.text.trim());
    // v1.3.2 (Argón #11): NO hacer dispose tras showDialog; el diálogo
    // sigue animando su cierre y el controller aún está en uso.
    // Los controllers locales los recoge el GC (igual que dialogo_pago).
    if (ok != true || !mounted) return;
    if (nombre.isEmpty || monto == null || monto <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nombre y monto válido requeridos')));
      return;
    }
    setState(() {
      _tipos = [
        for (final x in _tipos)
          if (x.id == t.id)
            TipoPago(
                id: x.id,
                nombre: nombre,
                monto: monto,
                dias: (dias != null && dias > 0) ? dias : x.dias,
                activo: x.activo,
                soloMenores: x.soloMenores)
          else
            x,
      ];
    });
    await _persistirTipos();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Tipo de pago actualizado (se sincronizará)')));
  }

  Future<void> _agregarTipo() async {
    final nombreCtrl = TextEditingController();
    final montoCtrl = TextEditingController();
    final diasCtrl = TextEditingController(text: '30');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Nuevo tipo de pago',
        iconoTitulo: Icons.add,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CampoTexto(
                controller: nombreCtrl,
                etiqueta: 'Nombre (ej: Trimestre)'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: montoCtrl,
                etiqueta: 'Monto (CUP)',
                teclado: const TextInputType
                    .numberWithOptions(decimal: true)),
            const SizedBox(height: 8),
            CampoTexto(
                controller: diasCtrl,
                etiqueta: 'Días que cubre',
                teclado: TextInputType.number),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
              child: const Text('Agregar')),
        ],
      ),
    );
    final nombre = nombreCtrl.text.trim();
    final monto = double.tryParse(
        montoCtrl.text.trim().replaceAll(',', '.'));
    final dias = int.tryParse(diasCtrl.text.trim()) ?? 30;
    // v1.3.2 (Argón #11): sin dispose tras showDialog (ver arriba).
    if (ok != true || !mounted) return;
    if (nombre.isEmpty || monto == null || monto <= 0 || dias <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Nombre, monto y días válidos requeridos')));
      return;
    }
    final id = nombre
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (id.isEmpty || _tipos.any((x) => x.id == id)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ya existe un tipo con ese nombre')));
      return;
    }
    setState(() {
      _tipos = [
        ..._tipos,
        TipoPago(
            id: id, nombre: nombre, monto: monto, dias: dias),
      ];
    });
    await _persistirTipos();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Tipo de pago agregado (se sincronizará)')));
  }

  Future<void> _eliminarTipo(TipoPago t) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Eliminar tipo',
      mensaje: '¿Eliminar "${t.nombre}"? Ya no aparecerá al cobrar.',
      aceptar: 'Eliminar',
      peligro: true,
      icono: Icons.delete_outline,
    );
    if (ok != true || !mounted) return;
    setState(() {
      _tipos = [for (final x in _tipos) if (x.id != t.id) x];
    });
    await _persistirTipos();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Tipo de pago eliminado (se sincronizará)')));
  }

  Future<void> _guardarTipos() async {
    final mensaje = [
      for (final t in _tipos)
        '• ${t.nombre}: ${fmtMonto(t.monto)} CUP · ${t.dias} días${t.activo ? '' : ' (inactivo)'}',
      '',
      'Se aplicará en la próxima sincronización.',
    ].join('\n');
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Guardar tipos de pago',
      mensaje: mensaje,
      aceptar: 'Confirmar',
      icono: Icons.payments,
    );
    if (ok != true || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'guardar_tipos_pago',
      payload: {
        'tipos': [for (final t in _tipos) t.toJson()],
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content:
            Text('Tipos guardados (se sincronizarán)')));
    SyncEngine.instance.push();
  }

  // -- pendiente a entrega ----------------------------------------------
  /// v1.3.1: elegir cuánto se paga por cliente a entrenadores.
  /// Movido desde Ajustes (solo dueño).
  Future<void> _elegirPagoEntrenador() async {
    final ctrl = TextEditingController(text: '$_pagoEntrenador');
    final sel = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pago a entrenadores'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'CUP por cada cliente que pagó su mensualidad:'),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                suffixText: 'CUP',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () {
                final v = int.tryParse(ctrl.text);
                Navigator.pop(ctx, v != null && v > 0 ? v : null);
              },
              child: const Text('Guardar')),
        ],
      ),
    );
    // v1.3.1: no hacer dispose aquí — el TextField sigue montado durante
    // la animación de salida del diálogo (error "used after being disposed").
    if (sel != null) {
      await PerfilService.instance.setPagoEntrenador(sel);
      if (mounted) {
        setState(() => _pagoEntrenador = sel);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('Pago actualizado: $sel CUP por cliente')));
      }
    }
  }

  /// v1.3.1: marca como entregado en SQLite local (optimismo).
  /// Filtra en Dart con esPendiente() (seguro sin JSON1 y con NULLs).
  Future<void> _marcarEntregadoLocal(int? trainerId) async {
    final d = await LocalDb.instance.db;
    final ahora = DateTime.now().toIso8601String();
    await d.transaction((txn) async {
      for (final tabla in ['pagos', 'pagos_diarios', 'ventas_suplementos']) {
        final col =
            tabla == 'pagos' ? 'telegram_user_id' : 'registrado_por';
        final rows =
            await txn.query(tabla, columns: ['id', 'data']);
        for (final r in rows) {
          final data = Map<String, dynamic>.from(
              jsonDecode(r['data'] as String) as Map);
          if (!esPendiente(data['entregado'])) continue;
          if (tabla == 'pagos' && data['metodo'] != 'efectivo') continue;
          if (trainerId != null && data[col] != trainerId) continue;
          data['entregado'] = 1;
          data['entregado_ts'] = ahora;
          await txn.update(tabla, {'data': jsonEncode(data)},
              where: 'id = ?', whereArgs: [r['id']]);
        }
      }
    });
  }

  Future<void> _confirmarEntrega(
      {int? trainerId, required String nombre}) async {
    final notaCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Confirmar entrega',
        iconoTitulo: Icons.done_all,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '¿Confirmas que recibiste el dinero pendiente de '
                '"$nombre"? Su pendiente se pondrá en cero.',
                style: AppTexto.cuerpo),
            const SizedBox(height: 12),
            CampoTexto(
              controller: notaCtrl,
              etiqueta: 'Nota (opcional)',
              hint: 'Ej: entregó en dos partes',
              maxLineas: 2,
            ),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
              child: const Text('Confirmar')),
        ],
      ),
    );
    final nota = notaCtrl.text.trim();
    notaCtrl.dispose();
    if (ok != true || !mounted) return;
    // v1.3.1: actualización optimista local (la UI se pone en 0 al instante).
    await _marcarEntregadoLocal(trainerId);
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'confirmar_entrega',
      payload: {
        'trainer_telegram_id': trainerId ?? 'todos',
        if (nota.isNotEmpty) 'nota': nota,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Entrega confirmada (se sincronizará)')));
    await _cargar();
    SyncEngine.instance.push();
  }

  // -- gastos ------------------------------------------------------------
  Future<void> _agregarGasto() async {
    final conceptoCtrl = TextEditingController();
    final montoCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Agregar gasto',
        iconoTitulo: Icons.receipt_long,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CampoTexto(
                controller: conceptoCtrl,
                etiqueta: 'Concepto (ej: pago de la luz)'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: montoCtrl,
                etiqueta: 'Monto (CUP)',
                teclado:
                    const TextInputType.numberWithOptions(decimal: true)),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.naranja,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
              ),
              child: const Text('Guardar')),
        ],
      ),
    );
    final concepto = conceptoCtrl.text.trim();
    final montoTexto = montoCtrl.text.replaceAll(',', '.');
    conceptoCtrl.dispose();
    montoCtrl.dispose();
    if (ok != true || !mounted) return;
    final monto = double.tryParse(montoTexto);
    if (concepto.isEmpty || monto == null || monto <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Concepto o monto inválidos')));
      return;
    }
    final hoy = DateTime.now();
    final fecha = '${hoy.year.toString().padLeft(4, '0')}-'
        '${hoy.month.toString().padLeft(2, '0')}-'
        '${hoy.day.toString().padLeft(2, '0')}';
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'gasto',
      payload: {
        'fecha': fecha,
        'concepto': concepto,
        'monto': monto,
      },
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gasto guardado (se sincronizará)')));
    await _cargar();
    SyncEngine.instance.push();
  }

  // -- exportar ----------------------------------------------------------
  String _csv(List<String> cab, List<List<String>> filas) {
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    final sb = StringBuffer();
    sb.writeln(cab.map(esc).join(','));
    for (final f in filas) {
      sb.writeln(f.map(esc).join(','));
    }
    return sb.toString();
  }

  Future<void> _exportar() async {
    final clientes = await LocalDb.instance.allMirror('clientes');
    final csvClientes = _csv(
      ['id', 'nombre', 'carnet', 'telefono', 'sexo', 'estado',
       'pagado_hasta', 'fecha_inscripcion'],
      [
        for (final c in clientes)
          [
            '${c['id'] ?? ''}',
            '${c['nombre'] ?? ''}',
            '${c['carnet'] ?? ''}',
            '${c['telefono'] ?? ''}',
            '${c['sexo'] ?? ''}',
            '${c['estado'] ?? ''}',
            '${c['pagado_hasta'] ?? ''}',
            '${c['fecha_inscripcion'] ?? ''}',
          ]
      ],
    );
    final n = DateTime.now();
    final pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';
    // v1.3.4 (ítem 2): columna `fecha` indexada en vez de allMirror.
    final pagosMes = await LocalDb.instance.pagosDelMes(pref);
    final csvPagos = _csv(
      ['id', 'cliente_id', 'fecha', 'monto', 'metodo', 'periodo'],
      [
        for (final p in pagosMes)
          [
            '${p['id'] ?? ''}',
            '${p['cliente_id'] ?? ''}',
            '${p['fecha'] ?? ''}',
            '${p['monto'] ?? ''}',
            '${p['metodo'] ?? ''}',
            '${p['periodo'] ?? ''}',
          ]
      ],
    );
    final dir = await getTemporaryDirectory();
    final f1 = File('${dir.path}/clientes_ironbody.csv');
    final f2 = File(
        '${dir.path}/pagos_${n.year}-${n.month.toString().padLeft(2, '0')}_ironbody.csv');
    await f1.writeAsString(csvClientes);
    await f2.writeAsString(csvPagos);
    await Share.shareXFiles([XFile(f1.path), XFile(f2.path)],
        text: 'Iron Body Gym — clientes y pagos del mes');
  }

  // -- UI (Panel del dueño, v1.6.0) -----------------------------------------
  // Rediseño según el mockup v2 aprobado y el consenso del panel de
  // diseño (2026-10-22): la Administración pasa a ser la consola del
  // dueño como estación de trabajo diaria. Orden estricto de bloques:
  // 1) Necesita tu atención (solo decisiones del dueño, con botón,
  //    máx. 5), 2) Acciones rápidas (Cobrar · Arqueo · Cierre),
  // 3) Resumen del mes, 4) Módulos (las entradas de siempre agrupadas
  //    y renombradas a lenguaje de tarea; cada una navega a donde
  //    navegaba en el hub v1.3.7).
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Administración')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: _cargar,
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _cabeceraPanel(),
                        _bloqueAtencion(),
                        _tituloSeccion('ACCIONES RÁPIDAS'),
                        _accionesRapidas(),
                        _tituloSeccion('RESUMEN DEL MES',
                            derecha: _textoActualizado()),
                        _resumenMes(),
                        _lineaCuentasCasa(),
                        _tituloSeccion('MÓDULOS'),
                        _tarjetasModulos(),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
                          child: Text(
                            'Diseño propio de esta sección: directo y con '
                            'lo urgente primero. Los entrenadores no ven '
                            'este panel.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 11,
                                color:
                                    AppColores.textoSecundario(context)),
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

  /// Cabecera del panel (mockup v2): título con acento naranja,
  /// subtítulo y chip con el estado de sincronización.
  Widget _cabeceraPanel() {
    final Color chipColor;
    final String chipTxt;
    if (_syncDet.error != null && _syncDet.error!.isNotEmpty) {
      chipColor = AppColores.error;
      chipTxt = 'Error de sync';
    } else if (_pendientesSubir > 0) {
      chipColor = AppColores.alerta;
      chipTxt = '$_pendientesSubir por subir';
    } else {
      chipColor = AppColores.exito;
      chipTxt = 'Sincronizado';
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  style: AppTexto.titulo
                      .copyWith(fontSize: 24, fontWeight: FontWeight.w800),
                  children: const [
                    TextSpan(text: 'Panel '),
                    TextSpan(
                        text: 'del dueño',
                        style: TextStyle(color: AppColores.naranja)),
                  ],
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Iron Body Gym · Solo tú ves esta sección',
                style: TextStyle(
                    fontSize: 12,
                    color: AppColores.textoSecundario(context)),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: chipColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: chipColor.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration:
                    BoxDecoration(color: chipColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(chipTxt,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: chipColor)),
            ],
          ),
        ),
      ],
    );
  }

  /// Título de bloque del panel (mockup v2): versalitas con tracking;
  /// naranja en «Necesita tu atención», gris en el resto.
  Widget _tituloSeccion(String titulo,
      {bool naranja = false, String? derecha}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
      child: Row(
        children: [
          if (naranja) ...[
            const Icon(Icons.warning_amber_rounded,
                size: 15, color: AppColores.naranja),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              titulo,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.6,
                color: naranja
                    ? AppColores.naranja
                    : AppColores.textoSecundario(context),
              ),
            ),
          ),
          if (derecha != null)
            Text(derecha,
                style: TextStyle(
                    fontSize: 11,
                    color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }

  /// Bloque 1 · Necesita tu atención: SOLO decisiones del dueño, cada
  /// una con su botón de acción, máx. 5 visibles (consenso del panel
  /// de diseño). Sin pendientes: una línea discreta, no una tarjeta.
  Widget _bloqueAtencion() {
    final pendientes = <_PendientePanel>[];

    // Solicitudes de inscripción de invitados (pedido de Jc,
    // 2026-10-22): decisión del dueño con acción en 1 toque; el
    // botón abre la bandeja YA filtrada en solicitudes. Misma
    // fuente que la pantalla de Invitados (InvitadosService).
    if (_solicitudesInvitados.isNotEmpty) {
      final n = _solicitudesInvitados.length;
      final s = _solicitudesInvitados.first;
      var detalle = s.nombre;
      if (s.solicitudDesde != null) {
        detalle += ' · ${hace(s.solicitudDesde)}';
      }
      pendientes.add(_PendientePanel(
        icono: Icons.mark_email_unread_rounded,
        tinte: AppColores.naranja,
        titulo: n == 1
            ? '1 solicitud de inscripción por atender'
            : '$n solicitudes de inscripción por atender',
        detalle: detalle,
        boton: 'Atender',
        primario: true,
        onTap: () =>
            _ir(const InvitadosScreen(filtroInicial: 'solicitudes')),
      ));
    }

    // Reservas por confirmar (bandeja FIFO; la primera manda el detalle).
    if (_reservasSolicitadas.isNotEmpty) {
      final n = _reservasSolicitadas.length;
      final r = _reservasSolicitadas.first;
      final nombreSupl =
          _nombreSupl['${r['suplemento_id']}'] ?? 'Suplemento';
      var detalle = '$nombreSupl ×${(r['cantidad'] as num?)?.toInt() ?? 1}';
      final exp = r['expira_en'] as String?;
      if (exp != null && exp.isNotEmpty) {
        detalle += ' · vence ${fmtFecha(exp)}';
      }
      pendientes.add(_PendientePanel(
        icono: Icons.inventory_2_rounded,
        tinte: AppColores.naranja,
        titulo: n == 1
            ? '1 reserva por confirmar'
            : '$n reservas por confirmar',
        detalle: detalle,
        boton: 'Revisar',
        // Botón lleno solo si es la primera fila (sin solicitudes
        // y ya sin su carga en curso).
        primario: _solicitudesInvitados.isEmpty && !_solicitudesCargando,
        onTap: () => _ir(const ReservasScreen()),
      ));
    }

    // G2 (v1.7.0): reportes de pago App Plus por confirmar. Solo
    // aparece con pendientes CONOCIDOS: si la RPC del segundo
    // pase falló, la fila no se pinta (sin cifras inventadas).
    if (_reportesPlus.isNotEmpty) {
      final n = _reportesPlus.length;
      final r = _reportesPlus.first;
      pendientes.add(_PendientePanel(
        icono: Icons.star_rounded,
        tinte: AppColores.naranja,
        titulo: n == 1
            ? '1 reporte App Plus por confirmar'
            : '$n reportes App Plus por confirmar',
        detalle: '${r.nombre} · ${fmtMonto(r.monto)} CUP · '
            'ref. ${r.referencia}',
        boton: 'Revisar',
        primario: false,
        onTap: () => _ir(const ReportesPlusScreen()),
      ));
    }

    // Efectivo por liquidar (pendiente a entregar, por entrenador).
    final pendTotal =
        _pend.fold<double>(0, (s, e) => s + (e['total'] as double? ?? 0));
    if (pendTotal > 0) {
      final detalle = [
            for (final t in _pend.take(2))
              '${t['nombre']} \$${fmtMonto(t['total'])}',
          ].join(' · ') +
          (_pend.length > 2 ? ' · …' : '');
      pendientes.add(_PendientePanel(
        icono: Icons.payments_rounded,
        tinte: AppColores.alerta,
        titulo: 'Efectivo por liquidar',
        detalle: detalle,
        boton: 'Arqueo',
        primario: false,
        onTap: () => _ir(const ArqueoScreen()),
      ));
    }

    // Cierre de caja pendiente: ayer ya es exigible completo;
    // hoy solo tras el cierre + gracia (regla de turnosSinReporte).
    if (_sinReporteAyer.isNotEmpty) {
      pendientes.add(_PendientePanel(
        icono: Icons.task_alt_rounded,
        tinte: AppColores.info,
        titulo: 'Cierre de caja pendiente',
        detalle: 'Ayer · turno ${_sinReporteAyer.join(' y ')}',
        boton: 'Cerrar',
        primario: false,
        onTap: () => _ir(_pantallaCierre()),
      ));
    }
    if (_sinReporteHoy.isNotEmpty) {
      pendientes.add(_PendientePanel(
        icono: Icons.task_alt_rounded,
        tinte: AppColores.info,
        titulo: 'Sin reporte de caja',
        detalle: 'Hoy · turno ${_sinReporteHoy.join(' y ')}',
        boton: 'Cerrar',
        primario: false,
        onTap: () => _ir(_pantallaCierre()),
      ));
    }

    // Incidencias de sync por revisar (aprobar/descartar, solo dueño).
    if (_incidenciasPend > 0) {
      pendientes.add(_PendientePanel(
        icono: Icons.sync_problem_rounded,
        tinte: AppColores.error,
        titulo: _incidenciasPend == 1
            ? '1 incidencia de sync por revisar'
            : '$_incidenciasPend incidencias de sync por revisar',
        detalle: 'Operaciones rechazadas o en revisión',
        boton: 'Revisar',
        primario: false,
        onTap: () => _ir(const IncidenciasSyncScreen()),
      ));
    }

    // Error de sincronización (último error, en lenguaje común).
    if (_syncDet.error != null && _syncDet.error!.isNotEmpty) {
      pendientes.add(_PendientePanel(
        icono: Icons.error_outline_rounded,
        tinte: AppColores.error,
        titulo: 'Problema de sincronización',
        detalle: errorSyncLegible(_syncDet.error!),
        boton: 'Ver',
        primario: false,
        onTap: () => _ir(const SeccionDiagnosticoScreen()),
      ));
    }

    // Stock crítico (mismo criterio que el chip de Suplementos).
    if (_stockCritico.isNotEmpty) {
      final s = _stockCritico.first;
      final stock = (s['stock'] as num?)?.toInt() ?? 0;
      pendientes.add(_PendientePanel(
        icono: Icons.warning_amber_rounded,
        tinte: AppColores.alerta,
        titulo: 'Stock crítico',
        detalle: _stockCritico.length == 1
            ? '${s['nombre']} · queda $stock'
            : '${_stockCritico.length} productos bajo el mínimo · '
                '${s['nombre']} queda $stock',
        boton: 'Ver',
        primario: false,
        onTap: () => _ir(const SuplementosScreen()),
      ));
    }

    final visibles = pendientes.take(5).toList();
    final ocultos = pendientes.length - visibles.length;
    final oscuro = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _tituloSeccion('NECESITA TU ATENCIÓN', naranja: true),
        if (pendientes.isEmpty && !_solicitudesCargando)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColores.superficie(context),
              borderRadius: BorderRadius.circular(AppRadio.lg),
              border: Border.all(color: AppColores.borde(context)),
            ),
            child: const Row(
              children: [
                Icon(Icons.check_circle_outline_rounded,
                    size: 20, color: AppColores.exito),
                SizedBox(width: 10),
                Text('Sin pendientes · Todo en orden',
                    style: AppTexto.cuerpo),
              ],
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color:
                  oscuro ? const Color(0xFF1B150B) : const Color(0xFFFFF6E5),
              borderRadius: BorderRadius.circular(AppRadio.lg),
              border: Border.all(
                  color: oscuro
                      ? const Color(0xFF6B4A12)
                      : AppColores.alerta.withValues(alpha: 0.45)),
            ),
            child: Column(
              children: [
                // Panel 1.6.0: mientras la RPC de solicitudes no
                // resuelve, su fila va en estado «cargando» (sin
                // conteo) en vez de bloquear todo el bloque.
                if (_solicitudesCargando)
                  _filaSolicitudesCargando(
                      ultima: visibles.isEmpty && ocultos == 0),
                for (var i = 0; i < visibles.length; i++)
                  _filaAtencion(visibles[i],
                      ultima: i == visibles.length - 1 && ocultos == 0),
                if (ocultos > 0)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                    child: Text(
                      '+$ocultos pendiente(s) más en los módulos',
                      style: TextStyle(
                          fontSize: 11.5,
                          color: AppColores.textoSecundario(context)),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// Fila «cargando» de las solicitudes de invitados: mismo cuerpo
  /// visual que _filaAtencion pero sin conteo ni botón, mientras
  /// la RPC no resuelve (panel 1.6.0: el panel pinta primero con
  /// los datos locales; esta fila se sustituye al llegar el dato).
  Widget _filaSolicitudesCargando({required bool ultima}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        border: ultima
            ? null
            : Border(
                bottom: BorderSide(
                    color: AppColores.borde(context)
                        .withValues(alpha: 0.6))),
      ),
      child: Row(
        children: [
          const IconoModuloBadge(
            icono: Icons.mark_email_unread_rounded,
            tinte: AppColores.naranja,
            iconoOscuro: AppColores.naranja,
            iconoClaro: AppColores.naranja,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Solicitudes de inscripción',
                    style: AppTexto.cuerpo.copyWith(
                        fontSize: 13.5, fontWeight: FontWeight.w700)),
                const SizedBox(height: 1),
                Text(
                  'Cargando…',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: AppColores.textoSecundario(context)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ),
    );
  }

  /// Fila de un pendiente: badge, título, detalle y botón píldora.
  Widget _filaAtencion(_PendientePanel p, {required bool ultima}) {
    return InkWell(
      onTap: p.onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          border: ultima
              ? null
              : Border(
                  bottom: BorderSide(
                      color: AppColores.borde(context)
                          .withValues(alpha: 0.6))),
        ),
        child: Row(
          children: [
            IconoModuloBadge(
              icono: p.icono,
              tinte: p.tinte,
              iconoOscuro: p.tinte,
              iconoClaro: p.tinte,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.titulo,
                      style: AppTexto.cuerpo.copyWith(
                          fontSize: 13.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 1),
                  Text(
                    p.detalle,
                    style: TextStyle(
                        fontSize: 11.5,
                        color: AppColores.textoSecundario(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: p.onTap,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                decoration: BoxDecoration(
                  color: p.primario
                      ? AppColores.naranja
                      : AppColores.superficie(context),
                  borderRadius: BorderRadius.circular(999),
                  border: p.primario
                      ? null
                      : Border.all(color: AppColores.borde(context)),
                ),
                child: Text(p.boton,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: p.primario
                            ? const Color(0xFF171106)
                            : null)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Bloque 2 · Acciones rápidas: Cobrar · Arqueo · Cierre, a un toque
  /// a los flujos de siempre (consenso del panel de diseño).
  Widget _accionesRapidas() {
    return Row(
      children: [
        Expanded(
          child: _accionRapida(Icons.payments_rounded, 'Cobrar',
              primario: true, onTap: () => _ir(const PagoScreen())),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _accionRapida(
              Icons.account_balance_wallet_rounded, 'Arqueo',
              onTap: () => _ir(const ArqueoScreen())),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _accionRapida(Icons.point_of_sale_rounded, 'Cierre',
              onTap: () => _ir(_pantallaCierre())),
        ),
      ],
    );
  }

  Widget _accionRapida(IconData icono, String texto,
      {bool primario = false, required VoidCallback onTap}) {
    final fg = primario ? const Color(0xFF171106) : null;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadio.lg),
      onTap: onTap,
      child: Container(
        height: 54,
        decoration: BoxDecoration(
          color: primario
              ? AppColores.naranja
              : AppColores.superficie(context),
          borderRadius: BorderRadius.circular(AppRadio.lg),
          border: primario
              ? null
              : Border.all(color: AppColores.borde(context)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icono, size: 19, color: fg),
            const SizedBox(width: 7),
            Text(texto,
                style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: fg)),
          ],
        ),
      ),
    );
  }

  /// «Actualizado …» del Resumen: última sincronización registrada
  /// (los datos son del espejo local; el panel de diseño pidió que se
  /// vea cuándo se actualizaron).
  String? _textoActualizado() {
    final u = _syncDet.ultimaPull ?? _syncDet.ultimaPush;
    if (u == null) return null;
    return 'Actualizado ${_fechaHora(u)}';
  }

  /// Bloque 3 · Resumen del mes: las 3 cifras del mockup v2
  /// (ingresosMes, NominaCalc — la definición de Home — y
  /// activosCount).
  Widget _resumenMes() {
    const meses = [
      'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio',
      'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre',
    ];
    final mes = meses[ahoraHabana().month - 1];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
            child: _kpi('\$${fmtMonto(_ingresos)}', 'Ingresos de $mes',
                color: AppColores.exito)),
        const SizedBox(width: 10),
        // v1.6.0 (Jc, añadido 7): «Pagos este mes» abre el LISTADO
        // exacto de los que pagaron el mes (PagaronMesScreen, el
        // conjunto de NominaCalc), no la nómina (misma corrección
        // que en la tarjeta de estadísticas de Home).
        Expanded(
            child: _kpi('$_pagosMes', 'Pagos este mes',
                onTap: () => _ir(const PagaronMesScreen()))),
        const SizedBox(width: 10),
        Expanded(child: _kpi('$_clientesActivos', 'Clientes activos')),
      ],
    );
  }

  /// v1.7.0: contador de Cuentas a la Casa activas (consulta
  /// local al espejo). Línea discreta bajo el resumen; sin
  /// cuentas, no ocupa espacio.
  Widget _lineaCuentasCasa() {
    if (_cuentasCasa <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: [
          const Icon(Icons.home_rounded,
              size: 16, color: Color(0xFFB8860B)),
          const SizedBox(width: 6),
          Text(
            _cuentasCasa == 1
                ? 'Cuentas a la Casa activas: 1'
                : 'Cuentas a la Casa activas: $_cuentasCasa',
            style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFFB8860B)),
          ),
        ],
      ),
    );
  }

  Widget _kpi(String valor, String etiqueta,
      {Color? color, VoidCallback? onTap}) {
    return Tarjeta(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(valor,
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(etiqueta,
              style: TextStyle(
                  fontSize: 10.5,
                  color: AppColores.textoSecundario(context))),
        ],
      ),
    );
  }

  /// Bloque 4 · Módulos: las 5 filas del mockup v2. Cada fila abre un
  /// contenedor con las tarjetas de destino de siempre.
  Widget _tarjetasModulos() {
    final modulos =
        <({IconData icono, Color tinte, String titulo, String resumen, int? badge, List<Widget> Function() tarjetas})>[
      (
        icono: Icons.attach_money_rounded,
        tinte: AppColores.exito,
        titulo: 'Caja y dinero',
        resumen: 'Arqueo · Cierre · Últimos gastos · Nómina · Historial',
        badge: null,
        tarjetas: _tarjetasCaja,
      ),
      (
        icono: Icons.people_rounded,
        tinte: AppColores.info,
        titulo: 'Clientes y equipo',
        resumen: 'Usuarios · Por recuperar · Congelados · Papelera',
        badge: _solicitudesInvitados.isEmpty
            ? null
            : _solicitudesInvitados.length,
        tarjetas: _tarjetasClientes,
      ),
      (
        icono: Icons.inventory_2_rounded,
        tinte: const Color(0xFFA855F7),
        titulo: 'Suplementos y contenido',
        resumen: 'Suplementos · Reservas · Reportes A++ · GymPedia',
        badge:
            _reservasSolicitadas.isEmpty ? null : _reservasSolicitadas.length,
        tarjetas: _tarjetasSuplementosModulo,
      ),
      (
        icono: Icons.bar_chart_rounded,
        tinte: const Color(0xFF14B8A6),
        titulo: 'Control y sistema',
        resumen: 'Estadísticas · Auditoría · Anomalías · Sincronización',
        badge: null,
        tarjetas: _tarjetasControl,
      ),
      (
        icono: Icons.settings_rounded,
        tinte: const Color(0xFF9AA3B2),
        titulo: 'Configuración y datos',
        resumen: 'Tipos de pago · Tarifas especiales · Datos bancarios',
        badge: null,
        tarjetas: _tarjetasConfig,
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AppColores.superficie(context),
        borderRadius: BorderRadius.circular(AppRadio.lg),
        border: Border.all(color: AppColores.borde(context)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < modulos.length; i++) ...[
            if (i > 0)
              Divider(height: 1, color: AppColores.borde(context)),
            InkWell(
              onTap: () => _ir(_ModuloAdminScreen(
                  titulo: modulos[i].titulo,
                  tarjetas: modulos[i].tarjetas())),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    IconoModuloBadge(
                      icono: modulos[i].icono,
                      tinte: modulos[i].tinte,
                      iconoOscuro: modulos[i].tinte,
                      iconoClaro: modulos[i].tinte,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(modulos[i].titulo,
                              style: AppTexto.subtitulo),
                          const SizedBox(height: 2),
                          Text(
                            modulos[i].resumen,
                            style: TextStyle(
                                fontSize: 11.5,
                                color:
                                    AppColores.textoSecundario(context)),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (modulos[i].badge != null) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColores.error,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('${modulos[i].badge}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(width: 6),
                    ],
                    Icon(Icons.chevron_right_rounded,
                        color: AppColores.textoSecundario(context)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Destino «Cierre de caja» de siempre (sección B · Cobros),
  /// reutilizado por la acción rápida, el módulo Caja y los
  /// pendientes de cierre/reporte.
  Widget _pantallaCierre() {
    return SeccionCobrosScreen(
      getCaja: () => _caja,
      getGastosHoy: () => _gastosHoy,
      getPend: () => _pend,
      onConfirmarEntrega: _confirmarEntrega,
      onIr: _irYRecargar,
    );
  }

  // -- Módulo · Caja y dinero -------------------------------------------------
  List<Widget> _tarjetasCaja() {
    final cajaTotal = (_caja['efectivo'] ?? 0) + (_caja['transferencia'] ?? 0);
    final netoHoy = cajaTotal - _gastosHoy;
    final pendTotal =
        _pend.fold<double>(0, (s, e) => s + (e['total'] as double? ?? 0));
    return [
      _tarjetaFlujo(
        Icons.account_balance_wallet_rounded,
        'Arqueo de caja',
        pendTotal > 0
            ? '${fmtMonto(pendTotal)} CUP por liquidar'
            : 'Todo cuadrado',
        () => _ir(const ArqueoScreen()),
      ),
      _tarjetaFlujo(
        Icons.point_of_sale_rounded,
        'Cierre de caja',
        'Neto hoy: ${fmtMonto(netoHoy)} CUP',
        () => _ir(_pantallaCierre()),
      ),
      _tarjetaFlujo(
        Icons.receipt_long_rounded,
        'Últimos gastos',
        'Hoy: ${fmtMonto(_gastosHoy)} CUP',
        () => _ir(SeccionGastosScreen(
          getGastos: () => _gastos,
          onAgregarGasto: _agregarGasto,
        )),
      ),
      _tarjetaFlujo(
        Icons.payments_rounded,
        'Nómina del mes',
        'Proyección: clientes pagados × 150 CUP',
        () => _ir(const NominaScreen()),
      ),
      _tarjetaFlujo(
        Icons.history_outlined,
        'Historial de caja',
        'Cierres por entrenador y fecha',
        () => _ir(const HistorialCajaScreen()),
      ),
      _tarjetaFlujo(
        Icons.credit_card_rounded,
        'Pagos por método',
        'Efectivo vs transferencia',
        () => _ir(const PagosPorMetodo()),
      ),
      _tarjetaFlujo(
        Icons.compare_arrows_rounded,
        'Comparativa mensual',
        'Este mes vs anterior',
        () => _ir(const ComparativaMensual()),
      ),
    ];
  }

  // -- Módulo · Clientes y equipo ---------------------------------------------
  List<Widget> _tarjetasClientes() {
    return [
      // v1.6.0 (pedido de Jc): Entrenadores, Clientes e Invitados
      // viven en una misma zona «Usuarios» (ControlAccesoScreen con
      // la bandeja de Invitados como tercera pestaña). Ya no hay
      // entrada suelta de Invitados en Administración.
      _tarjetaFlujo(
        Icons.manage_accounts_rounded,
        'Usuarios',
        _solicitudesInvitados.isEmpty
            ? 'Entrenadores, clientes e invitados'
            : 'Entrenadores, clientes e invitados · '
                '${_solicitudesInvitados.length} solicitud(es) por atender',
        () => _ir(const ControlAccesoScreen()),
      ),
      // v1.6.0 (Jc): UNA sola puerta «Turnos» — el hub agrupa el
      // plan semanal y los ajustes por fecha con la línea de
      // precedencia (antes eran dos entradas sueltas y confusas).
      _tarjetaFlujo(
        Icons.calendar_month_rounded,
        'Turnos',
        'Plan semanal y ajustes por fecha',
        () => _ir(const TurnosHubScreen()),
      ),
      _tarjetaFlujo(
        Icons.warning_amber_rounded,
        'Clientes por recuperar',
        'Inactivos 60+ días, buenos para recuperar',
        () => _ir(const RiesgoScreen()),
      ),
      _tarjetaFlujo(
        Icons.ac_unit_rounded,
        'Membresías congeladas',
        'Membresías pausadas',
        () => _ir(const CongeladosScreen()),
      ),
      _tarjetaFlujo(
        Icons.cake_rounded,
        'Cumpleaños',
        'Próximos 30 días',
        () => _ir(const CumpleanosMes()),
      ),
      _tarjetaFlujo(
        Icons.delete_outline_rounded,
        'Papelera',
        'Clientes eliminados (recuperables)',
        () => _ir(const PapeleraScreen()),
      ),
    ];
  }

  // -- Módulo · Suplementos y contenido ---------------------------------------
  List<Widget> _tarjetasSuplementosModulo() {
    return [
      _tarjetaFlujo(
        Icons.inventory_2_rounded,
        'Suplementos',
        'Catálogo, categorías y ventas',
        () => _ir(SeccionSuplementosScreen(
          onIr: _irYRecargar,
        )),
      ),
      _tarjetaFlujo(
        Icons.inbox_rounded,
        'Reservas',
        _reservasSolicitadas.isEmpty
            ? 'Bandeja de reservas de los clientes'
            : '${_reservasSolicitadas.length} por confirmar',
        () => _ir(const ReservasScreen()),
      ),
      _tarjetaFlujo(
        Icons.star_rounded,
        'Reportes App Plus',
        _reportesPlusCargando
            ? 'Consultando reportes…'
            : _reportesPlus.isEmpty
                ? 'Pagos del Plus reportados por invitados'
                : '${_reportesPlus.length} por confirmar',
        () => _ir(const ReportesPlusScreen()),
      ),
      _tarjetaFlujo(
        Icons.menu_book_rounded,
        'GymPedia',
        'Artículos para la app de clientes',
        () => _ir(const GympediaScreen()),
      ),
      _tarjetaFlujo(
        Icons.public_rounded,
        'Información pública',
        'Redes, contactos y precios para invitados',
        () => _ir(const InfoPublicaScreen()),
      ),
    ];
  }

  // -- Módulo · Control y sistema ---------------------------------------------
  List<Widget> _tarjetasControl() {
    return [
      // Estado y último error: las tarjetas compactas de siempre.
      _tarjetaCompacta(
        _pendientesSubir > 0
            ? Icons.sync_problem_rounded
            : Icons.check_circle_outline_rounded,
        'Estado de sync',
        _pendientesSubir > 0
            ? '$_pendientesSubir por subir'
            : 'Todo sincronizado',
        _pendientesSubir > 0 ? AppColores.alerta : AppColores.exito,
      ),
      if (_syncDet.error != null && _syncDet.error!.isNotEmpty)
        _tarjetaCompacta(
          Icons.error_outline_rounded,
          'Último error',
          // v1.3.8: lenguaje común, no tecnicismos.
          errorSyncLegible(_syncDet.error!),
          AppColores.error,
        ),
      _tarjetaFlujo(
        Icons.bar_chart_rounded,
        'Estadísticas del mes',
        '${fmtMonto(_ingresos)} CUP · $_inscMes insc.',
        () => _ir(SeccionResumenScreen(
          ingresos: _ingresos,
          inscMes: _inscMes,
          morosos: _morosos,
          inscPorEntrenador: _inscPorEntrenador,
        )),
      ),
      _tarjetaFlujo(
        Icons.fact_check_rounded,
        'Auditoría',
        'Quién hizo qué y cuándo',
        () => _ir(const AuditoriaScreen()),
      ),
      _tarjetaFlujo(
        Icons.radar_rounded,
        'Anomalías',
        'Detección silenciosa (solo dueño)',
        () => _ir(const AuditoriaSilenciosaScreen()),
      ),
      _tarjetaFlujo(
        Icons.sync_rounded,
        'Sincronización',
        _pendientesSubir > 0
            ? '$_pendientesSubir ops por subir'
            : 'Sincronizado',
        () => _ir(const SeccionDiagnosticoScreen()),
      ),
      _tarjetaFlujo(
        Icons.warning_amber_rounded,
        'Incidencias',
        'Errores que requieren atención',
        () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => const ListaIncidenciasScreen(),
            ),
          );
        },
      ),
    ];
  }

  // -- Módulo · Configuración y datos -----------------------------------------
  List<Widget> _tarjetasConfig() {
    return [
      _tarjetaFlujo(
        Icons.payments_outlined,
        'Tipos de pago',
        '${_tipos.length} tipos configurados',
        () => _ir(_pantallaAjustes(seccion: 'tipos')),
      ),
      _tarjetaFlujo(
        Icons.price_change_rounded,
        'Tarifas especiales',
        'Mensualidades, diario, tasa USD',
        () => _ir(_pantallaAjustes(seccion: 'precios')),
      ),
      _tarjetaFlujo(
        Icons.account_balance_rounded,
        'Datos bancarios',
        'Tarjetas y móvil de confirmación',
        () => _ir(_pantallaAjustes(seccion: 'bancarios')),
      ),
      _tarjetaFlujo(
        Icons.schedule_rounded,
        'Horario del Gym',
        'Configurar turnos',
        () => _ir(const HorarioGym()),
      ),
      _tarjetaFlujo(
        Icons.file_download_rounded,
        'Exportar',
        'CSV y Excel de clientes y pagos',
        () => _ir(SeccionSistemaScreen(
          syncDet: _syncDet,
          pendientesSubir: _pendientesSubir,
          fechaHora: _fechaHora,
          onExportar: _exportar,
          onExportarExcel: () async {
            final ok = await exportarExcel();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(ok
                      ? 'Archivos listos para compartir'
                      : 'No se pudo generar el archivo')));
            }
          },
          onIr: _irYRecargar,
        )),
      ),
    ];
  }

  /// Construye la pantalla de Ajustes (se reutiliza en 3 tarjetas).
  Widget _pantallaAjustes({String? seccion}) {
    return SeccionAjustesScreen(
      seccion: seccion,
      getTipos: () => _tipos,
      onToggleTipo: _toggleTipo,
      onEditarTipo: _editarTipo,
      onEliminarTipo: _eliminarTipo,
      onAgregarTipo: _agregarTipo,
      onGuardarTipos: _guardarTipos,
      montos: _montos,
      clavesMonto: _clavesMonto,
      onGuardarMontos: _guardarMontos,
      bancarios: _bancarios,
      onGuardarBancarios: _guardarBancarios,
      gestionarUsuarios: Permisos().gestionarUsuarios,
      onIr: _irYRecargar,
      esTipoFijo: _esTipoFijo,
    );
  }

  /// Tarjeta de flujo: badge + título + una línea de resumen.
  Widget _tarjetaFlujo(
      IconData icono, String titulo, String resumen, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tarjeta(
        onTap: onTap,
        child: Row(
          children: [
            IconoModuloBadge.naranja(icono),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titulo, style: AppTexto.subtitulo),
                  const SizedBox(height: 2),
                  Text(
                    resumen,
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColores.textoSecundario(context)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded,
                color: AppColores.textoSecundario(context)),
          ],
        ),
      ),
    );
  }

  /// Tarjeta compacta informativa (no navegable): Estado / Último error.
  Widget _tarjetaCompacta(
      IconData icono, String titulo, String detalle, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Tarjeta(
        child: Row(
          children: [
            Icon(icono, color: color, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titulo,
                      style: AppTexto.cuerpo
                          .copyWith(fontWeight: FontWeight.w600)),
                  Text(
                    detalle,
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColores.textoSecundario(context)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Formatea fecha/hora para la sección de salud ("nunca" si es null).
  String _fechaHora(DateTime? dt) {
    if (dt == null) return 'nunca';
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m $h:$min';
  }
}

/// Un pendiente del bloque «Necesita tu atención» (v1.6.0): icono,
/// textos, botón de acción y destino. Solo decisiones del dueño.
class _PendientePanel {
  final IconData icono;
  final Color tinte;
  final String titulo;
  final String detalle;
  final String boton;
  final bool primario;
  final VoidCallback onTap;

  const _PendientePanel({
    required this.icono,
    required this.tinte,
    required this.titulo,
    required this.detalle,
    required this.boton,
    required this.primario,
    required this.onTap,
  });
}

/// Contenedor de un módulo del Panel del dueño (v1.6.0): lista las
/// tarjetas de destino existentes del módulo. No añade funciones;
/// solo agrupa las que ya estaban en el hub.
class _ModuloAdminScreen extends StatelessWidget {
  final String titulo;
  final List<Widget> tarjetas;

  const _ModuloAdminScreen({required this.titulo, required this.tarjetas});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(titulo)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: tarjetas,
      ),
    );
  }
}
