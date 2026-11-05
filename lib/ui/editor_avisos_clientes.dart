/// 1.24 Bloque 6 (ítem 16 del Panel): editor de «Avisos a
/// clientes» — el dueño publica los avisos que la app de
/// clientes muestra en su centro de avisos (F6 de Clientes).
///
/// El contenido vive SOLO en el servidor (sync_avisos): se lee
/// y se escribe por las RPC admin_* (guarda es_admin() en el
/// servidor; esta pantalla además se protege a sí misma como
/// solo-dueño). Por eso esta pantalla ES de red: sin conexión
/// muestra el error con reintento, nunca un spinner eterno ni
/// una lista local inventada. Cada cambio baja al teléfono de
/// los clientes en su próxima sincronización (avisos_delta).
library;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

class AvisoCliente {
  final int id;
  final String titulo;
  final String cuerpo;
  final String nivel;
  final String creadoTs;

  const AvisoCliente({
    required this.id,
    required this.titulo,
    required this.cuerpo,
    required this.nivel,
    required this.creadoTs,
  });

  bool get importante => nivel == 'importante';

  factory AvisoCliente.fromJson(Map<String, dynamic> j) => AvisoCliente(
        id: (j['id'] as num?)?.toInt() ?? 0,
        titulo: '${j['titulo'] ?? ''}',
        cuerpo: '${j['cuerpo'] ?? ''}',
        nivel: '${j['nivel'] ?? 'info'}',
        creadoTs: '${j['creado_ts'] ?? ''}',
      );
}

class EditorAvisosClientesScreen extends StatefulWidget {
  const EditorAvisosClientesScreen({super.key});

  @override
  State<EditorAvisosClientesScreen> createState() =>
      _EditorAvisosClientesScreenState();
}

class _EditorAvisosClientesScreenState
    extends State<EditorAvisosClientesScreen> {
  List<AvisoCliente> _avisos = [];
  bool _cargando = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    if (mounted) setState(() {
      _cargando = true;
      _error = false;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('admin_listar_avisos')
          .timeout(const Duration(seconds: 12));
      final lista = ((res as List?) ?? const [])
          .map((e) =>
              AvisoCliente.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!mounted) return;
      setState(() {
        _avisos = lista;
        _cargando = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = true;
      });
    }
  }

  Future<void> _abrirFormulario([AvisoCliente? aviso]) async {
    final cambiado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _FormularioAvisoScreen(aviso: aviso),
      ),
    );
    if (cambiado == true && mounted) await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Avisos a clientes'),
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño',
          subtitulo: 'Los avisos a clientes los publica el dueño.',
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Avisos a clientes'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrirFormulario(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nuevo aviso'),
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando avisos…')
          : _error
              ? EstadoError(
                  titulo: 'No se pudieron cargar los avisos',
                  detalle: 'Los avisos viven en el servidor: '
                      'revisa la conexión e inténtalo de nuevo.',
                  onReintentar: _cargar,
                )
              : _avisos.isEmpty
                  ? const EstadoVacio(
                      icono: Icons.campaign_rounded,
                      titulo: 'Sin avisos publicados',
                      subtitulo: 'Publica el primer aviso para '
                          'que lo vean los clientes en su app.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(AppEspacio.lg),
                      itemCount: _avisos.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: AppEspacio.sm),
                      itemBuilder: (ctx, i) {
                        final a = _avisos[i];
                        return Tarjeta(
                          onTap: () => _abrirFormulario(a),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                a.importante
                                    ? Icons.priority_high_rounded
                                    : Icons.campaign_rounded,
                                color: a.importante
                                    ? AppColores.error
                                    : AppColores.naranja,
                              ),
                              const SizedBox(width: AppEspacio.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(a.titulo,
                                        style: AppTexto.subtitulo),
                                    const SizedBox(height: 2),
                                    Text(a.cuerpo,
                                        style: AppTexto.secundario,
                                        maxLines: 2,
                                        overflow:
                                            TextOverflow.ellipsis),
                                    if (a.creadoTs.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        a.creadoTs.substring(
                                            0,
                                            a.creadoTs.length > 10
                                                ? 10
                                                : a.creadoTs.length),
                                        style: AppTexto.metadato,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right_rounded),
                            ],
                          ),
                        );
                      },
                    ),
    );
  }
}

class _FormularioAvisoScreen extends StatefulWidget {
  final AvisoCliente? aviso;
  const _FormularioAvisoScreen({this.aviso});

  @override
  State<_FormularioAvisoScreen> createState() =>
      _FormularioAvisoScreenState();
}

class _FormularioAvisoScreenState extends State<_FormularioAvisoScreen> {
  late final TextEditingController _tituloCtrl;
  late final TextEditingController _cuerpoCtrl;
  late bool _importante;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _tituloCtrl = TextEditingController(text: widget.aviso?.titulo ?? '');
    _cuerpoCtrl = TextEditingController(text: widget.aviso?.cuerpo ?? '');
    _importante = widget.aviso?.importante ?? false;
  }

  @override
  void dispose() {
    _tituloCtrl.dispose();
    _cuerpoCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    // Anti-doble-toque síncrono (ítem 5): la bandera sube
    // antes del primer await.
    if (_guardando) return;
    final titulo = _tituloCtrl.text.trim();
    final cuerpo = _cuerpoCtrl.text.trim();
    if (titulo.isEmpty || cuerpo.isEmpty) {
      mostrarSnack(context, 'El aviso necesita título y texto',
          significado: SignificadoChip.alerta);
      return;
    }
    setState(() => _guardando = true);
    try {
      await Supabase.instance.client
          .rpc('admin_guardar_aviso', params: {
            'p_id': widget.aviso?.id,
            'p_titulo': titulo,
            'p_cuerpo': cuerpo,
            'p_nivel': _importante ? 'importante' : 'info',
          })
          // 1.24 Bloque 4: timeout de escritura (12 s).
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      mostrarSnack(context, 'Aviso publicado',
          significado: SignificadoChip.exito);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarSnack(context, 'No se pudo publicar: $e',
          significado: SignificadoChip.error);
    }
  }

  Future<void> _retirar() async {
    final aviso = widget.aviso;
    if (aviso == null || _guardando) return;
    // Escalera de confirmaciones (ítem 2): retirar es
    // destructivo → confirmación explícita en rojo.
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Retirar aviso',
      mensaje: '«${aviso.titulo}» dejará de verse en la app de '
          'los clientes en su próxima sincronización.',
      aceptar: 'Retirar',
      icono: Icons.delete_outline_rounded,
      peligro: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _guardando = true);
    try {
      await Supabase.instance.client
          .rpc('admin_retirar_aviso', params: {'p_id': aviso.id})
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      mostrarSnack(context, 'Aviso retirado',
          significado: SignificadoChip.exito);
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      mostrarSnack(context, 'No se pudo retirar: $e',
          significado: SignificadoChip.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final esEdicion = widget.aviso != null;
    return Scaffold(
      appBar: appBarIron(
          context, esEdicion ? 'Editar aviso' : 'Nuevo aviso'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          TextField(
            controller: _tituloCtrl,
            decoration: const InputDecoration(
              labelText: 'Título',
              hintText: 'Ej.: Horario especial este viernes',
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: AppEspacio.md),
          TextField(
            controller: _cuerpoCtrl,
            decoration: const InputDecoration(
              labelText: 'Texto del aviso',
              alignLabelWithHint: true,
            ),
            minLines: 4,
            maxLines: 8,
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(
            'Lo verán todos los clientes en el centro de avisos '
            'de su app, en su próxima sincronización.',
            style: AppTexto.metadato,
          ),
          const SizedBox(height: AppEspacio.md),
          SwitchListTile(
            value: _importante,
            onChanged: _guardando
                ? null
                : (v) => setState(() => _importante = v),
            title: const Text('Aviso importante'),
            subtitle: const Text(
                'Sale primero y destacado en la app del cliente.'),
          ),
          const SizedBox(height: AppEspacio.lg),
          ElevatedButton(
            onPressed: _guardando ? null : _guardar,
            child: Text(_guardando
                ? 'Publicando…'
                : (esEdicion ? 'Guardar cambios' : 'Publicar aviso')),
          ),
          if (esEdicion) ...[
            const SizedBox(height: AppEspacio.sm),
            TextButton(
              onPressed: _guardando ? null : _retirar,
              child: Text('Retirar aviso',
                  style: TextStyle(color: AppColores.error)),
            ),
          ],
        ],
      ),
    );
  }
}
