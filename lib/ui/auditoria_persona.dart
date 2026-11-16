// lib/ui/auditoria_persona.dart
// v1.8.0 — Auditoría total POR PERSONA (diseño propio + adenda
// de Argón P1–P4). El dueño elige a cualquier usuario APK; el
// entrenador solo puede verse a sí mismo. Todo se deriva de los
// espejos locales y del río de ops de este teléfono, con la
// cobertura DECLARADA (P2): si el espejo no cubre el período,
// se dice, no se inventa un cero.
//
// Es una vista CONSULTIVA: no recalcula nómina, adelantos ni
// dosis; si un número difiere de la corrida de nómina, manda
// la nómina y la diferencia se investiga.
import 'dart:convert';

import 'package:flutter/material.dart';

import '../auditoria_persona.dart';
import '../app_log.dart';
import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../tiempo.dart';
import '../turnos_resolucion.dart';
import 'app_bar.dart';
import 'auditoria.dart' show descripcionOp, payloadDeOp, tiposOpSensibles;
import 'componentes.dart';
import 'skeleton.dart';
import 'diseno.dart';

class AuditoriaPersonaScreen extends StatefulWidget {
  // 1.25 T112: embebida = pestaña del Centro de control.
  final bool embebida;

  /// 1.29 (Oleada 6, FB-17): persona preseleccionada al
  /// llegar desde un caso de la auditoría silenciosa (el
  /// dueño aterriza ya en la persona del caso, sin tener
  /// que buscarla en el selector).
  final int? telegramIdInicial;
  const AuditoriaPersonaScreen(
      {super.key, this.embebida = false, this.telegramIdInicial});

  @override
  State<AuditoriaPersonaScreen> createState() =>
      _AuditoriaPersonaScreenState();
}

class _AuditoriaPersonaScreenState extends State<AuditoriaPersonaScreen> {
  bool _cargando = true;
  // Yunque de App 1.31 (C1-4): el fallo de carga se PINTA
  // como error, no como persona sin movimientos.
  String? _falloCarga;
  List<PersonaApk> _personas = [];
  PersonaApk? _persona;
  String _modo = 'mes'; // dia | semana | mes | rango
  DateTime? _rangoDesde;
  DateTime? _rangoHasta;

  // 1.29 (Oleada 6, D-B3-09 + regla de ventana H-06): la
  // BASE (ajustes + los seis espejos) se carga UNA vez por
  // entrada a la pantalla y el río de ops una vez por
  // VENTANA cubierta: cambiar de persona o estrechar el
  // período filtra EN MEMORIA; el río solo se recarga
  // desde SQLite cuando el período se AMPLÍA más allá de
  // la ventana ya cubierta (la recarga pide la UNIÓN de
  // ventanas, así un estrechamiento posterior tampoco
  // recarga). Antes, cada cambio de persona/período
  // releía todo y el río venía recortado a 500 ops por
  // conteo: un mes con más de 500 ops daba cifras de un
  // río incompleto sin decirlo.
  bool _baseLista = false;
  Map<String, dynamic> _ajustesBase = {};
  List<Map<String, dynamic>> _aperturasBase = [];
  List<Map<String, dynamic>> _cierresBase = [];
  List<Map<String, dynamic>> _pagosBase = [];
  // Yunque 2.34 (D-7): anulaciones vivas en la cola, para que
  // la auditoría no sume pagos ya anulados en este teléfono.
  Set<int> _anuladosColaBase = const {};
  List<Map<String, dynamic>> _diariosBase = [];
  List<Map<String, dynamic>> _ventasSupBase = [];
  List<Map<String, dynamic>> _ventasServBase = [];
  List<Map<String, dynamic>> _rio = [];
  String? _rioDesdeIso;
  String? _rioHastaIso;

  List<TurnoAuditado> _turnos = [];
  DineroAuditado? _dinero;
  ResumenAuditoria? _resumen;
  // 1.25 T115: las series diarias de la tarjeta resumen.
  List<Map<String, dynamic>> _serieMinutos = const [];
  List<Map<String, dynamic>> _serieCobros = const [];
  List<Map<String, dynamic>> _sensibles = [];
  String? _avisoCobertura;
  String _periodoTexto = '';

  bool get _soyDuenio => AuthService().isOwner;

  @override
  void initState() {
    super.initState();
    _cargarPersonas();
  }

  Future<void> _cargarPersonas() async {
    final personas = <PersonaApk>[];
    try {
      final raw = await LocalDb.instance.getMeta('usuarios_apk');
      if (raw != null && raw.isNotEmpty) {
        for (final u in jsonDecode(raw) as List) {
          final m = Map<String, dynamic>.from(u as Map);
          final id = '${m['id'] ?? ''}';
          if (id.isEmpty) continue;
          final nom = (m['nombre'] as String?)?.trim();
          personas.add(PersonaApk(
            id: id,
            telegramId:
                (m['telegram_id'] as num?)?.toInt() ??
                    int.tryParse('${m['telegram_id'] ?? ''}'),
            nombre: (nom != null && nom.isNotEmpty)
                ? nom
                : (m['username'] as String? ?? 'Usuario'),
            activo: m['activo'] != false,
          ));
        }
      }
    } catch (e) {
      // Yunque de App 1.31 (C1-4): el fallo de leer la lista
      // de usuarios queda en bitácora; sin ella, la lista
      // vacía se atribuía a la sesión («No se pudo
      // identificar tu usuario…») y no a la lectura.
      AppLog.error('auditoria_persona', 'cargar_personas_fallo',
          d: '$e');
    }
    if (!mounted) return;
    setState(() {
      _personas = personas;
      if (_soyDuenio) {
        // FB-17: si se llega desde un caso, la persona del
        // caso manda sobre la primera de la lista.
        final inicial = widget.telegramIdInicial == null
            ? null
            : personas
                .where((p) => p.telegramId == widget.telegramIdInicial)
                .firstOrNull;
        _persona = inicial ?? personas.firstOrNull;
      } else {
        // El entrenador solo se ve a sí mismo (por telegram_id).
        final miTg = AuthService().telegramId;
        _persona = personas
            .where((p) => p.telegramId != null && p.telegramId == miTg)
            .firstOrNull;
      }
    });
    if (_persona != null) {
      await _cargar();
    } else {
      setState(() => _cargando = false);
    }
  }

  ({DateTime desde, DateTime hasta}) _periodo() {
    final hoy = ahoraHabana();
    final h = DateTime(hoy.year, hoy.month, hoy.day);
    switch (_modo) {
      case 'dia':
        return (desde: h, hasta: h);
      case 'semana':
        final lunes = h.subtract(Duration(days: h.weekday - 1));
        return (desde: lunes, hasta: lunes.add(const Duration(days: 6)));
      case 'rango':
        final d = _rangoDesde ?? h;
        final t = _rangoHasta ?? h;
        return (
          desde: DateTime(d.year, d.month, d.day),
          hasta: DateTime(t.year, t.month, t.day)
        );
      case 'mes':
      default:
        return (
          desde: DateTime(h.year, h.month, 1),
          hasta: DateTime(h.year, h.month + 1, 0)
        );
    }
  }

  /// D-B3-09: carga la base (ajustes + seis espejos) si aún
  /// no se cargó en esta entrada a la pantalla.
  Future<void> _asegurarBase() async {
    if (_baseLista) return;
    final db = LocalDb.instance;
    _ajustesBase = await db.getAjustes();
    _aperturasBase = await db.allMirror('turnos_apertura');
    _cierresBase = await db.allMirror('turnos_cierre');
    _pagosBase = await db.allMirror('pagos');
    _anuladosColaBase = await db.pagosAnuladosEnCola();
    _diariosBase = await db.allMirror('pagos_diarios');
    _ventasSupBase = await db.allMirror('ventas_suplementos');
    _ventasServBase = await db.allMirror('servicio_ventas');
    _baseLista = true;
  }

  /// D-B3-09 + H-06: el río se recarga SOLO si la ventana
  /// pedida se sale de la cubierta (ampliar); la recarga
  /// pide la unión para que estrechar después no recargue.
  /// Cambiar de persona nunca pasa por aquí con recarga:
  /// la ventana no cambia al cambiar de persona.
  Future<void> _asegurarRio(String desdeIso, String hastaIso) async {
    final cubierto = _rioDesdeIso != null &&
        desdeIso.compareTo(_rioDesdeIso!) >= 0 &&
        hastaIso.compareTo(_rioHastaIso!) <= 0;
    if (cubierto) return;
    final nuevoDesde = (_rioDesdeIso == null ||
            desdeIso.compareTo(_rioDesdeIso!) < 0)
        ? desdeIso
        : _rioDesdeIso!;
    final nuevoHasta = (_rioHastaIso == null ||
            hastaIso.compareTo(_rioHastaIso!) > 0)
        ? hastaIso
        : _rioHastaIso!;
    _rio = await LocalDb.instance
        .opsEntreFechas(nuevoDesde, nuevoHasta);
    _rioDesdeIso = nuevoDesde;
    _rioHastaIso = nuevoHasta;
  }

  /// El botón de refrescar SÍ relee todo (es su oficio):
  /// invalida la base y la ventana del río y recalcula.
  Future<void> _recargarTodo() async {
    _baseLista = false;
    _rio = [];
    _rioDesdeIso = null;
    _rioHastaIso = null;
    await _cargar();
  }

  Future<void> _cargar() async {
    final persona = _persona;
    if (persona == null) return;
    setState(() => _cargando = true);
    try {
      final per = _periodo();
      final desdeIso = isoFechaTurno(per.desde);
      final hastaIso = isoFechaTurno(per.hasta);
      await _asegurarBase();
      await _asegurarRio(desdeIso, hastaIso);
      final ajustes = _ajustesBase;
      final aperturas = _aperturasBase;
      final cierres = _cierresBase;
      final pagos = _pagosBase;
      final diarios = _diariosBase;
      final ventasSup = _ventasSupBase;
      final ventasServ = _ventasServBase;

      final turnos = auditarTurnosPersona(
        persona: persona,
        desde: per.desde,
        hasta: per.hasta,
        patron: parsePatronTurnos(ajustes['horario_turnos']),
        excepciones:
            parseExcepcionesTurnos(ajustes['horario_excepciones']),
        aperturas: aperturas,
        cierres: cierres,
        usuarios: _personas,
      );
      final dinero = auditarDineroPersona(
        persona: persona,
        desdeIso: desdeIso,
        hastaIso: hastaIso,
        pagos: pagos,
        pagosDiarios: diarios,
        ventasSuplementos: ventasSup,
        ventasServicios: ventasServ,
        cierres: cierres,
        anuladosEnCola: _anuladosColaBase,
      );
      // Bloque 3: el río de ops de ESTE teléfono (el de la
      // ventana cubierta, completo), filtrado EN MEMORIA
      // por actor, tipo sensible y la ventana pedida.
      final ops = _rio;
      final sensibles = <Map<String, dynamic>>[];
      for (final op in ops) {
        if (!tiposOpSensibles.contains('${op['tipo']}')) continue;
        final creada = '${op['creada_ts'] ?? ''}';
        if (creada.length < 10) continue;
        final f = creada.substring(0, 10);
        if (f.compareTo(desdeIso) < 0 || f.compareTo(hastaIso) > 0) {
          continue;
        }
        final p = payloadDeOp(op);
        final tg = p['registrado_por'];
        final nombre = '${p['registrado_por_nombre'] ?? ''}';
        final esSuya = (tg is num && persona.telegramId == tg.toInt()) ||
            (nombre.isNotEmpty &&
                normalizarNombreTurno(nombre) ==
                    normalizarNombreTurno(persona.nombre));
        if (esSuya) sensibles.add(op);
      }
      // Cobertura P2: ventana global del espejo de aperturas.
      String? minFecha;
      for (final a in aperturas) {
        final f = '${a['fecha_turno'] ?? ''}';
        if (f.length >= 10 &&
            (minFecha == null || f.compareTo(minFecha) < 0)) {
          minFecha = f.substring(0, 10);
        }
      }
      if (mounted) {
        setState(() {
          _turnos = turnos;
          _dinero = dinero;
          _sensibles = sensibles;
          _resumen = resumirAuditoria(
            turnos: turnos,
            dinero: dinero,
            accionesSensibles: sensibles.length,
          );
          _falloCarga = null;
          _avisoCobertura = avisoCoberturaAperturas(
              desdeIso: desdeIso, minFechaEspejo: minFecha);
          // 1.25 T115: series diarias y período LEGIBLE.
          _serieMinutos = serieMinutosPorDia(
              turnos: turnos, desdeIso: desdeIso, hastaIso: hastaIso);
          _serieCobros = serieCobrosPorDia(
              persona: persona,
              desdeIso: desdeIso,
              hastaIso: hastaIso,
              pagos: pagos,
              pagosDiarios: diarios,
              ventasSuplementos: ventasSup,
              ventasServicios: ventasServ,
              anuladosEnCola: _anuladosColaBase);
          _periodoTexto = textoPeriodoLegible(desdeIso, hastaIso);
          _cargando = false;
        });
      }
    } catch (e) {
      // Yunque de App 1.31 (C1-4): bitácora + error visible.
      // Antes el fallo dejaba «Sin datos.»/«Sin turnos en el
      // período.»: en la pantalla que audita el dinero de una
      // persona, un fallo de lectura parecía una persona sin
      // movimientos.
      AppLog.error('auditoria_persona', 'carga_fallo', d: '$e');
      if (mounted) {
        setState(() {
          _falloCarga = '$e';
          _cargando = false;
        });
      }
    }
  }

  Future<void> _elegirRango() async {
    final hoy = ahoraHabana();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(hoy.year - 1, 1, 1),
      lastDate: hoy,
      initialDateRange: _rangoDesde != null && _rangoHasta != null
          ? DateTimeRange(start: _rangoDesde!, end: _rangoHasta!)
          : null,
    );
    if (r != null && mounted) {
      setState(() {
        _rangoDesde = r.start;
        _rangoHasta = r.end;
        _modo = 'rango';
      });
      await _cargar();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embebida
          ? null
          : appBarIron(
        context,
        'Auditoría por persona',
        acciones: [
          IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _recargarTodo),
        ],
      ),
      body: _cargando
          // 1.25 T114: esqueleto con la forma de la lista.
          ? const Padding(
              padding: EdgeInsets.all(AppEspacio.md),
              child: SkeletonLista(items: 3))
          : _falloCarga != null
              ? EstadoError(
                  detalle: _falloCarga,
                  onReintentar: _recargarTodo,
                )
              : _persona == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(AppEspacio.xl),
                    child: Text(
                        'No se pudo identificar tu usuario en este '
                        'teléfono. Sincroniza y vuelve a intentarlo.'),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(AppEspacio.md),
                  children: [
                    if (_soyDuenio) _selectorPersona(),
                    _selectorPeriodo(),
                    const SizedBox(height: AppEspacio.sm),
                    Text('Período: $_periodoTexto',
                        style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
                    if (_avisoCobertura != null) ...[
                      const SizedBox(height: AppEspacio.sm),
                      Tarjeta(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.info_rounded,
                                size: 19, color: AppColores.alerta),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(_avisoCobertura!,
                                    style: AppTexto.cuerpo)),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: AppEspacio.md),
                    if (_resumen != null) _tarjetaResumen(),
                    const SizedBox(height: AppEspacio.md),
                    _bloqueTurnos(),
                    const SizedBox(height: AppEspacio.md),
                    _bloqueDinero(),
                    const SizedBox(height: AppEspacio.md),
                    _bloqueSensibles(),
                  ],
                ),
    );
  }

  Widget _selectorPersona() {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: SelectorIronForm<PersonaApk>(
        valorInicial: _persona,
        etiqueta: 'Persona',
        opciones: [
          for (final p in _personas)
            OpcionSelector(
              p,
              p.activo ? p.nombre : '${p.nombre} (de baja)',
            ),
        ],
        alCambiar: (p) async {
          setState(() => _persona = p);
          await _cargar();
        },
      ),
    );
  }

  Widget _selectorPeriodo() {
    const modos = {
      'dia': 'Día',
      'semana': 'Semana',
      'mes': 'Mes',
      'rango': 'Rango',
    };
    return Wrap(
      spacing: 8,
      children: [
        for (final e in modos.entries)
          ChoiceChip(
            label: Text(e.value),
            selected: _modo == e.key,
            onSelected: (_) async {
              if (e.key == 'rango') {
                await _elegirRango();
              } else {
                setState(() => _modo = e.key);
                await _cargar();
              }
            },
          ),
      ],
    );
  }

  Widget _tarjetaResumen() {
    final r = _resumen!;
    final horas = r.horasRealesMin ~/ 60;
    final mins = r.horasRealesMin % 60;
    Widget dato(String etiqueta, String valor) => Expanded(
          child: Column(
            children: [
              Text(valor,
                  style: AppTexto.titulo.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(etiqueta,
                  textAlign: TextAlign.center,
                  style: AppTexto.metadato),
            ],
          ),
        );
    // 1.25 T115: rejilla legible 3+3 (antes 5 métricas
    // apretadas en una fila) + los dos mini-gráficos
    // del período con el componente de barras de la casa.
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              dato('Días trabajados', '${r.diasTrabajados}'),
              dato('Horas reales', '${horas}h ${mins}m'),
              dato('Total cobrado', fmtMonto(r.totalCobrado)),
            ],
          ),
          const SizedBox(height: AppEspacio.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              dato('Turnos', '${_turnos.length}'),
              dato('Acciones sensibles', '${r.accionesSensibles}'),
              dato('Anomalías', '${r.anomalias}'),
            ],
          ),
          const SizedBox(height: AppEspacio.md),
          const Divider(height: 1),
          const SizedBox(height: AppEspacio.md),
          const Text('Minutos por día', style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.sm),
          GraficoBarrasDiarias(datos: _serieMinutos, altura: 64),
          const SizedBox(height: AppEspacio.md),
          const Text('Cobros por día (CUP)', style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.sm),
          GraficoBarrasDiarias(datos: _serieCobros, altura: 64),
        ],
      ),
    );
  }

  Widget _bloqueTurnos() {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Turnos', style: AppTexto.subtitulo),
          const SizedBox(height: 8),
          if (_turnos.isEmpty)
            const Text('Sin turnos en el período.',
                style: AppTexto.cuerpo)
          else
            for (final t in _turnos) _lineaTurno(t),
        ],
      ),
    );
  }

  Widget _lineaTurno(TurnoAuditado t) {
    final f = isoFechaTurno(t.fecha);
    final franja = t.franja == 'manana' ? 'Mañana' : 'Tarde';
    final partes = <String>[];
    if (t.noApertura) {
      partes.add('⚠ no abrió');
    } else if (t.aperturaEn != null) {
      final h = t.aperturaEn!;
      partes.add('abrió '
          '${h.hour.toString().padLeft(2, '0')}:${h.minute.toString().padLeft(2, '0')}');
      if (t.tarde) partes.add('⚠ tarde ${t.tardanzaMin} min');
    }
    if (t.cubrioFueraDePlan) partes.add('cubrió fuera de plan');
    if (t.duracionMin != null) {
      partes.add('duró ${t.duracionMin! ~/ 60}h ${t.duracionMin! % 60}m');
      if (t.corto) partes.add('⚠ turno corto');
    }
    if (t.diferenciaArqueo != null && t.diferenciaArqueo != 0) {
      partes.add('arqueo ${fmtMonto(t.diferenciaArqueo!)}');
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text('$f · $franja',
                style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: Text(
                partes.isEmpty ? 'sin novedad' : partes.join(' · '),
                style: AppTexto.metadato),
          ),
        ],
      ),
    );
  }

  Widget _bloqueDinero() {
    final d = _dinero;
    Widget fila(String etiqueta, String valor) => Padding(
          padding: const EdgeInsets.only(bottom: AppEspacio.xs),
          child: Row(
            children: [
              Expanded(
                  child:
                      Text(etiqueta, style: AppTexto.cuerpo)),
              Text(valor,
                  style: AppTexto.secundario.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
        );
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Dinero que movió', style: AppTexto.subtitulo),
          const SizedBox(height: 8),
          if (d == null)
            const Text('Sin datos.', style: AppTexto.cuerpo)
          else ...[
            fila('Mensualidades (${d.pagosMes}) — efectivo',
                fmtMonto(d.mensualEfectivo)),
            fila('Mensualidades — transferencia',
                fmtMonto(d.mensualTransferencia)),
            fila('Pagos diarios (${d.pagosDiarios})',
                fmtMonto(d.diarioTotal)),
            fila('Suplementos (${d.ventasSuplementos})',
                fmtMonto(d.suplementosTotal)),
            fila('Dosis vendidas (${d.ventasDosis})',
                fmtMonto(d.dosisTotal)),
            fila('Su comisión por dosis', fmtMonto(d.comisionDosis)),
            fila('Pendiente a entregar (generado)',
                fmtMonto(d.pendienteGenerado)),
            fila('Entregado y confirmado',
                fmtMonto(d.entregadoConfirmado)),
            fila('Arqueos suyos (${d.arqueos}) — diferencia total',
                fmtMonto(d.diferenciaArqueos)),
          ],
        ],
      ),
    );
  }

  Widget _bloqueSensibles() {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acciones sensibles (en este teléfono)',
              style: AppTexto.subtitulo),
          const SizedBox(height: 8),
          if (_sensibles.isEmpty)
            const Text(
                'Ninguna registrada en el período en el río de '
                'este teléfono.',
                style: AppTexto.cuerpo)
          else
            for (final op in _sensibles.take(30))
              Padding(
                padding: const EdgeInsets.only(bottom: AppEspacio.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 84,
                      child: Text(
                          '${op['creada_ts'] ?? ''}'.length >= 10
                              ? '${op['creada_ts']}'.substring(0, 10)
                              : '',
                          style: AppTexto.metadato),
                    ),
                    Expanded(
                      child: Text(descripcionOp('${op['tipo']}'),
                          style: AppTexto.metadato),
                    ),
                  ],
                ),
              ),
          if (_sensibles.length > 30)
            Text('… y ${_sensibles.length - 30} más.',
                style: AppTexto.cuerpo),
        ],
      ),
    );
  }
}
