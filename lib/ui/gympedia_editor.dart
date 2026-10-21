// lib/ui/gympedia_editor.dart
// v1.4.4 (v33): editor de artículos GymPedia (solo dueño).
// Trabaja SIEMPRE sobre un borrador local; Publicar encola la op
// gympedia_upsert_publicado (el servidor asigna revision e
// imagen_rev) y actualiza el espejo de forma optimista. Si el
// artículo publicado cambió desde que se abrió el borrador
// (revision del espejo > base_revision), se avisa antes de pisar
// (adenda de Argón, ajuste 3).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../config.dart';
import '../gympedia_validacion.dart';
import '../localdb.dart';
import '../tiempo.dart';
import 'diseno.dart';

class _RefEdit {
  final titulo = TextEditingController();
  final fuente = TextEditingController();
  final url = TextEditingController();
  _RefEdit([Map<String, dynamic>? m]) {
    if (m != null) {
      titulo.text = '${m['titulo'] ?? ''}';
      fuente.text = '${m['fuente'] ?? ''}';
      url.text = '${m['url'] ?? ''}';
    }
  }

  void dispose() {
    titulo.dispose();
    fuente.dispose();
    url.dispose();
  }
}

class GympediaEditorScreen extends StatefulWidget {
  final Map<String, dynamic>? publicado;
  final Map<String, dynamic>? borrador;
  final Set<String> slugsPublicados;

  const GympediaEditorScreen({
    super.key,
    this.publicado,
    this.borrador,
    required this.slugsPublicados,
  });

  @override
  State<GympediaEditorScreen> createState() => _GympediaEditorScreenState();
}

class _GympediaEditorScreenState extends State<GympediaEditorScreen> {
  final _db = LocalDb.instance;
  final _slug = TextEditingController();
  final _titulo = TextEditingController();
  final _esencial = TextEditingController();
  final _explicacion = TextEditingController();
  String _categoria = 'entrenamiento';
  String _sello = 'verde';
  final List<TextEditingController> _pasos = [];
  final List<TextEditingController> _errores = [];
  final List<_RefEdit> _refs = [];
  Set<String> _relacionados = {};
  bool _tieneImagen = false;
  bool _imagenCambiada = false;
  int _baseRevision = 0;
  int _imagenRev = 0;
  bool _slugBloqueado = false;
  bool _hayPublicado = false;
  bool _listo = false;
  bool _vistaPrevia = false;
  bool _ocupado = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    Map<String, dynamic>? fuente = widget.borrador;
    var desdeBorrador = fuente != null;
    if (fuente == null && widget.publicado != null) {
      // Si ya hay borrador de este artículo, manda el borrador.
      final b = await _db.gympediaBorrador('${widget.publicado!['id']}');
      if (b != null) {
        fuente = b;
        desdeBorrador = true;
      } else {
        fuente = widget.publicado;
      }
    }
    if (fuente != null) {
      if (desdeBorrador) {
        _aplicarBorrador(fuente);
      } else {
        _aplicarPublicado(fuente);
      }
    } else {
      _refs.addAll([_RefEdit(), _RefEdit()]);
      _pasos.add(TextEditingController());
      _errores.add(TextEditingController());
    }
    if (mounted) setState(() => _listo = true);
  }

  List<dynamic> _lista(dynamic v) {
    if (v is List) return v;
    if (v is String && v.isNotEmpty) {
      try {
        final d = jsonDecode(v);
        if (d is List) return d;
      } catch (_) {}
    }
    return const [];
  }

  void _aplicarPublicado(Map<String, dynamic> p) {
    _slug.text = '${p['id'] ?? ''}';
    _slugBloqueado = true;
    _hayPublicado = true;
    _titulo.text = '${p['titulo'] ?? ''}';
    _categoria = '${p['categoria'] ?? 'entrenamiento'}';
    _esencial.text = '${p['lo_esencial'] ?? ''}';
    _explicacion.text = '${p['explicacion_md'] ?? ''}';
    _sello = '${p['sello'] ?? 'verde'}';
    _baseRevision = (p['revision'] as num?)?.toInt() ?? 0;
    _imagenRev = (p['imagen_rev'] as num?)?.toInt() ?? 0;
    _tieneImagen = p['tiene_imagen'] == true || p['tiene_imagen'] == 1;
    _cargarListas(p);
  }

  void _aplicarBorrador(Map<String, dynamic> b) {
    _slug.text = '${b['slug'] ?? ''}';
    _slugBloqueado = _slug.text.isNotEmpty;
    _titulo.text = '${b['titulo'] ?? ''}';
    _categoria = '${b['categoria'] ?? 'entrenamiento'}';
    _esencial.text = '${b['lo_esencial'] ?? ''}';
    _explicacion.text = '${b['explicacion_md'] ?? ''}';
    _sello = '${b['sello'] ?? 'verde'}';
    _baseRevision = (b['base_revision'] as num?)?.toInt() ?? 0;
    _tieneImagen = b['tiene_imagen'] == 1 || b['tiene_imagen'] == true;
    _imagenCambiada =
        b['imagen_cambiada'] == 1 || b['imagen_cambiada'] == true;
    _cargarListas(b);
    // ¿Sigue publicado en el espejo?
    _db.gympediaPublicado(_slug.text).then((p) {
      if (mounted && p != null) {
        setState(() {
          _hayPublicado = true;
          _imagenRev = (p['imagen_rev'] as num?)?.toInt() ?? 0;
        });
      }
    });
  }

  void _cargarListas(Map<String, dynamic> m) {
    for (final c in _pasos) {
      c.dispose();
    }
    for (final c in _errores) {
      c.dispose();
    }
    for (final r in _refs) {
      r.dispose();
    }
    _pasos.clear();
    _errores.clear();
    _refs.clear();
    for (final s in _lista(m['pasos'])) {
      _pasos.add(TextEditingController(text: '$s'));
    }
    if (_pasos.isEmpty) _pasos.add(TextEditingController());
    for (final s in _lista(m['errores'])) {
      _errores.add(TextEditingController(text: '$s'));
    }
    if (_errores.isEmpty) _errores.add(TextEditingController());
    for (final r in _lista(m['referencias'])) {
      if (r is Map) {
        _refs.add(_RefEdit(Map<String, dynamic>.from(r)));
      }
    }
    while (_refs.length < 2) {
      _refs.add(_RefEdit());
    }
    _relacionados =
        _lista(m['related_ids']).map((e) => '$e').toSet();
  }

  @override
  void dispose() {
    _slug.dispose();
    _titulo.dispose();
    _esencial.dispose();
    _explicacion.dispose();
    for (final c in _pasos) {
      c.dispose();
    }
    for (final c in _errores) {
      c.dispose();
    }
    for (final r in _refs) {
      r.dispose();
    }
    super.dispose();
  }

  String _slugDesdeTitulo(String t) {
    var s = t.toLowerCase().trim();
    const con = 'áéíóúüñ';
    const sin = 'aeiouun';
    for (var i = 0; i < con.length; i++) {
      s = s.replaceAll(con[i], sin[i]);
    }
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'^-+|-+$'), '');
    return s.length > 80 ? s.substring(0, 80) : s;
  }

  Map<String, dynamic> _articuloActual() {
    List<String> limpios(List<TextEditingController> cs) => cs
        .map((c) => c.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    return {
      'id': _slug.text.trim(),
      'titulo': _titulo.text.trim(),
      'categoria': _categoria,
      'lo_esencial': _esencial.text.trim(),
      'explicacion_md': _explicacion.text.trim(),
      'pasos': limpios(_pasos),
      'errores': limpios(_errores),
      'referencias': [
        for (final r in _refs)
          if (r.titulo.text.trim().isNotEmpty ||
              r.fuente.text.trim().isNotEmpty ||
              r.url.text.trim().isNotEmpty)
            {
              'titulo': r.titulo.text.trim(),
              'fuente': r.fuente.text.trim(),
              'url': r.url.text.trim(),
            },
      ],
      'sello': _sello,
      'related_ids': _relacionados.toList()..sort(),
      'tiene_imagen': _tieneImagen,
      'imagen_cambiada': _imagenCambiada,
    };
  }

  Map<String, dynamic> _borradorActual() {
    final a = _articuloActual();
    return {
      'slug': a['id'],
      'titulo': a['titulo'],
      'categoria': a['categoria'],
      'lo_esencial': a['lo_esencial'],
      'explicacion_md': a['explicacion_md'],
      'pasos': jsonEncode(a['pasos']),
      'errores': jsonEncode(a['errores']),
      'referencias': jsonEncode(a['referencias']),
      'sello': a['sello'],
      'related_ids': jsonEncode(a['related_ids']),
      'tiene_imagen': _tieneImagen ? 1 : 0,
      'imagen_cambiada': _imagenCambiada ? 1 : 0,
      'base_revision': _baseRevision,
      'actualizado_ts': isoHabana(ahoraHabana()),
    };
  }

  void _aviso(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _guardarBorrador() async {
    if (_slug.text.trim().isEmpty) {
      final s = _slugDesdeTitulo(_titulo.text);
      if (s.isEmpty) {
        _aviso('Escribe un título o un identificador primero.');
        return;
      }
      _slug.text = s;
    }
    await _db.gympediaGuardarBorrador(_borradorActual());
    _slugBloqueado = true;
    _aviso('Borrador guardado en este teléfono.');
    setState(() {});
  }

  Future<bool> _chequearObsoleto() async {
    final actual = await _db.gympediaPublicado(_slug.text.trim());
    if (actual == null) return true;
    final rev = (actual['revision'] as num?)?.toInt() ?? 0;
    if (rev <= _baseRevision) return true;
    if (!mounted) return false;
    final recargar = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('El artículo cambió'),
        content: Text(
            'La versión publicada ya va por la revisión $rev y tu '
            'borrador partió de la $_baseRevision. Si publicas ahora, '
            'pisas esa versión más nueva.\n\n'
            'Puedes recargar el borrador desde lo publicado (pierdes '
            'tus cambios sin guardar) o cancelar.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Recargar desde lo publicado')),
        ],
      ),
    );
    if (recargar == true) {
      setState(() => _aplicarPublicado(actual));
      _aviso('Borrador recargado con la versión publicada.');
    }
    return false;
  }

  Future<void> _publicar() async {
    if (_ocupado) return;
    if (_slug.text.trim().isEmpty) {
      _slug.text = _slugDesdeTitulo(_titulo.text);
    }
    setState(() => _ocupado = true);
    try {
      if (!await _chequearObsoleto()) return;
      final a = _articuloActual();
      final slugs = {...widget.slugsPublicados};
      final actual = await _db.gympediaPublicado('${a['id']}');
      if (actual != null) slugs.add('${a['id']}');
      final errores =
          GympediaValidacion.validar(a, slugsPublicados: slugs);
      // related_ids no puede apuntar al propio artículo aunque la
      // validación ya lo marca; los slugs ofrecidos ya lo excluyen.
      if (errores.isNotEmpty) {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Falta corregir'),
            content: SingleChildScrollView(
                child: Text(errores.map((e) => '• $e').join('\n'))),
            actions: [
              FilledButton(
                  onPressed: () => Navigator.pop(c),
                  child: const Text('Entendido')),
            ],
          ),
        );
        return;
      }
      await _db.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'gympedia_upsert_publicado',
        payload: a,
      );
      // Espejo optimista: el pull lo confirmará con la revision del
      // servidor; imagen_rev lo asigna SOLO el servidor.
      final optimista = Map<String, dynamic>.from(a)
        ..remove('imagen_cambiada')
        ..['revision'] = _baseRevision + 1
        ..['imagen_rev'] = _imagenRev;
      await _db.upsertMirrorTexto(
          'gympedia_articulos', '${a['id']}', optimista, 0);
      await _db.gympediaEliminarBorrador('${a['id']}');
      _aviso('Publicado. Se enviará al servidor al sincronizar.');
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _retirar() async {
    final slug = _slug.text.trim();
    if (slug.isEmpty || !_hayPublicado) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Retirar artículo'),
        content: Text(
            '«${_titulo.text}» dejará de verse en la app de clientes '
            'en cuanto se sincronice. El borrador local también se '
            'elimina. ¿Seguro?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: AppColores.error),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Retirar')),
        ],
      ),
    );
    if (ok != true) return;
    await _db.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'gympedia_retirar',
      payload: {'id': slug},
    );
    await _db.deleteMirrorTexto('gympedia_articulos', slug);
    await _db.gympediaEliminarBorrador(slug);
    _aviso('Artículo retirado. Se aplicará al sincronizar.');
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _elegirImagen() async {
    final slug = _slug.text.trim();
    if (!GympediaValidacion.slugValido(slug)) {
      _aviso('Primero define el identificador del artículo.');
      return;
    }
    final img = await ImagePicker()
        .pickImage(source: ImageSource.gallery, maxWidth: 1600);
    if (img == null || !mounted) return;
    setState(() => _ocupado = true);
    try {
      final bytes = await FlutterImageCompress.compressWithFile(
        img.path,
        minWidth: 1024,
        minHeight: 1024,
        quality: 82,
        format: CompressFormat.webp,
      );
      if (bytes == null) {
        _aviso('No se pudo procesar la imagen.');
        return;
      }
      final token = AuthService().session?.accessToken ?? '';
      final r = await http
          .post(
            Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
                '${AppConfig.bucketGympedia}/$slug.webp'),
            headers: {
              'apikey': AppConfig.anonKey,
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
              'Content-Type': 'image/webp',
              'x-upsert': 'true',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 60));
      if (r.statusCode == 200 || r.statusCode == 201) {
        setState(() {
          _tieneImagen = true;
          _imagenCambiada = true;
        });
        _aviso('Imagen subida. Se enlaza al publicar.');
      } else {
        _aviso('La subida falló (HTTP ${r.statusCode}). '
            'Revisa la conexión e inténtalo de nuevo.');
      }
    } catch (_) {
      _aviso('La subida falló. Revisa la conexión e inténtalo de nuevo.');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _quitarImagen() async {
    final slug = _slug.text.trim();
    setState(() {
      _tieneImagen = false;
      _imagenCambiada = true;
    });
    // Borrado directo del objeto (mejor esfuerzo): la app de
    // clientes, al ver tiene_imagen=false, limpia su caché local.
    try {
      final token = AuthService().session?.accessToken ?? '';
      await http
          .delete(
            Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
                '${AppConfig.bucketGympedia}/$slug.webp'),
            headers: {
              'apikey': AppConfig.anonKey,
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {}
    _aviso('Imagen desvinculada. Se aplica al publicar.');
  }

  Widget _campoTexto(String etiqueta, TextEditingController c,
      {int lineas = 1,
      String? ayuda,
      bool mono = false,
      bool soloLectura = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        maxLines: lineas,
        readOnly: soloLectura,
        enabled: !soloLectura,
        style: mono ? const TextStyle(fontFamily: 'monospace', fontSize: 13) : null,
        decoration: InputDecoration(
          labelText: etiqueta,
          helperText: ayuda,
          border: const OutlineInputBorder(),
          alignLabelWithHint: lineas > 1,
        ),
      ),
    );
  }

  Widget _listaEditable(
      String titulo, List<TextEditingController> cs, String singular) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(titulo, style: AppTexto.subtitulo)),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Añadir $singular',
              onPressed: cs.length >= 10
                  ? null
                  : () => setState(() => cs.add(TextEditingController())),
            ),
          ],
        ),
        for (var i = 0; i < cs.length; i++)
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: cs[i],
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: '$singular ${i + 1}',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: cs.length <= 1
                    ? null
                    : () => setState(() {
                          cs[i].dispose();
                          cs.removeAt(i);
                        }),
              ),
            ],
          ),
        const SizedBox(height: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_listo) {
      return Scaffold(
        appBar: AppBar(title: const Text('Artículo GymPedia')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final candidatosRel = widget.slugsPublicados
        .where((s) => s != _slug.text.trim())
        .toList()
      ..sort();
    return Scaffold(
      appBar: AppBar(
        title: Text(_hayPublicado || _slugBloqueado
            ? 'Editar artículo'
            : 'Nuevo artículo'),
        actions: [
          IconButton(
            icon: Icon(_vistaPrevia ? Icons.edit : Icons.visibility),
            tooltip: _vistaPrevia ? 'Editar explicación' : 'Vista previa',
            onPressed: () =>
                setState(() => _vistaPrevia = !_vistaPrevia),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _campoTexto('Identificador (slug)', _slug,
                    ayuda: _slugBloqueado
                        ? 'El identificador no se puede cambiar.'
                        : 'Minúsculas y guiones: tecnica-sentadilla',
                    mono: true,
                    soloLectura: _slugBloqueado),
                _campoTexto('Título', _titulo),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _categoria,
                        decoration: const InputDecoration(
                            labelText: 'Categoría',
                            border: OutlineInputBorder()),
                        items: [
                          for (final c in GympediaValidacion.categorias)
                            DropdownMenuItem(
                                value: c,
                                child: Text(GympediaValidacion
                                        .nombreCategoria[c] ??
                                    c)),
                        ],
                        onChanged: (v) =>
                            setState(() => _categoria = v ?? _categoria),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _sello,
                        decoration: const InputDecoration(
                            labelText: 'Sello de respaldo',
                            border: OutlineInputBorder()),
                        items: const [
                          DropdownMenuItem(
                              value: 'verde',
                              child: Text('🟢 Respaldo sólido')),
                          DropdownMenuItem(
                              value: 'amarillo',
                              child: Text('🟡 Con matices')),
                          DropdownMenuItem(
                              value: 'gris',
                              child: Text('⚪ Sin respaldo')),
                        ],
                        onChanged: (v) =>
                            setState(() => _sello = v ?? _sello),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _campoTexto('Lo esencial (resumen corto)', _esencial,
                    lineas: 3, ayuda: 'Máx. 500 bytes.'),
                if (_vistaPrevia)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: MarkdownBody(
                          data: _explicacion.text.isEmpty
                              ? '_(sin explicación todavía)_'
                              : _explicacion.text),
                    ),
                  )
                else
                  _campoTexto('Explicación (Markdown)', _explicacion,
                      lineas: 12, ayuda: 'Máx. 8192 bytes.'),
                _listaEditable('En la práctica (pasos)', _pasos, 'Paso'),
                _listaEditable('Errores comunes', _errores, 'Error'),
                const Text('Referencias (2 a 6)', style: AppTexto.subtitulo),
                const SizedBox(height: 8),
                for (var i = 0; i < _refs.length; i++)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        children: [
                          _campoTexto('Título del estudio/artículo',
                              _refs[i].titulo),
                          _campoTexto(
                              'Fuente (revista, año)', _refs[i].fuente),
                          Row(
                            children: [
                              Expanded(
                                  child: _campoTexto(
                                      'Enlace (https://…)', _refs[i].url,
                                      mono: true)),
                              IconButton(
                                icon:
                                    const Icon(Icons.remove_circle_outline),
                                onPressed: _refs.length <= 2
                                    ? null
                                    : () => setState(() {
                                          _refs[i].dispose();
                                          _refs.removeAt(i);
                                        }),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_refs.length < 6)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () =>
                          setState(() => _refs.add(_RefEdit())),
                      icon: const Icon(Icons.add),
                      label: const Text('Añadir referencia'),
                    ),
                  ),
                const SizedBox(height: 8),
                const Text('Artículos relacionados',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 6),
                if (candidatosRel.isEmpty)
                  const Text('Aún no hay otros artículos publicados.',
                      style: TextStyle(color: Colors.grey))
                else
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final s in candidatosRel)
                        FilterChip(
                          label: Text(s, style: const TextStyle(fontSize: 12)),
                          selected: _relacionados.contains(s),
                          onSelected: (sel) => setState(() {
                            if (sel) {
                              if (_relacionados.length < 6) {
                                _relacionados.add(s);
                              }
                            } else {
                              _relacionados.remove(s);
                            }
                          }),
                        ),
                    ],
                  ),
                const SizedBox(height: 16),
                const Text('Imagen del artículo',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 6),
                if (_tieneImagen)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      '${AppConfig.supabaseUrl}/storage/v1/object/public/'
                      '${AppConfig.bucketGympedia}/${_slug.text.trim()}.webp'
                      '?v=$_imagenRev',
                      height: 160,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('Imagen enlazada (sin vista previa)'),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _ocupado ? null : _elegirImagen,
                      icon: const Icon(Icons.image),
                      label: Text(_tieneImagen
                          ? 'Cambiar imagen'
                          : 'Elegir imagen'),
                    ),
                    if (_tieneImagen) ...[
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _ocupado ? null : _quitarImagen,
                        icon: const Icon(Icons.link_off),
                        label: const Text('Quitar'),
                      ),
                    ],
                  ],
                ),
                const Text(
                  'La imagen se sube al momento (necesita conexión); el '
                  'enlace con el artículo se aplica al publicar.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                if (_hayPublicado) ...[
                  const SizedBox(height: 24),
                  const Divider(),
                  ListTile(
                    leading: const Icon(Icons.visibility_off,
                        color: AppColores.error),
                    title: const Text('Retirar artículo',
                        style: TextStyle(color: AppColores.error)),
                    subtitle: const Text(
                        'Deja de verse en la app de clientes al sincronizar.'),
                    onTap: _ocupado ? null : _retirar,
                  ),
                ],
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _ocupado ? null : _guardarBorrador,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('Guardar borrador'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _ocupado ? null : _publicar,
                      icon: _ocupado
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.publish),
                      label: const Text('Publicar'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
