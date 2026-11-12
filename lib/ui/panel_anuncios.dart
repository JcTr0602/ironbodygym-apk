import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../anuncios_admin.dart';
import '../auth.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'publicador_cache.dart';

/// Corrección A2-D3 (auditorías 1.28): parseo tolerante
/// de la ventana de un anuncio. El modelo ya entra
/// saneado por parseAnunciosAdmin, pero un AnuncioAdmin
/// armado a mano (o de una versión vieja) con un ISO
/// ilegible no puede tumbar la pantalla con un
/// DateTime.parse duro: degrada a «sin ventana».
DateTime? _habanaDeIso(String? iso) {
  if (iso == null) return null;
  final f = DateTime.tryParse(iso);
  return f == null ? null : aHabana(f);
}

/// 1.28 (M5, ítem fijo — Pieza G del diseño de
/// Anuncios): compositor «Anuncio a clientes» del
/// Panel (módulo «Clientes e invitados»). Crea, edita,
/// retira y borra los anuncios que la app de Clientes
/// muestra en su pantalla principal (visor de la 0.18).
///
/// Todo va por las RPC admin_anuncio_* de Supabase: la
/// guarda es_dueno() vive en el servidor y la app la
/// traduce, no la sustituye. Son operaciones de RED:
/// sin conexión la pantalla lo dice y no finge guardar
/// nada (los anuncios NO se encolan como ops: un
/// anuncio «guardado» offline llegaría tarde y mal).
/// La tarjeta de cada anuncio pinta el cuerpo con el
/// mismo MarkdownBody que verán los clientes.
/// Cargadores inyectables para los tests.
///
/// 1.32 (Oleada 2, Fase 3 — Publicador Unificado): con
/// [embebida] la pantalla es el segmento «Anuncio de
/// portada» del Publicador (sin Scaffold ni FAB: la
/// cabecera y el selector los pone la pantalla madre) y
/// el arranque pinta primero la COPIA LOCAL guardada
/// (Compuerta 3: 0 ms con sello de copia) mientras la
/// red revalida detrás con su timeout de 12 s
/// (Compuerta 4). La copia jamás se disfraza de fresca:
/// si la revalidación falla, la lista queda con el
/// sello «Sin conexión · copia de las HH:MM»; sin
/// copia, el fallo se declara como error, como siempre.
class PanelAnunciosScreen extends StatefulWidget {
  final Future<Map<String, dynamic>> Function()? cargarAnuncios;
  final Future<Map<String, dynamic>> Function(DatosAnuncio datos)?
      guardarAnuncio;
  final Future<Map<String, dynamic>> Function(int id)? borrarAnuncio;
  final Future<List<({int id, String nombre})>> Function()?
      buscarClientes;

  /// Se monta dentro del Publicador Unificado.
  final bool embebida;

  /// Costuras de la copia local (tests); null = las
  /// reales de publicador_cache sobre preferencias.
  final Future<CopiaAnuncios?> Function()? leerCopia;
  final Future<void> Function(Map<String, dynamic> json)?
      guardarCopia;

  const PanelAnunciosScreen({
    super.key,
    this.cargarAnuncios,
    this.guardarAnuncio,
    this.borrarAnuncio,
    this.buscarClientes,
    this.embebida = false,
    this.leerCopia,
    this.guardarCopia,
  });

  @override
  State<PanelAnunciosScreen> createState() =>
      _PanelAnunciosScreenState();
}

class _PanelAnunciosScreenState extends State<PanelAnunciosScreen> {
  bool _cargando = true;
  bool _falloCarga = false;
  bool _resolviendo = false;
  bool _editando = false;
  List<AnuncioAdmin> _anuncios = const [];

  /// 1.32 (Fase 3, Compuerta 3): la copia local pintada
  /// al abrir. [_horaCopia] != null = lo pintado salió
  /// de la copia; [_copiaSinRevalidar] = la red aún no
  /// ha confirmado esos datos (el sello se enseña);
  /// [_revalidando] = la confirmación está en curso
  /// (el sello dice «actualizando…»; si la red falla,
  /// pasa a «Sin conexión · copia de las HH:MM»).
  DateTime? _horaCopia;
  bool _copiaSinRevalidar = false;
  bool _revalidando = false;

  @override
  void initState() {
    super.initState();
    if (AuthService().isOwner) _arrancar();
  }

  /// Arranque en dos tiempos (Compuertas 3 y 4): la
  /// copia local pinta primero, sin esperar red; la
  /// red revalida detrás. Sin copia, el arranque es el
  /// de siempre (spinner → lista o error declarado).
  Future<void> _arrancar() async {
    try {
      final copia = await (widget.leerCopia ??
          () => leerCopiaAnuncios(AuthService().telegramId))();
      if (copia != null && mounted) {
        setState(() {
          _anuncios = parseAnunciosAdmin(copia.json);
          _cargando = false;
          _horaCopia = copia.hora;
          _copiaSinRevalidar = true;
          _revalidando = true;
        });
      }
    } catch (_) {
      // La copia nunca es un punto de fallo: sin ella,
      // la carga de red de siempre.
    }
    await _cargar(desdeArranque: true);
  }

  /// Persiste la copia tras una carga verificada. Sin
  /// await en el llamador y sin lanzar jamás: perder
  /// la copia no es un error de la pantalla.
  Future<void> _persistirCopia(Map<String, dynamic> json) async {
    try {
      await (widget.guardarCopia ??
          (j) => guardarCopiaAnuncios(
              AuthService().telegramId, j))(json);
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _cargarReal() async {
    final res = await Supabase.instance.client
        .rpc('admin_anuncios_listar')
        .timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    // Una respuesta que no es un mapa es un fallo, no
    // «sin anuncios» (misma regla que Premios/Comunidad).
    throw StateError(
        'admin_anuncios_listar: respuesta no es un mapa');
  }

  Future<Map<String, dynamic>> _guardarReal(DatosAnuncio d) async {
    final res = await Supabase.instance.client.rpc(
      'admin_anuncio_guardar',
      params: {
        'p_id': d.id,
        'p_titulo': d.titulo,
        'p_cuerpo_md': d.cuerpoMd,
        'p_audiencia': d.audiencia,
        'p_cliente_ids': d.clienteIds,
        'p_descartable': d.descartable,
        'p_desde': d.desdeHabana == null
            ? null
            : isoHabana(d.desdeHabana!),
        'p_hasta': d.hastaHabana == null
            ? null
            : isoHabana(d.hastaHabana!),
        'p_activo': d.activo,
      },
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<Map<String, dynamic>> _borrarReal(int id) async {
    final res = await Supabase.instance.client.rpc(
      'admin_anuncio_borrar',
      params: {'p_id': id},
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  /// Los clientes elegibles para la audiencia
  /// «específicos»: el espejo local, sin eliminados
  /// (los ids son los de la ficha, los mismos que la
  /// app de Clientes resuelve por su token).
  Future<List<({int id, String nombre})>> _buscarReal() async {
    final filas = await listaClientes('');
    final out = <({int id, String nombre})>[];
    for (final m in filas) {
      if (esClienteEliminado(m)) continue;
      final id = (m['id'] as num?)?.toInt() ??
          int.tryParse('${m['id'] ?? ''}');
      if (id == null) continue;
      out.add((id: id, nombre: '${m['nombre'] ?? 'Cliente'}'));
    }
    out.sort((a, b) => a.nombre.compareTo(b.nombre));
    return out;
  }

  /// [desdeArranque] con copia pintada: la revalidación
  /// NO vuelve al spinner (la copia ya está en pantalla)
  /// y un fallo NO se declara error — la copia se queda
  /// con su sello «Sin conexión». En cualquier otro
  /// caso, el comportamiento es el histórico: spinner y
  /// error declarado (error ≠ vacío, jamás).
  Future<void> _cargar({bool desdeArranque = false}) async {
    final conCopia = desdeArranque && _horaCopia != null;
    if (conCopia) {
      setState(() => _revalidando = true);
    } else {
      setState(() {
        _cargando = true;
        _falloCarga = false;
      });
    }
    void fallo() {
      _cargando = false;
      _revalidando = false;
      if (conCopia) {
        _copiaSinRevalidar = true;
      } else {
        _falloCarga = true;
      }
    }

    try {
      final json = await (widget.cargarAnuncios ?? _cargarReal)();
      if (!mounted) return;
      if (json['ok'] != true) {
        setState(fallo);
        return;
      }
      unawaited(_persistirCopia(json));
      setState(() {
        _anuncios = parseAnunciosAdmin(json);
        _cargando = false;
        _revalidando = false;
        _copiaSinRevalidar = false;
        _horaCopia = null;
      });
    } catch (_) {
      if (mounted) setState(fallo);
    }
  }

  /// Corrección A4-D4 (auditorías 1.28): guardar con
  /// comprobación tras un fallo de transporte. Una
  /// excepción de la RPC puede ser un timeout con la
  /// escritura YA aplicada en el servidor (la respuesta
  /// se perdió en la red): afirmar «no se guardó»
  /// empujaba al dueño a crear el anuncio OTRA vez y
  /// quedaban dos publicados. Ante la excepción se
  /// recarga la lista y se comprueba:
  /// - el guardado SÍ aterrizó → se devuelve ok (el
  ///   flujo sigue como un éxito normal);
  /// - la lista cargó y el guardado NO está → se
  ///   relanza la excepción (el «no se guardó» del
  ///   llamador ya es cierto);
  /// - ni la comprobación pudo cargar → se devuelve el
  ///   código SIN_CONFIRMAR: el aviso dice la verdad
  ///   (no se sabe; revisa la lista antes de repetir).
  Future<Map<String, dynamic>> _guardarVerificado(
      DatosAnuncio d) async {
    try {
      return await (widget.guardarAnuncio ?? _guardarReal)(d);
    } catch (_) {
      final List<AnuncioAdmin> lista;
      try {
        final json =
            await (widget.cargarAnuncios ?? _cargarReal)();
        if (json['ok'] != true) {
          return {'ok': false, 'error': 'SIN_CONFIRMAR'};
        }
        lista = parseAnunciosAdmin(json);
      } catch (_) {
        return {'ok': false, 'error': 'SIN_CONFIRMAR'};
      }
      if (_guardadoReflejado(lista, d)) return {'ok': true};
      rethrow;
    }
  }

  /// ¿La lista recién cargada ya refleja el guardado
  /// [d]? En una edición: la fila con su id trae el
  /// cuerpo y el estado nuevos. En una creación: hay un
  /// anuncio con el mismo cuerpo/título/audiencia cuyo
  /// id NO estaba en la lista que la pantalla tenía
  /// (un duplicado idéntico preexistente no cuenta como
  /// prueba: la prueba es que apareció uno nuevo).
  bool _guardadoReflejado(List<AnuncioAdmin> lista, DatosAnuncio d) {
    if (d.id != null) {
      for (final a in lista) {
        if (a.id == d.id) {
          return a.cuerpoMd == d.cuerpoMd && a.activo == d.activo;
        }
      }
      return false;
    }
    final previos = {for (final a in _anuncios) a.id};
    return lista.any((a) =>
        !previos.contains(a.id) &&
        a.cuerpoMd == d.cuerpoMd &&
        a.titulo == d.titulo &&
        a.audiencia == d.audiencia);
  }

  Future<void> _editar(AnuncioAdmin? inicial) async {
    if (_editando) return;
    _editando = true;
    try {
      final hecho = await showDialog<bool>(
        context: context,
        builder: (_) => _DialogoEditorAnuncio(
          inicial: inicial,
          buscarClientes: widget.buscarClientes ?? _buscarReal,
          guardar: _guardarVerificado,
        ),
      );
      if (hecho == true && mounted) {
        mostrarSnack(context, 'Anuncio guardado',
            significado: SignificadoChip.exito);
        await _cargar();
      }
    } finally {
      _editando = false;
    }
  }

  /// Retirar (activo=false) o reactivar un anuncio sin
  /// abrir el editor: viaja por la misma RPC de guardado
  /// con la foto completa del anuncio.
  Future<void> _alternarActivo(AnuncioAdmin a) async {
    if (_resolviendo) return;
    setState(() => _resolviendo = true);
    try {
      final res =
          await _guardarVerificado(_datosDe(a, activo: !a.activo));
      if (!mounted) return;
      if (res['ok'] == true) {
        setState(() {
          _anuncios = [
            for (final x in _anuncios)
              if (x.id == a.id) x.conActivo(!a.activo) else x,
          ];
        });
        mostrarSnack(
            context,
            !a.activo ? 'Anuncio publicado' : 'Anuncio retirado',
            significado: SignificadoChip.exito);
      } else {
        _avisar(mensajeErrorAnuncio(res['error']?.toString()));
      }
    } catch (_) {
      if (mounted) {
        _avisar('Sin conexión: el cambio no se aplicó.');
      }
    } finally {
      if (mounted) setState(() => _resolviendo = false);
    }
  }

  Future<void> _borrar(AnuncioAdmin a) async {
    if (_resolviendo) return;
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Borrar anuncio',
      mensaje: 'Se borra el anuncio'
          '${a.titulo != null ? ' «${a.titulo}»' : ''} '
          'del servidor. No se puede deshacer (retirarlo '
          'sí es reversible).',
      aceptar: 'Borrar',
      peligro: true,
    );
    if (!ok || !mounted) return;
    setState(() => _resolviendo = true);
    try {
      final res =
          await (widget.borrarAnuncio ?? _borrarReal)(a.id);
      if (!mounted) return;
      if (res['ok'] == true) {
        mostrarSnack(context, 'Anuncio borrado',
            significado: SignificadoChip.exito);
        await _cargar();
      } else {
        _avisar(mensajeErrorAnuncio(res['error']?.toString()));
      }
    } catch (_) {
      if (mounted) {
        _avisar('Sin conexión: el anuncio no se borró.');
      }
    } finally {
      if (mounted) setState(() => _resolviendo = false);
    }
  }

  DatosAnuncio _datosDe(AnuncioAdmin a, {required bool activo}) {
    return DatosAnuncio(
      id: a.id,
      titulo: a.titulo,
      cuerpoMd: a.cuerpoMd,
      audiencia: a.audiencia,
      clienteIds: a.clienteIds,
      descartable: a.descartable,
      desdeHabana: _habanaDeIso(a.desde),
      hastaHabana: _habanaDeIso(a.hasta),
      activo: activo,
    );
  }

  void _avisar(String texto) {
    mostrarSnack(context, texto,
        significado: SignificadoChip.error);
  }

  String _ventanaTexto(AnuncioAdmin a) {
    String? fmt(String iso) {
      final h = _habanaDeIso(iso);
      if (h == null) return null;
      return '${h.day}/${h.month}/${h.year} '
          '${h.hour.toString().padLeft(2, '0')}:'
          '${h.minute.toString().padLeft(2, '0')}';
    }

    if (a.desde == null && a.hasta == null) {
      return 'Sin ventana: visible hasta retirarlo';
    }
    final d = a.desde == null ? null : fmt(a.desde!);
    final h = a.hasta == null ? null : fmt(a.hasta!);
    if ((a.desde != null && d == null) ||
        (a.hasta != null && h == null)) {
      // Corrección A2-D3: una ventana ilegible se DICE,
      // no tumba la tarjeta (y el anuncio sigue pudiendo
      // editarse o borrarse).
      return 'Ventana con una fecha no válida: '
          'edítalo para corregirla';
    }
    if (d != null && h != null) return 'Del $d al $h';
    if (d != null) return 'Desde el $d';
    return 'Hasta el $h';
  }

  @override
  Widget build(BuildContext context) {
    // Guarda defensiva de dueño (patrón de Comunidad y
    // Premios): la tarjeta solo vive en el Panel y la
    // RPC exige es_dueno() en el servidor.
    if (!AuthService().isOwner) {
      if (widget.embebida) {
        return const Center(
            child: Text('Solo el dueño publica anuncios.'));
      }
      return Scaffold(
        appBar: appBarIron(context, 'Anuncio a clientes'),
        body: const Center(
            child:
                Text('Solo el dueño publica anuncios.')),
      );
    }
    if (widget.embebida) {
      // Segmento del Publicador: la cabecera la pone la
      // pantalla madre; el «Nuevo anuncio» del FAB vive
      // aquí como botón de la fila superior.
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.md, AppEspacio.lg, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed:
                    _resolviendo ? null : () => _editar(null),
                icon: const Icon(Icons.campaign_rounded,
                    size: 18),
                label: const Text('Nuevo anuncio'),
              ),
            ),
          ),
          Expanded(child: _cuerpo()),
        ],
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Anuncio a clientes'),
      body: _cuerpo(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _resolviendo ? null : () => _editar(null),
        icon: const Icon(Icons.campaign_rounded),
        label: const Text('Nuevo anuncio'),
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando anuncios…');
    }
    if (_falloCarga) {
      return EstadoVacio(
        icono: Icons.cloud_off_rounded,
        titulo: 'No se pudieron cargar los anuncios.',
        subtitulo: 'Los anuncios viven en el servidor: '
            'hace falta conexión.',
        textoAccion: 'Reintentar',
        onAccion: _cargar,
      );
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          // 1.32 (Fase 3): el sello de la copia — solo
          // mientras lo pintado es la copia sin
          // revalidar; con el dato fresco desaparece.
          if (_copiaSinRevalidar && _horaCopia != null) ...[
            SelloCopiaPublicador(
              hora: _horaCopia!,
              actualizando: _revalidando,
            ),
            const SizedBox(height: 12),
          ],
          const Text(
            'El anuncio aparece en la pantalla principal '
            'de la app de Clientes, tal como se ve en cada '
            'tarjeta. Se guarda en el servidor al momento: '
            'sin conexión no se puede crear ni cambiar.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          if (_anuncios.isEmpty)
            const EstadoVacio(
              icono: Icons.campaign_rounded,
              titulo: 'Sin anuncios todavía.',
              subtitulo: 'Crea el primero con «Nuevo '
                  'anuncio»: mantenimiento, novedades, '
                  'avisos del gym.',
            )
          else
            for (final a in _anuncios) ...[
              _tarjetaAnuncio(a),
              const SizedBox(height: 12),
            ],
          const SizedBox(height: 64),
        ],
      ),
    );
  }

  Widget _tarjetaAnuncio(AnuncioAdmin a) {
    final estado = a.estadoEn(ahoraUtcReal());
    final (chipTexto, chipSignificado) = switch (estado) {
      'visible' => ('Visible ahora', SignificadoChip.exito),
      'programado' => ('Programado', SignificadoChip.alerta),
      'expirado' => ('Expirado', SignificadoChip.neutral),
      _ => ('Retirado', SignificadoChip.error),
    };
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.campaign_rounded,
                  color: AppColores.naranja, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(a.titulo ?? 'Sin título',
                    style: AppTexto.subtitulo),
              ),
              ChipEstado.semantico(
                  texto: chipTexto, significado: chipSignificado),
            ],
          ),
          const SizedBox(height: 8),
          // El cuerpo TAL como lo verán los clientes: el
          // mismo render Markdown de su app.
          MarkdownBody(data: a.cuerpoMd),
          const SizedBox(height: 8),
          Text(
            '${a.audienciaTexto} · '
            '${a.descartable ? 'Descartable' : 'No descartable'}',
            style: AppTexto.secundario,
          ),
          Text(_ventanaTexto(a), style: AppTexto.secundario),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded,
                    size: 20),
                onPressed: _resolviendo ? null : () => _borrar(a),
              ),
              TextButton(
                onPressed:
                    _resolviendo ? null : () => _alternarActivo(a),
                child: Text(a.activo ? 'Retirar' : 'Reactivar'),
              ),
              const SizedBox(width: 4),
              FilledButton.icon(
                onPressed: _resolviendo ? null : () => _editar(a),
                icon: const Icon(Icons.edit_rounded, size: 18),
                label: const Text('Editar'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Editor de un anuncio (nuevo o existente).
/// StatefulWidget con dispose (regla de la casa). La
/// vista previa usa el mismo MarkdownBody que la app
/// de Clientes: lo que se ve aquí es lo que verán.
class _DialogoEditorAnuncio extends StatefulWidget {
  final AnuncioAdmin? inicial;
  final Future<List<({int id, String nombre})>> Function()
      buscarClientes;
  final Future<Map<String, dynamic>> Function(DatosAnuncio datos)
      guardar;

  const _DialogoEditorAnuncio({
    required this.inicial,
    required this.buscarClientes,
    required this.guardar,
  });

  @override
  State<_DialogoEditorAnuncio> createState() =>
      _DialogoEditorAnuncioState();
}

class _DialogoEditorAnuncioState extends State<_DialogoEditorAnuncio> {
  late final TextEditingController _tituloCtrl;
  late final TextEditingController _cuerpoCtrl;
  final _busquedaCtrl = TextEditingController();
  late String _audiencia;
  late bool _descartable;
  late bool _activo;
  late bool _vistaPrevia;
  DateTime? _desde;
  DateTime? _hasta;
  final Set<int> _elegidos = {};
  List<({int id, String nombre})> _clientes = const [];
  bool _cargandoClientes = false;
  String? _error;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    final a = widget.inicial;
    _tituloCtrl = TextEditingController(text: a?.titulo ?? '');
    _cuerpoCtrl = TextEditingController(text: a?.cuerpoMd ?? '');
    _audiencia = a?.audiencia ?? 'todos';
    _descartable = a?.descartable ?? true;
    _activo = a?.activo ?? true;
    _vistaPrevia = false;
    _desde = _habanaDeIso(a?.desde);
    _hasta = _habanaDeIso(a?.hasta);
    if (a != null) _elegidos.addAll(a.clienteIds);
    if (_audiencia == 'especificos') _cargarClientes();
  }

  @override
  void dispose() {
    _tituloCtrl.dispose();
    _cuerpoCtrl.dispose();
    _busquedaCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarClientes() async {
    if (_cargandoClientes || _clientes.isNotEmpty) return;
    setState(() => _cargandoClientes = true);
    try {
      final lista = await widget.buscarClientes();
      if (mounted) {
        setState(() {
          _clientes = lista;
          _cargandoClientes = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargandoClientes = false);
    }
  }

  Future<void> _elegirFecha(bool esDesde) async {
    final actual = esDesde ? _desde : _hasta;
    final hoy = ahoraHabana();
    final fecha = await showDatePicker(
      context: context,
      initialDate: actual ?? hoy,
      firstDate: DateTime(2025),
      lastDate: DateTime(2031),
    );
    if (fecha == null || !mounted) return;
    final hora = await showTimePicker(
      context: context,
      initialTime: actual != null
          ? TimeOfDay(hour: actual.hour, minute: actual.minute)
          : const TimeOfDay(hour: 8, minute: 0),
    );
    if (hora == null || !mounted) return;
    setState(() {
      final valor =
          DateTime(fecha.year, fecha.month, fecha.day, hora.hour, hora.minute);
      if (esDesde) {
        _desde = valor;
      } else {
        _hasta = valor;
      }
    });
  }

  String _fechaTexto(DateTime? v) {
    if (v == null) return 'Sin fecha';
    return '${v.day}/${v.month}/${v.year} '
        '${v.hour.toString().padLeft(2, '0')}:'
        '${v.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _enviar() async {
    final cuerpo = _cuerpoCtrl.text;
    String? error;
    if (cuerpo.trim().isEmpty) {
      error = 'Escribe el texto del anuncio.';
    } else if (cuerpo.length > 4000) {
      error = 'El texto no puede pasar de 4000 caracteres.';
    } else if (_audiencia == 'especificos' && _elegidos.isEmpty) {
      error = 'Elige al menos un cliente para este anuncio.';
    } else if (_desde != null &&
        _hasta != null &&
        !_hasta!.isAfter(_desde!)) {
      error = 'La fecha «hasta» debe ser posterior a «desde».';
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
      final titulo = _tituloCtrl.text.trim();
      final res = await widget.guardar(DatosAnuncio(
        id: widget.inicial?.id,
        titulo: titulo.isEmpty ? null : titulo,
        cuerpoMd: cuerpo,
        audiencia: _audiencia,
        clienteIds: _audiencia == 'especificos'
            ? _elegidos.toList()
            : const [],
        descartable: _descartable,
        desdeHabana: _desde,
        hastaHabana: _hasta,
        activo: _activo,
      ));
      if (!mounted) return;
      if (res['ok'] == true) {
        Navigator.pop(context, true);
        return;
      }
      setState(() {
        _guardando = false;
        _error = mensajeErrorAnuncio(res['error']?.toString());
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = 'Sin conexión con el servidor: el '
              'anuncio no se guardó.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = _busquedaCtrl.text.trim().toLowerCase();
    final clientesVisibles = q.isEmpty
        ? _clientes
        : _clientes
            .where((c) => c.nombre.toLowerCase().contains(q))
            .toList();
    return DialogoApp(
      titulo: widget.inicial == null
          ? 'Nuevo anuncio'
          : 'Editar anuncio',
      iconoTitulo: Icons.campaign_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CampoTexto(
              controller: _tituloCtrl,
              etiqueta: 'Título (opcional, hasta 120 caracteres)',
            ),
            const SizedBox(height: 8),
            CampoTexto(
              controller: _cuerpoCtrl,
              etiqueta: 'Texto del anuncio (Markdown)',
              maxLineas: 6,
              onChanged: (_) => setState(() {}),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Text('${_cuerpoCtrl.text.length} / 4000',
                  style: AppTexto.secundario),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Vista previa'),
              subtitle: const Text(
                  'Así lo verán en la app de Clientes'),
              value: _vistaPrevia,
              onChanged: (v) => setState(() => _vistaPrevia = v),
            ),
            if (_vistaPrevia)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppEspacio.md),
                  child: MarkdownBody(
                    data: _cuerpoCtrl.text.isEmpty
                        ? '_(sin texto todavía)_'
                        : _cuerpoCtrl.text,
                  ),
                ),
              ),
            const SizedBox(height: 4),
            const Text('¿Quién lo ve?', style: AppTexto.cuerpo),
            RadioGroup<String>(
              groupValue: _audiencia,
              onChanged: (v) {
                if (v == null) return;
                setState(() => _audiencia = v);
                if (v == 'especificos') _cargarClientes();
              },
              child: const Column(
                children: [
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: 'todos',
                    title: Text('Todos (clientes e invitados)'),
                  ),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: 'clientes',
                    title: Text('Solo clientes'),
                  ),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: 'invitados',
                    title: Text('Solo invitados'),
                  ),
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: 'especificos',
                    title: Text('Solo algunos clientes'),
                  ),
                ],
              ),
            ),
            if (_audiencia == 'especificos') ...[
              CampoTexto(
                controller: _busquedaCtrl,
                etiqueta: 'Buscar cliente',
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 4),
              Text(
                _elegidos.isEmpty
                    ? 'Ningún cliente elegido todavía'
                    : '${_elegidos.length} cliente(s) elegido(s)',
                style: AppTexto.secundario,
              ),
              if (_cargandoClientes)
                const Padding(
                  padding: EdgeInsets.all(AppEspacio.md),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                // Columna, no ListView: el contenido del
                // diálogo ya se desplaza con el
                // SingleChildScrollView exterior y un
                // viewport shrinkWrap revienta los
                // intrínsecos del AlertDialog.
                Column(
                  children: [
                    for (final c in clientesVisibles)
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(c.nombre),
                        value: _elegidos.contains(c.id),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _elegidos.add(c.id);
                          } else {
                            _elegidos.remove(c.id);
                          }
                        }),
                      ),
                  ],
                ),
            ],
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('El cliente puede descartarlo'),
              value: _descartable,
              onChanged: (v) => setState(() => _descartable = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Publicado'),
              subtitle: const Text(
                  'Apagado = retirado (no lo ve nadie)'),
              value: _activo,
              onChanged: (v) => setState(() => _activo = v),
            ),
            const SizedBox(height: 4),
            const Text('Vigencia (hora de La Habana)',
                style: AppTexto.cuerpo),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                    child: Text('Desde: ${_fechaTexto(_desde)}')),
                TextButton(
                  onPressed: () => _elegirFecha(true),
                  child: const Text('Elegir'),
                ),
                if (_desde != null)
                  TextButton(
                    onPressed: () => setState(() => _desde = null),
                    child: const Text('Quitar'),
                  ),
              ],
            ),
            Row(
              children: [
                Expanded(
                    child: Text('Hasta: ${_fechaTexto(_hasta)}')),
                TextButton(
                  onPressed: () => _elegirFecha(false),
                  child: const Text('Elegir'),
                ),
                if (_hasta != null)
                  TextButton(
                    onPressed: () => setState(() => _hasta = null),
                    child: const Text('Quitar'),
                  ),
              ],
            ),
            Text(
              _desde == null && _hasta == null
                  ? 'Sin fechas: se publica al guardar y no '
                      'expira solo.'
                  : 'Editar un anuncio lo re-publica para '
                      'quien lo había descartado.',
              style: AppTexto.secundario,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: AppTexto.secundario
                      .copyWith(color: AppColores.error)),
            ],
          ],
        ),
      ),
      acciones: [
        TextButton(
            onPressed:
                _guardando ? null : () => Navigator.pop(context, false),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _guardando ? null : _enviar,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
          ),
          child: Text(_guardando ? 'Guardando…' : 'Guardar anuncio'),
        ),
      ],
    );
  }
}
