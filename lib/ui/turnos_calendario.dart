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

import '../app_log.dart';
import '../auth.dart';
import '../errores_sync.dart';
import '../localdb.dart';
import '../tiempo.dart';
import '../turnos_resolucion.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

class CalendarioTurnosScreen extends StatefulWidget {
  const CalendarioTurnosScreen({super.key});

  @override
  State<CalendarioTurnosScreen> createState() =>
      _CalendarioTurnosScreenState();
}

/// T2 (estéticas 1.19): color estable por entrenador para los
/// chips del calendario — mismo nombre, mismo color todo el mes.
/// Los dos entrenadores del gym tienen color fijo y distinto; el
/// resto cae por hash del nombre.
Color colorChipEntrenador(String? nombre) {
  final n = (nombre ?? '').trim().toLowerCase();
  if (n.isEmpty) return Colors.grey;
  if (n.contains('duany')) return AppColores.naranja;
  if (n.contains('gabriel')) return AppColores.info;
  const paleta = [
    AppColores.exito,
    AppColores.alerta,
    AppColores.info,
    AppColores.naranja,
  ];
  var h = 0;
  for (final u in n.runes) {
    h = (h * 31 + u) % 1000003;
  }
  return paleta[h % paleta.length];
}

class _CalendarioTurnosScreenState extends State<CalendarioTurnosScreen> {
  static const _diasCortos = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  static const _meses = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre',
    'diciembre'
  ];

  bool _cargando = true;
  // SL-11 (G12-1): la carga fallida se DICE con EstadoError:
  // antes el catch mudo dejaba patrón y excepciones vacíos y
  // el mes se pintaba como si nadie trabajara nunca.
  bool _errorCarga = false;
  bool _guardando = false;
  late DateTime _mes;
  Map<int, Map<String, String?>> _patron = {};
  Map<String, Map<String, String?>> _excepciones = {};
  List<String> _entrenadores = [];

  /// 1.25 T81: las aperturas REALES del espejo, por
  /// fecha ISO — la marca de lo que pasó de verdad.
  Map<String, List<Map<String, dynamic>>> _aperturasPorDia = {};

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
      // 1.25 T81: las aperturas reales para contrastar
      // programado vs real en los días pasados.
      // F02-PB (z14_turnos-1): un fallo de aperturas deja
      // rastro y marca la carga como fallida — nunca se
      // pinta como calendario normal sin señal.
      var falloAperturas = false;
      try {
        final aps =
            await LocalDb.instance.allMirror('turnos_apertura');
        final porDia = <String, List<Map<String, dynamic>>>{};
        for (final a in aps) {
          final f = '${a['fecha_turno'] ?? ''}';
          if (f.isEmpty) continue;
          porDia.putIfAbsent(f, () => []).add(a);
        }
        _aperturasPorDia = porDia;
      } catch (e) {
        falloAperturas = true;
        AppLog.error('turnos_calendario', 'aperturas_fallo',
            d: '$e');
      }
      if (mounted) setState(() => _errorCarga = falloAperturas);
    } catch (_) {
      if (mounted) setState(() => _errorCarga = true);
    }
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
        mostrarSnack(context, 'Excepciones guardadas (se sincronizarán)', significado: SignificadoChip.exito);
      }
    } catch (e) {
      // SL-11 (G12-8): nada crudo a pantalla — mensaje amable
      // de la casa y la excepción a la bitácora.
      AppLog.error('turnos_calendario', 'guardar_excepciones_fallo',
          d: '$e');
      if (mounted) {
        mostrarSnack(context,
            'No se pudieron guardar las excepciones: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
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
                    padding: EdgeInsets.only(bottom: AppEspacio.md),
                    child: Text('Día pasado: solo lectura.',
                        style: AppTexto.secundario),
                  ),
                for (final franja in sel.keys) ...[
                  Text(franja == 'manana' ? 'Mañana' : 'Tarde',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 4),
                  SelectorIronForm<String>(
                    valorInicial: sel[franja],
                    opciones: [
                      OpcionSelector(
                        '__patron',
                        'Según patrón: '
                            '${_patron[fecha.weekday]?[franja] ?? 'sin nadie'}',
                      ),
                      for (final n in _entrenadores)
                        OpcionSelector(n, n),
                      if (sel[franja] != '__patron' &&
                          sel[franja] != '__nadie' &&
                          !_entrenadores.contains(sel[franja]))
                        OpcionSelector(
                          // No nulo: el bucle solo recorre las
                          // franjas recién asignadas arriba.
                          sel[franja]!,
                          '⚠ ${sel[franja]} (ya no es '
                              'usuario de la app)',
                        ),
                      const OpcionSelector(
                        '__nadie',
                        'Sin nadie (anular la franja)',
                      ),
                    ],
                    alCambiar: pasado
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
        appBar: appBarIron(context, 'Horario y turnos'),
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
      appBar: appBarIron(
        context,
        'Calendario de turnos',
        acciones: [
          // F3-21: la navegación se limita a ±6 meses (las
          // excepciones se podan a 180 días: más allá no hay
          // nada que ver ni corregir).
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            onPressed: _puedeRetrocederMes(hoy)
                ? () => setState(() =>
                    _mes = DateTime(_mes.year, _mes.month - 1))
                : null,
          ),
          Center(
            child: Text(
                '${_meses[_mes.month - 1]} ${_mes.year}',
                style: AppTexto.subtitulo),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            onPressed: _puedeAvanzarMes(hoy)
                ? () => setState(() =>
                    _mes = DateTime(_mes.year, _mes.month + 1))
                : null,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando calendario…')
          : _errorCarga
              ? EstadoError(
                  detalle: 'No se pudo cargar el patrón ni las '
                      'excepciones de turnos.',
                  onReintentar: () {
                    setState(() => _cargando = true);
                    _cargar();
                  },
                )
              : ListView(
              padding: const EdgeInsets.all(AppEspacio.md),
              children: [
                const Text(
                  'Cada día muestra quién está programado (patrón '
                  'con las excepciones de ese día). El punto '
                  'ámbar marca los días con excepción. Toca un '
                  'día para corregirlo sin tocar el patrón.',
                  style: AppTexto.cuerpo,
                ),
                // F3-21: leyenda de colores por entrenador
                // (antes había que adivinarlos celda a celda).
                if (_nombresEnCalendario().isNotEmpty) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Wrap(
                    spacing: AppEspacio.md,
                    runSpacing: AppEspacio.xs,
                    children: [
                      for (final n in _nombresEnCalendario())
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(
                                color: colorChipEntrenador(n),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: AppEspacio.xs),
                            Text(n.split(' ').first,
                                style: AppTexto.metadato),
                          ],
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: AppEspacio.md),
                Row(
                  children: [
                    for (final d in _diasCortos)
                      Expanded(
                        child: Center(
                          child: Text(d,
                              style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(
                                      context), fontWeight: FontWeight.w700)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
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
                // 1.25 T81: leyenda de las marcas reales.
                Wrap(
                  spacing: AppEspacio.md,
                  runSpacing: AppEspacio.xs,
                  children: [
                    for (final (color, txt) in [
                      (AppColores.exito, 'Abrió el programado'),
                      (AppColores.alerta, 'Abrió otro'),
                      (AppColores.error, 'Nadie abrió'),
                    ])
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: AppEspacio.xs),
                          Text(txt, style: AppTexto.metadato),
                        ],
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

  /// F3-21: nombres con color en el calendario, desde el
  /// patrón y las excepciones cargadas (para la leyenda).
  List<String> _nombresEnCalendario() {
    final nombres = <String>{};
    for (final franjas in _patron.values) {
      for (final n in franjas.values) {
        if (n != null && n.trim().isNotEmpty) nombres.add(n.trim());
      }
    }
    for (final franjas in _excepciones.values) {
      for (final n in franjas.values) {
        if (n != null && n.trim().isNotEmpty) nombres.add(n.trim());
      }
    }
    return nombres.toList()..sort();
  }

  bool _puedeRetrocederMes(DateTime hoy) =>
      DateTime(_mes.year, _mes.month - 1)
          .isAfter(DateTime(hoy.year, hoy.month - 7));

  bool _puedeAvanzarMes(DateTime hoy) =>
      DateTime(_mes.year, _mes.month + 1)
          .isBefore(DateTime(hoy.year, hoy.month + 7));

  /// T2 (estéticas 1.19): chip de franja — el color identifica al
  /// entrenador de un vistazo en todo el mes.
  Widget _chipTurno(String letra, String? nombre) {
    if (nombre == null) {
      return Row(
        children: [
          Text('$letra ',
              style: AppTexto.minuscula.copyWith(fontWeight: FontWeight.w700)),
          const Text('—', style: AppTexto.minuscula),
        ],
      );
    }
    final color = colorChipEntrenador(nombre);
    return Row(
      children: [
        Text('$letra ',
            style: AppTexto.minuscula.copyWith(fontWeight: FontWeight.w700)),
        Expanded(
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: AppEspacio.xs, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(AppRadio.circular),
            ),
            child: Text(
              nombre.split(' ').first,
              style: AppTexto.minuscula.copyWith(color: color, fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  Widget _celda(
      BuildContext context, int dia, int diasEnMes, DateTime hoy) {
    if (dia < 1 || dia > diasEnMes) {
      // F3-21: alto MÍNIMO, no fijo (con el texto del sistema
      // grande la celda de 64 px fijos desbordaba).
      return ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 64),
        child: const SizedBox.shrink(),
      );
    }
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
    return Padding(
      padding: const EdgeInsets.all(2),
      child: Material(
        color: esHoy
            ? AppColores.naranja.withValues(alpha: 0.12)
            : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(AppRadio.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadio.md),
          onTap: domingo ? null : () => _editarDia(fecha),
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.all(AppEspacio.xs),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadio.md),
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
                          style: AppTexto.metadato.copyWith(color: esHoy
                                  ? AppColores.naranja
                                  : null, fontWeight: FontWeight.w800)),
                      const Spacer(),
                      // 1.25 T81: la marca de lo REAL en
                      // los días pasados (verde: abrieron
                      // todos los programados; ámbar:
                      // abrió otro o faltó un programado;
                      // rojo: nadie abrió).
                      if (pasado && !domingo)
                        Builder(builder: (context) {
                          final marca = marcaRealDiaCalendario(
                            programados: {
                              if (manana != null) manana,
                              if (tarde != null) tarde,
                            },
                            aperturasDia:
                                _aperturasPorDia[iso] ?? const [],
                          );
                          if (marca == null) {
                            return const SizedBox.shrink();
                          }
                          final color = switch (marca) {
                            'abrio' => AppColores.exito,
                            'distinto' => AppColores.alerta,
                            'parcial' => AppColores.alerta,
                            _ => AppColores.error,
                          };
                          return Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(
                                right: AppEspacio.xs),
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          );
                        }),
                      if (conExcepcion)
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: AppColores.alerta,
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  if (domingo)
                    const Text('Cerrado',
                        style: AppTexto.minuscula)
                  else ...[
                    _chipTurno('M', manana),
                    const SizedBox(height: 2),
                    if (fecha.weekday != 6) _chipTurno('T', tarde),
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
