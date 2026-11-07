/// 1.24 Bloque 6 (ítem 17 del Panel): editor de «Rutinas del
/// gym» — el banco de rutinas que la app de clientes ofrece
/// en «Del gym» para adoptar con un toque (Fase B de Rutinas).
///
/// El contenido vive SOLO en el servidor (sync_rutinas_gym):
/// se lee y se escribe por las RPC admin_* (guarda es_admin()
/// en el servidor; esta pantalla además se protege a sí misma
/// como solo-dueño). Cada rutina es un nombre + la lista
/// ORDENADA de fichas de la Guía de musculación que la
/// componen; el catálogo sale del espejo local guia_fichas
/// (las publicadas), con el id CANÓNICO '${equipoId}_$slug'
/// que la app de clientes cruza contra su guiaCatalogo al
/// adoptar. (1.24.1, Argón G-09→G-07: la primera versión leía
/// gympedia_articulos — los artículos de LECTURA — y toda
/// rutina publicada era inadoptable.) Sin conexión, la
/// pantalla muestra el error con reintento: nunca un spinner
/// eterno ni datos inventados.
library;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth.dart';
import '../localdb.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'skeleton.dart';
import 'diseno.dart';

/// Una serie prescrita (0.15 Bloque 3, Parte B): la forma
/// JSON es IDÉNTICA a la SerieRutina de la app de clientes
/// (tipo/peso_kg/reps_min/reps_max) para que el contenido
/// viaje sin traducción servidor → cliente.
class SerieGymAdmin {
  final String tipo;
  final double? pesoKg;
  final int repsMin;
  final int? repsMax;

  const SerieGymAdmin({
    this.tipo = 'normal',
    this.pesoKg,
    required this.repsMin,
    this.repsMax,
  });

  factory SerieGymAdmin.fromJson(Map<String, dynamic> j) {
    final min = (j['reps_min'] as num?)?.toInt() ?? 10;
    var max = (j['reps_max'] as num?)?.toInt();
    if (max != null && max < min) max = min;
    const tipos = ['normal', 'calentamiento', 'fallo', 'drop'];
    final tipo = '${j['tipo'] ?? 'normal'}';
    return SerieGymAdmin(
      tipo: tipos.contains(tipo) ? tipo : 'normal',
      pesoKg: (j['peso_kg'] as num?)?.toDouble(),
      repsMin: min,
      repsMax: max,
    );
  }

  Map<String, dynamic> toJson() => {
        'tipo': tipo,
        if (pesoKg != null) 'peso_kg': pesoKg,
        'reps_min': repsMin,
        'reps_max': repsMax ?? repsMin,
      };
}

/// Un ejercicio de la rutina con sus series prescritas.
class EjercicioGymAdmin {
  final String fichaId;
  final int? descansoSeg;
  final String nota;
  final List<SerieGymAdmin> series;

  const EjercicioGymAdmin({
    required this.fichaId,
    this.descansoSeg,
    this.nota = '',
    required this.series,
  });

  /// Las series con las que nace un ejercicio recién
  /// añadido: 3 × 10 sin peso (Jc las ajusta en el editor).
  static const seriesPorDefecto = [
    SerieGymAdmin(repsMin: 10),
    SerieGymAdmin(repsMin: 10),
    SerieGymAdmin(repsMin: 10),
  ];

  factory EjercicioGymAdmin.desdeFicha(String fichaId) =>
      EjercicioGymAdmin(
          fichaId: fichaId, series: List.of(seriesPorDefecto));

  factory EjercicioGymAdmin.fromJson(Map<String, dynamic> j) {
    final series = <SerieGymAdmin>[];
    final crudas = j['series'];
    if (crudas is List) {
      for (final s in crudas) {
        if (s is Map) {
          series.add(SerieGymAdmin.fromJson(
              Map<String, dynamic>.from(s)));
        }
      }
    }
    return EjercicioGymAdmin(
      fichaId: '${j['ficha_id'] ?? ''}',
      descansoSeg: (j['descanso_seg'] as num?)?.toInt(),
      nota: '${j['nota'] ?? ''}',
      series: series.isEmpty ? List.of(seriesPorDefecto) : series,
    );
  }

  Map<String, dynamic> toJson() => {
        'ficha_id': fichaId,
        if (descansoSeg != null) 'descanso_seg': descansoSeg,
        if (nota.isNotEmpty) 'nota': nota,
        'series': series.map((s) => s.toJson()).toList(),
      };
}

class RutinaGymAdmin {
  final int id;
  final String nombre;
  final List<String> fichaIds;

  /// El contenido v2 (nota general + ejercicios con
  /// series) o null si la rutina es v1 (solo fichas).
  final String nota;
  final List<EjercicioGymAdmin>? ejercicios;

  const RutinaGymAdmin({
    required this.id,
    required this.nombre,
    required this.fichaIds,
    this.nota = '',
    this.ejercicios,
  });

  bool get esV2 => ejercicios != null;

  factory RutinaGymAdmin.fromJson(Map<String, dynamic> j) {
    final crudo = j['ficha_ids'];
    List<EjercicioGymAdmin>? ejercicios;
    var nota = '';
    final contenido = j['contenido'];
    if (contenido is Map) {
      nota = '${contenido['nota'] ?? ''}';
      final lista = contenido['ejercicios'];
      if (lista is List) {
        ejercicios = [
          for (final e in lista)
            if (e is Map)
              EjercicioGymAdmin.fromJson(
                  Map<String, dynamic>.from(e)),
        ];
      }
    }
    return RutinaGymAdmin(
      id: (j['id'] as num?)?.toInt() ?? 0,
      nombre: '${j['nombre'] ?? ''}',
      fichaIds: crudo is List
          ? crudo.map((e) => e.toString()).toList()
          : const [],
      nota: nota,
      ejercicios: ejercicios,
    );
  }

  /// El JSON del parámetro p_contenido del RPC.
  static Map<String, dynamic> contenidoJson(
          List<EjercicioGymAdmin> ejercicios, String nota) =>
      {
        if (nota.isNotEmpty) 'nota': nota,
        'ejercicios': ejercicios.map((e) => e.toJson()).toList(),
      };
}

/// Una ficha del catálogo de la Guía de musculación
/// (espejo local guia_fichas, solo publicadas).
class FichaCatalogo {
  /// Id CANÓNICO '${equipoId}_$slug': el que la app de
  /// clientes espera en ficha_ids al adoptar la rutina.
  final String id;
  final String titulo;
  const FichaCatalogo({required this.id, required this.titulo});
}

/// La identidad canónica con la que una ficha del espejo
/// entra en las rutinas: '${equipoId}_$slug', EXCEPTO cuando
/// el documento declara `idCanonico`. Dos fichas del
/// catálogo de Clientes comparten slug con distinto equipo
/// (peso-muerto-rumano con barra y con mancuernas) y la PK
/// de la tubería es el slug a secas: la segunda viaja con un
/// slug alias y su `idCanonico` es el id EXACTO que la app
/// de clientes cruza contra su catálogo embebido. Un
/// idCanonico cuyo prefijo no sea el equipoId de la propia
/// fila NO se honra (defensa contra un documento cruzado o
/// corrupto): se cae al compuesto de siempre.
String idCanonicoFichaGuia(
    String slug, String equipoId, dynamic declarado) {
  final compuesto = '${equipoId}_$slug';
  final d = '${declarado ?? ''}'.trim();
  if (d.isEmpty || d == compuesto) return compuesto;
  final prefijo = '${equipoId}_';
  if (!d.startsWith(prefijo)) return compuesto;
  final resto = d.substring(prefijo.length);
  if (resto.isEmpty || resto.contains('_')) return compuesto;
  return d;
}

/// Convierte las filas del espejo (guiaPublicadas) en el
/// catálogo del editor de rutinas. Función pura: la usa
/// _cargarCatalogo y la congelan los tests de colisión de
/// slug (guia_id_canonico_test.dart).
List<FichaCatalogo> fichasCatalogoDesdeEspejo(
    List<Map<String, dynamic>> filas) {
  final out = <FichaCatalogo>[];
  for (final f in filas) {
    final slug = '${f['id'] ?? ''}'.trim();
    final equipoId = '${f['equipoId'] ?? ''}'.trim();
    if (slug.isEmpty || equipoId.isEmpty) continue;
    final titulo = '${f['titulo'] ?? ''}'.trim();
    out.add(FichaCatalogo(
      id: idCanonicoFichaGuia(slug, equipoId, f['idCanonico']),
      titulo: titulo.isEmpty ? slug : titulo,
    ));
  }
  out.sort((a, b) => a.titulo.compareTo(b.titulo));
  return out;
}

Future<List<FichaCatalogo>> _cargarCatalogo() async {
  // 1.24.1 (Argón G-07): la fuente son las fichas PUBLICADAS
  // de la Guía (guiaPublicadas ya decodifica el espejo y
  // deja el slug en 'id'; el equipoId viaja en el data). Una
  // ficha sin equipoId no tiene id canónico: no entra (el
  // cliente tampoco podría cruzarla).
  final filas = await LocalDb.instance.guiaPublicadas();
  return fichasCatalogoDesdeEspejo(filas);
}

class EditorRutinasGymScreen extends StatefulWidget {
  const EditorRutinasGymScreen({super.key});

  @override
  State<EditorRutinasGymScreen> createState() =>
      _EditorRutinasGymScreenState();
}

class _EditorRutinasGymScreenState extends State<EditorRutinasGymScreen> {
  List<RutinaGymAdmin> _rutinas = [];
  bool _cargando = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    if (mounted) {
      setState(() {
        _cargando = true;
        _error = false;
      });
    }
    try {
      final res = await Supabase.instance.client
          .rpc('admin_listar_rutinas')
          .timeout(const Duration(seconds: 12));
      final lista = ((res as List?) ?? const [])
          .map((e) =>
              RutinaGymAdmin.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!mounted) return;
      setState(() {
        _rutinas = lista;
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

  Future<void> _abrirFormulario([RutinaGymAdmin? rutina]) async {
    final cambiado = await Navigator.push<bool>(
      context,
      RutaIron(
        builder: (_) => _FormularioRutinaScreen(rutina: rutina),
      ),
    );
    if (cambiado == true && mounted) await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Rutinas del gym'),
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño',
          subtitulo: 'Las rutinas del gym las publica el dueño.',
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Rutinas del gym'),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrirFormulario(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nueva rutina'),
      ),
      body: _cargando
          // 1.25 T114: esqueleto con la forma de la lista.
          ? const Padding(
              padding: EdgeInsets.all(AppEspacio.lg),
              child: SkeletonLista(items: 3))
          : _error
              ? EstadoError(
                  titulo: 'No se pudieron cargar las rutinas',
                  detalle: 'Las rutinas viven en el servidor: '
                      'revisa la conexión e inténtalo de nuevo.',
                  onReintentar: _cargar,
                )
              : _rutinas.isEmpty
                  ? const EstadoVacio(
                      icono: Icons.fitness_center_rounded,
                      titulo: 'Sin rutinas del gym',
                      subtitulo: 'Arma la primera rutina con '
                          'fichas de GymPedia para que los '
                          'clientes la adopten desde su app.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(AppEspacio.lg),
                      itemCount: _rutinas.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: AppEspacio.sm),
                      itemBuilder: (ctx, i) {
                        final r = _rutinas[i];
                        return Tarjeta(
                          onTap: () => _abrirFormulario(r),
                          child: Row(
                            children: [
                              const Icon(Icons.fitness_center_rounded,
                                  color: AppColores.naranja),
                              const SizedBox(width: AppEspacio.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(r.nombre,
                                        style: AppTexto.subtitulo),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${r.fichaIds.length} ejercicio'
                                      '${r.fichaIds.length == 1 ? '' : 's'}'
                                      '${r.esV2 ? ' · con series puestas' : ''}',
                                      style: AppTexto.secundario,
                                    ),
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

class _FormularioRutinaScreen extends StatefulWidget {
  final RutinaGymAdmin? rutina;
  const _FormularioRutinaScreen({this.rutina});

  @override
  State<_FormularioRutinaScreen> createState() =>
      _FormularioRutinaScreenState();
}

class _FormularioRutinaScreenState extends State<_FormularioRutinaScreen> {
  late final TextEditingController _nombreCtrl;
  late final TextEditingController _notaCtrl;
  List<FichaCatalogo> _catalogo = [];

  /// Bloque 3: la rutina se edita como ejercicios con
  /// series (v2). Una rutina v1 entra con las series por
  /// defecto sembradas en memoria, pero si Jc no toca ni
  /// las fichas ni las series se guarda COMO v1 (el
  /// servidor no recibe contenido): publicar no debe
  /// imponer series que nadie decidió.
  final List<EjercicioGymAdmin> _ejercicios = [];
  late final List<String> _fichasIniciales;
  late final bool _eraV2;
  bool _seriesEditadas = false;
  bool _cargandoCatalogo = true;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    final r = widget.rutina;
    _nombreCtrl = TextEditingController(text: r?.nombre ?? '');
    _notaCtrl = TextEditingController(text: r?.nota ?? '');
    _eraV2 = r?.esV2 ?? false;
    _fichasIniciales = List.of(r?.fichaIds ?? const []);
    if (r != null && r.ejercicios != null) {
      _ejercicios.addAll(r.ejercicios!);
    } else {
      for (final id in _fichasIniciales) {
        _ejercicios.add(EjercicioGymAdmin.desdeFicha(id));
      }
    }
    _cargarCatalogo().then((lista) {
      if (!mounted) return;
      setState(() {
        _catalogo = lista;
        _cargandoCatalogo = false;
      });
    });
  }

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  String _tituloDe(String id) {
    for (final f in _catalogo) {
      if (f.id == id) return f.titulo;
    }
    return id;
  }

  List<String> get _seleccion =>
      _ejercicios.map((e) => e.fichaId).toList();

  bool get _fichasCambiaron {
    final ahora = _seleccion;
    if (ahora.length != _fichasIniciales.length) return true;
    for (var i = 0; i < ahora.length; i++) {
      if (ahora[i] != _fichasIniciales[i]) return true;
    }
    return false;
  }

  /// ¿Se manda p_contenido? Solo si la rutina ya era v2 o
  /// Jc tocó las fichas o las series en esta edición.
  bool get _enviaContenido =>
      _eraV2 || _seriesEditadas || _fichasCambiaron;

  Future<void> _elegirFichas() async {
    final elegidas = await Navigator.push<List<String>>(
      context,
      RutaIron(
        builder: (_) => _SelectorFichasScreen(
          catalogo: _catalogo,
          seleccionInicial: _seleccion,
        ),
      ),
    );
    if (elegidas == null || !mounted) return;
    setState(() {
      // Conservar las series ya editadas de las fichas que
      // siguen; las nuevas nacen con las de por defecto.
      final porId = {for (final e in _ejercicios) e.fichaId: e};
      _ejercicios
        ..clear()
        ..addAll([
          for (final id in elegidas)
            porId[id] ?? EjercicioGymAdmin.desdeFicha(id),
        ]);
    });
  }

  Future<void> _guardar() async {
    // Anti-doble-toque síncrono (ítem 5).
    if (_guardando) return;
    final nombre = _nombreCtrl.text.trim();
    if (nombre.isEmpty) {
      mostrarSnack(context, 'La rutina necesita un nombre',
          significado: SignificadoChip.alerta);
      return;
    }
    if (_seleccion.isEmpty) {
      mostrarSnack(context, 'Elige al menos una ficha de GymPedia',
          significado: SignificadoChip.alerta);
      return;
    }
    setState(() => _guardando = true);
    try {
      await Supabase.instance.client
          .rpc('admin_guardar_rutina', params: {
            'p_id': widget.rutina?.id,
            'p_nombre': nombre,
            'p_ficha_ids': _seleccion,
            // Bloque 3: el contenido v2 solo viaja cuando
            // aplica (ver _enviaContenido); el servidor lo
            // sanea y DERIVA ficha_ids de él.
            if (_enviaContenido)
              'p_contenido': RutinaGymAdmin.contenidoJson(
                  _ejercicios, _notaCtrl.text.trim()),
          })
          // 1.24 Bloque 4: timeout de escritura (12 s).
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      mostrarSnack(context, 'Rutina publicada',
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
    final rutina = widget.rutina;
    if (rutina == null || _guardando) return;
    // Escalera de confirmaciones (ítem 2): retirar es
    // destructivo → confirmación explícita en rojo.
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Retirar rutina',
      mensaje: '«${rutina.nombre}» dejará de ofrecerse en el '
          'banco «Del gym» de la app de clientes. Las rutinas que '
          'un cliente ya adoptó NO se le borran.',
      aceptar: 'Retirar',
      icono: Icons.delete_outline_rounded,
      peligro: true,
    );
    if (ok != true || !mounted) return;
    setState(() => _guardando = true);
    try {
      await Supabase.instance.client
          .rpc('admin_retirar_rutina', params: {'p_id': rutina.id})
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      mostrarSnack(context, 'Rutina retirada',
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
    final esEdicion = widget.rutina != null;
    return Scaffold(
      appBar: appBarIron(
          context, esEdicion ? 'Editar rutina' : 'Nueva rutina'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          TextField(
            controller: _nombreCtrl,
            decoration: const InputDecoration(
              labelText: 'Nombre de la rutina',
              hintText: 'Ej.: Pecho y tríceps — nivel inicial',
            ),
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: AppEspacio.md),
          TextField(
            controller: _notaCtrl,
            decoration: const InputDecoration(
              labelText: 'Nota para el cliente (opcional)',
              hintText: 'Ej.: Sube peso cuando completes todas',
            ),
            maxLines: 2,
          ),
          const SizedBox(height: AppEspacio.lg),
          Text('Ejercicios (en este orden)',
              style: AppTexto.subtitulo),
          const SizedBox(height: 2),
          Text(
            'Toca un ejercicio para ponerle las series: el '
            'cliente entrena la rutina con esos pesos, '
            'repeticiones y descansos ya puestos.',
            style: AppTexto.metadato,
          ),
          const SizedBox(height: AppEspacio.sm),
          if (_cargandoCatalogo)
            const EstadoCargando(texto: 'Cargando GymPedia…')
          else ...[
            for (var i = 0; i < _ejercicios.length; i++)
              _TarjetaEjercicioEditor(
                key: ValueKey(_ejercicios[i].fichaId),
                indice: i,
                titulo: _tituloDe(_ejercicios[i].fichaId),
                datos: _ejercicios[i],
                bloqueado: _guardando,
                onCambio: (nuevo) => setState(() {
                  _ejercicios[i] = nuevo;
                  _seriesEditadas = true;
                }),
                onQuitar: () =>
                    setState(() => _ejercicios.removeAt(i)),
              ),
            OutlinedButton.icon(
              onPressed: _guardando ? null : _elegirFichas,
              icon: const Icon(Icons.add_rounded),
              label: Text(_ejercicios.isEmpty
                  ? 'Elegir fichas de GymPedia'
                  : 'Añadir o quitar fichas'),
            ),
          ],
          const SizedBox(height: AppEspacio.sm),
          Text(
            'El cliente la ve en «Del gym»: puede entrenarla '
            'directo con tus series o adoptarla como copia '
            'suya editable.',
            style: AppTexto.metadato,
          ),
          const SizedBox(height: AppEspacio.lg),
          ElevatedButton(
            onPressed: _guardando ? null : _guardar,
            child: Text(_guardando
                ? 'Publicando…'
                : (esEdicion ? 'Guardar cambios' : 'Publicar rutina')),
          ),
          if (esEdicion) ...[
            const SizedBox(height: AppEspacio.sm),
            TextButton(
              onPressed: _guardando ? null : _retirar,
              child: Text('Retirar rutina',
                  style: TextStyle(color: AppColores.error)),
            ),
          ],
        ],
      ),
    );
  }
}

/// Bloque 3: la tarjeta expandible de UN ejercicio con su
/// editor de series. Es StatefulWidget propio porque posee
/// los TextEditingController de sus campos (regla de la
/// casa: quien posee controladores los libera en su
/// dispose). Emite el ejercicio reconstruido en cada
/// cambio; el formulario solo guarda el dato.
class _TarjetaEjercicioEditor extends StatefulWidget {
  final int indice;
  final String titulo;
  final EjercicioGymAdmin datos;
  final bool bloqueado;
  final void Function(EjercicioGymAdmin) onCambio;
  final VoidCallback onQuitar;

  const _TarjetaEjercicioEditor({
    super.key,
    required this.indice,
    required this.titulo,
    required this.datos,
    required this.bloqueado,
    required this.onCambio,
    required this.onQuitar,
  });

  @override
  State<_TarjetaEjercicioEditor> createState() =>
      _TarjetaEjercicioEditorState();
}

class _CtrlsSerie {
  final TextEditingController peso;
  final TextEditingController min;
  final TextEditingController max;
  String tipo;
  _CtrlsSerie(SerieGymAdmin s)
      : peso = TextEditingController(
            text: s.pesoKg == null
                ? ''
                : (s.pesoKg! % 1 == 0
                    ? '${s.pesoKg!.toInt()}'
                    : '${s.pesoKg}')),
        min = TextEditingController(text: '${s.repsMin}'),
        max = TextEditingController(
            text: '${s.repsMax ?? s.repsMin}'),
        tipo = s.tipo;

  void dispose() {
    peso.dispose();
    min.dispose();
    max.dispose();
  }
}

class _TarjetaEjercicioEditorState
    extends State<_TarjetaEjercicioEditor> {
  bool _abierta = false;
  late final TextEditingController _descansoCtrl;
  late final TextEditingController _notaCtrl;
  late final List<_CtrlsSerie> _series;

  static const _tipos = ['normal', 'calentamiento', 'fallo', 'drop'];
  static const _tipoCorto = {
    'normal': 'Normal',
    'calentamiento': 'Calent.',
    'fallo': 'Fallo',
    'drop': 'Drop',
  };

  @override
  void initState() {
    super.initState();
    _descansoCtrl = TextEditingController(
        text: widget.datos.descansoSeg == null
            ? ''
            : '${widget.datos.descansoSeg}');
    _notaCtrl = TextEditingController(text: widget.datos.nota);
    _series = [for (final s in widget.datos.series) _CtrlsSerie(s)];
  }

  @override
  void dispose() {
    _descansoCtrl.dispose();
    _notaCtrl.dispose();
    for (final s in _series) {
      s.dispose();
    }
    super.dispose();
  }

  void _emitir() {
    widget.onCambio(EjercicioGymAdmin(
      fichaId: widget.datos.fichaId,
      descansoSeg: int.tryParse(_descansoCtrl.text.trim()),
      nota: _notaCtrl.text.trim(),
      series: [
        for (final c in _series)
          SerieGymAdmin(
            tipo: c.tipo,
            pesoKg: double.tryParse(
                c.peso.text.trim().replaceAll(',', '.')),
            repsMin: int.tryParse(c.min.text.trim()) ?? 0,
            repsMax: int.tryParse(c.max.text.trim()),
          ),
      ],
    ));
  }

  String get _resumenSeries {
    if (_series.isEmpty) return 'Sin series';
    final partes = <String>[];
    for (final c in _series) {
      final reps = c.max.text == c.min.text || c.max.text.isEmpty
          ? c.min.text
          : '${c.min.text}-${c.max.text}';
      partes.add(c.peso.text.isEmpty
          ? '× $reps'
          : '${c.peso.text} kg × $reps');
    }
    return partes.join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Column(
        children: [
          ListTile(
            dense: true,
            leading: CircleAvatar(child: Text('${widget.indice + 1}')),
            title: Text(widget.titulo),
            subtitle: Text(_resumenSeries,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_abierta
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: widget.bloqueado ? null : widget.onQuitar,
                ),
              ],
            ),
            onTap: () => setState(() => _abierta = !_abierta),
          ),
          if (_abierta)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, 0, AppEspacio.lg, AppEspacio.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _descansoCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Descanso (seg)',
                            hintText: 'Global si vacío',
                          ),
                          onChanged: (_) => _emitir(),
                        ),
                      ),
                      const SizedBox(width: AppEspacio.md),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _notaCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nota del ejercicio',
                          ),
                          onChanged: (_) => _emitir(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  for (var i = 0; i < _series.length; i++)
                    _filaSerie(i),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: widget.bloqueado
                            ? null
                            : () => setState(() {
                                  _series.add(_CtrlsSerie(_series
                                      .isEmpty
                                      ? const SerieGymAdmin(repsMin: 10)
                                      : SerieGymAdmin(
                                          tipo: _series.last.tipo,
                                          pesoKg: double.tryParse(
                                              _series.last.peso.text),
                                          repsMin: int.tryParse(
                                                  _series.last.min.text) ??
                                              10,
                                          repsMax: int.tryParse(
                                              _series.last.max.text),
                                        )));
                                  _emitir();
                                }),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Serie'),
                      ),
                      if (_series.length > 1)
                        TextButton(
                          onPressed: widget.bloqueado
                              ? null
                              : () => setState(() {
                                    final p = _series.first;
                                    for (final c in _series.skip(1)) {
                                      c.peso.text = p.peso.text;
                                      c.min.text = p.min.text;
                                      c.max.text = p.max.text;
                                      c.tipo = p.tipo;
                                    }
                                    _emitir();
                                  }),
                          child: const Text('Aplicar la 1ª a todas'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _filaSerie(int i) {
    final c = _series[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text('${i + 1}',
                style: AppTexto.secundario,
                textAlign: TextAlign.center),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(AppRadio.sm),
            onTap: widget.bloqueado
                ? null
                : () => setState(() {
                      final idx = _tipos.indexOf(c.tipo);
                      c.tipo = _tipos[(idx + 1) % _tipos.length];
                      _emitir();
                    }),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppEspacio.sm, vertical: 6),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadio.sm),
              ),
              child: Text(_tipoCorto[c.tipo] ?? 'Normal',
                  style: AppTexto.minuscula
                      .copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: c.peso,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'kg', isDense: true),
              onChanged: (_) => _emitir(),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: c.min,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'reps', isDense: true),
              onChanged: (_) => _emitir(),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: c.max,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'a', isDense: true),
              onChanged: (_) => _emitir(),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            onPressed: widget.bloqueado || _series.length <= 1
                ? null
                : () => setState(() {
                      _series.removeAt(i).dispose();
                      _emitir();
                    }),
          ),
        ],
      ),
    );
  }
}

/// Selector múltiple del catálogo: el orden de la selección es
/// el orden en que se toca cada ficha (así se arma la rutina).
class _SelectorFichasScreen extends StatefulWidget {
  final List<FichaCatalogo> catalogo;
  final List<String> seleccionInicial;
  const _SelectorFichasScreen({
    required this.catalogo,
    required this.seleccionInicial,
  });

  @override
  State<_SelectorFichasScreen> createState() =>
      _SelectorFichasScreenState();
}

class _SelectorFichasScreenState extends State<_SelectorFichasScreen> {
  late final List<String> _seleccion;
  String _busqueda = '';

  @override
  void initState() {
    super.initState();
    _seleccion = List.of(widget.seleccionInicial);
  }

  @override
  Widget build(BuildContext context) {
    final q = _busqueda.trim().toLowerCase();
    final visibles = q.isEmpty
        ? widget.catalogo
        : widget.catalogo
            .where((f) => f.titulo.toLowerCase().contains(q))
            .toList();
    return Scaffold(
      appBar: appBarIron(context, 'Fichas de GymPedia'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppEspacio.lg),
            child: TextField(
              decoration: const InputDecoration(
                labelText: 'Buscar ficha',
                prefixIcon: Icon(Icons.search_rounded),
              ),
              onChanged: (v) => setState(() => _busqueda = v),
            ),
          ),
          Expanded(
            child: visibles.isEmpty
                ? const EstadoVacio(
                    icono: Icons.menu_book_rounded,
                    titulo: 'Sin fichas',
                    subtitulo: 'No hay fichas publicadas de '
                        'GymPedia con ese criterio.',
                  )
                : ListView.builder(
                    itemCount: visibles.length,
                    itemBuilder: (ctx, i) {
                      final f = visibles[i];
                      final pos = _seleccion.indexOf(f.id);
                      return CheckboxListTile(
                        value: pos >= 0,
                        title: Text(f.titulo),
                        secondary: pos >= 0
                            ? CircleAvatar(child: Text('${pos + 1}'))
                            : null,
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _seleccion.add(f.id);
                          } else {
                            _seleccion.remove(f.id);
                          }
                        }),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppEspacio.lg),
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context, _seleccion),
                child: Text('Listo (${_seleccion.length})'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
