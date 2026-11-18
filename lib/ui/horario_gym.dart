// lib/ui/horario_gym.dart
// v1.3.9 Sprint 4 (#10): horario del gym configurable.
// Guarda en Supabase (public.gym_horarios) + caché local.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:convert';
import '../app_log.dart';
import '../auth.dart';
import '../errores_sync.dart';
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
        // 1.36 H-B3 (136-788): el contrato de turnos
        // prohíbe domingo (sin franjas) y tarde de sábado —
        // ventanaFranja aplica esa guarda a las constantes
        // de fábrica pero NO al mapa sembrado, así que aquí
        // se fuerza null: el horario del gym puede abrir
        // domingo, pero no crea franjas de turno.
        manana: (d.abierto && d.diaSemana != 7)
            ? ventana(d.apertura1, d.cierre1)
            : null,
        tarde: (d.abierto && d.diaSemana != 6 && d.diaSemana != 7)
            ? ventana(d.apertura2, d.cierre2)
            : null,
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
  // 1.36 H-B3 (136-789): el refresco de red falló y lo que
  // se ve es la copia guardada — se dice con un chip (antes
  // la caché se pintaba como si fuera el dato fresco).
  bool _refrescoFallo = false;
  // 1.36 H-B3 (136-784): el error de validación/guardado
  // vive inline y señala el día implicado (con scroll
  // hasta su tarjeta y resaltado).
  String? _errorGuardado;
  int? _diaConError;
  final _clavesDia = <int, GlobalKey>{};

  // 1.25 T89: firma del horario tal como se cargó (y
  // tras cada guardado): salir con la firma distinta
  // pide confirmación, como en el editor del patrón.
  String _firmaCargada = '';

  String get _firmaActual =>
      jsonEncode(_dias.map((d) => d.toJson()).toList());

  bool get _hayCambios =>
      _dias.length == 7 && _firmaActual != _firmaCargada;

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
    // Yunque de App 1.31 (C2-3): getInstance iba FUERA de
    // toda red: su fallo dejaba la pantalla en «Cargando…»
    // para siempre sin diagnóstico. Dentro del try, el
    // fallo cae al aviso de error de la rama de red.
    late final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      // SL-X2 (G12-8): nada crudo a pantalla — mensaje
      // amable y la excepción a la bitácora, como SL-11 en
      // las otras dos pantallas de horarios.
      AppLog.error('ui', 'horario_gym_cargar', d: '$e');
      if (mounted) {
        setState(() => _cargando = false);
        mostrarSnack(context,
            'No se pudo cargar el horario: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
      return;
    }
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
            _firmaCargada = _firmaActual;
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
      if (lista.length == 7 && mounted && _hayCambios) {
        // 1.36 H-C2 (136-787): el usuario editó sobre la
        // copia de caché mientras la RPC venía: sus
        // ediciones mandan, el refresco no las pisa (ni
        // la caché, que conserva su copia editada).
        setState(() {
          _cargando = false;
          _refrescoFallo = false;
        });
      } else if (lista.length == 7 && mounted) {
        setState(() {
          _dias = lista;
          _firmaCargada = _firmaActual;
          _cargando = false;
          _refrescoFallo = false;
        });
        // Guardar caché
        await prefs.setString(_kCacheKey,
            jsonEncode(lista.map((d) => d.toJson()).toList()));
      } else if (mounted && _dias.isEmpty) {
        setState(() => _cargando = false);
      }
    } catch (e) {
      // SL-X2 (G12-8): mensaje amable + bitácora.
      AppLog.error('ui', 'horario_gym_cargar', d: '$e');
      if (mounted && _dias.isNotEmpty) {
        // 1.36 H-B3 (136-789): con copia en pantalla, el
        // fallo del refresco se anuncia con el chip «Sin
        // conexión: copia guardada», no en silencio.
        setState(() => _refrescoFallo = true);
      }
      if (mounted && _dias.isEmpty) {
        setState(() => _cargando = false);
        mostrarSnack(context,
            'No se pudo cargar el horario: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
    }
  }

  /// 1.25 T119 (F3-12): validación local de rangos antes de
  /// guardar — antes un rango invertido o solapado viajaba al
  /// servidor y volvía como error crudo. Devuelve el problema
  /// en lenguaje llano o null si todo está bien.
  /// 1.36 H-B3 (136-784): devuelve también el día implicado
  /// para señalarlo inline y llevar el scroll hasta él.
  ({String mensaje, int diaSemana})? _validarRangos() {
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
        return (
          mensaje:
              '${d.nombre}: falta la hora de apertura o de cierre del Turno 1.',
          diaSemana: d.diaSemana
        );
      }
      if (a1 >= c1) {
        return (
          mensaje:
              '${d.nombre}: la apertura del Turno 1 debe ser antes que su cierre.',
          diaSemana: d.diaSemana
        );
      }
      final hay2 = d.apertura2 != null || d.cierre2 != null;
      if (hay2) {
        final a2 = min(d.apertura2), c2 = min(d.cierre2);
        if (a2 == null || c2 == null) {
          return (
            mensaje: '${d.nombre}: el Turno 2 necesita apertura y cierre.',
            diaSemana: d.diaSemana
          );
        }
        if (a2 >= c2) {
          return (
            mensaje:
                '${d.nombre}: la apertura del Turno 2 debe ser antes que su cierre.',
            diaSemana: d.diaSemana
          );
        }
        if (a2 < c1) {
          return (
            mensaje: '${d.nombre}: el Turno 2 se solapa con el Turno 1.',
            diaSemana: d.diaSemana
          );
        }
      }
    }
    return null;
  }

  /// 1.36 H-B3 (136-784): lleva el scroll hasta la tarjeta
  /// del día implicado en el error (tras el repintado que
  /// lo resalta).
  void _irAlDiaConError() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _diaConError == null
          ? null
          : _clavesDia[_diaConError]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx,
            duration: AppMovimiento.media,
            curve: AppMovimiento.curva,
            alignment: 0.1);
      }
    });
  }

  Future<void> _guardar() async {
    if (!AuthService().isOwner) return;
    // F3-12: validar en local antes de molestar al servidor.
    final problema = _validarRangos();
    if (problema != null) {
      // 1.36 H-B3 (136-784): error INLINE sobre la lista y
      // scroll al día implicado (el snack solo, se iba y
      // el día culpable quedaba sin señalar).
      setState(() {
        _errorGuardado = problema.mensaje;
        _diaConError = problema.diaSemana;
      });
      mostrarSnack(context, problema.mensaje,
          significado: SignificadoChip.error);
      _irAlDiaConError();
      return;
    }
    setState(() {
      _errorGuardado = null;
      _diaConError = null;
    });
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
      _firmaCargada = _firmaActual;
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
      // SL-X2 (G12-8): mensaje amable + bitácora.
      AppLog.error('ui', 'horario_gym_guardar', d: '$e');
      if (mounted) {
        // 1.36 H-B3 (136-784): también inline.
        setState(() => _errorGuardado =
            'No se pudo guardar el horario: ${mensajeErrorAmable(e)}');
        mostrarSnack(context,
            'No se pudo guardar el horario: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
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
        // 1.36 H-B3 (136-784): al corregir, el error y el
        // resaltado del día se retiran.
        _errorGuardado = null;
        _diaConError = null;
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
    // 1.25 T89: salir con cambios sin guardar pide
    // confirmación (mismo patrón que el editor del
    // patrón semanal, F3-11).
    return PopScope(
      canPop: !_hayCambios,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final salir = await DialogoApp.confirmar(
          context,
          titulo: 'Cambios sin guardar',
          mensaje:
              'Tienes cambios en el horario del gym que aún no se han guardado.',
          aceptar: 'Salir sin guardar',
          cancelar: 'Seguir editando',
          icono: Icons.warning_amber_rounded,
          peligro: true,
        );
        if (salir && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
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
                // 1.36 H-B3 (136-789): el resumen canónico
                // (textoHorarioCanonico) se calculaba y no
                // se pintaba en ninguna parte — ahora abre
                // la pantalla; y si el refresco falló, el
                // chip «Sin conexión: copia guardada».
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                      AppEspacio.md, AppEspacio.lg, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (textoHorarioCanonico(_dias).isNotEmpty)
                        Text(textoHorarioCanonico(_dias),
                            style: AppTexto.secundario),
                      if (_refrescoFallo) ...[
                        const SizedBox(height: AppEspacio.sm),
                        const ChipEstado.semantico(
                            texto: 'Sin conexión: copia guardada',
                            significado: SignificadoChip.alerta),
                      ],
                      if (_errorGuardado != null) ...[
                        const SizedBox(height: AppEspacio.sm),
                        Tarjeta(
                          color:
                              AppColores.error.withValues(alpha: 0.10),
                          child: Row(
                            children: [
                              Icon(Icons.error_outline_rounded,
                                  color:
                                      AppColores.errorTexto(context)),
                              const SizedBox(width: AppEspacio.sm),
                              Expanded(
                                child: Text(_errorGuardado!,
                                    style: AppTexto.secundario),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
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
      ),
    );
  }

  Widget _buildDiaCard(DiaHorario dia) {
    // F3-30: Tarjeta de la casa (antes Card de Material).
    // 1.36 H-B3 (136-784): la tarjeta lleva su GlobalKey
    // (para llevar el scroll al día del error) y se tiñe
    // si es el día implicado en el error de guardado.
    return Padding(
      key: _clavesDia.putIfAbsent(dia.diaSemana, () => GlobalKey()),
      padding:
          const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        color: _diaConError == dia.diaSemana
            ? AppColores.error.withValues(alpha: 0.08)
            : null,
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
                // 1.36 H-B3 (136-789): el Switch se anuncia
                // («Abierto»/«Cerrado» de ese día) — antes
                // era un interruptor sin etiqueta semántica.
                Semantics(
                  label: '${dia.nombre}: abierto',
                  toggled: dia.abierto,
                  child: Switch(
                    value: dia.abierto,
                    onChanged: (v) {
                      setState(
                          () => dia.abierto = v);
                    },
                  ),
                ),
                Text(
                  dia.abierto
                      ? 'Abierto'
                      : 'Cerrado',
                  // 1.36 H-B3 (136-789): tokens de estado
                  // con contexto (fuera exitoOscuro /
                  // errorOscuro fijos, ilegibles en oscuro).
                  style: AppTexto.metadato.copyWith(color: dia.abierto
                        ? AppColores.exitoTexto(context)
                        : AppColores.errorTexto(context), fontWeight: FontWeight.w600),
                ),
              ],
            ),
            // 1.36 H-B3 (136-788): aviso de lo que NO mueve
            // turnos — domingo sin franjas y sábado sin
            // tarde, aunque el gym abra.
            if (dia.diaSemana == 7)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.xs),
                child: Text(
                  'El domingo no hay turnos: este horario no crea franjas de turno.',
                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                ),
              ),
            if (dia.diaSemana == 6)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.xs),
                child: Text(
                  'La tarde del sábado no crea franja de turno.',
                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                ),
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
                      // SL-X2 (G12-10): SIN borrado por
                      // pulsación larga — era un gesto
                      // destructivo oculto y duplicado; la
                      // única vía de quitar el Turno 2 es el
                      // botón visible «Quitar turno 2».
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
                      // SL-X2 (G12-10): SIN borrado por
                      // pulsación larga (aquí ni snack
                      // había); queda solo el botón visible.
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
    // 1.36 H-B3 (136-789): el chip se anuncia como botón
    // con su hora («Apertura: 06:00») y el InkWell recorta
    // la onda con el mismo radio del borde (antes la onda
    // salía cuadrada sobre la caja redondeada).
    return Semantics(
      button: true,
      label: '$label: ${valor ?? 'sin hora'}',
      child: InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(AppRadio.sm),
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
      ),
    );
  }
}
