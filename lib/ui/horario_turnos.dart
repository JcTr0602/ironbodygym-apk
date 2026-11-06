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

import '../auth.dart';
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
  Map<int, Map<String, String?>> _inicial = {};

  bool get _hayCambios {
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
    } catch (_) {}

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
          if (base.trim().isNotEmpty) registrar(base);
        }
      }
    } catch (_) {}
    for (final (d, franja, nombre) in crudas) {
      final visible = registrar(nombre);
      if (_sel.containsKey(d) && _sel[d]!.containsKey(franja)) {
        _sel[d]![franja] = visible;
      }
    }

    if (mounted) {
      setState(() {
        _entrenadores = canon.values.toList();
        _usuariosNoCargaron = !usuariosOk;
        _inicial = {
          for (final e in _sel.entries)
            e.key: Map<String, String?>.from(e.value),
        };
        _cargando = false;
      });
    }
  }

  Future<void> _guardar() async {
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
        mostrarSnack(context, 'Horario de turnos guardado (se sincronizará)', significado: SignificadoChip.exito);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, 'Error: $e', significado: SignificadoChip.error);
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
        body: const Center(
          child: Text('Solo el dueño puede configurar el horario.'),
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
              onPressed: _guardando ? null : _guardar,
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
                        const Icon(Icons.warning_amber_rounded,
                            color: AppColores.alertaOscuro),
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
        SizedBox(
          width: 64,
          child: Text(etiqueta,
              style: AppTexto.secundario.copyWith(color: AppColores.textoSecundario(context))),
        ),
        Expanded(
          child: DropdownButton<String?>(
            isExpanded: true,
            value: valor,
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('Sin asignar'),
              ),
              for (final n in _entrenadores)
                DropdownMenuItem<String?>(value: n, child: Text(n)),
            ],
            onChanged: (v) => setState(() => _sel[dia]![franja] = v),
          ),
        ),
      ],
    );
  }
}
