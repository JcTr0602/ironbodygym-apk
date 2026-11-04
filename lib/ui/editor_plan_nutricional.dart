// lib/ui/editor_plan_nutricional.dart
// v1.3.9 Sprint 2 (#4): editor de plan nutricional.
// Jc escribe sus propios planes; el editor es texto libre con
// plantillas personales guardadas en SharedPreferences.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'app_bar.dart';
import 'diseno.dart';
import 'componentes.dart';
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
      // Autoauditoría 1.22 #2: la LECTURA con timeout (12 s):
      // sin tope, una conexión colgada dejaba el editor en
      // «cargando» eterno. La ESCRITURA (_guardar) no lleva
      // timeout a propósito, como en Invitados: un corte del
      // lado cliente no debe fingir que el servidor no guardó.
      final res = await Supabase.instance.client
          .rpc(
            'obtener_plan_cliente',
            params: {'p_cliente_id': widget.clienteId},
          )
          .timeout(const Duration(seconds: 12));
      if (res != null && mounted) {
        // Fix 2026-10-19: el RPC puede devolver List (PostgREST) o Map.
        dynamic data = res;
        if (data is List && data.isNotEmpty) {
          data = data.first;
        }
        if (data is! Map) {
          setState(() => _cargando = false);
          return;
        }
        final m = Map<String, dynamic>.from(data);
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
        mostrarSnack(context, 'Error: $e', significado: SignificadoChip.error);
      }
    }
  }

  Future<void> _guardar() async {
    // Autoauditoría 1.22 #2 (P-3): revalidar el permiso EN el
    // guardado, no solo en el botón que lo invoca (puedeEditar
    // se calculó al pintar; la sesión pudo cambiar con la
    // pantalla abierta). Fail-closed.
    if (!(AuthService().isOwner ||
        PermisosEntrenador().canEditNutrition)) {
      mostrarSnack(context,
          'No tienes permiso para editar planes nutricionales',
          significado: SignificadoChip.error);
      return;
    }
    final texto = _ctrl.text.trim();
    if (texto.isEmpty) {
      mostrarSnack(context, 'El plan no puede estar vacío', significado: SignificadoChip.alerta);
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
        mostrarSnack(context, 'Plan guardado', significado: SignificadoChip.exito);
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _guardando = false);
        mostrarSnack(context, 'Error: $e', significado: SignificadoChip.error);
      }
    }
  }

  Future<void> _usarPlantillaPersonal() async {
    final prefs = await SharedPreferences.getInstance();
    final plantilla =
        prefs.getString('plantilla_nutricional_personal');
    if (plantilla == null || plantilla.isEmpty) {
      if (mounted) {
        mostrarSnack(context, 'No tienes plantilla guardada. Escribe un plan y usa "Guardar como plantilla".', significado: SignificadoChip.alerta);
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
                child: const Text('Cancelar')),
            TextButton(
                onPressed: () =>
                    Navigator.pop(ctx, true),
                child: const Text('Reemplazar')),
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
      mostrarSnack(context, 'Escribe un plan primero', significado: SignificadoChip.alerta);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'plantilla_nutricional_personal', texto);
    if (mounted) {
      mostrarSnack(context, 'Plantilla personal guardada', significado: SignificadoChip.exito);
    }
  }

  @override
  Widget build(BuildContext context) {
    final puedeEditar = AuthService().isOwner ||
        PermisosEntrenador().canEditNutrition;

    return Scaffold(
      appBar: appBarIron(
        context,
        'Plan: ${widget.nombreCliente}',
        acciones: [
          if (puedeEditar && !_cargando)
            IconButton(
              icon: const Icon(Icons.save_rounded),
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
                    padding: const EdgeInsets.all(AppEspacio.sm),
                    child: Text(
                      'Última actualización: ${_actualizadoPor ?? ''}'
                      '${_actualizadoEn != null ? ' • ${_actualizadoEn!.day}/${_actualizadoEn!.month}/${_actualizadoEn!.year}' : ''}',
                      style: AppTexto.metadato.copyWith(color: Colors.grey[600]),
                    ),
                  ),
                if (puedeEditar)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppEspacio.lg),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(
                                Icons.auto_awesome_rounded,
                                size: 16),
                            label: const Text(
                                'Usar mi plantilla',
                                style: AppTexto.metadato),
                            onPressed:
                                _usarPlantillaPersonal,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(
                                Icons.bookmark_add_rounded,
                                size: 16),
                            label: const Text(
                                'Guardar como plantilla',
                                style: AppTexto.metadato),
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
                        horizontal: AppEspacio.lg),
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
                              BorderRadius.circular(AppRadio.md),
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
