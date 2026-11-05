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
import 'diseno.dart';

class RutinaGymAdmin {
  final int id;
  final String nombre;
  final List<String> fichaIds;

  const RutinaGymAdmin({
    required this.id,
    required this.nombre,
    required this.fichaIds,
  });

  factory RutinaGymAdmin.fromJson(Map<String, dynamic> j) {
    final crudo = j['ficha_ids'];
    return RutinaGymAdmin(
      id: (j['id'] as num?)?.toInt() ?? 0,
      nombre: '${j['nombre'] ?? ''}',
      fichaIds: crudo is List
          ? crudo.map((e) => e.toString()).toList()
          : const [],
    );
  }
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

Future<List<FichaCatalogo>> _cargarCatalogo() async {
  // 1.24.1 (Argón G-07): la fuente son las fichas PUBLICADAS
  // de la Guía (guiaPublicadas ya decodifica el espejo y
  // deja el slug en 'id'; el equipoId viaja en el data). Una
  // ficha sin equipoId no tiene id canónico: no entra (el
  // cliente tampoco podría cruzarla).
  final filas = await LocalDb.instance.guiaPublicadas();
  final out = <FichaCatalogo>[];
  for (final f in filas) {
    final slug = '${f['id'] ?? ''}'.trim();
    final equipoId = '${f['equipoId'] ?? ''}'.trim();
    if (slug.isEmpty || equipoId.isEmpty) continue;
    final titulo = '${f['titulo'] ?? ''}'.trim();
    out.add(FichaCatalogo(
      id: '${equipoId}_$slug',
      titulo: titulo.isEmpty ? slug : titulo,
    ));
  }
  out.sort((a, b) => a.titulo.compareTo(b.titulo));
  return out;
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
      MaterialPageRoute(
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
          ? const EstadoCargando(texto: 'Cargando rutinas…')
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
                                      '${r.fichaIds.length == 1 ? '' : 's'}',
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
  List<FichaCatalogo> _catalogo = [];
  final List<String> _seleccion = [];
  bool _cargandoCatalogo = true;
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _nombreCtrl = TextEditingController(text: widget.rutina?.nombre ?? '');
    _seleccion.addAll(widget.rutina?.fichaIds ?? const []);
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
    super.dispose();
  }

  String _tituloDe(String id) {
    for (final f in _catalogo) {
      if (f.id == id) return f.titulo;
    }
    return id;
  }

  Future<void> _elegirFichas() async {
    final elegidas = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(
        builder: (_) => _SelectorFichasScreen(
          catalogo: _catalogo,
          seleccionInicial: List.of(_seleccion),
        ),
      ),
    );
    if (elegidas == null || !mounted) return;
    setState(() {
      _seleccion
        ..clear()
        ..addAll(elegidas);
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
          const SizedBox(height: AppEspacio.lg),
          Text('Ejercicios (en este orden)',
              style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.sm),
          if (_cargandoCatalogo)
            const EstadoCargando(texto: 'Cargando GymPedia…')
          else ...[
            for (var i = 0; i < _seleccion.length; i++)
              ListTile(
                dense: true,
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Text(_tituloDe(_seleccion[i])),
                trailing: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _guardando
                      ? null
                      : () => setState(() => _seleccion.removeAt(i)),
                ),
              ),
            OutlinedButton.icon(
              onPressed: _guardando ? null : _elegirFichas,
              icon: const Icon(Icons.add_rounded),
              label: Text(_seleccion.isEmpty
                  ? 'Elegir fichas de GymPedia'
                  : 'Añadir o quitar fichas'),
            ),
          ],
          const SizedBox(height: AppEspacio.sm),
          Text(
            'El cliente la ve en «Del gym» y la adopta con un '
            'toque: se le copia a su semana con estas fichas.',
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
