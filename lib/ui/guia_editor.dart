// lib/ui/guia_editor.dart
// Biblioteca / Guía (v47) — SOLO DUEÑO. Editor de fichas en el
// orden en que un entrenador piensa la ficha: identificación,
// músculos/silueta, esencial, vista rápida, dosificación, ejecutar,
// errores, seguridad, regresión, imagen. Trabaja SIEMPRE sobre un
// borrador local; Publicar encola la op guia_upsert_publicado (el
// servidor asigna revision, imagen_rev, nivel y equipoNombre) y
// actualiza el espejo de forma optimista. Antes de publicar se
// muestra la vista previa en modo sala (M4) con «Confirmar y
// publicar». Retirar encola guia_retirar.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../config.dart';
import '../guia_validacion.dart';
import '../localdb.dart';
import '../tiempo.dart';
import 'diseno.dart';

class GuiaEditorScreen extends StatefulWidget {
  final Map<String, dynamic>? publicado;
  final Map<String, dynamic>? borrador;

  const GuiaEditorScreen({super.key, this.publicado, this.borrador});

  @override
  State<GuiaEditorScreen> createState() => _GuiaEditorScreenState();
}

class _GuiaEditorScreenState extends State<GuiaEditorScreen> {
  final _db = LocalDb.instance;
  final _titulo = TextEditingController();
  final _slug = TextEditingController();
  final _sinonimoNuevo = TextEditingController();
  final _muscPrinc = TextEditingController();
  final _muscSec = TextEditingController();
  final _ajuste = TextEditingController();
  final _clave1 = TextEditingController();
  final _clave2 = TextEditingController();
  final _advertencia = TextEditingController();
  final _series = TextEditingController(text: '3');
  final _repeticiones = TextEditingController();
  final _descanso = TextEditingController();
  final _pesoInicial = TextEditingController();
  final _senalParada = TextEditingController();
  final _autoVerificacion = TextEditingController();
  final _regresion = TextEditingController();

  List<String> _sinonimos = [];
  String? _equipoId;
  String _silueta = 'pecho';
  bool _esencial = false;
  bool _revisado = false;
  bool _tieneImagen = false;
  bool _imagenCambiada = false;
  String _imagenLocal = '';
  int _imagenRev = 0;
  int _baseRevision = 0;
  bool _publicadoExiste = false;
  bool _ocupado = false;
  List<Map<String, dynamic>> _equipos = [];
  int _esenciales = 0;

  List<TextEditingController> _ejecutar = [];
  List<TextEditingController> _errores = [];

  @override
  void initState() {
    super.initState();
    // Ronda 17 M3-H1: sin dueño no se inicializa el editor
    // (antes initState ya disparaba _cargarEquipos y _cargarDoc).
    if (!AuthService().isOwner) return;
    _cargarEquipos();
    final p = widget.publicado;
    final b = widget.borrador;
    Map<String, dynamic>? doc;
    if (b != null) {
      try {
        doc = Map<String, dynamic>.from(
            jsonDecode('${b['data']}') as Map);
      } catch (_) {
        doc = null;
      }
      _slug.text = '${b['slug']}';
      _baseRevision = (b['base_revision'] as num?)?.toInt() ?? 0;
      _tieneImagen = b['tiene_imagen'] == 1 || b['tiene_imagen'] == true;
      _imagenCambiada =
          b['imagen_cambiada'] == 1 || b['imagen_cambiada'] == true;
      _imagenLocal = '${b['imagen_local'] ?? ''}';
      if (p != null) {
        _imagenRev = (p['imagen_rev'] as num?)?.toInt() ?? 0;
        _publicadoExiste = true;
      }
    } else if (p != null) {
      doc = p;
      _slug.text = '${p['id']}';
      _baseRevision = (p['revision'] as num?)?.toInt() ?? 0;
      _imagenRev = (p['imagen_rev'] as num?)?.toInt() ?? 0;
      _tieneImagen = p['tiene_imagen'] == true || p['tiene_imagen'] == 1;
      _publicadoExiste = true;
    }
    if (doc != null) _cargarDoc(doc);
    if (_ejecutar.isEmpty) _ejecutar = [TextEditingController()];
    if (_errores.isEmpty) _errores = [TextEditingController()];
  }

  Future<void> _cargarEquipos() async {
    // Ronda 17 M3-H1 (defensa en profundidad).
    if (!AuthService().isOwner) return;
    final eq = await _db.guiaEquipos();
    final pub = await _db.guiaPublicadas();
    if (!mounted) return;
    setState(() {
      _equipos = eq;
      _esenciales = pub.where((p) => p['esencial'] == true).length;
      // Si el borrador trae un equipo ya inactivo, se conserva en
      // la lista para mostrarlo (la validación impedirá publicar).
      if (_equipoId != null &&
          !_equipos.any((e) => '${e['equipoId']}' == _equipoId)) {
        _equipos = [
          ..._equipos,
          {
            'equipoId': _equipoId,
            'equipoNombre': '$_equipoId (inactivo)',
            'activo': false,
          }
        ];
      }
    });
  }

  void _cargarDoc(Map<String, dynamic> d) {
    // Ronda 17 M3-H3: disponer los controladores previos antes
    // de reemplazar las listas (recarga desde _chequearObsoleto).
    for (final c in _ejecutar) {
      c.dispose();
    }
    for (final c in _errores) {
      c.dispose();
    }
    _titulo.text = '${d['titulo'] ?? ''}';
    if (_slug.text.isEmpty) _slug.text = '${d['id'] ?? ''}';
    _sinonimos = [for (final s in (d['sinonimos'] as List?) ?? []) '$s'];
    _equipoId = '${d['equipoId'] ?? ''}';
    _silueta = '${d['siluetaId'] ?? 'pecho'}';
    _esencial = d['esencial'] == true;
    _revisado = d['revisado_entrenador'] == true;
    _muscPrinc.text = ((d['musculosPrincipales'] as List?) ?? []).join(', ');
    _muscSec.text = ((d['musculosSecundarios'] as List?) ?? []).join(', ');
    final vr = d['vistaRapida'] as Map?;
    if (vr != null) {
      _ajuste.text = '${vr['ajusteMaquina'] ?? ''}';
      final claves = (vr['claves'] as List?) ?? [];
      if (claves.isNotEmpty) _clave1.text = '${claves[0]}';
      if (claves.length > 1) _clave2.text = '${claves[1]}';
      _advertencia.text = '${vr['advertenciaClave'] ?? ''}';
    }
    final dos = d['dosificacion'] as Map?;
    if (dos != null) {
      _series.text = '${dos['series'] ?? 3}';
      _repeticiones.text = '${dos['repeticiones'] ?? ''}';
      _descanso.text = '${dos['descanso'] ?? ''}';
      _pesoInicial.text = '${dos['pesoInicial'] ?? ''}';
    }
    _ejecutar = [
      for (final s in (d['ejecutar'] as List?) ?? [])
        TextEditingController(text: '$s')
    ];
    _errores = [
      for (final s in (d['errores'] as List?) ?? [])
        TextEditingController(text: '$s')
    ];
    final seg = d['seguridad'] as Map?;
    if (seg != null) {
      _senalParada.text = '${seg['senalParada'] ?? ''}';
      _autoVerificacion.text = '${seg['autoVerificacion'] ?? ''}';
    }
    _regresion.text = '${d['regresion'] ?? ''}';
  }

  static String _slugDesdeTitulo(String titulo) {
    const mapa = {
      'á': 'a',
      'é': 'e',
      'í': 'i',
      'ó': 'o',
      'ú': 'u',
      'ü': 'u',
      'ñ': 'n',
    };
    var s = titulo.trim().toLowerCase();
    mapa.forEach((k, v) => s = s.replaceAll(k, v));
    s = s.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    s = s.replaceAll(RegExp(r'-+'), '-');
    return s.replaceAll(RegExp(r'^-|-$'), '');
  }

  List<String> _listaDeTexto(String raw) => raw
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Map<String, dynamic> _fichaActual() {
    final claves = [_clave1.text.trim(), _clave2.text.trim()]
        .where((e) => e.isNotEmpty)
        .toList();
    return {
      'id': _slug.text.trim(),
      'titulo': _titulo.text.trim(),
      'sinonimos': _sinonimos,
      'equipoId': _equipoId ?? '',
      'musculosPrincipales': _listaDeTexto(_muscPrinc.text),
      'musculosSecundarios': _listaDeTexto(_muscSec.text),
      'siluetaId': _silueta,
      'esencial': _esencial,
      'revisado_entrenador': _revisado,
      'vistaRapida': {
        'ajusteMaquina': _ajuste.text.trim(),
        'claves': claves,
        'advertenciaClave': _advertencia.text.trim(),
      },
      'dosificacion': {
        'series': int.tryParse(_series.text.trim()) ?? 0,
        'repeticiones': _repeticiones.text.trim(),
        'descanso': _descanso.text.trim(),
        'pesoInicial': _pesoInicial.text.trim(),
      },
      'ejecutar': [
        for (final c in _ejecutar) c.text.trim(),
      ].where((e) => e.isNotEmpty).toList(),
      'errores': [
        for (final c in _errores) c.text.trim(),
      ].where((e) => e.isNotEmpty).toList(),
      'seguridad': {
        'senalParada': _senalParada.text.trim(),
        'autoVerificacion': _autoVerificacion.text.trim(),
      },
      'regresion': _regresion.text.trim(),
      'tiene_imagen': _tieneImagen,
    };
  }

  Map<String, dynamic> _borradorActual() => {
        'slug': _slug.text.trim(),
        'data': jsonEncode(_fichaActual()),
        'equipoId': _equipoId ?? '',
        'esencial': _esencial ? 1 : 0,
        'tiene_imagen': _tieneImagen ? 1 : 0,
        'imagen_cambiada': _imagenCambiada ? 1 : 0,
        'imagen_local': _imagenLocal,
        'base_revision': _baseRevision,
        'actualizado_ts': isoHabana(ahoraHabana()),
      };

  void _aviso(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _guardarBorrador() async {
    // Ronda 17 M3-H1.
    if (!AuthService().isOwner) return;
    if (_slug.text.trim().isEmpty) {
      _slug.text = _slugDesdeTitulo(_titulo.text);
    }
    if (_slug.text.trim().isEmpty) {
      _aviso('Primero escribe el título para generar el identificador.');
      return;
    }
    await _db.guiaGuardarBorrador(_borradorActual());
    _aviso('Borrador guardado en este teléfono.');
  }

  Future<bool> _chequearObsoleto() async {
    final actual = await _db.guiaPublicada(_slug.text.trim());
    if (actual == null) return true;
    final rev = (actual['revision'] as num?)?.toInt() ?? 0;
    if (rev <= _baseRevision) return true;
    if (!mounted) return false;
    final recargar = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('La ficha cambió'),
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
    if (recargar == true && mounted) {
      final doc = await _db.guiaPublicada(_slug.text.trim());
      if (doc != null) {
        // Ronda 17 M3-H2: la recarga también reemplaza el borrador
        // PERSISTIDO y borra la imagen local vieja (igual que
        // GympediaEditorScreen): si no, al salir sin guardar
        // reaparece el borrador obsoleto.
        final rutaVieja = _imagenLocal;
        setState(() {
          _cargarDoc(doc);
          _baseRevision = (doc['revision'] as num?)?.toInt() ?? 0;
          _imagenRev = (doc['imagen_rev'] as num?)?.toInt() ?? 0;
          _tieneImagen =
              doc['tiene_imagen'] == true || doc['tiene_imagen'] == 1;
          _imagenCambiada = false;
          _imagenLocal = '';
        });
        await _db.guiaEliminarBorrador(_slug.text.trim());
        if (rutaVieja.isNotEmpty) {
          await _db.guiaBorrarImagenLocal(rutaVieja);
        }
      }
    }
    return false;
  }

  Future<void> _publicar() async {
    // Ronda 17 M3-H1.
    if (!AuthService().isOwner) return;
    if (_ocupado) return;
    if (_slug.text.trim().isEmpty) {
      _slug.text = _slugDesdeTitulo(_titulo.text);
    }
    setState(() => _ocupado = true);
    try {
      if (!await _chequearObsoleto()) return;
      final a = _fichaActual();
      final equipos = await _db.guiaEquipos();
      final vigentes = {
        for (final e in equipos)
          if (e['activo'] == true) '${e['equipoId']}',
      };
      final errores =
          GuiaValidacion.validar(a, equiposVigentes: vigentes);
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
      // D7: con 0 esenciales, la primera ficha DEBE ser esencial
      // (el servidor la rechazaría si no). Se avisa antes de la
      // vista previa para no quemar una op condenada.
      if (_esenciales == 0 && !_esencial) {
        if (!mounted) return;
        final marcar = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('Aún no hay esenciales'),
            content: const Text(
                'La primera ficha de la Guía debe ser esencial. '
                '¿La marcas como esencial?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(c, false),
                  child: const Text('Cancelar')),
              FilledButton(
                  onPressed: () => Navigator.pop(c, true),
                  child: const Text('Marcar como esencial')),
            ],
          ),
        );
        if (marcar == true) {
          setState(() => _esencial = true);
          // Argón P2#12-parte: la vista previa se construye con `a`
          // (tomado antes del setState); sin esto mostraba el mapa
          // viejo sin el chip Esencial (el payload sí salía bien).
          a['esencial'] = true;
        } else {
          return;
        }
      }
      // M4: vista previa en modo sala antes de publicar.
      if (!mounted) return;
      final confirmar = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text('${a['titulo']}'),
          content: SingleChildScrollView(child: _vistaPrevia(a)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Seguir editando')),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: const Text('Confirmar y publicar')),
          ],
        ),
      );
      if (confirmar != true) return;
      final slug = '${a['id']}';
      final quitabaImagen = _imagenCambiada && !_tieneImagen;
      if (_imagenCambiada && _tieneImagen && _imagenLocal.isNotEmpty) {
        if (!await _subirImagen(slug)) return;
      }
      final payload = Map<String, dynamic>.from(_fichaActual())
        ..['base_revision'] = _baseRevision;
      await _db.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'guia_upsert_publicado',
        payload: payload,
      );
      final optimista = Map<String, dynamic>.from(_fichaActual())
        ..remove('imagen_cambiada')
        ..['revision'] = _baseRevision + 1
        ..['imagen_rev'] = _imagenRev;
      await _db.upsertMirrorTexto('guia_fichas', slug, optimista, 0);
      final rutaSubida = _imagenLocal;
      _baseRevision = _baseRevision + 1;
      _imagenCambiada = false;
      _imagenLocal = '';
      await _db.guiaGuardarBorrador(_borradorActual());
      if (rutaSubida.isNotEmpty) {
        await _db.guiaBorrarImagenLocal(rutaSubida);
      }
      if (quitabaImagen) await _borrarImagenRemota(slug);
      _aviso('Publicado. Se enviará al servidor al sincronizar.');
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Widget _vistaPrevia(Map<String, dynamic> a) {
    final vr = a['vistaRapida'] as Map;
    final dos = a['dosificacion'] as Map;
    final seg = a['seguridad'] as Map;
    final nombreEquipo = _equipos
        .where((e) => '${e['equipoId']}' == '${a['equipoId']}')
        .map((e) => '${e['equipoNombre']}')
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
            '${nombreEquipo ?? a['equipoId']} · '
            '${GuiaValidacion.nombreSilueta['${a['siluetaId']}'] ?? a['siluetaId']}',
            style: const TextStyle(color: Colors.grey)),
        if (a['esencial'] == true)
          const Chip(
              label: Text('Esencial'),
              visualDensity: VisualDensity.compact),
        const SizedBox(height: 8),
        const Text('Ajuste de máquina',
            style: TextStyle(fontWeight: FontWeight.bold)),
        Text('${vr['ajusteMaquina']}'),
        const SizedBox(height: 8),
        const Text('Claves', style: TextStyle(fontWeight: FontWeight.bold)),
        for (final c in (vr['claves'] as List)) Text('• $c'),
        const SizedBox(height: 8),
        const Text('Advertencia',
            style: TextStyle(fontWeight: FontWeight.bold)),
        Text('${vr['advertenciaClave']}'),
        const SizedBox(height: 8),
        const Text('Dosificación',
            style: TextStyle(fontWeight: FontWeight.bold)),
        Text(
            '${dos['series']} series · ${dos['repeticiones']} · '
            'descanso ${dos['descanso']} · inicio ${dos['pesoInicial']}'),
        const SizedBox(height: 8),
        const Text('Ejecución',
            style: TextStyle(fontWeight: FontWeight.bold)),
        for (var i = 0; i < (a['ejecutar'] as List).length; i++)
          Text('${i + 1}. ${(a['ejecutar'] as List)[i]}'),
        const SizedBox(height: 8),
        const Text('Seguridad',
            style: TextStyle(fontWeight: FontWeight.bold)),
        Text('Parada: ${seg['senalParada']}'),
        Text('Verificación: ${seg['autoVerificacion']}'),
        if ('${a['regresion']}'.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text('Regresión',
              style: TextStyle(fontWeight: FontWeight.bold)),
          Text('${a['regresion']}'),
        ],
      ],
    );
  }

  Future<bool> _subirImagen(String slug) async {
    // Ronda 17 M3-H1: subir al bucket público es solo del dueño.
    if (!AuthService().isOwner) return false;
    try {
      final bytes = await File(_imagenLocal).readAsBytes();
      final token = AuthService().session?.accessToken ?? '';
      final r = await http
          .post(
            Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
                '${AppConfig.bucketGuia}/$slug.webp'),
            headers: {
              'apikey': AppConfig.anonKey,
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
              'Content-Type': 'image/webp',
              'x-upsert': 'true',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 60));
      if (r.statusCode == 200 || r.statusCode == 201) return true;
      _aviso('La subida de la imagen falló (HTTP ${r.statusCode}). '
          'No se publicó nada; revisa la conexión e inténtalo de nuevo.');
    } catch (_) {
      _aviso('La subida de la imagen falló. No se publicó nada; '
          'revisa la conexión e inténtalo de nuevo.');
    }
    return false;
  }

  Future<void> _borrarImagenRemota(String slug) async {
    // Ronda 17 M3-H1: borrar del bucket público es solo del dueño.
    if (!AuthService().isOwner) return;
    try {
      final token = AuthService().session?.accessToken ?? '';
      await http
          .delete(
            Uri.parse('${AppConfig.supabaseUrl}/storage/v1/object/'
                '${AppConfig.bucketGuia}/$slug.webp'),
            headers: {
              'apikey': AppConfig.anonKey,
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 30));
    } catch (_) {}
  }

  Future<void> _elegirImagen() async {
    final slug = _slug.text.trim();
    if (!GuiaValidacion.slugValido(slug)) {
      _aviso('Primero define el identificador de la ficha.');
      return;
    }
    final img = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 1024, maxHeight: 1024);
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
      final rutaVieja = _imagenLocal;
      final ruta = await _db.guiaGuardarImagenLocal(slug, bytes);
      if (rutaVieja.isNotEmpty && rutaVieja != ruta) {
        await _db.guiaBorrarImagenLocal(rutaVieja);
      }
      setState(() {
        _imagenLocal = ruta;
        _tieneImagen = true;
        _imagenCambiada = true;
      });
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _quitarImagen() async {
    if (_imagenLocal.isNotEmpty) {
      await _db.guiaBorrarImagenLocal(_imagenLocal);
    }
    setState(() {
      _imagenLocal = '';
      _tieneImagen = false;
      _imagenCambiada = true;
    });
  }

  Future<void> _retirar() async {
    // Ronda 17 M3-H1.
    if (!AuthService().isOwner) return;
    if (!_publicadoExiste || _ocupado) return;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Retirar ficha'),
        content: const Text(
            'La ficha dejará de verse en la app de clientes. '
            'El borrador se conserva.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Retirar')),
        ],
      ),
    );
    if (confirmar != true) return;
    setState(() => _ocupado = true);
    try {
      await _db.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'guia_retirar',
        payload: {
          'id': _slug.text.trim(),
          'base_revision': _baseRevision,
        },
      );
      await _db.guiaEliminarPublicada(_slug.text.trim());
      _aviso('Retirada. Se enviará al servidor al sincronizar.');
      if (mounted) Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Widget _campo(TextEditingController c, String etiqueta,
      {int maxLines = 1, String? ayuda, TextInputType? tipo}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        keyboardType: tipo,
        decoration: InputDecoration(
          labelText: etiqueta,
          helperText: ayuda,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _seccion(String titulo, List<Widget> hijos) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Text(titulo, style: AppTexto.subtitulo),
        const SizedBox(height: 8),
        ...hijos,
      ],
    );
  }

  Widget _listaEditable(String titulo, List<TextEditingController> items,
      void Function(List<TextEditingController>) onCambio, int maximo) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(titulo, style: AppTexto.subtitulo)),
            Text('${items.length}/$maximo',
                style: const TextStyle(color: Colors.grey)),
            IconButton(
              tooltip: 'Añadir',
              onPressed: items.length >= maximo
                  ? null
                  : () {
                      setState(() {
                        items.add(TextEditingController());
                        onCambio(items);
                      });
                    },
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        ReorderableListView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          // onReorderItem ya trae el índice ajustado (sin el -1
          // manual del onReorder viejo).
          onReorderItem: (viejo, nuevo) {
            setState(() {
              final item = items.removeAt(viejo);
              items.insert(nuevo, item);
              onCambio(items);
            });
          },
          children: [
            for (var i = 0; i < items.length; i++)
              Padding(
                key: ValueKey('item_$i'),
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.drag_handle, color: Colors.grey),
                    const SizedBox(width: 4),
                    Expanded(
                      child: TextField(
                        controller: items[i],
                        maxLines: 2,
                        decoration: InputDecoration(
                          labelText: '${i + 1}',
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Quitar',
                      onPressed: items.length <= 1
                          ? null
                          : () {
                              setState(() {
                                // Ronda 17 M3-H3: liberar el
                                // controlador antes de quitarlo.
                                items[i].dispose();
                                items.removeAt(i);
                                onCambio(items);
                              });
                            },
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Ficha')),
        body: const Center(
            child: Text('Solo el dueño administra la Biblioteca.')),
      );
    }
    final slugBloqueado = _publicadoExiste || _baseRevision > 0;
    return Scaffold(
      appBar: AppBar(
          title: Text(_slug.text.isEmpty ? 'Nueva ficha' : _slug.text)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
        children: [
          _seccion('Identificación', [
            _campo(_titulo, 'Título'),
            TextField(
              controller: _slug,
              readOnly: slugBloqueado,
              decoration: InputDecoration(
                labelText: 'Identificador (slug)',
                helperText: slugBloqueado
                    ? 'Bloqueado tras publicar (no se puede cambiar).'
                    : 'Se genera desde el título: minúsculas y guiones.',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              // initialValue + clave por valor: si el borrador se
              // recarga (obsoleto), el campo se reconstruye con el
              // nuevo valor en vez de quedarse con el viejo.
              key: ValueKey('equipo_${_equipoId ?? ''}'),
              initialValue:
                  _equipos.any((e) => '${e['equipoId']}' == _equipoId)
                      ? _equipoId
                      : null,
              decoration: const InputDecoration(
                labelText: 'Equipo (nunca texto libre)',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final e in _equipos)
                  DropdownMenuItem(
                    value: '${e['equipoId']}',
                    child: Text('${e['equipoNombre']}'),
                  ),
              ],
              onChanged: (v) => setState(() => _equipoId = v),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _sinonimoNuevo,
                    decoration: const InputDecoration(
                      labelText: 'Sinónimo (máx. 6)',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _agregarSinonimo(),
                  ),
                ),
                IconButton(
                  tooltip: 'Añadir sinónimo',
                  onPressed: _agregarSinonimo,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            if (_sinonimos.isNotEmpty)
              Wrap(
                spacing: 6,
                children: [
                  for (final s in _sinonimos)
                    Chip(
                      label: Text(s),
                      onDeleted: () =>
                          setState(() => _sinonimos.remove(s)),
                    ),
                ],
              ),
          ]),
          _seccion('Músculos y silueta', [
            _campo(_muscPrinc, 'Músculos principales',
                ayuda: 'Separados por comas (1–6).'),
            _campo(_muscSec, 'Músculos secundarios',
                ayuda: 'Separados por comas (0–6).'),
            DropdownButtonFormField<String>(
              key: ValueKey('silueta_$_silueta'),
              initialValue: GuiaValidacion.siluetas.contains(_silueta)
                  ? _silueta
                  : null,
              decoration: const InputDecoration(
                labelText: 'Silueta',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final s in GuiaValidacion.siluetas)
                  DropdownMenuItem(
                    value: s,
                    child: Text(
                        GuiaValidacion.nombreSilueta[s] ?? s),
                  ),
              ],
              onChanged: (v) => setState(() => _silueta = v ?? 'pecho'),
            ),
          ]),
          _seccion('Esencial', [
            SwitchListTile(
              title: const Text('Ficha esencial'),
              value: _esencial,
              onChanged: (v) => setState(() => _esencial = v),
            ),
            Text(
              '$_esenciales esenciales publicados '
              '(recomendado 4–7; el aviso no bloquea).',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            SwitchListTile(
              title: const Text('Revisado por entrenador'),
              value: _revisado,
              onChanged: (v) => setState(() => _revisado = v),
            ),
          ]),
          _seccion('Vista rápida', [
            _campo(_ajuste, 'Ajuste de máquina', maxLines: 3),
            _campo(_clave1, 'Clave 1'),
            _campo(_clave2, 'Clave 2 (opcional)'),
            _campo(_advertencia, 'Advertencia clave', maxLines: 3),
          ]),
          _seccion('Dosificación', [
            _campo(_series, 'Series (1–10)',
                tipo: TextInputType.number),
            _campo(_repeticiones, 'Repeticiones'),
            _campo(_descanso, 'Descanso'),
            _campo(_pesoInicial, 'Peso inicial'),
          ]),
          _listaEditable(
              'Ejecutar', _ejecutar, (l) => _ejecutar = l, 12),
          _listaEditable(
              'Errores', _errores, (l) => _errores = l, 12),
          _seccion('Seguridad', [
            _campo(_senalParada, 'Señal de parada', maxLines: 3),
            _campo(_autoVerificacion, 'Auto-verificación', maxLines: 3),
          ]),
          _seccion('Regresión', [
            _campo(_regresion, 'Regresión (si queda vacía, se avisa)',
                maxLines: 2),
            if (_regresion.text.trim().isEmpty)
              const Text(
                'Aviso: sin regresión, la ficha queda incompleta '
                'para quien no pueda con la versión completa.',
                style: TextStyle(fontSize: 12, color: Colors.orange),
              ),
          ]),
          _seccion('Imagen (1 por ficha)', [
            if (_tieneImagen && _imagenLocal.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Image.file(File(_imagenLocal), height: 160),
              )
            else if (_tieneImagen && _publicadoExiste)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Image.network(
                  // Argón P2#14: revienta la caché tras republicar.
                  '${AppConfig.supabaseUrl}/storage/v1/object/public/'
                  '${AppConfig.bucketGuia}/${_slug.text.trim()}.webp'
                  '?v=$_imagenRev',
                  height: 160,
                  errorBuilder: (_, __, ___) =>
                      const Text('Sin vista previa de la imagen.'),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _ocupado ? null : _elegirImagen,
                    icon: const Icon(Icons.image),
                    label: const Text('Elegir imagen'),
                  ),
                ),
                if (_tieneImagen) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _ocupado ? null : _quitarImagen,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Quitar imagen'),
                    ),
                  ),
                ],
              ],
            ),
            const Text(
              'La imagen solo se sube al publicar; un borrador '
              'nunca altera la imagen ya publicada.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ]),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _ocupado ? null : _guardarBorrador,
            icon: const Icon(Icons.save),
            label: const Text('Guardar borrador'),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _ocupado ? null : _publicar,
            icon: const Icon(Icons.publish),
            label: const Text('Publicar (con vista previa)'),
          ),
          if (_publicadoExiste) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _ocupado ? null : _retirar,
              icon: const Icon(Icons.visibility_off),
              label: const Text('Retirar ficha'),
            ),
          ],
        ],
      ),
    );
  }

  void _agregarSinonimo() {
    final s = _sinonimoNuevo.text.trim();
    if (s.isEmpty) return;
    if (_sinonimos.length >= 6) {
      _aviso('Como máximo 6 sinónimos.');
      return;
    }
    if (_sinonimos.contains(s)) {
      _aviso('Sinónimo repetido.');
      return;
    }
    setState(() {
      _sinonimos.add(s);
      _sinonimoNuevo.clear();
    });
  }

  @override
  void dispose() {
    _titulo.dispose();
    _slug.dispose();
    _sinonimoNuevo.dispose();
    _muscPrinc.dispose();
    _muscSec.dispose();
    _ajuste.dispose();
    _clave1.dispose();
    _clave2.dispose();
    _advertencia.dispose();
    _series.dispose();
    _repeticiones.dispose();
    _descanso.dispose();
    _pesoInicial.dispose();
    _senalParada.dispose();
    _autoVerificacion.dispose();
    _regresion.dispose();
    for (final c in _ejecutar) {
      c.dispose();
    }
    for (final c in _errores) {
      c.dispose();
    }
    super.dispose();
  }
}
