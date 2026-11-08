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
///
/// 1.29 (Oleada 7, FB-22): el aviso gana fecha de fin
/// OPCIONAL («dejarse de mostrar el [fecha]»): viaja en el
/// documento como fecha civil de La Habana (AAAA-MM-DD) y el
/// servidor deja de entregarlo al terminar ese día
/// (23:59:59.999 hora de La Habana, calculado en
/// avisos_delta). Sin fecha = se retira a mano, como antes.
library;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../app_log.dart';
import '../auth.dart';
import '../tiempo.dart' show ahoraHabana, fmtFechaHabana, hoyHabanaIso;
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

class AvisoCliente {
  final int id;
  final String titulo;
  final String cuerpo;
  final String nivel;
  final String creadoTs;

  /// 1.29 (FB-22): fecha de fin opcional, 'AAAA-MM-DD'
  /// (fecha civil de La Habana). null = sin fecha.
  final String? fechaFin;

  const AvisoCliente({
    required this.id,
    required this.titulo,
    required this.cuerpo,
    required this.nivel,
    required this.creadoTs,
    this.fechaFin,
  });

  bool get importante => nivel == 'importante';

  factory AvisoCliente.fromJson(Map<String, dynamic> j) {
    final ff = '${j['fecha_fin'] ?? ''}'.trim();
    return AvisoCliente(
      id: (j['id'] as num?)?.toInt() ?? 0,
      titulo: '${j['titulo'] ?? ''}',
      cuerpo: '${j['cuerpo'] ?? ''}',
      nivel: '${j['nivel'] ?? 'info'}',
      creadoTs: '${j['creado_ts'] ?? ''}',
      fechaFin: ff.isEmpty ? null : ff,
    );
  }
}

/// FB-22: el día elegido → 'AAAA-MM-DD' (los componentes
/// del día, sin convertir zonas: es una fecha civil).
String fechaFinIsoDe(DateTime dia) =>
    '${dia.year.toString().padLeft(4, '0')}-'
    '${dia.month.toString().padLeft(2, '0')}-'
    '${dia.day.toString().padLeft(2, '0')}';

/// FB-22: 'AAAA-MM-DD' → 'd/m/aaaa' por componentes (NO se
/// usa fmtFechaHabana: convertir el instante de zona
/// correría el día; la fecha civil se lee tal cual).
String textoFechaFin(String fechaFin) {
  final d = DateTime.tryParse(fechaFin);
  if (d == null) return fechaFin;
  return '${d.day}/${d.month}/${d.year}';
}

/// FB-22: la leyenda de la fecha de fin en la lista —
/// futura (o de hoy) se anuncia; pasada se dice en pasado:
/// el servidor ya no lo entrega, y la lista del editor lo
/// sigue enseñando para que el dueño lo retire o lo edite.
/// La comparación es de fechas civiles AAAA-MM-DD (el
/// orden lexicográfico ES el cronológico en ese formato).
String etiquetaFechaFin(String fechaFin, {String? hoyIso}) {
  final hoy = hoyIso ?? hoyHabanaIso();
  return fechaFin.compareTo(hoy) < 0
      ? 'Dejó de mostrarse el ${textoFechaFin(fechaFin)}'
      : 'Se deja de mostrar el ${textoFechaFin(fechaFin)}';
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
/// 1.29 (FB-22): la comparación incluye la fecha de fin —
/// un guardado que aterrizó SIN la fecha pedida no cuenta
/// como reflejado (el dueño reintenta en vez de creer que
/// el aviso caducará cuando no es verdad).
bool avisoReflejaGuardado({
  required List<AvisoCliente> lista,
  required Set<int> idsPrevios,
  required int? idEditado,
  required String titulo,
  required String cuerpo,
  required String nivel,
  String? fechaFin,
}) {
  if (idEditado != null) {
    for (final a in lista) {
      if (a.id == idEditado) {
        return a.titulo == titulo &&
            a.cuerpo == cuerpo &&
            a.nivel == nivel &&
            a.fechaFin == fechaFin;
      }
    }
    return false;
  }
  return lista.any((a) =>
      !idsPrevios.contains(a.id) &&
      a.titulo == titulo &&
      a.cuerpo == cuerpo &&
      a.nivel == nivel &&
      a.fechaFin == fechaFin);
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
  String? fechaFin,
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
          fechaFin: fechaFin,
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
      required String nivel,
      String? fechaFin})? guardarAvisoRpc;
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
      required String nivel,
      String? fechaFin}) async {
    await Supabase.instance.client.rpc('admin_guardar_aviso', params: {
      'p_id': id,
      'p_titulo': titulo,
      'p_cuerpo': cuerpo,
      'p_nivel': nivel,
      // 1.29 (FB-22): 'AAAA-MM-DD' o null (sin fecha). La
      // firma del servidor es única con el parámetro en
      // default NULL: la app vieja, que no lo manda, sigue
      // guardando sin fecha.
      'p_fecha_fin': fechaFin,
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
                                    if (a.fechaFin != null) ...[
                                      const SizedBox(height: 2),
                                      // 1.29 (FB-22): la fecha
                                      // de fin se lee en la
                                      // tarjeta (en pasado si
                                      // el servidor ya dejó de
                                      // entregarlo).
                                      Text(
                                        etiquetaFechaFin(
                                            a.fechaFin!),
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
      required String nivel,
      String? fechaFin}) guardarAvisoRpc;
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

  /// 1.29 (FB-22): el día elegido como fecha de fin
  /// (solo el día; la hora la pone el servidor: el aviso
  /// se muestra durante todo ese día, hora de La Habana).
  /// null = sin fecha de fin.
  DateTime? _fechaFinDia;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _tituloCtrl = TextEditingController(text: widget.aviso?.titulo ?? '');
    _cuerpoCtrl = TextEditingController(text: widget.aviso?.cuerpo ?? '');
    _importante = widget.aviso?.importante ?? false;
    final ff = widget.aviso?.fechaFin;
    final d = ff == null ? null : DateTime.tryParse(ff);
    _fechaFinDia = d == null ? null : DateTime(d.year, d.month, d.day);
  }

  @override
  void dispose() {
    _tituloCtrl.dispose();
    _cuerpoCtrl.dispose();
    super.dispose();
  }

  /// FB-22: el selector de fecha de fin. No se ofrecen
  /// días pasados (el servidor los rechaza: nadie vería
  /// el aviso). Hoy sí vale: caduca esta noche.
  Future<void> _elegirFechaFin() async {
    final h = ahoraHabana();
    final hoy = DateTime(h.year, h.month, h.day);
    // 1.29 (ajuste de Argón al código, H-01): un aviso YA
    // VENCIDO trae su fecha en el pasado, y showDatePicker
    // exige initialDate >= firstDate: sin acotar, tocar
    // «Cambiar» reventaba con un AssertionError. La inicial
    // se acota al suelo de hoy.
    final inicial = (_fechaFinDia != null &&
            !_fechaFinDia!.isBefore(hoy))
        ? _fechaFinDia!
        : hoy;
    final elegida = await showDatePicker(
      context: context,
      initialDate: inicial,
      firstDate: hoy,
      lastDate: hoy.add(const Duration(days: 366)),
      helpText: 'Dejarse de mostrar el',
    );
    if (elegida != null && mounted) {
      setState(() => _fechaFinDia =
          DateTime(elegida.year, elegida.month, elegida.day));
    }
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
    // 1.29 (ajuste de Argón al código, H-01): una fecha de
    // fin que ya pasó NUNCA viaja a la RPC (el servidor la
    // rechaza y el aviso reviviría sin caducar): se pide
    // elegir una vigente o quitarla antes de guardar.
    if (_fechaFinDia != null) {
      final h = ahoraHabana();
      final hoy = DateTime(h.year, h.month, h.day);
      if (_fechaFinDia!.isBefore(hoy)) {
        mostrarSnack(context,
            'La fecha de fin ya pasó. Elige una fecha '
            'vigente o quita la fecha para guardar.',
            significado: SignificadoChip.alerta);
        return;
      }
    }
    setState(() => _guardando = true);
    final nivel = _importante ? 'importante' : 'info';
    // 1.29 (FB-22): la fecha viaja como 'AAAA-MM-DD'.
    final fechaFinIso =
        _fechaFinDia == null ? null : fechaFinIsoDe(_fechaFinDia!);
    // 1.29 (Oleada 6, D-B3-05): guardado VERIFICADO — si la
    // llamada falla (timeout), se comprueba si el aviso
    // aterrizó antes de ofrecer reintentar: reintentar a
    // ciegas duplicaba el aviso en la app de los clientes.
    final resultado = await guardarAvisoVerificado(
      guardar: () => widget.guardarAvisoRpc(
          id: widget.aviso?.id,
          titulo: titulo,
          cuerpo: cuerpo,
          nivel: nivel,
          fechaFin: fechaFinIso),
      listar: widget.listarAvisosRpc,
      idsPrevios: widget.idsPrevios,
      idEditado: widget.aviso?.id,
      titulo: titulo,
      cuerpo: cuerpo,
      nivel: nivel,
      fechaFin: fechaFinIso,
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
          const SizedBox(height: AppEspacio.md),
          // 1.29 (FB-22): fecha de fin opcional.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.event_rounded,
                  color: AppColores.naranja),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Dejarse de mostrar el',
                        style: AppTexto.subtitulo),
                    const SizedBox(height: 2),
                    Text(
                      _fechaFinDia == null
                          ? 'Sin fecha de fin: se muestra hasta '
                              'que lo retires a mano.'
                          : '${textoFechaFin(fechaFinIsoDe(_fechaFinDia!))}'
                              ' — se muestra durante todo ese día '
                              'y deja de entregarse al terminar '
                              '(hora de La Habana).',
                      style: AppTexto.metadato,
                    ),
                  ],
                ),
              ),
              if (_fechaFinDia == null)
                TextButton(
                  onPressed: _guardando ? null : _elegirFechaFin,
                  child: const Text('Elegir fecha'),
                )
              else ...[
                TextButton(
                  onPressed: _guardando ? null : _elegirFechaFin,
                  child: const Text('Cambiar'),
                ),
                TextButton(
                  onPressed: _guardando
                      ? null
                      : () => setState(() => _fechaFinDia = null),
                  child: const Text('Quitar'),
                ),
              ],
            ],
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
