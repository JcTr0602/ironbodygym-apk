import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../premios_panel.dart';
import 'componentes.dart';
import 'diseno.dart';

/// Premios (1.27, S2/G2): pestaña «Catálogo» del hub de
/// Premios — los logros con su premio, editables sin
/// tocar SQL: meta (días verificados), premio (días
/// gratis) e interruptor. Guardar es RPC directa con
/// timeout (no mueve dinero: no necesita cola offline,
/// como el rechazo de vales); el servidor valida, exige
/// admin y deja auditoría antes→después de cada cambio.
/// Los cargadores son inyectables para los tests.
class PremiosCatalogoTab extends StatefulWidget {
  final Future<Map<String, dynamic>> Function()? cargarCatalogo;
  final Future<Map<String, dynamic>> Function(String logroId,
      int metaDias, int premioDias, bool activo)? guardarEntrada;

  const PremiosCatalogoTab(
      {super.key, this.cargarCatalogo, this.guardarEntrada});

  @override
  State<PremiosCatalogoTab> createState() =>
      _PremiosCatalogoTabState();
}

class _PremiosCatalogoTabState extends State<PremiosCatalogoTab> {
  bool _cargando = true;
  bool _falloCarga = false;
  List<EntradaCatalogoPremio> _entradas = const [];

  // 1.28 (M5-A4/C-R2M5-H3): generación de carga — una
  // foto vieja que llega tarde no pisa el estado.
  int _genCarga = 0;

  // 1.28 (M5-A4/C-R2M5-H1): el editor no se apila —
  // check-and-set síncrono antes del primer await (un
  // doble toque abría dos editores y el segundo
  // guardado pisaba el primero sin avisar).
  bool _editando = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<Map<String, dynamic>> _cargarReal() async {
    final res = await Supabase.instance.client
        .rpc('admin_premios_catalogo')
        .timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<Map<String, dynamic>> _guardarReal(String logroId,
      int metaDias, int premioDias, bool activo) async {
    final res = await Supabase.instance.client.rpc(
      'admin_premios_catalogo_guardar',
      params: {
        'p_logro_id': logroId,
        'p_meta_dias': metaDias,
        'p_premio_dias': premioDias,
        'p_activo': activo,
      },
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<void> _cargar() async {
    final gen = ++_genCarga;
    setState(() {
      _cargando = true;
      _falloCarga = false;
    });
    try {
      final json = await (widget.cargarCatalogo ?? _cargarReal)();
      if (!mounted || gen != _genCarga) return;
      // 1.28 (M5-A2 ★): el éxito de admin_premios_catalogo
      // SÍ trae ok:true (s2): una respuesta sin ok no es
      // un catálogo vacío legítimo — es un fallo, y se
      // pinta como fallo, no como «sin premios».
      if (json['ok'] != true) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
        return;
      }
      setState(() {
        _entradas = parseCatalogoPremios(json);
        _cargando = false;
      });
    } catch (_) {
      if (mounted && gen == _genCarga) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
    }
  }

  Future<void> _editar(EntradaCatalogoPremio e) async {
    if (_editando) return;
    _editando = true;
    try {
      final guardado = await showDialog<bool>(
        context: context,
        builder: (_) => _DialogoEditarPremio(
          entrada: e,
          guardar: widget.guardarEntrada ?? _guardarReal,
        ),
      );
      if (guardado == true && mounted) {
        mostrarSnack(context, 'Catálogo actualizado',
            significado: SignificadoChip.exito);
        await _cargar();
      }
    } finally {
      _editando = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando catálogo…');
    }
    if (_falloCarga) {
      return EstadoVacio(
        icono: Icons.cloud_off_rounded,
        titulo: 'No se pudo cargar el catálogo.',
        subtitulo:
            'El catálogo vive en el servidor: hace falta conexión.',
        textoAccion: 'Reintentar',
        onAccion: _cargar,
      );
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          const Text(
            'Qué gana el cliente al cumplir cada logro. '
            'La meta cuenta días entrenados verificados '
            'por el servidor; el premio son días de '
            'mensualidad gratis que tú apruebas en la '
            'bandeja cuando el cliente lo reclama.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          for (final e in _entradas) ...[
            Tarjeta(
              onTap: () => _editar(e),
              child: Row(
                children: [
                  Icon(
                    e.activo
                        ? Icons.emoji_events_rounded
                        : Icons.emoji_events_outlined,
                    color: e.activo
                        ? AppColores.alerta
                        : AppColores.textoSecundario(context),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(e.nombre,
                            style: AppTexto.cuerpo.copyWith(
                                fontWeight: FontWeight.w700)),
                        Text(e.estadoTexto,
                            style: AppTexto.secundario),
                        if (e.ultimoCambioTexto != null)
                          Text(e.ultimoCambioTexto!,
                              style: AppTexto.metadato),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// Editor de una entrada del catálogo. StatefulWidget
/// propio con dispose (regla de la casa). Valida en
/// cliente con las mismas reglas del servidor para dar
/// el aviso al momento; el servidor revalida y su
/// mensaje manda si difieren.
class _DialogoEditarPremio extends StatefulWidget {
  final EntradaCatalogoPremio entrada;
  final Future<Map<String, dynamic>> Function(String logroId,
      int metaDias, int premioDias, bool activo) guardar;

  const _DialogoEditarPremio(
      {required this.entrada, required this.guardar});

  @override
  State<_DialogoEditarPremio> createState() =>
      _DialogoEditarPremioState();
}

class _DialogoEditarPremioState extends State<_DialogoEditarPremio> {
  late final TextEditingController _metaCtrl;
  late final TextEditingController _premioCtrl;
  late bool _activo;
  String? _error;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _metaCtrl =
        TextEditingController(text: '${widget.entrada.metaDias}');
    _premioCtrl =
        TextEditingController(text: '${widget.entrada.premioDias}');
    _activo = widget.entrada.activo;
  }

  @override
  void dispose() {
    _metaCtrl.dispose();
    _premioCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    final meta = int.tryParse(_metaCtrl.text.trim());
    final premio = int.tryParse(_premioCtrl.text.trim());
    String? error;
    if (meta == null || meta < 1 || meta > 3650) {
      error = 'La meta debe estar entre 1 y 3650 días.';
    } else if (premio == null || premio < 0 || premio > 365) {
      error = 'El premio debe estar entre 0 y 365 días.';
    } else if (_activo && premio == 0) {
      error = 'Un premio activo con 0 días no regala nada: '
          'apágalo en vez de ponerlo en 0.';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final res = await widget.guardar(
          widget.entrada.logroId, meta!, premio!, _activo);
      if (!mounted) return;
      if (res['ok'] == true) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _guardando = false;
        _error = '${res['mensaje'] ?? res['motivo'] ?? 'No se pudo guardar.'}';
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = 'Sin conexión con el servidor.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: widget.entrada.nombre,
      iconoTitulo: Icons.emoji_events_rounded,
      contenido: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CampoTexto(
              controller: _metaCtrl,
              etiqueta: 'Meta (días entrenados verificados)',
              teclado: TextInputType.number),
          const SizedBox(height: 8),
          CampoTexto(
              controller: _premioCtrl,
              etiqueta: 'Premio (días de mensualidad gratis)',
              teclado: TextInputType.number),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Premio activo'),
            value: _activo,
            onChanged: _guardando
                ? null
                : (v) => setState(() => _activo = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(_error!,
                style: AppTexto.secundario
                    .copyWith(color: AppColores.error)),
          ],
        ],
      ),
      acciones: [
        TextButton(
            onPressed:
                _guardando ? null : () => Navigator.pop(context, false),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _guardando ? null : _guardar,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: Text(_guardando ? 'Guardando…' : 'Guardar'),
        ),
      ],
    );
  }
}
