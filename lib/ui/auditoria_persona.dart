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
import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../tiempo.dart';
import '../turnos_resolucion.dart';
import 'auditoria.dart' show descripcionOp, payloadDeOp, tiposOpSensibles;
import 'componentes.dart';
import 'diseno.dart';

class AuditoriaPersonaScreen extends StatefulWidget {
  const AuditoriaPersonaScreen({super.key});

  @override
  State<AuditoriaPersonaScreen> createState() =>
      _AuditoriaPersonaScreenState();
}

class _AuditoriaPersonaScreenState extends State<AuditoriaPersonaScreen> {
  bool _cargando = true;
  List<PersonaApk> _personas = [];
  PersonaApk? _persona;
  String _modo = 'mes'; // dia | semana | mes | rango
  DateTime? _rangoDesde;
  DateTime? _rangoHasta;

  List<TurnoAuditado> _turnos = [];
  DineroAuditado? _dinero;
  ResumenAuditoria? _resumen;
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
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _personas = personas;
      if (_soyDuenio) {
        _persona = personas.firstOrNull;
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

  Future<void> _cargar() async {
    final persona = _persona;
    if (persona == null) return;
    setState(() => _cargando = true);
    try {
      final per = _periodo();
      final desdeIso = isoFechaTurno(per.desde);
      final hastaIso = isoFechaTurno(per.hasta);
      final db = LocalDb.instance;
      final ajustes = await db.getAjustes();
      final aperturas = await db.allMirror('turnos_apertura');
      final cierres = await db.allMirror('turnos_cierre');
      final pagos = await db.allMirror('pagos');
      final diarios = await db.allMirror('pagos_diarios');
      final ventasSup = await db.allMirror('ventas_suplementos');
      final ventasServ = await db.allMirror('servicio_ventas');

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
      );
      // Bloque 3: el río de ops de ESTE teléfono, filtrado por
      // actor y tipo sensible (se reutiliza el río tal cual).
      final ops = await db.recentOps(limit: 500);
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
          _avisoCobertura = avisoCoberturaAperturas(
              desdeIso: desdeIso, minFechaEspejo: minFecha);
          _periodoTexto = '$desdeIso → $hastaIso';
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
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
      appBar: AppBar(
        title: const Text('Auditoría por persona'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh), onPressed: _cargar),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando auditoría…')
          : _persona == null
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
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
                        style: TextStyle(
                            fontSize: 12,
                            color: AppColores.textoSecundario(context))),
                    if (_avisoCobertura != null) ...[
                      const SizedBox(height: AppEspacio.sm),
                      Tarjeta(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.info_outline_rounded,
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
      child: DropdownButtonFormField<PersonaApk>(
        initialValue: _persona,
        isExpanded: true,
        decoration:
            const InputDecoration(labelText: 'Persona'),
        items: [
          for (final p in _personas)
            DropdownMenuItem(
              value: p,
              child: Text(p.activo ? p.nombre : '${p.nombre} (de baja)'),
            ),
        ],
        onChanged: (p) async {
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
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(etiqueta,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11)),
            ],
          ),
        );
    return Tarjeta(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          dato('Días trabajados', '${r.diasTrabajados}'),
          dato('Horas reales', '${horas}h ${mins}m'),
          dato('Total cobrado', fmtMonto(r.totalCobrado)),
          dato('Acciones sensibles', '${r.accionesSensibles}'),
          dato('Anomalías', '${r.anomalias}'),
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
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text('$f · $franja',
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: Text(
                partes.isEmpty ? 'sin novedad' : partes.join(' · '),
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _bloqueDinero() {
    final d = _dinero;
    Widget fila(String etiqueta, String valor) => Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Row(
            children: [
              Expanded(
                  child:
                      Text(etiqueta, style: AppTexto.cuerpo)),
              Text(valor,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13)),
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
                padding: const EdgeInsets.only(bottom: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 84,
                      child: Text(
                          '${op['creada_ts'] ?? ''}'.length >= 10
                              ? '${op['creada_ts']}'.substring(0, 10)
                              : '',
                          style: const TextStyle(fontSize: 12)),
                    ),
                    Expanded(
                      child: Text(descripcionOp('${op['tipo']}'),
                          style: const TextStyle(fontSize: 12)),
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
