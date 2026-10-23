// lib/ui/horario_gym.dart
// v1.3.9 Sprint 4 (#10): horario del gym configurable.
// Guarda en Supabase (public.gym_horarios) + caché local.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import '../auth.dart';

class DiaHorario {
  final int diaSemana; // 1=Lun ... 7=Dom
  final String nombre;
  bool abierto;
  String? apertura1;
  String? cierre1;
  String? apertura2;
  String? cierre2;

  DiaHorario({
    required this.diaSemana,
    required this.nombre,
    this.abierto = true,
    this.apertura1,
    this.cierre1,
    this.apertura2,
    this.cierre2,
  });

  factory DiaHorario.fromJson(
      Map<String, dynamic> j, String nombre) {
    String? fmt(dynamic v) {
      if (v == null) return null;
      final s = '$v';
      // TIME viene como "06:00:00", tomar HH:MM
      return s.length >= 5 ? s.substring(0, 5) : s;
    }

    return DiaHorario(
      diaSemana: (j['dia_semana'] as num?)?.toInt() ?? 1,
      nombre: nombre,
      abierto: j['abierto'] == true,
      apertura1: fmt(j['apertura_1']),
      cierre1: fmt(j['cierre_1']),
      apertura2: fmt(j['apertura_2']),
      cierre2: fmt(j['cierre_2']),
    );
  }

  Map<String, dynamic> toJson() => {
        'dia_semana': diaSemana,
        'abierto': abierto,
        'apertura_1': abierto ? apertura1 : null,
        'cierre_1': abierto ? cierre1 : null,
        'apertura_2': abierto ? apertura2 : null,
        'cierre_2': abierto ? cierre2 : null,
      };
}

const _nombresDiasHorario = [
  '',
  'Lunes',
  'Martes',
  'Miércoles',
  'Jueves',
  'Viernes',
  'Sábado',
  'Domingo'
];

/// v1.6.0: texto compacto del horario CANÓNICO del gym (fuente
/// única: esta pantalla lo edita; el resto solo lo lee). Agrupa
/// días seguidos con la misma franja. Función pura, testeable.
/// Ej.: «Lun–Vie 06:00–12:00 y 14:00–20:00 · Sáb 07:00–12:00 ·
/// Dom cerrado». Devuelve '' si no hay 7 días.
String textoHorarioCanonico(List<DiaHorario> dias) {
  if (dias.length != 7) return '';
  const cortos = ['', 'Lun', 'Mar', 'Mié', 'Jue', 'Vie', 'Sáb', 'Dom'];
  String franjas(DiaHorario d) {
    if (!d.abierto) return 'cerrado';
    final partes = <String>[];
    if (d.apertura1 != null && d.cierre1 != null) {
      partes.add('${d.apertura1}–${d.cierre1}');
    }
    if (d.apertura2 != null && d.cierre2 != null) {
      partes.add('${d.apertura2}–${d.cierre2}');
    }
    return partes.isEmpty ? 'cerrado' : partes.join(' y ');
  }

  final ordenados = [...dias]
    ..sort((a, b) => a.diaSemana.compareTo(b.diaSemana));
  final grupos = <String>[];
  var i = 0;
  while (i < ordenados.length) {
    final f = franjas(ordenados[i]);
    var j = i;
    while (j + 1 < ordenados.length && franjas(ordenados[j + 1]) == f) {
      j++;
    }
    final desde = cortos[ordenados[i].diaSemana.clamp(1, 7)];
    final hasta = cortos[ordenados[j].diaSemana.clamp(1, 7)];
    grupos.add(i == j ? '$desde $f' : '$desde–$hasta $f');
    i = j + 1;
  }
  return grupos.join(' · ');
}

/// v1.6.0: carga el horario canónico del gym con los datos que la
/// app ya tiene: caché local «cache_horarios_gym» primero y
/// refresco por la RPC «obtener_horarios» después (el mismo camino
/// que usa la pantalla Horario del Gym). Devuelve [] si no se
/// pudo cargar de ninguna fuente.
Future<List<DiaHorario>> cargarHorarioCanonico() async {
  var dias = <DiaHorario>[];
  try {
    final prefs = await SharedPreferences.getInstance();
    final cacheRaw = prefs.getString('cache_horarios_gym');
    if (cacheRaw != null && cacheRaw.isNotEmpty) {
      final lista = (jsonDecode(cacheRaw) as List).map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        final ds = (m['dia_semana'] as num?)?.toInt() ?? 1;
        return DiaHorario.fromJson(
            m, _nombresDiasHorario[ds.clamp(1, 7)]);
      }).toList();
      if (lista.length == 7) dias = lista;
    }
  } catch (_) {}
  try {
    final res = await Supabase.instance.client.rpc('obtener_horarios');
    final lista = ((res as List?) ?? []).map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      final ds = (m['dia_semana'] as num?)?.toInt() ?? 1;
      return DiaHorario.fromJson(m, _nombresDiasHorario[ds.clamp(1, 7)]);
    }).toList();
    if (lista.length == 7) {
      dias = lista;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cache_horarios_gym',
          jsonEncode(lista.map((d) => d.toJson()).toList()));
    }
  } catch (_) {}
  return dias;
}

class HorarioGym extends StatefulWidget {
  const HorarioGym({super.key});

  @override
  State<HorarioGym> createState() =>
      _HorarioGymState();
}

class _HorarioGymState extends State<HorarioGym> {
  bool _cargando = true;
  bool _guardando = false;
  List<DiaHorario> _dias = [];

  static const _nombres = [
    '',
    'Lunes',
    'Martes',
    'Miércoles',
    'Jueves',
    'Viernes',
    'Sábado',
    'Domingo'
  ];
  static const _kCacheKey = 'cache_horarios_gym';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    // 1. Intentar caché local primero
    final prefs =
        await SharedPreferences.getInstance();
    final cacheRaw = prefs.getString(_kCacheKey);
    if (cacheRaw != null && cacheRaw.isNotEmpty) {
      try {
        final lista = (jsonDecode(cacheRaw) as List)
            .map((e) => DiaHorario.fromJson(
                Map<String, dynamic>.from(e as Map),
                _nombres[(e as Map)['dia_semana']
                        as int? ??
                    1]))
            .toList();
        if (mounted && lista.length == 7) {
          setState(() {
            _dias = lista;
            _cargando = false;
          });
        }
      } catch (_) {}
    }
    // 2. Refrescar desde Supabase
    try {
      final res = await Supabase.instance.client
          .rpc('obtener_horarios');
      final lista = ((res as List?) ?? [])
          .map((e) {
            final m =
                Map<String, dynamic>.from(e as Map);
            final ds =
                (m['dia_semana'] as num?)?.toInt() ??
                    1;
            return DiaHorario.fromJson(m,
                _nombres[ds.clamp(1, 7)]);
          })
          .toList();
      if (lista.length == 7 && mounted) {
        setState(() {
          _dias = lista;
          _cargando = false;
        });
        // Guardar caché
        await prefs.setString(_kCacheKey,
            jsonEncode(lista.map((d) => d.toJson()).toList()));
      } else if (mounted && _dias.isEmpty) {
        setState(() => _cargando = false);
      }
    } catch (e) {
      if (mounted && _dias.isEmpty) {
        setState(() => _cargando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _guardar() async {
    if (!AuthService().isOwner) return;
    setState(() => _guardando = true);
    try {
      final payload =
          _dias.map((d) => d.toJson()).toList();
      await Supabase.instance.client
          .rpc('guardar_horarios', params: {
        'p_horarios': payload,
      });
      // Actualizar caché
      final prefs =
          await SharedPreferences.getInstance();
      await prefs.setString(
          _kCacheKey, jsonEncode(payload));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Horario guardado')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _guardando = false);
      }
    }
  }

  Future<void> _editarHora(
      DiaHorario dia, String campo) async {
    final actual = campo == 'apertura1'
        ? dia.apertura1
        : campo == 'cierre1'
            ? dia.cierre1
            : campo == 'apertura2'
                ? dia.apertura2
                : dia.cierre2;
    TimeOfDay? inicial;
    if (actual != null && actual.contains(':')) {
      final partes = actual.split(':');
      inicial = TimeOfDay(
        hour: int.tryParse(partes[0]) ?? 6,
        minute: int.tryParse(partes[1]) ?? 0,
      );
    }
    final picked = await showTimePicker(
      context: context,
      initialTime: inicial ?? const TimeOfDay(hour: 6, minute: 0),
    );
    if (picked != null && mounted) {
      final hh = picked.hour.toString().padLeft(2, '0');
      final mm =
          picked.minute.toString().padLeft(2, '0');
      setState(() {
        final valor = '$hh:$mm';
        switch (campo) {
          case 'apertura1':
            dia.apertura1 = valor;
            break;
          case 'cierre1':
            dia.cierre1 = valor;
            break;
          case 'apertura2':
            dia.apertura2 = valor;
            break;
          case 'cierre2':
            dia.cierre2 = valor;
            break;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar:
            AppBar(title: const Text('Horario')),
        body: const Center(
          child: Text(
              'Solo el dueño puede configurar el horario.'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Horario del Gym'),
        actions: [
          if (!_cargando)
            TextButton(
              onPressed:
                  _guardando ? null : _guardar,
              child: _guardando
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child:
                          CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white),
                    )
                  : const Text('GUARDAR',
                      style: TextStyle(
                          color: Colors.white)),
            ),
        ],
      ),
      body: _cargando
          ? const Center(
              child: CircularProgressIndicator())
          : Column(
              children: [
                // v1.6.0 (Jc): la entrada «Entrenadores por turno»
                // que vivía aquí se retiró — los turnos tienen UNA
                // sola puerta (el hub «Turnos» en Administración →
                // Clientes y equipo, y en Usuarios), con el plan
                // semanal, los ajustes por fecha y la precedencia.
                // Esta pantalla queda solo para el horario del gym.
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _dias.length,
                    itemBuilder: (ctx, i) =>
                        _buildDiaCard(_dias[i]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildDiaCard(DiaHorario dia) {
    return Card(
      margin:
          const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    dia.nombre,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Switch(
                  value: dia.abierto,
                  onChanged: (v) {
                    setState(
                        () => dia.abierto = v);
                  },
                ),
                Text(
                  dia.abierto
                      ? 'Abierto'
                      : 'Cerrado',
                  style: TextStyle(
                    fontSize: 12,
                    color: dia.abierto
                        ? Colors.green[700]
                        : Colors.red[700],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            if (dia.abierto) ...[
              const Divider(),
              const Text('Turno 1',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey)),
              Row(
                children: [
                  Expanded(
                    child: _horaChip(
                        'Apertura',
                        dia.apertura1,
                        () => _editarHora(
                            dia, 'apertura1')),
                  ),
                  const Padding(
                    padding:
                        EdgeInsets.symmetric(
                            horizontal: 8),
                    child: Text('—'),
                  ),
                  Expanded(
                    child: _horaChip(
                        'Cierre',
                        dia.cierre1,
                        () => _editarHora(
                            dia, 'cierre1')),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text('Turno 2 (opcional)',
                  style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey)),
              Row(
                children: [
                  Expanded(
                    child: _horaChip(
                      'Apertura',
                      dia.apertura2,
                      () => _editarHora(
                          dia, 'apertura2'),
                      onLongPress: () {
                        setState(() {
                          dia.apertura2 = null;
                          dia.cierre2 = null;
                        });
                        ScaffoldMessenger.of(
                                context)
                            .showSnackBar(
                          const SnackBar(
                            content: Text(
                                'Turno 2 eliminado (mantén para borrar)'),
                            duration:
                                Duration(seconds: 1),
                          ),
                        );
                      },
                    ),
                  ),
                  const Padding(
                    padding:
                        EdgeInsets.symmetric(
                            horizontal: 8),
                    child: Text('—'),
                  ),
                  Expanded(
                    child: _horaChip(
                      'Cierre',
                      dia.cierre2,
                      () => _editarHora(
                          dia, 'cierre2'),
                      onLongPress: () {
                        setState(() {
                          dia.apertura2 = null;
                          dia.cierre2 = null;
                        });
                      },
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _horaChip(
      String label, String? valor, VoidCallback onTap,
      {VoidCallback? onLongPress}) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(
            vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(
              color: Colors.grey[300]!),
          borderRadius:
              BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 10,
                    color: Colors.grey)),
            Text(
              valor ?? '--:--',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
