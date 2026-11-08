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

import '../app_log.dart';
import '../auth.dart';
import '../tiempo.dart' show fmtFechaHabana;
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

/// 1.29 (Oleada 6, D-B3-05): el resultado de un guardado
/// con comprobación post-fallo (el patrón de Anuncios y
/// Premios de la 1.28, que este editor viejo no tenía).
enum ResultadoGuardadoAviso { guardado, noGuardado, sinConfirmar }

/// ¿La lista recién cargada ya refleja el guardado? En
/// una edición: la fila con su id trae el título/cuerpo/
/// nivel nuevos. En una creación: hay un aviso con el
/// mismo título/cuerpo/nivel cuyo id NO estaba en la
/// lista previa (un gemelo idéntico preexistente no es
/// prueba: la prueba es que apareció uno nuevo).
bool avisoReflejaGuardado({
  required List<AvisoCliente> lista,
  required Set<int> idsPrevios,
  required int? idEditado,
  required String titulo,
  required String cuerpo,
  required String nivel,
}) {
  if (idEditado != null) {
    for (final a in lista) {
      if (a.id == idEditado) {
        return a.titulo == titulo &&
            a.cuerpo == cuerpo &&
            a.nivel == nivel;
      }
    }
    return false;
  }
  return lista.any((a) =>
      !idsPrevios.contains(a.id) &&
      a.titulo == titulo &&
      a.cuerpo == cuerpo &&
      a.nivel == nivel);
}

/// Guarda y, si la llamada FALLA (p. ej. timeout: la
/// respuesta se perdió pero el aviso pudo aterrizar),
/// comprueba contra la lista antes de declarar el fallo:
/// sin esta comprobación, el dueño reintentaba y el aviso
/// salía DUPLICADO a todos los clientes.
Future<ResultadoGuardadoAviso> guardarAvisoVerificado({
  required Future<void> Function() guardar,
  required Future<List<AvisoCliente>> Function() listar,
  required Set<int> idsPrevios,
  required int? idEditado,
  required String titulo,
  required String cuerpo,
  required String nivel,
}) async {
  try {
    await guardar();
    return ResultadoGuardadoAviso.guardado;
  } catch (_) {
    final List<AvisoCliente> lista;
    try {
      lista = await listar();
    } catch (_) {
      // Ni el guardado ni la comprobación respondieron:
      // no se sabe — y se dice que no se sabe.
      return ResultadoGuardadoAviso.sinConfirmar;
    }
    return avisoReflejaGuardado(
          lista: lista,
          idsPrevios: idsPrevios,
          idEditado: idEditado,
          titulo: titulo,
          cuerpo: cuerpo,
          nivel: nivel,
        )
        ? ResultadoGuardadoAviso.guardado
        : ResultadoGuardadoAviso.noGuardado;
  }
}

class EditorAvisosClientesScreen extends StatefulWidget {
  /// Costuras de red para los tests (D-B3-05): por defecto
  /// van las RPC reales admin_guardar_aviso /
  /// admin_listar_avisos.
  final Future<void> Function(
      {int? id,
      required String titulo,
      required String cuerpo,
      required String nivel})? guardarAvisoRpc;
  final Future<List<AvisoCliente>> Function()? listarAvisosRpc;

  const EditorAvisosClientesScreen(
      {super.key, this.guardarAvisoRpc, this.listarAvisosRpc});

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

  Future<List<AvisoCliente>> _listarReal() async {
    final res = await Supabase.instance.client
        .rpc('admin_listar_avisos')
        .timeout(const Duration(seconds: 12));
    return ((res as List?) ?? const [])
        .map((e) =>
            AvisoCliente.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> _guardarReal(
      {int? id,
      required String titulo,
      required String cuerpo,
      required String nivel}) async {
    await Supabase.instance.client.rpc('admin_guardar_aviso', params: {
      'p_id': id,
      'p_titulo': titulo,
      'p_cuerpo': cuerpo,
      'p_nivel': nivel,
    })
        // 1.24 Bloque 4: timeout de escritura (12 s).
        .timeout(const Duration(seconds: 12));
  }

  Future<void> _cargar() async {
    if (mounted) setState(() {
      _cargando = true;
      _error = false;
    });
    try {
      final lista =
          await (widget.listarAvisosRpc ?? _listarReal)();
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
      RutaIron(
        builder: (_) => _FormularioAvisoScreen(
          aviso: aviso,
          // D-B3-05: la foto de ids que la lista tenía al
          // abrir — la prueba de «apareció uno nuevo» de
          // la comprobación post-fallo se mide contra ella.
          idsPrevios: {for (final a in _avisos) a.id},
          guardarAvisoRpc: widget.guardarAvisoRpc ?? _guardarReal,
          listarAvisosRpc: widget.listarAvisosRpc ?? _listarReal,
        ),
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
                                      // 1.25 T122 (F6-20): antes
                                      // se enseñaba la subcadena
                                      // ISO cruda del timestamp.
                                      Text(
                                        _fechaAviso(a.creadoTs),
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
  final Set<int> idsPrevios;
  final Future<void> Function(
      {int? id,
      required String titulo,
      required String cuerpo,
      required String nivel}) guardarAvisoRpc;
  final Future<List<AvisoCliente>> Function() listarAvisosRpc;
  const _FormularioAvisoScreen({
    this.aviso,
    required this.idsPrevios,
    required this.guardarAvisoRpc,
    required this.listarAvisosRpc,
  });

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
    final nivel = _importante ? 'importante' : 'info';
    // 1.29 (Oleada 6, D-B3-05): guardado VERIFICADO — si la
    // llamada falla (timeout), se comprueba si el aviso
    // aterrizó antes de ofrecer reintentar: reintentar a
    // ciegas duplicaba el aviso en la app de los clientes.
    final resultado = await guardarAvisoVerificado(
      guardar: () => widget.guardarAvisoRpc(
          id: widget.aviso?.id,
          titulo: titulo,
          cuerpo: cuerpo,
          nivel: nivel),
      listar: widget.listarAvisosRpc,
      idsPrevios: widget.idsPrevios,
      idEditado: widget.aviso?.id,
      titulo: titulo,
      cuerpo: cuerpo,
      nivel: nivel,
    );
    if (!mounted) return;
    switch (resultado) {
      case ResultadoGuardadoAviso.guardado:
        mostrarSnack(context, 'Aviso publicado',
            significado: SignificadoChip.exito);
        Navigator.pop(context, true);
      case ResultadoGuardadoAviso.noGuardado:
        setState(() => _guardando = false);
        AppLog.error('avisos_clientes', 'publicar_fallo',
            d: 'guardado no reflejado tras el fallo');
        mostrarSnack(context,
            'No se pudo publicar el aviso. Revisa la conexión '
            'e inténtalo de nuevo.',
            significado: SignificadoChip.error);
      case ResultadoGuardadoAviso.sinConfirmar:
        // No se sabe si aterrizó: se vuelve a la lista (que
        // se recarga) para comprobarlo ANTES de repetir —
        // y el mensaje dice exactamente eso.
        mostrarSnack(context,
            'No se pudo confirmar si el aviso se publicó. '
            'Revisa la lista antes de intentarlo de nuevo.',
            significado: SignificadoChip.alerta);
        Navigator.pop(context, true);
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

/// F6-20: fecha legible (d/m/aaaa, hora de La Habana) del
/// timestamp del aviso; si no se puede interpretar, se
/// devuelve el texto original recortado a la fecha.
String _fechaAviso(String ts) {
  final dt = DateTime.tryParse(ts);
  if (dt == null) return ts.length > 10 ? ts.substring(0, 10) : ts;
  return fmtFechaHabana(dt);
}
