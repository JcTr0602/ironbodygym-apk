// lib/ui/gympedia.dart
// v1.4.4 (v33): GymPedia en Gestión — SOLO DUEÑO.
// Lista los artículos publicados (espejo local) y los borradores
// (100% locales). Publicar/retirar viaja como op por la cola de
// sync; el espejo se actualiza optimista y el pull lo confirma.
import 'package:flutter/material.dart';

import '../auth.dart';
import '../config.dart';
import '../gympedia_validacion.dart';
import '../localdb.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'gympedia_editor.dart';

/// GY3 (estéticas 1.19): texto del sello de respaldo de un
/// artículo GymPedia (puro; mismo vocabulario que el editor).
String textoSelloGympedia(String sello) {
  switch (sello) {
    case 'verde':
      return 'Respaldo sólido';
    case 'amarillo':
      return 'Con matices';
    case 'gris':
      return 'Sin respaldo';
    default:
      return sello;
  }
}

class GympediaScreen extends StatefulWidget {
  /// Si es true, se muestra sin Scaffold/AppBar (pestaña dentro de
  /// Biblioteca): el cuerpo trae sus propios botones de acción.
  final bool embebida;

  const GympediaScreen({super.key, this.embebida = false});

  @override
  State<GympediaScreen> createState() => _GympediaScreenState();
}

class _GympediaScreenState extends State<GympediaScreen> {
  final _db = LocalDb.instance;
  List<Map<String, dynamic>> _publicados = [];
  List<Map<String, dynamic>> _borradores = [];
  bool _cargando = true;
  bool _sincronizando = false;
  // 20/25: buscador (título, slug o categoría).
  String _busqueda = '';
  final _busquedaCtrl = TextEditingController();

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  /// Listas filtradas por la búsqueda (vacía = todo).
  List<Map<String, dynamic>> get _publicadosVisibles => _publicados
      .where((p) => GympediaValidacion.coincideBusqueda(p, _busqueda))
      .toList();
  List<Map<String, dynamic>> get _borradoresVisibles => _borradores
      .where((b) => GympediaValidacion.coincideBusqueda(b, _busqueda))
      .toList();

  void _limpiarBusqueda() {
    _busquedaCtrl.clear();
    setState(() => _busqueda = '');
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  /// 1.22 GY-04: slugs ya publicados desde este teléfono
  /// cuya op sigue en cola (marca `gympedia_en_cola_<slug>`).
  Set<String> _enCola = {};

  Future<void> _cargar() async {
    // Ronda 17 M3-H1 (defensa en profundidad): sin dueño no
    // se cargan publicados ni borradores aunque se invoque directo.
    if (!AuthService().isOwner) return;
    final pub = await _db.gympediaPublicados();
    final bor = await _db.gympediaBorradores();
    final marcas = await _db.metasConPrefijo('gympedia_en_cola_');
    // Panel Pieza 7: autolimpieza de la marca (borrador
    // desaparecido u op ya resuelta → la marca se apaga).
    final enCola = <String>{};
    for (final k in marcas) {
      if (k.isEmpty) continue;
      final slug = k.substring('gympedia_en_cola_'.length);
      final existeBorrador = bor.any((b) => '${b['slug']}' == slug);
      if (existeBorrador && await _db.upsertBibliotecaEnCola(slug)) {
        enCola.add(slug);
      } else {
        await _db.setMeta(k, '');
      }
    }
    if (!mounted) return;
    setState(() {
      _publicados = pub;
      _borradores = bor;
      _enCola = enCola;
      _cargando = false;
    });
  }

  Future<void> _sincronizar() async {
    if (_sincronizando) return;
    setState(() => _sincronizando = true);
    // 1.22 GY-07: scope de biblioteca (push global + pull de
    // gympedia_articulos), simétrico con Guía — antes era un
    // pull COMPLETO por un botón de una sola sección.
    // 1.22 GY-06: snack honesto según si el ciclo corrió.
    var corrio = false;
    try {
      corrio = await SyncEngine.instance.sincronizarScope('gympedia');
    } catch (_) {}
    await _cargar();
    if (!mounted) return;
    setState(() => _sincronizando = false);
    if (corrio) {
      mostrarSnack(context, 'GymPedia actualizada',
          significado: SignificadoChip.exito);
    } else {
      mostrarSnack(context, 'Sin conexión: catálogo local');
    }
  }

  Map<String, dynamic>? _publicadoDe(String slug) {
    for (final p in _publicados) {
      if ('${p['id']}' == slug) return p;
    }
    return null;
  }

  bool _obsoleto(Map<String, dynamic> borrador) {
    final pub = _publicadoDe('${borrador['slug']}');
    if (pub == null) return false;
    final revPub = (pub['revision'] as num?)?.toInt() ?? 0;
    final base = (borrador['base_revision'] as num?)?.toInt() ?? 0;
    return revPub > base;
  }

  Future<void> _abrirEditor(
      {Map<String, dynamic>? publicado,
      Map<String, dynamic>? borrador}) async {
    await Navigator.of(context).push(RutaIron(
      builder: (_) => GympediaEditorScreen(
        publicado: publicado,
        borrador: borrador,
        slugsPublicados: _publicados.map((p) => '${p['id']}').toSet(),
      ),
    ));
    await _cargar();
  }

  Color _colorSello(BuildContext context, String sello) {
    switch (sello) {
      case 'verde':
        return AppColores.exito;
      case 'amarillo':
        return AppColores.alerta;
      default:
        return AppColores.textoSecundario(context);
    }
  }

  /// GY3 (estéticas 1.19): el sello con texto — mismo vocabulario
  /// que el editor («Respaldo sólido / Con matices / Sin respaldo»).
  String _textoSello(String sello) => textoSelloGympedia(sello);

  /// GY1 (estéticas 1.19): miniatura del artículo — misma URL
  /// pública que la vista previa del editor; si no hay imagen o
  /// falla, cae al punto del sello.
  Widget _miniaturaArticulo(Map<String, dynamic> p) {
    final tieneImagen =
        p['tiene_imagen'] == true || p['tiene_imagen'] == 1;
    final sello = _colorSello(context, '${p['sello']}');
    if (!tieneImagen) {
      return Icon(Icons.circle_rounded, size: 16, color: sello);
    }
    final slug = '${p['slug'] ?? p['id'] ?? ''}';
    final rev = (p['imagen_rev'] as num?)?.toInt() ?? 0;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColores.borde(context)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Image(
          // D-02 (1.21) + hotfix campo: miniatura de 48 px,
          // decodificar acotado SIN deformar (providerFoto-
          // Acotada; con cacheWidth+cacheHeight la foto se
          // estiraba al cuadrado).
          image: providerFotoAcotada(
              NetworkImage('${AppConfig.supabaseUrl}/storage/v1/'
                  'object/public/${AppConfig.bucketGympedia}/'
                  '$slug.webp?v=$rev'),
              ancho: 288),
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          loadingBuilder: (_, hijo, progreso) => progreso == null
              ? hijo
              : Container(
                  color: AppColores.borde(context)
                      .withValues(alpha: 0.3),
                  child: Icon(Icons.menu_book_rounded,
                      size: 20,
                      color: AppColores.textoSecundario(context)),
                ),
          errorBuilder: (_, __, ___) =>
              Icon(Icons.circle_rounded, size: 16, color: sello),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('GymPedia')),
        body: const Center(
            child: Text('Solo el dueño administra la GymPedia.')),
      );
    }
    if (widget.embebida) return _cuerpo();
    return Scaffold(
      appBar: AppBar(
        title: const Text('GymPedia'),
        actions: [
          IconButton(
            icon: _sincronizando
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync_rounded),
            tooltip: 'Actualizar (bajar cambios)',
            onPressed: _sincronizando ? null : _sincronizar,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _abrirEditor(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nuevo artículo'),
      ),
      body: _cuerpo(),
    );
  }

  /// Cuerpo de la lista (compartido entre la pantalla propia y la
  /// pestaña embebida en Biblioteca).
  Widget _cuerpo() {
    if (_cargando) return const EstadoCargando(texto: 'Cargando biblioteca…');
    return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
        // 20/25: buscador (título, slug o categoría).
        Row(
          children: [
            Expanded(
              child: CampoTexto(
                controller: _busquedaCtrl,
                hint: 'Buscar artículo…',
                icono: Icons.search_rounded,
                onChanged: (v) =>
                    setState(() => _busqueda = v.trim()),
              ),
            ),
            if (_busqueda.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.clear_rounded),
                tooltip: 'Limpiar búsqueda',
                onPressed: _limpiarBusqueda,
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (widget.embebida) ...[
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _sincronizando ? null : _sincronizar,
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('Actualizar'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _abrirEditor(),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Nuevo artículo'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],

                if (_borradoresVisibles.isNotEmpty) ...[
                  Text('Borradores', style: AppTexto.subtitulo),
                  const SizedBox(height: 4),
                  Text(
                    'Solo viven en este teléfono hasta que los publiques.',
                    style: AppTexto.metadato,
                  ),
                  const SizedBox(height: 8),
                  for (final b in _borradoresVisibles)
                    Card(
                      child: ListTile(
                        leading: Icon(Icons.edit_note_rounded,
                            color: AppColores.textoSecundario(context)),
                        title: Text(
                            '${b['titulo']}'.isEmpty
                                ? '(sin título)'
                                : '${b['titulo']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        subtitle: Text('${b['slug']}'),
                        trailing: _obsoleto(b)
                            ? const Tooltip(
                                message:
                                    'El artículo publicado cambió desde que abriste este borrador',
                                child: Icon(Icons.warning_amber_rounded,
                                    color: AppColores.error),
                              )
                            : _enCola.contains('${b['slug']}')
                                ? const Chip(
                                    label: Text('En cola de publicación',
                                        style: AppTexto.minuscula),
                                    visualDensity: VisualDensity.compact,
                                  )
                                : const Chip(
                                    label: Text('Borrador',
                                        style: AppTexto.minuscula),
                                    visualDensity: VisualDensity.compact,
                                  ),
                        onTap: () => _abrirEditor(borrador: b),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                Text('Publicados (${_publicadosVisibles.length})',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 8),
                if (_publicadosVisibles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: EstadoVacio(
                      icono: Icons.menu_book_rounded,
                      titulo: _busqueda.isNotEmpty
                          ? 'Ningún artículo coincide con «$_busqueda».'
                          : 'Aún no bajó ningún artículo.',
                      subtitulo: _busqueda.isEmpty
                          ? 'Toca el botón de actualizar con conexión '
                              'y espera a que el espejo se llene.'
                          : null,
                      textoAccion: _busqueda.isNotEmpty
                          ? 'Limpiar búsqueda'
                          : 'Actualizar',
                      onAccion: _busqueda.isNotEmpty
                          ? _limpiarBusqueda
                          : _sincronizar,
                    ),
                  ),
                for (final cat in GympediaValidacion.categorias)
                  if (_publicadosVisibles.any((p) => '${p['categoria']}' == cat)) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 12, bottom: 4),
                      child: Text(
                        GympediaValidacion.nombreCategoria[cat] ?? cat,
                        style: AppTexto.etiqueta.copyWith(
                            fontWeight: FontWeight.bold,
                            color: AppColores.naranja),
                      ),
                    ),
                    for (final p in _publicadosVisibles.where(
                        (p) => '${p['categoria']}' == cat))
                      Padding(
                        padding: const EdgeInsets.only(
                            bottom: AppEspacio.sm),
                        child: Tarjeta(
                          padding:
                              const EdgeInsets.all(AppEspacio.md),
                          onTap: () => _abrirEditor(publicado: p),
                          child: Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              _miniaturaArticulo(p),
                              const SizedBox(width: AppEspacio.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text('${p['titulo']}',
                                        style: AppTexto.subtitulo,
                                        maxLines: 2,
                                        overflow:
                                            TextOverflow.ellipsis),
                                    const SizedBox(height: 2),
                                    Text(
                                        'Rev. ${(p['revision'] as num?)?.toInt() ?? 1}'
                                        '${(p['tiene_imagen'] == true || p['tiene_imagen'] == 1) ? ' · con imagen' : ''}',
                                        style: AppTexto.secundario),
                                    // GY3: el sello con su texto.
                                    Text(_textoSello('${p['sello']}'),
                                        style: AppTexto.metadato.copyWith(
                                            color: _colorSello(context,
                                                '${p['sello']}'),
                                            fontWeight:
                                                FontWeight.w600)),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right_rounded),
                            ],
                          ),
                        ),
                      ),
                  ],
                const SizedBox(height: 12),
                const Text(
                  'Los artículos se leen sin conexión en la app de '
                  'clientes. Publicar y retirar se aplica al sincronizar.',
                  style: AppTexto.secundario,
                ),
              ],
            );
  }
}
