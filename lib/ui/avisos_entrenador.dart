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
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'skeleton.dart';
import 'widgets.dart';
import '../app_log.dart';

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
  // GEN-10: vistos del espejo (solo bajan al dueño).
  List<VistoAviso> _vistos = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    setState(() => _cargando = true);
    final avisos = await AvisosEntrenadorService.instance.todos();
    final vistos = await AvisosEntrenadorService.instance.vistos();
    if (!mounted) return;
    setState(() {
      _avisos = avisos;
      _vistos = vistos;
      _cargando = false;
    });
  }

  void _snack(String texto) {
    if (!mounted) return;
    mostrarSnack(context, texto);
  }

  Future<void> _editar([AvisoEntrenador? actual]) async {
    // P2#9: escritura solo-dueño.
    if (!AuthService().isOwner) {
      _snack('Solo el dueño puede crear o editar avisos.');
      return;
    }
    final datos = await showDialog<_DatosAvisoEntrenador>(
      context: context,
      builder: (ctx) => _DialogoEditarAviso(actual: actual),
    );
    if (datos == null || !mounted) return;
    final titulo = datos.titulo.trim();
    final mensaje = datos.mensaje.trim();
    if (titulo.isEmpty || mensaje.isEmpty) {
      _snack('Título y mensaje son obligatorios.');
      return;
    }
    try {
      await AvisosEntrenadorService.instance.guardar(AvisoEntrenador(
        id: actual?.id ?? '',
        titulo: titulo,
        mensaje: mensaje,
        modo: datos.modo,
        // G#30 (Hy4): editar NO reactiva — un aviso
        // inactivo conserva su estado al guardarlo (antes
        // todo guardado nacía activo: true y un aviso
        // desactivado volvía a salir en silencio). Solo
        // un aviso NUEVO nace activo.
        activo: actual?.activo ?? true,
        vigenteDesde: datos.desde,
        vigenteHasta: datos.hasta,
        destinatarioTelegramId: datos.destinatario,
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
          appBar: appBarIron(context, 'Avisos para entrenadores'),
          body: const Center(
              child: Text('Solo el dueño ve esta pantalla.')));
    }
    return Scaffold(
      appBar: appBarIron(context, 'Avisos para entrenadores'),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.campaign_rounded),
        label: const Text('Nuevo aviso'),
        onPressed: () => _editar(),
      ),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(
            child: FadeEntrada(
              // 1.23 T7: cruce por tipo de estado (la key es solo
              // el tipo, nunca los datos).
              child: CruceEstados(
                estado: _cargando
                    ? 'cargando'
                    : _avisos.isEmpty
                        ? 'vacio'
                        : 'contenido',
                child: _cuerpo(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      // 1.35 (UI-09): esqueleto de lista.
      return const SkeletonLista(items: 4);
    }
    if (_avisos.isEmpty) {
      // 1.23 B7: vacío compartido del sistema.
      return const EstadoVacio(
        icono: Icons.campaign_rounded,
        titulo: 'No hay avisos.',
        subtitulo: 'Crea uno con el botón «Nuevo aviso»: '
            'aparecerá en el Home de los entrenadores.',
      );
    }
    return RefrescoIron(
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
                            horizontal: AppEspacio.sm, vertical: 3),
                        decoration: BoxDecoration(
                          color: (a.activo
                                  ? AppColores.exitoOscuro
                                  : AppColores.error)
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          a.activo ? 'Activo' : 'Inactivo',
                          style: AppTexto.minuscula.copyWith(color: a.activo
                                ? AppColores.exitoOscuro
                                : AppColores.error, fontWeight: FontWeight.w600),
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
                  const SizedBox(height: 4),
                  Text(
                    'Visto por: '
                    '${textoVistoPor(a, vistosDeAviso(_vistos, a.id))}',
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

/// Datos que devuelve el diálogo de aviso al guardar.
typedef _DatosAvisoEntrenador = ({
  String titulo,
  String mensaje,
  String modo,
  String? desde,
  String? hasta,
  int? destinatario,
});

/// 1.30 (Oleada 7, clase B): editor de aviso como
/// StatefulWidget propio: posee y dispone los controladores
/// de título y mensaje (antes se creaban en el llamador y
/// nunca se liberaban). Devuelve los datos al guardar o
/// null si se cancela.
class _DialogoEditarAviso extends StatefulWidget {
  final AvisoEntrenador? actual;
  const _DialogoEditarAviso({required this.actual});

  @override
  State<_DialogoEditarAviso> createState() =>
      _DialogoEditarAvisoState();
}

class _DialogoEditarAvisoState extends State<_DialogoEditarAviso> {
  late final TextEditingController _tituloCtrl;
  late final TextEditingController _mensajeCtrl;
  late String _modo;
  late String? _desde;
  late String? _hasta;
  // 1.19: destinatario del aviso (null = todos los entrenadores).
  // Argón avisos Q5: si el destinatario guardado ya no está en
  // kEntrenadoresAviso, el Dropdown reventaría con AssertionError
  // (ningún item con ese valor); se cae a «Todos» en ese caso.
  late int? _destinatario;

  @override
  void initState() {
    super.initState();
    final actual = widget.actual;
    _tituloCtrl = TextEditingController(text: actual?.titulo ?? '');
    _mensajeCtrl = TextEditingController(text: actual?.mensaje ?? '');
    _modo = actual?.modo ?? 'una_vez';
    _desde = actual?.vigenteDesde;
    _hasta = actual?.vigenteHasta;
    _destinatario =
        kEntrenadoresAviso.containsKey(actual?.destinatarioTelegramId)
            ? actual?.destinatarioTelegramId
            : null;
  }

  @override
  void dispose() {
    _tituloCtrl.dispose();
    _mensajeCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final actual = widget.actual;
    return AlertDialog(
      title: Text(actual == null ? 'Nuevo aviso' : 'Editar aviso'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _tituloCtrl,
              decoration: const InputDecoration(
                labelText: 'Título',
                border: OutlineInputBorder(),
              ),
              maxLength: 80,
            ),
            const SizedBox(height: AppEspacio.md),
            TextField(
              controller: _mensajeCtrl,
              decoration: const InputDecoration(
                labelText: 'Mensaje',
                border: OutlineInputBorder(),
              ),
              maxLines: 4,
              maxLength: 500,
            ),
            const SizedBox(height: AppEspacio.md),
            SelectorIronForm<int?>(
              valorInicial: _destinatario,
              etiqueta: 'Para',
              opciones: [
                const OpcionSelector<int?>(null, 'Todos los entrenadores'),
                for (final e in kEntrenadoresAviso.entries)
                  OpcionSelector<int?>(e.key, 'Solo ${e.value}'),
              ],
              alCambiar: (v) => setState(() => _destinatario = v),
            ),
            const SizedBox(height: AppEspacio.md),
            RadioListTile<String>(
              value: 'una_vez',
              groupValue: _modo,
              onChanged: (v) =>
                  setState(() => _modo = v ?? 'una_vez'),
              title: const Text('Una vez'),
              subtitle: const Text(
                'Aparece una sola vez por teléfono.',
                style: AppTexto.secundario,
              ),
            ),
            RadioListTile<String>(
              value: 'descartable',
              groupValue: _modo,
              onChanged: (v) =>
                  setState(() => _modo = v ?? 'una_vez'),
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
                        context: context,
                        initialDate: ahoraHabana(),
                        firstDate: DateTime(2026),
                        lastDate: DateTime(2030),
                      );
                      if (f != null) {
                        setState(() => _desde =
                            f.toIso8601String().substring(0, 10));
                      }
                    },
                    child: Text(_desde == null
                        ? 'Desde (opcional)'
                        : 'Desde $_desde'),
                  ),
                ),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () async {
                      final f = await showDatePicker(
                        context: context,
                        initialDate: ahoraHabana(),
                        firstDate: DateTime(2026),
                        lastDate: DateTime(2030),
                      );
                      if (f != null) {
                        setState(() => _hasta =
                            f.toIso8601String().substring(0, 10));
                      }
                    },
                    child: Text(_hasta == null
                        ? 'Hasta (opcional)'
                        : 'Hasta $_hasta'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop((
            titulo: _tituloCtrl.text,
            mensaje: _mensajeCtrl.text,
            modo: _modo,
            desde: _desde,
            hasta: _hasta,
            destinatario: _destinatario,
          )),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
