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

  /// día ISO (1-6) -> franja -> entrenador asignado (null = sin asignar)
  final Map<int, Map<String, String?>> _sel = {
    for (var d = 1; d <= 6; d++) d: {'manana': null, 'tarde': null},
  };

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // Asignaciones vigentes (del espejo de ajustes).
    final asignados = <String>{};
    try {
      final aj = await LocalDb.instance.getAjustes();
      final h = aj['horario_turnos'];
      if (h is Map) {
        h.forEach((dia, franjas) {
          final d = int.tryParse('$dia');
          if (d == null || franjas is! Map) return;
          franjas.forEach((franja, nombre) {
            final n = '$nombre'.trim();
            if (n.isEmpty) return;
            asignados.add(n);
            if (_sel.containsKey(d) &&
                _sel[d]!.containsKey('$franja')) {
              _sel[d]!['$franja'] = n;
            }
          });
        });
      }
    } catch (_) {}

    // Nombres del selector: usuarios APK conocidos (meta usuarios_apk).
    final nombres = <String>[];
    void agregar(String? bruto) {
      final n = (bruto ?? '').trim();
      if (n.isEmpty) return;
      final bonito =
          n.length == 1 ? n.toUpperCase() : '${n[0].toUpperCase()}${n.substring(1)}';
      if (!nombres.contains(bonito)) nombres.add(bonito);
    }

    try {
      final raw = await LocalDb.instance.getMeta('usuarios_apk');
      if (raw != null && raw.isNotEmpty) {
        for (final u in jsonDecode(raw) as List) {
          final m = Map<String, dynamic>.from(u as Map);
          final nom = (m['nombre'] as String?)?.trim();
          agregar(nom != null && nom.isNotEmpty
              ? nom
              : m['username'] as String?);
        }
      }
    } catch (_) {}
    // Una asignación vigente nunca queda fuera del selector.
    for (final n in asignados) {
      if (!nombres.contains(n)) nombres.add(n);
    }

    if (mounted) {
      setState(() {
        _entrenadores = nombres;
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Horario de turnos guardado (se sincronizará)')));
        Navigator.of(context).pop();
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

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Entrenadores por turno')),
        body: const Center(
          child: Text('Solo el dueño puede configurar el horario.'),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Entrenadores por turno'),
        actions: [
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
                  : const Text('GUARDAR',
                      style: TextStyle(color: Colors.white)),
            ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Quién cubre cada turno según el plan semanal. La app '
                  'de clientes lo muestra solo cuando no hay un turno '
                  'abierto en vivo a esa hora; la apertura real manda.',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                for (var d = 1; d <= 6; d++) _tarjetaDia(d),
                const Card(
                  child: ListTile(
                    leading: Icon(Icons.block, color: Colors.red),
                    title: Text('Domingo'),
                    subtitle: Text('Cerrado — sin turnos'),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _tarjetaDia(int dia) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _nombres[dia],
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const Divider(),
            _selectorFranja(dia, 'manana', 'Mañana'),
            if (dia == 6)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Sin franja de tarde los sábados',
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
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
              style: const TextStyle(fontSize: 13, color: Colors.grey)),
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
