/// Hub operativo de turnos (24/25): UN solo lugar para el día.
///
/// Reúne lo que hoy vive en pantallas separadas:
/// - Quién está de turno en cada franja (programado ⊕ apertura
///   viva, con la misma resolución que la app de clientes).
/// - Abrir / cerrar MI turno (entrenador).
/// - Pendiente a entregar (mío para el entrenador; por entrenador
///   para el dueño, con salto al Arqueo).
/// No sustituye al hub de Horario y turnos (patrón semanal y
/// calendario de excepciones): ese configura, este opera el día.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import '../turno_service.dart';
import '../turnos_resolucion.dart';
import 'arqueo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'mi_turno.dart';
import 'turnos_hub.dart';

class HubTurnosScreen extends StatefulWidget {
  const HubTurnosScreen({super.key});
  @override
  State<HubTurnosScreen> createState() => _HubTurnosScreenState();
}

class _HubTurnosScreenState extends State<HubTurnosScreen> {
  bool _cargando = true;
  bool _procesando = false;
  // Panel Terra B1 (bloqueante): _hoy nace inicializado. Antes era
  // `late` y solo se asignaba en el setState de éxito de _cargar:
  // si una lectura fallaba antes, el catch apagaba el spinner y el
  // siguiente build leía _hoy sin inicializar (LateInitializationError).
  DateTime _hoy = ahoraHabana();
  String? _franjaActual;
  Map<int, Map<String, String?>> _patron = {};
  Map<String, Map<String, String?>> _excepciones = {};
  List<AperturaTurno> _aperturas = [];
  List<Map<String, dynamic>> _cierres = [];
  Map<String, dynamic>? _miTurnoVisible;
  // Pendientes: (nombre, telegramId, cup, usd).
  List<({String nombre, int tid, double cup, double usd})> _pendientes =
      [];

  bool get _soyDueno => AuthService().isOwner;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final hoy = ahoraHabana();
      final hoyIso = isoFechaTurno(hoy);
      final db = LocalDb.instance;
      final ajustes = await db.getAjustes();
      final patron =
          parsePatronTurnos(ajustes['horario_turnos']);
      final excepciones =
          parseExcepcionesTurnos(ajustes['horario_excepciones']);
      final apMirror = await db.allMirror('turnos_apertura');
      final cierres = await db.allMirror('turnos_cierre');
      var aperturas = aperturasHoyConViva(
          aperturas: apMirror, cierres: cierres, fechaIso: hoyIso);
      // Mi turno local es más fresco que el espejo: si tengo un
      // turno abierto hoy, cuenta como apertura viva aunque el
      // espejo aún no lo traiga.
      Map<String, dynamic>? miVisible;
      if (!_soyDueno) {
        miVisible = await TurnoService.instance.turnoVisible();
        final abierto =
            await TurnoService.instance.turnoActual();
        if (abierto != null) {
          final en = DateTime.tryParse(
              '${abierto['hora_apertura'] ?? ''}');
          if (en != null) {
            final nombre = AuthService().displayName;
            aperturas = [
              for (final a in aperturas)
                if (normalizarNombreTurno(a.nombre) !=
                    normalizarNombreTurno(nombre))
                  a,
              (
                nombre: nombre,
                aperturaEn: en,
                viva: true,
              ),
            ];
          }
        }
      }
      // Pendientes: el dueño ve a cada entrenador; el entrenador
      // solo el suyo.
      final pendientes =
          <({String nombre, int tid, double cup, double usd})>[];
      if (_soyDueno) {
        final yo = AuthService().telegramId;
        try {
          final raw = await db.getMeta('usuarios_apk');
          if (raw != null && raw.isNotEmpty) {
            for (final u in jsonDecode(raw) as List) {
              final m = Map<String, dynamic>.from(u as Map);
              final tid =
                  LocalDb.normalizarTelegramId(m['telegram_id']);
              final nombre =
                  '${m['nombre'] ?? m['username'] ?? ''}'.trim();
              if (tid == null || nombre.isEmpty || tid == yo) {
                continue;
              }
              pendientes.add((
                nombre: nombre,
                tid: tid,
                cup: await pendienteEntrega(tid),
                usd: await pendienteEntregaUsd(tid),
              ));
            }
          }
        } catch (_) {}
      } else {
        final tid = AuthService().telegramId;
        if (tid != null) {
          pendientes.add((
            nombre: AuthService().displayName,
            tid: tid,
            cup: await pendienteEntrega(tid),
            usd: await pendienteEntregaUsd(tid),
          ));
        }
      }
      if (!mounted) return;
      setState(() {
        _hoy = hoy;
        _franjaActual = franjaDeInstante(hoy);
        _patron = patron;
        _excepciones = excepciones;
        _aperturas = aperturas;
        _cierres = cierres;
        _miTurnoVisible = miVisible;
        _pendientes = pendientes;
        _cargando = false;
      });
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  void _snack(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _abrir() async {
    setState(() => _procesando = true);
    try {
      await TurnoService.instance.abrirTurno();
      _snack('Turno abierto.');
      await _cargar();
    } catch (e) {
      _snack('No se pudo abrir el turno: $e');
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  Future<void> _cerrar() async {
    setState(() => _procesando = true);
    try {
      final prep = await TurnoService.instance.prepararCierre();
      if (prep['ok'] != true) {
        _snack('No hay turno abierto para cerrar.');
        return;
      }
      if (!mounted) return;
      final limpio = prep['limpio'] == true;
      final ok = await DialogoApp.confirmar(
        context,
        titulo: 'Cerrar turno',
        mensaje: 'Cobrado del día: ${prep['pagosCount']} pago(s). '
            'Pendientes sin sincronizar: ${prep['pendientesCount']} '
            '(${fmtMonto((prep['pendientesCup'] as num).toDouble())} CUP'
            '${(prep['pendientesUsd'] as num) > 0 ? ' + ${fmtMonto((prep['pendientesUsd'] as num).toDouble())} USD' : ''})'
            '${(prep['revisionCount'] as int) > 0 ? ', ${prep['revisionCount']} en revisión' : ''}.'
            '${limpio ? '' : ' Cerrar de todos modos deja los pendientes guardados en este teléfono.'}',
        aceptar: limpio ? 'Confirmar cierre' : 'Cerrar de todos modos',
        icono: Icons.lock_outline_rounded,
      );
      if (!ok) return;
      await TurnoService.instance.confirmarCierre(
        turnoId: '${prep['turnoId']}',
        forzado: !limpio,
      );
      _snack('Turno cerrado.');
      await _cargar();
    } catch (e) {
      _snack('No se pudo cerrar el turno: $e');
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  String _hora(String? iso) {
    if (iso == null || iso.length < 16) return '—';
    return iso.substring(11, 16);
  }

  /// T1 (estéticas 1.19): quién trabaja hoy, de un vistazo
  /// (nombres distintos de las franjas del día, sin duplicar).
  List<String> _quienesTrabajanHoy() {
    if (_hoy.weekday == 7) return const [];
    final franjas = ['manana', if (_hoy.weekday != 6) 'tarde'];
    final nombres = <String>[];
    for (final f in franjas) {
      final m = estadoFranjaCompleto(
        fecha: _hoy,
        franja: f,
        patron: _patron,
        excepciones: _excepciones,
        aperturas: _aperturas,
        cierres: _cierres,
      ).mostrado;
      if (m != null && m.isNotEmpty && !nombres.contains(m)) {
        nombres.add(m);
      }
    }
    return nombres;
  }

  Widget _filaFranja(String franja, String titulo) {
    final est = estadoFranjaCompleto(
      fecha: _hoy,
      franja: franja,
      patron: _patron,
      excepciones: _excepciones,
      aperturas: _aperturas,
      cierres: _cierres,
    );
    final esActual = _franjaActual == franja;
    final estadoTexto = switch (est.estado) {
      'abierto' => 'Abierto',
      'cerrado' => 'Cerrado',
      _ => 'Sin abrir',
    };
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$titulo${esActual ? ' · ahora' : ''}',
                  style: AppTexto.subtitulo,
                ),
              ),
              Text(estadoTexto, style: AppTexto.cuerpo),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'De turno: ${est.mostrado ?? 'Sin asignar'}'
            '${est.cubriendo ? ' (cubriendo)' : ''}',
            style: AppTexto.cuerpo,
          ),
          if (est.programado != null &&
              est.programado != est.mostrado)
            Text('Programado: ${est.programado}',
                style: AppTexto.secundario),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // T1: se calcula una vez (estado puro, barato, pero sin
    // duplicar el trabajo en cada rebuild).
    final quienesHoy =
        _cargando || _hoy.weekday == 7 ? const <String>[] : _quienesTrabajanHoy();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Turnos de hoy'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Actualizar',
            onPressed: _cargando ? null : _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando turnos…')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Hoy ${_hoy.day}/${_hoy.month}/${_hoy.year}'
                  '${_franjaActual == null ? ' · fuera de horario' : ''}',
                  style: AppTexto.subtitulo,
                ),
                const SizedBox(height: 12),
                // T1 (estéticas 1.19): quién trabaja hoy.
                if (_hoy.weekday != 7) ...[
                  Tarjeta(
                    child: Row(
                      children: [
                        const Icon(Icons.group_rounded,
                            color: AppColores.naranja),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            quienesHoy.isEmpty
                                ? 'Hoy sin asignar'
                                : 'Hoy trabajan: '
                                    '${quienesHoy.join(' · ')}',
                            style: AppTexto.cuerpo,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_hoy.weekday == 7)
                  const Tarjeta(
                    child: Text(
                      'Domingo: el gym no abre. Abajo sigue el '
                      'pendiente a entregar.',
                      style: AppTexto.cuerpo,
                    ),
                  )
                else ...[
                  _filaFranja('manana', 'Mañana'),
                  const SizedBox(height: 8),
                  if (_hoy.weekday != 6) ...[
                    _filaFranja('tarde', 'Tarde'),
                    const SizedBox(height: 8),
                  ],
                ],
                // Mi turno (entrenador).
                if (!_soyDueno) ...[
                  const SizedBox(height: 8),
                  Tarjeta(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Mi turno',
                            style: AppTexto.subtitulo),
                        const SizedBox(height: 6),
                        Builder(
                          builder: (_) {
                            final v = _miTurnoVisible;
                            final estado = '${v?['estado'] ?? ''}';
                            if (v == null) {
                              return const Text(
                                'No tienes turno hoy.',
                                style: AppTexto.cuerpo,
                              );
                            }
                            if (estado.startsWith('abierto')) {
                              return Text(
                                'Abierto a las ${_hora('${v['hora_apertura']}')} '
                                '(${v['turno'] ?? ''}).',
                                style: AppTexto.cuerpo,
                              );
                            }
                            if (estado.startsWith('cerrado')) {
                              return const Text(
                                'Turno de hoy cerrado.',
                                style: AppTexto.cuerpo,
                              );
                            }
                            return const Text(
                              'Turno anterior sin cerrar.',
                              style: AppTexto.cuerpo,
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                        if (_miTurnoVisible == null ||
                            '${_miTurnoVisible!['estado'] ?? ''}'
                                .startsWith('abierto'))
                          FilledButton(
                            onPressed: _procesando
                                ? null
                                : (_miTurnoVisible != null &&
                                        '${_miTurnoVisible!['estado'] ?? ''}'
                                            .startsWith('abierto')
                                    ? _cerrar
                                    : _abrir),
                            child: Text(_procesando
                                ? 'Trabajando…'
                                : (_miTurnoVisible != null
                                    ? 'Cerrar turno'
                                    : 'Abrir turno')),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text('Pendiente a entregar',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 8),
                if (_pendientes.isEmpty)
                  const Tarjeta(
                    child: Text('Nada pendiente.',
                        style: AppTexto.cuerpo),
                  )
                else
                  for (final p in _pendientes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Tarjeta(
                        child: InkWell(
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _soyDueno
                                  ? const ArqueoScreen()
                                  : const MiTurnoScreen(),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(p.nombre,
                                    style: AppTexto.subtitulo),
                              ),
                              Text(
                                '${fmtMonto(p.cup)} CUP'
                                '${p.usd > 0 ? ' + ${fmtMonto(p.usd)} USD' : ''}',
                                style: AppTexto.cuerpo,
                              ),
                              const Icon(Icons.chevron_right,
                                  color: Colors.grey, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                const SizedBox(height: 12),
                if (_soyDueno)
                  Tarjeta(
                    child: InkWell(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const TurnosHubScreen(),
                        ),
                      ),
                      child: const Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Horario y turnos (patrón y calendario)',
                              style: AppTexto.subtitulo,
                            ),
                          ),
                          Icon(Icons.chevron_right,
                              color: Colors.grey, size: 18),
                        ],
                      ),
                    ),
                  ),
                // T3 (estéticas 1.19): explicación del hub,
                // plegable para no ocupar sitio a diario.
                const SizedBox(height: 12),
                const ExpansionTile(
                  title: Text('¿Cómo funciona este hub?'),
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        'Arriba ves quién está de turno hoy: lo '
                        'programado en el patrón, y si otro abrió '
                        'el turno, se muestra a él mientras siga '
                        'abierto (cubriendo). Abrir y Cerrar son '
                        'tu turno del día; al cerrar se liquida '
                        'el pendiente. «Pendiente a entregar» es '
                        'el efectivo que falta por entregar de la '
                        'caja. El patrón y el calendario se '
                        'configuran en «Horario y turnos».',
                        style: AppTexto.cuerpo,
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
