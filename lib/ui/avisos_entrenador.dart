/// Avisos para entrenadores (v1.12.0, Bloque 3 F4 — SOLO dueño).
/// Crear, editar y desactivar avisos del espejo
/// `avisos_entrenadores`. Viajan por sync_ops (el dueño puede
/// publicarlos sin red); los entrenadores los ven en PopUp en su
/// Home. Modo 'una_vez': aparece una sola vez por teléfono.
/// Modo 'descartable': aparece hasta que se cierra. La ventana de
/// vigencia es opcional (sin fechas = siempre vigente si activo).
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../bloque3.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'widgets.dart';

class AvisosEntrenadorScreen extends StatefulWidget {
  const AvisosEntrenadorScreen({super.key});
  @override
  State<AvisosEntrenadorScreen> createState() =>
      _AvisosEntrenadorScreenState();
}

class _AvisosEntrenadorScreenState
    extends State<AvisosEntrenadorScreen> {
  bool _cargando = true;
  List<AvisoEntrenador> _avisos = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final avisos = await AvisosEntrenadorService.instance.todos();
    if (!mounted) return;
    setState(() {
      _avisos = avisos;
      _cargando = false;
    });
  }

  void _snack(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _editar([AvisoEntrenador? actual]) async {
    // P2#9: escritura solo-dueño.
    if (!AuthService().isOwner) {
      _snack('Solo el dueño puede crear o editar avisos.');
      return;
    }
    final tituloCtrl = TextEditingController(text: actual?.titulo ?? '');
    final mensajeCtrl =
        TextEditingController(text: actual?.mensaje ?? '');
    var modo = actual?.modo ?? 'una_vez';
    var desde = actual?.vigenteDesde;
    var hasta = actual?.vigenteHasta;
    // 1.19: destinatario del aviso (null = todos los entrenadores).
    // Argón avisos Q5: si el destinatario guardado ya no está en
    // kEntrenadoresAviso, el Dropdown reventaría con AssertionError
    // (ningún item con ese valor); se cae a «Todos» en ese caso.
    var destinatario = kEntrenadoresAviso.containsKey(
            actual?.destinatarioTelegramId)
        ? actual?.destinatarioTelegramId
        : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(actual == null ? 'Nuevo aviso' : 'Editar aviso'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: tituloCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Título',
                    border: OutlineInputBorder(),
                  ),
                  maxLength: 80,
                ),
                const SizedBox(height: AppEspacio.md),
                TextField(
                  controller: mensajeCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Mensaje',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 4,
                  maxLength: 500,
                ),
                const SizedBox(height: AppEspacio.md),
                DropdownButtonFormField<int?>(
                  initialValue: destinatario,
                  decoration: const InputDecoration(
                    labelText: 'Para',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('Todos los entrenadores'),
                    ),
                    for (final e in kEntrenadoresAviso.entries)
                      DropdownMenuItem<int?>(
                        value: e.key,
                        child: Text('Solo ${e.value}'),
                      ),
                  ],
                  onChanged: (v) => setS(() => destinatario = v),
                ),
                const SizedBox(height: AppEspacio.md),
                RadioListTile<String>(
                  value: 'una_vez',
                  groupValue: modo,
                  onChanged: (v) => setS(() => modo = v ?? 'una_vez'),
                  title: const Text('Una vez'),
                  subtitle: const Text(
                    'Aparece una sola vez por teléfono.',
                    style: AppTexto.secundario,
                  ),
                ),
                RadioListTile<String>(
                  value: 'descartable',
                  groupValue: modo,
                  onChanged: (v) => setS(() => modo = v ?? 'una_vez'),
                  title: const Text('Descartable'),
                  subtitle: const Text(
                    'Aparece hasta que se cierra.',
                    style: AppTexto.secundario,
                  ),
                ),
                const SizedBox(height: AppEspacio.sm),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final f = await showDatePicker(
                            context: ctx,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2026),
                            lastDate: DateTime(2030),
                          );
                          if (f != null) {
                            setS(() => desde =
                                f.toIso8601String().substring(0, 10));
                          }
                        },
                        child: Text(desde == null
                            ? 'Desde (opcional)'
                            : 'Desde $desde'),
                      ),
                    ),
                    const SizedBox(width: AppEspacio.sm),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () async {
                          final f = await showDatePicker(
                            context: ctx,
                            initialDate: DateTime.now(),
                            firstDate: DateTime(2026),
                            lastDate: DateTime(2030),
                          );
                          if (f != null) {
                            setS(() => hasta =
                                f.toIso8601String().substring(0, 10));
                          }
                        },
                        child: Text(hasta == null
                            ? 'Hasta (opcional)'
                            : 'Hasta $hasta'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final titulo = tituloCtrl.text.trim();
    final mensaje = mensajeCtrl.text.trim();
    if (titulo.isEmpty || mensaje.isEmpty) {
      _snack('Título y mensaje son obligatorios.');
      return;
    }
    try {
      await AvisosEntrenadorService.instance.guardar(AvisoEntrenador(
        id: actual?.id ?? '',
        titulo: titulo,
        mensaje: mensaje,
        modo: modo,
        activo: true,
        vigenteDesde: desde,
        vigenteHasta: hasta,
        destinatarioTelegramId: destinatario,
      ));
      _snack('Aviso guardado.');
      await _cargar();
    } catch (e) {
      _snack('No se pudo guardar: $e');
    }
  }

  Future<void> _desactivar(AvisoEntrenador a) async {
    // P2#9: escritura solo-dueño.
    if (!AuthService().isOwner) {
      _snack('Solo el dueño puede desactivar avisos.');
      return;
    }
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Desactivar aviso',
      mensaje:
          '«${a.titulo}» dejará de aparecer en los teléfonos de los entrenadores. No se borra el registro.',
      aceptar: 'Desactivar',
    );
    if (ok != true || !mounted) return;
    try {
      await AvisosEntrenadorService.instance.desactivar(a);
      _snack('Aviso desactivado.');
      await _cargar();
    } catch (e) {
      _snack('No se pudo desactivar: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // P2#9: pantalla SOLO dueño sin guarda. Los initialDate de
    // los pickers son solo UI y se dejan como están.
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(
              title: const Text('Avisos para entrenadores')),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Avisos para entrenadores')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.campaign_rounded),
        label: const Text('Nuevo aviso'),
        onPressed: () => _editar(),
      ),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(child: FadeEntrada(child: _cuerpo())),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_avisos.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(AppEspacio.xl),
          child: Text(
            'No hay avisos. Crea uno con el botón «Nuevo aviso»: '
            'aparecerá en el Home de los entrenadores.',
            textAlign: TextAlign.center,
            style: AppTexto.secundario,
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.builder(
        padding: const EdgeInsets.all(AppEspacio.lg),
        itemCount: _avisos.length,
        itemBuilder: (ctx, i) {
          final a = _avisos[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.md),
            child: Tarjeta(
              color: a.activo
                  ? null
                  : AppColores.error.withValues(alpha: 0.08),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(a.titulo,
                            style: AppTexto.subtitulo),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: (a.activo
                                  ? AppColores.exitoOscuro
                                  : AppColores.error)
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          a.activo ? 'Activo' : 'Inactivo',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: a.activo
                                ? AppColores.exitoOscuro
                                : AppColores.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(a.mensaje, style: AppTexto.cuerpo),
                  const SizedBox(height: 4),
                  Text(
                    'Modo: ${a.modo == 'una_vez' ? 'una vez' : 'descartable'}'
                    '${a.vigenteDesde != null ? ' · desde ${a.vigenteDesde}' : ''}'
                    '${a.vigenteHasta != null ? ' · hasta ${a.vigenteHasta}' : ''}'
                    ' · Para: ${nombreDestinoAviso(a.destinatarioTelegramId)}',
                    style: AppTexto.secundario,
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  Wrap(
                    spacing: AppEspacio.sm,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.edit_rounded, size: 18),
                        label: const Text('Editar'),
                        onPressed: () => _editar(a),
                      ),
                      if (a.activo)
                        OutlinedButton.icon(
                          icon: const Icon(Icons.block_rounded,
                              size: 18),
                          label: const Text('Desactivar'),
                          onPressed: () => _desactivar(a),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
