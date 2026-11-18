// lib/ui/horario_turnos.dart
// v1.4.1 (Pieza 5): horario semanal de entrenadores por turno.
// Qué entrenador cubre cada franja (mañana/tarde) cada día. La app de
// clientes lo muestra como respaldo SOLO dentro de la ventana actual
// cuando no hay un turno abierto en vivo (la apertura real manda).
//
// Se guarda como ajuste 'horario_turnos' (op de sync, offline-first,
// mismo patrón que los precios): el servidor lo valida con
// validar_horario_turnos, viaja en sync_estado.ajustes y lo lee
// autenticar en la app de clientes. El nombre sale de un selector
// controlado (usuarios APK conocidos + asignaciones vigentes), nunca
// de texto libre. Domingo cerrado (sin filas) y sábado sin tarde,
// como prohíbe el validador del servidor.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../app_log.dart';
import '../auth.dart';
import '../errores_sync.dart';
import '../localdb.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

class HorarioTurnosScreen extends StatefulWidget {
  const HorarioTurnosScreen({super.key});

  @override
  State<HorarioTurnosScreen> createState() => _HorarioTurnosScreenState();
}

class _HorarioTurnosScreenState extends State<HorarioTurnosScreen> {
  static const _nombres = [
    '',
    'Lunes',
    'Martes',
    'Miércoles',
    'Jueves',
    'Viernes',
    'Sábado',
    'Domingo',
  ];

  bool _cargando = true;
  bool _guardando = false;
  List<String> _entrenadores = [];
  // 1.25 T119 (F3-11): la carga de usuarios podía fallar en
  // silencio y los selectores quedaban solo con «Sin asignar»
  // como si no hubiera entrenadores; ahora se avisa. Y la
  // foto inicial de las selecciones permite avisar al salir
  // con cambios sin guardar.
  bool _usuariosNoCargaron = false;
  // 1.36 H-B3 (136-780): la lectura del PATRÓN guardado
  // falló — guardar encima pisaría el patrón real con el
  // de por defecto, así que el guardado se bloquea.
  bool _errorLecturaPatron = false;
  // 1.36 H-B3 (136-780): la lista de usuarios SÍ cargó
  // pero no dejó ningún asignable (todos dueño/admin o
  // bloqueados): es un estado distinto del fallo de
  // lectura y se dice distinto.
  bool _sinAsignables = false;
  // 1.36 H-B3 (136-784): el error de guardado también
  // vive inline sobre los días, no solo en el snack.
  String? _errorGuardado;
  Map<int, Map<String, String?>> _inicial = {};

  bool get _hayCambios {
    // 1.36 H-C2 (136-781): durante la carga _inicial aún
    // está vacío y _sel ya se está poblando: no hay
    // cambios DEL USUARIO que proteger todavía.
    if (_cargando) return false;
    for (final d in _sel.keys) {
      for (final f in _sel[d]!.keys) {
        if (_sel[d]![f] != _inicial[d]?[f]) return true;
      }
    }
    return false;
  }

  /// día ISO (1-6) -> franja -> entrenador asignado (null = sin asignar).
  /// El día 6 (sábado) NO tiene clave 'tarde': ni se carga ni se
  /// serializa, como exige el contrato (corrección del panel S4).
  final Map<int, Map<String, String?>> _sel = {
    for (var d = 1; d <= 5; d++) d: {'manana': null, 'tarde': null},
    6: {'manana': null},
  };

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  /// Forma visible canónica de un nombre: recortado y con la
  /// primera letra en mayúscula ("duany" -> "Duany").
  static String _visible(String bruto) {
    final n = bruto.trim();
    if (n.length <= 1) return n.toUpperCase();
    return '${n[0].toUpperCase()}${n.substring(1)}';
  }

  Future<void> _cargar() async {
    // Asignaciones vigentes en crudo (del espejo de ajustes).
    final crudas = <(int, String, String)>[];
    var patronFallo = false;
    try {
      final aj = await LocalDb.instance.getAjustes();
      final h = aj['horario_turnos'];
      if (h is Map) {
        h.forEach((dia, franjas) {
          final d = int.tryParse('$dia');
          if (d == null || franjas is! Map) return;
          franjas.forEach((franja, nombre) {
            final n = '$nombre'.trim();
            // El sábado no tiene tarde: ni siquiera se carga.
            if (n.isEmpty || (d == 6 && franja == 'tarde')) return;
            crudas.add((d, '$franja', n));
          });
        });
      }
    } catch (e) {
      // 1.36 H-B3 (136-780): antes el catch era mudo y el
      // guardado quedaba habilitado sobre el patrón por
      // defecto — guardar pisaba el patrón real.
      patronFallo = true;
      AppLog.error('horario_turnos', 'leer_patron_fallo', d: '$e');
    }

    // UNA normalización de identidad para usuarios y asignaciones
    // (panel S4): clave en minúsculas -> forma visible. Primero los
    // usuarios APK conocidos; las asignaciones se remapean al mismo
    // canon, así "duany" asignado y "Duany" de usuario son la MISMA
    // opción y el valor del desplegable siempre está en sus items.
    final canon = <String, String>{};
    String registrar(String bruto) =>
        canon.putIfAbsent(bruto.trim().toLowerCase(),
            () => _visible(bruto));
    var usuariosOk = false;
    var asignables = 0;
    try {
      final raw = await LocalDb.instance.getMeta('usuarios_apk');
      if (raw != null && raw.isNotEmpty) {
        usuariosOk = true;
        for (final u in jsonDecode(raw) as List) {
          final m = Map<String, dynamic>.from(u as Map);
          // F3-11: el mismo filtro de asignables que las
          // suplencias (turno_abrir): fuera dueño/admin y
          // usuarios bloqueados — el patrón no debe poder
          // asignar un turno al dueño ni a un bloqueado.
          final rol = '${m['rol'] ?? ''}'.trim().toLowerCase();
          if (rol == 'owner' ||
              rol == 'dueno' ||
              rol == 'dueño' ||
              rol == 'admin') {
            continue;
          }
          if (m['bloqueado'] == true) continue;
          final nom = (m['nombre'] as String?)?.trim();
          final base = (nom != null && nom.isNotEmpty)
              ? nom
              : (m['username'] as String? ?? '');
          if (base.trim().isNotEmpty) {
            registrar(base);
            asignables++;
          }
        }
      }
    } catch (_) {}
    for (final (d, franja, nombre) in crudas) {
      // 1.36 H-B3 (136-780): validar día 1..6 y franja
      // permitida ANTES de registrar — una asignación con
      // día 7 o franja «noche» colaba su nombre en el canon
      // y aparecía como entrenador asignable.
      if (!_sel.containsKey(d) || !_sel[d]!.containsKey(franja)) {
        continue;
      }
      _sel[d]![franja] = registrar(nombre);
    }

    if (mounted) {
      setState(() {
        // 1.36 H-B3 (136-783): orden alfabético — el orden
        // ya no depende del orden guardado en ajustes.
        _entrenadores = canon.values.toList()
          ..sort((a, b) =>
              a.toLowerCase().compareTo(b.toLowerCase()));
        _usuariosNoCargaron = !usuariosOk;
        _errorLecturaPatron = patronFallo;
        _sinAsignables = usuariosOk && asignables == 0;
        _inicial = {
          for (final e in _sel.entries)
            e.key: Map<String, String?>.from(e.value),
        };
        _cargando = false;
      });
    }
  }

  Future<void> _guardar() async {
    // 1.36 H-B3 (136-780): con la lectura del patrón
    // fallida, guardar pisaría el patrón real con el de
    // por defecto — bloqueado hasta recargar bien.
    if (_errorLecturaPatron) {
      setState(() => _errorGuardado =
          'No se puede guardar: la lectura del patrón guardado falló. '
          'Sal y vuelve a entrar para recargarlo.');
      return;
    }
    final mapa = <String, dynamic>{};
    _sel.forEach((dia, franjas) {
      final limpio = <String, String>{};
      franjas.forEach((franja, nombre) {
        if (nombre != null && nombre.isNotEmpty) {
          limpio[franja] = nombre;
        }
      });
      if (limpio.isNotEmpty) mapa['$dia'] = limpio;
    });
    setState(() => _guardando = true);
    try {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': 'horario_turnos', 'valor': mapa},
      );
      // Actualización optimista del espejo local (patrón de precios).
      final aj = await LocalDb.instance.getAjustes();
      aj['horario_turnos'] = mapa;
      await LocalDb.instance.setAjustes(aj);
      // Lo guardado pasa a ser la foto inicial: el pop no
      // debe disparar el aviso de cambios sin guardar.
      _inicial = {
        for (final e in _sel.entries)
          e.key: Map<String, String?>.from(e.value),
      };
      if (mounted) {
        setState(() => _errorGuardado = null);
        mostrarSnack(context, 'Horario de turnos guardado (se sincronizará)', significado: SignificadoChip.exito);
        Navigator.of(context).pop();
      }
    } catch (e) {
      // SL-11 (G12-8): nada crudo a pantalla — mensaje amable
      // de la casa y la excepción a la bitácora.
      AppLog.error('horario_turnos', 'guardar_patron_fallo', d: '$e');
      if (mounted) {
        // 1.36 H-B3 (136-784): el error queda TAMBIÉN
        // inline sobre los días (el snack se va y el
        // motivo se perdía).
        setState(() => _errorGuardado =
            'No se pudo guardar el horario: ${mensajeErrorAmable(e)}');
        mostrarSnack(context,
            'No se pudo guardar el horario: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Entrenadores por turno'),
        // 1.36 H-B3 (136-782): estado de la casa con icono
        // y tipografía (antes un Text pelado centrado).
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño',
          subtitulo:
              'Solo el dueño puede configurar el horario de turnos.',
        ),
      );
    }
    // F3-11: salir con cambios sin guardar pide confirmación
    // (antes se perdían en silencio).
    return PopScope(
      canPop: !_hayCambios,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final salir = await DialogoApp.confirmar(
          context,
          titulo: 'Cambios sin guardar',
          mensaje:
              'Tienes cambios en el patrón semanal que aún no se han guardado.',
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
        'Entrenadores por turno',
        acciones: [
          if (!_cargando)
            TextButton(
              // 1.36 H-B3 (136-780): sin patrón leído no se
              // guarda (ver _guardar, que también lo frena).
              onPressed:
                  (_guardando || _errorLecturaPatron) ? null : _guardar,
              child: _guardando
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Guardar',
                      style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando horario…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                Text(
                  'Quién cubre cada turno según el plan semanal. La app '
                  'de clientes lo muestra solo cuando no hay un turno '
                  'abierto en vivo a esa hora; la apertura real manda.',
                  style: AppTexto.secundario.copyWith(color: AppColores.textoSecundario(context)),
                ),
                if (_usuariosNoCargaron) ...[
                  const SizedBox(height: 12),
                  Tarjeta(
                    color: AppColores.alerta.withValues(alpha: 0.12),
                    child: Row(
                      children: [
                        // 1.36 H-B3 (136-782): token con
                        // contexto (fuera alertaOscuro fijo).
                        Icon(Icons.warning_amber_rounded,
                            color: AppColores.alertaTexto(context)),
                        const SizedBox(width: AppEspacio.sm),
                        Expanded(
                          child: Text(
                            'No se pudo cargar la lista de entrenadores: '
                            'los selectores solo muestran las asignaciones '
                            'ya guardadas. Sincroniza y vuelve a entrar.',
                            style: AppTexto.secundario,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                // 1.36 H-B3 (136-780): estados que antes se
                // confundían con el fallo de lectura o con
                // el patrón por defecto.
                if (_errorLecturaPatron) ...[
                  const SizedBox(height: 12),
                  Tarjeta(
                    color: AppColores.error.withValues(alpha: 0.10),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded,
                            color: AppColores.errorTexto(context)),
                        const SizedBox(width: AppEspacio.sm),
                        const Expanded(
                          child: Text(
                            'No se pudo leer el patrón guardado: '
                            'el guardado está bloqueado para no '
                            'pisarlo. Sal y vuelve a entrar.',
                            style: AppTexto.secundario,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_sinAsignables) ...[
                  const SizedBox(height: 12),
                  Tarjeta(
                    child: Row(
                      children: [
                        Icon(Icons.info_outline_rounded,
                            color: AppColores.textoSecundario(context)),
                        const SizedBox(width: AppEspacio.sm),
                        const Expanded(
                          child: Text(
                            'La lista de usuarios cargó, pero no '
                            'hay entrenadores asignables (solo '
                            'cuentas de dueño/administración o '
                            'bloqueadas).',
                            style: AppTexto.secundario,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (_errorGuardado != null) ...[
                  const SizedBox(height: 12),
                  Tarjeta(
                    color: AppColores.error.withValues(alpha: 0.10),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded,
                            color: AppColores.errorTexto(context)),
                        const SizedBox(width: AppEspacio.sm),
                        Expanded(
                          child: Text(_errorGuardado!,
                              style: AppTexto.secundario),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                for (var d = 1; d <= 6; d++) _tarjetaDia(d),
                // F3-30: componentes de la casa (antes Card
                // de Material con Colors.red crudo).
                const Tarjeta(
                  child: ListTile(
                    leading: Icon(Icons.block_rounded,
                        color: AppColores.error),
                    title: Text('Domingo'),
                    subtitle: Text('Cerrado — sin turnos'),
                  ),
                ),
              ],
            ),
      ),
    );
  }

  Widget _tarjetaDia(int dia) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _nombres[dia],
              style: AppTexto.titulo,
            ),
            const Divider(),
            _selectorFranja(dia, 'manana', 'Mañana'),
            if (dia == 6)
              Padding(
                padding: EdgeInsets.only(top: AppEspacio.sm),
                child: Text('Sin franja de tarde los sábados',
                    style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context))),
              )
            else
              _selectorFranja(dia, 'tarde', 'Tarde'),
          ],
        ),
      ),
    );
  }

  Widget _selectorFranja(int dia, String franja, String etiqueta) {
    final valor = _sel[dia]![franja];
    return Row(
      children: [
        // 1.36 H-B3 (136-782): ancho flexible — los 64 dp
        // fijos cortaban «Mañana» con texto grande.
        Flexible(
          child: Text(etiqueta,
              overflow: TextOverflow.ellipsis,
              style: AppTexto.secundario.copyWith(color: AppColores.textoSecundario(context))),
        ),
        const SizedBox(width: AppEspacio.sm),
        Expanded(
          flex: 3,
          child: SelectorIron<String?>(
            valor: valor,
            tituloPanel: etiqueta,
            opciones: [
              const OpcionSelector<String?>(null, 'Sin asignar'),
              for (final n in _entrenadores)
                OpcionSelector<String?>(n, n),
            ],
            alCambiar: (v) => setState(() => _sel[dia]![franja] = v),
          ),
        ),
      ],
    );
  }
}
