// lib/ui/editor_plan_nutricional.dart
// v1.3.9 Sprint 2 (#4): editor de plan nutricional.
// Jc escribe sus propios planes; el editor es texto libre con
// plantillas personales guardadas en SharedPreferences.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../auth.dart';
import '../permisos_entrenador.dart';

class EditorPlanNutricional extends StatefulWidget {
  final String clienteId;
  final String nombreCliente;

  const EditorPlanNutricional({
    super.key,
    required this.clienteId,
    required this.nombreCliente,
  });

  @override
  State<EditorPlanNutricional> createState() =>
      _EditorPlanNutricionalState();
}

class _EditorPlanNutricionalState
    extends State<EditorPlanNutricional> {
  final _ctrl = TextEditingController();
  bool _cargando = true;
  bool _guardando = false;
  String? _actualizadoPor;
  DateTime? _actualizadoEn;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'obtener_plan_cliente',
        params: {'p_cliente_id': widget.clienteId},
      );
      if (res != null && mounted) {
        final m = Map<String, dynamic>.from(res as Map);
        // El contenido está en detalle.contenido (JSONB)
        final detalle = m['detalle'];
        String contenido = '';
        if (detalle is Map) {
          contenido = '${detalle['contenido'] ?? ''}';
        } else if (detalle is String) {
          contenido = detalle;
        }
        setState(() {
          _ctrl.text = contenido;
          _actualizadoPor =
              m['creado_por']?.toString();
          final ae = m['actualizado_en'];
          if (ae != null) {
            _actualizadoEn =
                DateTime.tryParse(ae.toString());
          }
          _cargando = false;
        });
      } else if (mounted) {
        setState(() => _cargando = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cargando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _guardar() async {
    final texto = _ctrl.text.trim();
    if (texto.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('El plan no puede estar vacío')),
      );
      return;
    }
    setState(() => _guardando = true);
    try {
      await Supabase.instance.client
          .rpc('guardar_plan_nutricional', params: {
        'p_cliente_id': widget.clienteId,
        'p_contenido': texto,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Plan guardado')),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _usarPlantillaPersonal() async {
    final prefs = await SharedPreferences.getInstance();
    final plantilla =
        prefs.getString('plantilla_nutricional_personal');
    if (plantilla == null || plantilla.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text(
                  'No tienes plantilla guardada. Escribe un plan y usa "Guardar como plantilla".')),
        );
      }
      return;
    }
    if (_ctrl.text.trim().isNotEmpty && mounted) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reemplazar texto'),
          content: const Text(
              '¿Reemplazar el texto actual con tu plantilla?'),
          actions: [
            TextButton(
                onPressed: () =>
                    Navigator.pop(ctx, false),
                child: const Text('CANCELAR')),
            TextButton(
                onPressed: () =>
                    Navigator.pop(ctx, true),
                child: const Text('REEMPLAZAR')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _ctrl.text = plantilla);
  }

  Future<void> _guardarComoPlantilla() async {
    final texto = _ctrl.text.trim();
    if (texto.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Escribe un plan primero')),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'plantilla_nutricional_personal', texto);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content:
                Text('Plantilla personal guardada')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final puedeEditar = AuthService().isOwner ||
        PermisosEntrenador().canEditNutrition;

    return Scaffold(
      appBar: AppBar(
        title: Text('Plan: ${widget.nombreCliente}'),
        actions: [
          if (puedeEditar && !_cargando)
            IconButton(
              icon: const Icon(Icons.save),
              onPressed:
                  _guardando ? null : _guardar,
              tooltip: 'Guardar',
            ),
        ],
      ),
      body: _cargando
          ? const Center(
              child: CircularProgressIndicator())
          : Column(
              children: [
                if (_actualizadoPor != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      'Última actualización: ${_actualizadoPor ?? ''}'
                      '${_actualizadoEn != null ? ' • ${_actualizadoEn!.day}/${_actualizadoEn!.month}/${_actualizadoEn!.year}' : ''}',
                      style: TextStyle(
                          color: Colors.grey[600],
                          fontSize: 12),
                    ),
                  ),
                if (puedeEditar)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(
                                Icons.auto_awesome,
                                size: 16),
                            label: const Text(
                                'Usar mi plantilla',
                                style: TextStyle(
                                    fontSize: 12)),
                            onPressed:
                                _usarPlantillaPersonal,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(
                                Icons.bookmark_add,
                                size: 16),
                            label: const Text(
                                'Guardar como plantilla',
                                style: TextStyle(
                                    fontSize: 12)),
                            onPressed:
                                _guardarComoPlantilla,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16),
                    child: TextField(
                      controller: _ctrl,
                      maxLines: null,
                      expands: true,
                      readOnly: !puedeEditar,
                      textAlignVertical:
                          TextAlignVertical.top,
                      decoration: InputDecoration(
                        hintText: puedeEditar
                            ? 'Escribe el plan nutricional...\n\nDESAYUNO\n...\n\nALMUERZO\n...'
                            : 'Sin plan asignado.',
                        border: OutlineInputBorder(
                          borderRadius:
                              BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
    );
  }
}
