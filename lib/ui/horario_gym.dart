// lib/ui/horario_gym.dart
// v1.3.9 Sprint 4 (#10): horario del gym configurable.
// Guarda en Supabase (public.gym_horarios) + caché local.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import '../auth.dart';
import '../turnos_resolucion.dart';
import 'app_bar.dart';
import 'diseno.dart';
import 'componentes.dart';

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
    // Autoauditoría 1.22 #2: lectura con timeout (12 s): los
    // llamadores esperan este futuro (la vista previa lo compone
    // con .then sobre la pintura, pero un cuelgue lo dejaba sin
    // llegar nunca en vez de quedarse con la caché local).
    final res = await Supabase.instance.client
        .rpc('obtener_horarios')
        .timeout(const Duration(seconds: 12));
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
  // 1.25 T30: el horario cargado manda también en las franjas
  // de turno de este teléfono.
  if (dias.length == 7) aplicarHorarioAFranjas(dias);
  return dias;
}

int? _minutosDeHhMm(String? hhmm) {
  if (hhmm == null || hhmm.length < 5) return null;
  final h = int.tryParse(hhmm.substring(0, 2));
  final m = int.tryParse(hhmm.substring(3, 5));
  if (h == null || m == null) return null;
  return h * 60 + m;
}

/// 1.25 T30: vuelca el horario canónico en las ventanas de
/// franja de turnos (turnos_resolucion): bloque 1 = mañana,
/// bloque 2 = tarde; día cerrado o bloque incompleto/invertido
/// = esa franja no existe ese día. Sin esto, editar el horario
/// no movía ningún turno (las franjas eran constantes).
void aplicarHorarioAFranjas(List<DiaHorario> dias) {
  if (dias.length != 7) return;
  ({int inicio, int fin})? ventana(String? ap, String? ci) {
    final i = _minutosDeHhMm(ap);
    final f = _minutosDeHhMm(ci);
    if (i == null || f == null || f <= i) return null;
    return (inicio: i, fin: f);
  }

  fijarVentanasDesdeHorarioGym({
    for (final d in dias)
      d.diaSemana: (
        manana: d.abierto ? ventana(d.apertura1, d.cierre1) : null,
        tarde: d.abierto ? ventana(d.apertura2, d.cierre2) : null,
      ),
  });
}

/// Siembra las franjas SOLO desde la caché local del horario
/// (sin red): la llama Home al arrancar para que la resolución
/// de turnos nazca ya con el horario guardado en este teléfono.
/// El refresco con red llega por cargarHorarioCanonico().
Future<void> sembrarFranjasDesdeCacheHorario() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final cacheRaw = prefs.getString('cache_horarios_gym');
    if (cacheRaw == null || cacheRaw.isEmpty) return;
    final lista = (jsonDecode(cacheRaw) as List).map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      final ds = (m['dia_semana'] as num?)?.toInt() ?? 1;
      return DiaHorario.fromJson(
          m, _nombresDiasHorario[ds.clamp(1, 7)]);
    }).toList();
    if (lista.length == 7) aplicarHorarioAFranjas(lista);
  } catch (_) {}
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
      // Autoauditoría 1.22 #2: con timeout (12 s): sin caché
      // local, el spinner esperaba esta RPC y un cuelgue no es
      // un error (el catch no corría nunca).
      final res = await Supabase.instance.client
          .rpc('obtener_horarios')
          .timeout(const Duration(seconds: 12));
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
        mostrarSnack(context, 'Error: $e', significado: SignificadoChip.error);
      }
    }
  }

  /// 1.25 T119 (F3-12): validación local de rangos antes de
  /// guardar — antes un rango invertido o solapado viajaba al
  /// servidor y volvía como error crudo. Devuelve el problema
  /// en lenguaje llano o null si todo está bien.
  String? _validarRangos() {
    int? min(String? hhmm) {
      if (hhmm == null || hhmm.length < 5) return null;
      final h = int.tryParse(hhmm.substring(0, 2));
      final m = int.tryParse(hhmm.substring(3, 5));
      if (h == null || m == null) return null;
      return h * 60 + m;
    }

    for (final d in _dias) {
      if (!d.abierto) continue;
      final a1 = min(d.apertura1), c1 = min(d.cierre1);
      if (a1 == null || c1 == null) {
        return '${d.nombre}: falta la hora de apertura o de cierre del Turno 1.';
      }
      if (a1 >= c1) {
        return '${d.nombre}: la apertura del Turno 1 debe ser antes que su cierre.';
      }
      final hay2 = d.apertura2 != null || d.cierre2 != null;
      if (hay2) {
        final a2 = min(d.apertura2), c2 = min(d.cierre2);
        if (a2 == null || c2 == null) {
          return '${d.nombre}: el Turno 2 necesita apertura y cierre.';
        }
        if (a2 >= c2) {
          return '${d.nombre}: la apertura del Turno 2 debe ser antes que su cierre.';
        }
        if (a2 < c1) {
          return '${d.nombre}: el Turno 2 se solapa con el Turno 1.';
        }
      }
    }
    return null;
  }

  Future<void> _guardar() async {
    if (!AuthService().isOwner) return;
    // F3-12: validar en local antes de molestar al servidor.
    final problema = _validarRangos();
    if (problema != null) {
      mostrarSnack(context, problema, significado: SignificadoChip.error);
      return;
    }
    setState(() => _guardando = true);
    try {
      final payload =
          _dias.map((d) => d.toJson()).toList();
      await Supabase.instance.client
          .rpc('guardar_horarios', params: {
            'p_horarios': payload,
          })
          // 1.24 Bloque 4: timeout de escritura (12 s).
          .timeout(const Duration(seconds: 12));
      // Actualizar caché
      final prefs =
          await SharedPreferences.getInstance();
      await prefs.setString(
          _kCacheKey, jsonEncode(payload));
      // 1.25 T30: el horario recién guardado mueve las
      // franjas de turno al instante en este teléfono.
      aplicarHorarioAFranjas(_dias);
      if (mounted) {
        mostrarSnack(context, 'Horario guardado', significado: SignificadoChip.exito);
        // F3-12: mismo comportamiento que el editor hermano
        // (Entrenadores por turno): guardar y salir.
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, 'Error: $e', significado: SignificadoChip.error);
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
            appBarIron(context, 'Horario'),
        body: const Center(
          child: Text(
              'Solo el dueño puede configurar el horario.'),
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(
        context,
        'Horario del Gym',
        acciones: [
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
                  : const Text('Guardar',
                      style: TextStyle(
                          color: Colors.white)),
            ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando horario…')
          // F3-12: sin caché y sin conexión el cuerpo quedaba
          // en blanco (lista de 0 días) sin decir nada.
          : _dias.isEmpty
              ? EstadoVacio(
                  icono: Icons.schedule_rounded,
                  titulo: 'No se pudo cargar el horario',
                  subtitulo:
                      'Sin conexión y sin una copia guardada en este teléfono.',
                  textoAccion: 'Reintentar',
                  onAccion: _cargar,
                )
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
                    padding: const EdgeInsets.all(AppEspacio.lg),
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
    // F3-30: Tarjeta de la casa (antes Card de Material).
    return Padding(
      padding:
          const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    dia.nombre,
                    style: AppTexto.titulo,
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
                  style: AppTexto.metadato.copyWith(color: dia.abierto
                        ? AppColores.exitoOscuro
                        : AppColores.errorOscuro, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            if (dia.abierto) ...[
              const Divider(),
              Text('Turno 1',
                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
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
                            horizontal: AppEspacio.sm),
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
              Text('Turno 2 (opcional)',
                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
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
                        mostrarSnack(context,
                            'Turno 2 eliminado (mantén para borrar)',
                            duracion:
                                const Duration(seconds: 1));
                      },
                    ),
                  ),
                  const Padding(
                    padding:
                        EdgeInsets.symmetric(
                            horizontal: AppEspacio.sm),
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
              // F3-12: borrar el Turno 2 con un botón visible
              // (antes solo existía por presión larga, sin
              // ninguna pista en pantalla).
              if (dia.apertura2 != null || dia.cierre2 != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.delete_outline_rounded,
                        size: 18),
                    label: const Text('Quitar turno 2'),
                    onPressed: () {
                      setState(() {
                        dia.apertura2 = null;
                        dia.cierre2 = null;
                      });
                      mostrarSnack(context, 'Turno 2 eliminado',
                          duracion: const Duration(seconds: 1));
                    },
                  ),
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
            vertical: 10, horizontal: AppEspacio.md),
        decoration: BoxDecoration(
          border: Border.all(
              color: AppColores.borde(context)),
          borderRadius:
              BorderRadius.circular(AppRadio.sm),
        ),
        child: Column(
          children: [
            Text(label,
                style: AppTexto.minuscula.copyWith(color: AppColores.textoSecundario(context))),
            Text(
              valor ?? '--:--',
              style: AppTexto.titulo.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
