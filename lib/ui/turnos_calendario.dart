// lib/ui/turnos_calendario.dart
// v1.8.0 — Editor único de Turnos, vista Calendario: cada día
// muestra la resolución patrón ⊕ excepción; tocar un día edita
// SOLO ese día (excepción) sin tocar el patrón. Sustituye a la
// pantalla de «Turnos manuales» (absorbidos como excepciones,
// migración T4 de Argón): la fuente de verdad pasa a ser el
// ajuste `horario_excepciones`, validado por el servidor con
// poda móvil de 180 días (T3) y publicado junto al patrón.
//
// Solo el dueño edita; los días pasados son de solo lectura y el
// domingo está cerrado (sin excepciones, como manda el validador).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../tiempo.dart';
import '../turnos_resolucion.dart';
import 'componentes.dart';
import 'diseno.dart';

class CalendarioTurnosScreen extends StatefulWidget {
  const CalendarioTurnosScreen({super.key});

  @override
  State<CalendarioTurnosScreen> createState() =>
      _CalendarioTurnosScreenState();
}

class _CalendarioTurnosScreenState extends State<CalendarioTurnosScreen> {
  static const _diasCortos = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  static const _meses = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre',
    'diciembre'
  ];

  bool _cargando = true;
  bool _guardando = false;
  late DateTime _mes;
  Map<int, Map<String, String?>> _patron = {};
  Map<String, Map<String, String?>> _excepciones = {};
  List<String> _entrenadores = [];

  @override
  void initState() {
    super.initState();
    final hoy = ahoraHabana();
    _mes = DateTime(hoy.year, hoy.month);
    _cargar();
  }

  static String _visible(String bruto) {
    final n = bruto.trim();
    if (n.length <= 1) return n.toUpperCase();
    return '${n[0].toUpperCase()}${n.substring(1)}';
  }

  Future<void> _cargar() async {
    try {
      final aj = await LocalDb.instance.getAjustes();
      _patron = parsePatronTurnos(aj['horario_turnos']);
      _excepciones = parseExcepcionesTurnos(aj['horario_excepciones']);
      // Canon de nombres (mismo criterio que el editor del
      // patrón): usuarios APK + nombres ya usados, para que un
      // nombre huérfano siga siendo visible (y marcable).
      final canon = <String, String>{};
      String registrar(String bruto) => canon.putIfAbsent(
          bruto.trim().toLowerCase(), () => _visible(bruto));
      try {
        final raw = await LocalDb.instance.getMeta('usuarios_apk');
        if (raw != null && raw.isNotEmpty) {
          for (final u in jsonDecode(raw) as List) {
            final m = Map<String, dynamic>.from(u as Map);
            final nom = (m['nombre'] as String?)?.trim();
            final base = (nom != null && nom.isNotEmpty)
                ? nom
                : (m['username'] as String? ?? '');
            if (base.trim().isNotEmpty) registrar(base);
          }
        }
      } catch (_) {}
      for (final franjas in _patron.values) {
        for (final n in franjas.values) {
          if (n != null) registrar(n);
        }
      }
      for (final franjas in _excepciones.values) {
        for (final n in franjas.values) {
          if (n != null) registrar(n);
        }
      }
      _entrenadores = canon.values.toList();
    } catch (_) {}
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _guardar() async {
    setState(() => _guardando = true);
    try {
      final podadas = podarExcepciones(_excepciones);
      final mapa = <String, dynamic>{
        for (final e in podadas.entries)
          e.key: {
            for (final f in e.value.entries) f.key: f.value,
          },
      };
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': 'horario_excepciones', 'valor': mapa},
      );
      final aj = await LocalDb.instance.getAjustes();
      aj['horario_excepciones'] = mapa;
      await LocalDb.instance.setAjustes(aj);
      _excepciones = podadas;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Excepciones guardadas (se sincronizarán)')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  bool _esDiaPasado(DateTime d) {
    final hoy = ahoraHabana();
    final h = DateTime(hoy.year, hoy.month, hoy.day);
    return DateTime(d.year, d.month, d.day).isBefore(h);
  }

  Future<void> _editarDia(DateTime fecha) async {
    if (fecha.weekday == 7) return;
    final iso = isoFechaTurno(fecha);
    final pasado = _esDiaPasado(fecha);
    // Estado por franja: '__patron' | '__nadie' | nombre.
    final sel = <String, String>{};
    for (final franja in const ['manana', 'tarde']) {
      if (ventanaFranja(fecha, franja) == null) continue;
      if (hayExcepcion(_excepciones, fecha, franja)) {
        final v = _excepciones[iso]![franja];
        sel[franja] = v == null ? '__nadie' : v;
      } else {
        sel[franja] = '__patron';
      }
    }
    final tieneExcepcion = _excepciones.containsKey(iso);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(
              '${_diasCortos[fecha.weekday - 1]} ${fecha.day} de '
              '${_meses[fecha.month - 1]}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pasado)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('Día pasado: solo lectura.',
                        style: TextStyle(fontSize: 13)),
                  ),
                for (final franja in sel.keys) ...[
                  Text(franja == 'manana' ? 'Mañana' : 'Tarde',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 4),
                  DropdownButtonFormField<String>(
                    initialValue: sel[franja],
                    isExpanded: true,
                    items: [
                      DropdownMenuItem(
                        value: '__patron',
                        child: Text('Según patrón: '
                            '${_patron[fecha.weekday]?[franja] ?? 'sin nadie'}'),
                      ),
                      for (final n in _entrenadores)
                        DropdownMenuItem(value: n, child: Text(n)),
                      if (sel[franja] != '__patron' &&
                          sel[franja] != '__nadie' &&
                          !_entrenadores.contains(sel[franja]))
                        DropdownMenuItem(
                          value: sel[franja],
                          child: Text('⚠ ${sel[franja]} (ya no es '
                              'usuario de la app)'),
                        ),
                      const DropdownMenuItem(
                        value: '__nadie',
                        child: Text('Sin nadie (anular la franja)'),
                      ),
                    ],
                    onChanged: pasado
                        ? null
                        : (v) => setLocal(() => sel[franja] = v!),
                  ),
                  const SizedBox(height: 12),
                ],
                if (tieneExcepcion && !pasado)
                  TextButton.icon(
                    icon: const Icon(Icons.restart_alt_rounded,
                        size: 18),
                    label: const Text('Volver al patrón (borrar '
                        'la excepción del día)'),
                    onPressed: () => setLocal(() {
                      for (final f in sel.keys) {
                        sel[f] = '__patron';
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cerrar'),
            ),
            if (!pasado)
              FilledButton(
                onPressed: _guardando
                    ? null
                    : () async {
                        final delDia = <String, String?>{};
                        for (final e in sel.entries) {
                          if (e.value == '__patron') continue;
                          if (e.value == '__nadie') {
                            delDia[e.key] = null;
                          } else {
                            delDia[e.key] = e.value;
                          }
                        }
                        setState(() {
                          if (delDia.isEmpty) {
                            _excepciones.remove(iso);
                          } else {
                            _excepciones[iso] = delDia;
                          }
                        });
                        Navigator.of(ctx).pop();
                        await _guardar();
                      },
                child: const Text('Guardar'),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Horario y turnos')),
        body: const Center(
          child: Text('Solo el dueño puede gestionar los turnos.'),
        ),
      );
    }
    final hoy = ahoraHabana();
    final primero = DateTime(_mes.year, _mes.month, 1);
    final diasEnMes = DateTime(_mes.year, _mes.month + 1, 0).day;
    final offset = primero.weekday - 1; // lunes = 0
    final celdas = offset + diasEnMes;
    final filas = (celdas / 7).ceil();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Calendario de turnos'),
        actions: [
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: () => setState(() =>
                _mes = DateTime(_mes.year, _mes.month - 1)),
          ),
          Center(
            child: Text(
                '${_meses[_mes.month - 1]} ${_mes.year}',
                style: AppTexto.subtitulo),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: () => setState(() =>
                _mes = DateTime(_mes.year, _mes.month + 1)),
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.md),
              children: [
                const Text(
                  'Cada día muestra quién está programado (patrón '
                  'con las excepciones de ese día). El punto '
                  'naranja marca los días con excepción. Toca un '
                  'día para corregirlo sin tocar el patrón.',
                  style: AppTexto.cuerpo,
                ),
                const SizedBox(height: AppEspacio.md),
                Row(
                  children: [
                    for (final d in _diasCortos)
                      Expanded(
                        child: Center(
                          child: Text(d,
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppColores.textoSecundario(
                                      context))),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                for (var fila = 0; fila < filas; fila++)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var col = 0; col < 7; col++)
                        Expanded(
                          child: _celda(
                            context,
                            fila * 7 + col - offset + 1,
                            diasEnMes,
                            hoy,
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: AppEspacio.md),
                const Tarjeta(
                  child: Text(
                    'Lo programado es lo que se muestra en las '
                    'apps desde la hora del turno, haya abierto '
                    'el entrenador o no. Si abre otro, se le '
                    'muestra a él mientras su turno siga abierto.',
                    style: AppTexto.cuerpo,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _celda(
      BuildContext context, int dia, int diasEnMes, DateTime hoy) {
    if (dia < 1 || dia > diasEnMes) return const SizedBox(height: 64);
    final fecha = DateTime(_mes.year, _mes.month, dia);
    final esHoy = fecha.year == hoy.year &&
        fecha.month == hoy.month &&
        fecha.day == hoy.day;
    final domingo = fecha.weekday == 7;
    final pasado = _esDiaPasado(fecha);
    final iso = isoFechaTurno(fecha);
    final conExcepcion = _excepciones.containsKey(iso);
    final manana = domingo
        ? null
        : programadoEn(
            fecha: fecha,
            franja: 'manana',
            patron: _patron,
            excepciones: _excepciones);
    final tarde = domingo || fecha.weekday == 6
        ? null
        : programadoEn(
            fecha: fecha,
            franja: 'tarde',
            patron: _patron,
            excepciones: _excepciones);
    String corto(String? n) =>
        n == null ? '—' : n.split(' ').first;
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        color: esHoy
            ? AppColores.naranja.withValues(alpha: 0.12)
            : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: domingo ? null : () => _editarDia(fecha),
          child: Container(
            height: 64,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: esHoy
                    ? AppColores.naranja
                    : Theme.of(context).dividerColor,
              ),
            ),
            child: Opacity(
              opacity: pasado ? 0.55 : 1,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('$dia',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: esHoy
                                  ? AppColores.naranja
                                  : null)),
                      const Spacer(),
                      if (conExcepcion)
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: Colors.orange,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  if (domingo)
                    const Text('Cerrado',
                        style: TextStyle(fontSize: 10))
                  else ...[
                    Text('M ${corto(manana)}',
                        style: const TextStyle(fontSize: 10),
                        overflow: TextOverflow.ellipsis),
                    if (fecha.weekday != 6)
                      Text('T ${corto(tarde)}',
                          style: const TextStyle(fontSize: 10),
                          overflow: TextOverflow.ellipsis),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
