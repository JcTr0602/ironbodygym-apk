// lib/ui/turnos_manuales.dart
// v1.4.0 Paso 2 (Control de Acceso, propuesta 55): asignación manual
// de entrenador de turno por adelantado (mañana/tarde), con guardado
// en lote (RPC guardar_turnos_manuales_lote). Solo dueño.
// La app de clientes lee estos turnos vía obtener_turnos_manuales y
// muestra solo el nombre visible (nunca el email — Argón).
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth.dart';
import 'diseno.dart';

class TurnosManualesScreen extends StatefulWidget {
  const TurnosManualesScreen({super.key});

  @override
  State<TurnosManualesScreen> createState() => _TurnosManualesScreenState();
}

class _TurnosManualesScreenState extends State<TurnosManualesScreen> {
  static const _diasSemana = ['Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  static const _meses = [
    'ene', 'feb', 'mar', 'abr', 'may', 'jun',
    'jul', 'ago', 'sep', 'oct', 'nov', 'dic'
  ];

  late DateTime _lunes;
  bool _cargando = true;
  bool _guardando = false;

  /// clave 'yyyy-MM-dd|manana' → 'duany' | 'gabriel'
  final Map<String, String> _turnos = {};
  Map<String, String> _original = {};

  @override
  void initState() {
    super.initState();
    _lunes = _lunesDe(DateTime.now());
    _cargar();
  }

  DateTime _lunesDe(DateTime d) {
    final solo = DateTime(d.year, d.month, d.day);
    return solo.subtract(Duration(days: solo.weekday - 1));
  }

  String _isoFecha(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _etiquetaFecha(DateTime d) =>
      '${_diasSemana[d.weekday - 1]} ${d.day} ${_meses[d.month - 1]}';

  bool get _hayCambios {
    if (_turnos.length != _original.length) return true;
    for (final e in _turnos.entries) {
      if (_original[e.key] != e.value) return true;
    }
    return false;
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final desde = _isoFecha(_lunes);
      final hasta = _isoFecha(_lunes.add(const Duration(days: 6)));
      final res = await Supabase.instance.client.rpc(
        'obtener_turnos_manuales',
        params: {'p_desde': desde, 'p_hasta': hasta},
      );
      final mapa = <String, String>{};
      for (final e in (res as List? ?? [])) {
        final m = Map<String, dynamic>.from(e as Map);
        final fecha = '${m['fecha'] ?? ''}'.substring(0, 10);
        final turno = '${m['turno'] ?? ''}';
        final ent = '${m['entrenador_id'] ?? ''}';
        if (fecha.isNotEmpty && turno.isNotEmpty && ent.isNotEmpty) {
          mapa['$fecha|$turno'] = ent;
        }
      }
      if (mounted) {
        setState(() {
          _turnos
            ..clear()
            ..addAll(mapa);
          _original = Map.from(mapa);
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cargando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al cargar turnos: $e')),
        );
      }
    }
  }

  Future<void> _guardar() async {
    // Solo se envían los turnos que cambiaron (vacío = borrar el turno).
    final lote = <Map<String, String>>[];
    final claves = {..._turnos.keys, ..._original.keys};
    for (final k in claves) {
      if (_turnos[k] != _original[k]) {
        final partes = k.split('|');
        lote.add({
          'fecha': partes[0],
          'turno': partes[1],
          'entrenador_id': _turnos[k] ?? '',
        });
      }
    }
    if (lote.isEmpty) return;
    setState(() => _guardando = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'guardar_turnos_manuales_lote',
        params: {'p_turnos': lote},
      );
      final data = Map<String, dynamic>.from(res as Map);
      if (mounted) {
        setState(() {
          _original = Map.from(_turnos);
          _guardando = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Turnos guardados: ${data['guardados'] ?? 0}, borrados: ${data['borrados'] ?? 0}.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar: $e')),
        );
      }
    }
  }

  /// Auditoría OpenCode 2026-10-20: no descartar cambios sin
  /// guardar en silencio al navegar entre semanas.
  Future<bool> _confirmarSiHayCambios() async {
    if (!_hayCambios) return true;
    final seguir = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cambios sin guardar'),
        content: const Text(
            'Tienes turnos editados sin guardar en esta semana. '
            'Si cambias de semana, se pierden.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Quedarme'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Descartar y cambiar'),
          ),
        ],
      ),
    );
    return seguir == true && mounted;
  }

  Future<void> _moverSemana(int delta) async {
    if (!await _confirmarSiHayCambios()) return;
    setState(() {
      _lunes = _lunes.add(Duration(days: 7 * delta));
    });
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Turnos manuales')),
        body: const Center(
          child: Text('Solo el dueño puede asignar turnos.'),
        ),
      );
    }
    final hoyIso = _isoFecha(DateTime.now());
    final finSemana = _lunes.add(const Duration(days: 6));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Turnos manuales'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargando ? null : _cargar,
            tooltip: 'Recargar',
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left),
                  onPressed: _cargando ? null : () => _moverSemana(-1),
                ),
                Expanded(
                  child: Text(
                    '${_etiquetaFecha(_lunes)} — ${_etiquetaFecha(finSemana)}',
                    textAlign: TextAlign.center,
                    style: AppTexto.subtitulo,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right),
                  onPressed: _cargando ? null : () => _moverSemana(1),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _cargando
                ? null
                : () async {
                    if (!await _confirmarSiHayCambios()) return;
                    setState(() => _lunes = _lunesDe(DateTime.now()));
                    _cargar();
                  },
            child: const Text('Ir a esta semana'),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: AppEspacio.lg),
            child: Text(
              'Si un turno queda vacío, la app de clientes usa el turno '
              'registrado del día como hasta ahora.',
              style: AppTexto.secundario,
            ),
          ),
          const SizedBox(height: AppEspacio.sm),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppEspacio.lg),
                    itemCount: 7,
                    itemBuilder: (ctx, i) {
                      final dia = _lunes.add(Duration(days: i));
                      final esHoy = _isoFecha(dia) == hoyIso;
                      return Card(
                        color: esHoy
                            ? AppColores.naranja.withOpacity(0.08)
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(AppEspacio.md),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _etiquetaFecha(dia) +
                                    (esHoy ? '  · HOY' : ''),
                                style: AppTexto.cuerpo.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: esHoy
                                      ? AppColores.naranjaOscuro
                                      : null,
                                ),
                              ),
                              const SizedBox(height: AppEspacio.sm),
                              _filaTurno(dia, 'manana', '🌅 Mañana'),
                              const SizedBox(height: AppEspacio.xs),
                              _filaTurno(dia, 'tarde', '🌇 Tarde'),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_hayCambios)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(AppEspacio.lg),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: _guardando
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.save, size: 18),
                    label: Text(_guardando ? 'Guardando…' : 'Guardar turnos'),
                    onPressed: _guardando ? null : _guardar,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _filaTurno(DateTime dia, String turno, String etiqueta) {
    final clave = '${_isoFecha(dia)}|$turno';
    final actual = _turnos[clave];
    return Row(
      children: [
        SizedBox(width: 92, child: Text(etiqueta, style: AppTexto.cuerpo)),
        Expanded(
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '', label: Text('—')),
              ButtonSegment(value: 'duany', label: Text('Duany')),
              ButtonSegment(value: 'gabriel', label: Text('Gabriel')),
            ],
            selected: {actual ?? ''},
            onSelectionChanged: (s) {
              setState(() {
                final v = s.first;
                if (v.isEmpty) {
                  _turnos.remove(clave);
                } else {
                  _turnos[clave] = v;
                }
              });
            },
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        ),
      ],
    );
  }
}
