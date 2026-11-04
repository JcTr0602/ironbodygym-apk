// lib/ui/guia_lista.dart
// Biblioteca / Guía (v47) — SOLO DUEÑO. Lista de fichas agrupada
// POR EQUIPO en orden canónico, con borradores locales, buscador,
// botón de publicar todos los borradores válidos y actividad
// reciente de este teléfono. Publicar/retirar viaja como op por
// la cola de sync; el espejo se actualiza optimista y el pull lo
// confirma (mismo patrón que GymPedia).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../config.dart';
import '../guia_validacion.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'diseno.dart';
import 'guia_editor.dart';
import 'guia_equipos.dart';
import 'componentes.dart';

/// 1.22 GY-05 (PURO): esenciales que quedarían tras publicar
/// [candidatosDoc], fusionando POR SLUG sobre [publicadas]:
/// un candidato que edita una ficha ya publicada la REEMPLAZA
/// (antes sumaba: la publicada esencial + el mismo borrador
/// contaban dos veces y la regla D7 se evaluaba mal), y el
/// flag esencial se lee del DOCUMENTO del borrador
/// (_docBorrador), no de la fila cruda.
int esencialesTrasPublicar({
  required List<Map<String, dynamic>> publicadas,
  required List<Map<String, dynamic>> candidatosDoc,
}) {
  bool esEsencial(Object? v) => v == true || v == 1;
  final porSlug = <String, bool>{
    for (final p in publicadas) '${p['id']}': esEsencial(p['esencial']),
  };
  for (final doc in candidatosDoc) {
    porSlug['${doc['id']}'] = esEsencial(doc['esencial']);
  }
  return porSlug.values.where((e) => e).length;
}

class GuiaScreen extends StatefulWidget {
  const GuiaScreen({super.key});

  @override
  State<GuiaScreen> createState() => _GuiaScreenState();
}

class _GuiaScreenState extends State<GuiaScreen> {
  final _db = LocalDb.instance;
  List<Map<String, dynamic>> _publicadas = [];
  List<Map<String, dynamic>> _borradores = [];
  List<Map<String, dynamic>> _equipos = [];
  List<Map<String, dynamic>> _actividad = [];
  bool _cargando = true;
  bool _sincronizando = false;
  bool _publicandoLote = false;
  bool _soloEsenciales = false;
  String _busqueda = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  /// 1.22 GY-04: slugs de borradores ya publicados desde
  /// este teléfono cuya op sigue en cola (marca en meta
  /// `guia_en_cola_<slug>`, la pone el editor/lote al publicar
  /// y la quita una nueva edición guardada).
  Set<String> _enCola = {};

  Future<void> _cargar() async {
    // 1.22 GY-02: sin dueño no se carga nada (defensa en
    // profundidad; build ya lo bloquea visualmente).
    if (!AuthService().isOwner) {
      if (mounted) setState(() => _cargando = false);
      return;
    }
    final pub = await _db.guiaPublicadas();
    final bor = await _db.guiaBorradores();
    final eq = await _db.guiaEquipos();
    final act = await _db.opsRecientesBiblioteca();
    final marcas = await _db.metasConPrefijo('guia_en_cola_');
    // Panel Pieza 7: la marca se AUTOLIMPIA al cargar si el
    // borrador ya no existe o su op ya se resolvió (aplicada
    // o rechazada): sin esto quedaba pegada para siempre y
    // el lote excluía el slug eternamente.
    final enCola = <String>{};
    for (final k in marcas) {
      if (k.isEmpty) continue;
      final slug = k.substring('guia_en_cola_'.length);
      final existeBorrador = bor.any((b) => '${b['slug']}' == slug);
      if (existeBorrador && await _db.upsertBibliotecaEnCola(slug)) {
        enCola.add(slug);
      } else {
        await _db.setMeta(k, '');
      }
    }
    if (!mounted) return;
    setState(() {
      _publicadas = pub;
      _borradores = bor;
      _equipos = eq;
      _actividad = act;
      _enCola = enCola;
      _cargando = false;
    });
  }

  Future<void> _sincronizar() async {
    if (_sincronizando) return;
    setState(() => _sincronizando = true);
    // 1.22 GY-06: snack honesto — «actualizada» solo si el
    // ciclo corrió; si no, se dice que manda el catálogo local.
    var corrio = false;
    try {
      corrio = await SyncEngine.instance.sincronizarScope('guia');
    } catch (_) {}
    await _cargar();
    if (!mounted) return;
    setState(() => _sincronizando = false);
    if (corrio) {
      mostrarSnack(context, 'Guía actualizada',
          significado: SignificadoChip.exito);
    } else {
      mostrarSnack(context, 'Sin conexión: catálogo local');
    }
  }

  Map<String, dynamic>? _publicadaDe(String slug) {
    for (final p in _publicadas) {
      if ('${p['id']}' == slug) return p;
    }
    return null;
  }

  bool _obsoleto(Map<String, dynamic> borrador) {
    final pub = _publicadaDe('${borrador['slug']}');
    if (pub == null) return false;
    final revPub = (pub['revision'] as num?)?.toInt() ?? 0;
    final base = (borrador['base_revision'] as num?)?.toInt() ?? 0;
    return revPub > base;
  }

  Set<String> get _equiposVigentes => {
        for (final e in _equipos)
          if (e['activo'] == true) '${e['equipoId']}',
      };

  String _nombreEquipo(String equipoId) {
    for (final e in _equipos) {
      if ('${e['equipoId']}' == equipoId) return '${e['equipoNombre']}';
    }
    return equipoId;
  }

  static String _sinAcentos(String s) {
    const mapa = {
      'á': 'a',
      'é': 'e',
      'í': 'i',
      'ó': 'o',
      'ú': 'u',
      'ü': 'u',
      'ñ': 'n',
      'Á': 'A',
      'É': 'E',
      'Í': 'I',
      'Ó': 'O',
      'Ú': 'U',
      'Ü': 'U',
      'Ñ': 'N',
    };
    var out = s;
    mapa.forEach((k, v) => out = out.replaceAll(k, v));
    return out.toLowerCase();
  }

  bool _coincideBusqueda(Map<String, dynamic> ficha) {
    if (_busqueda.trim().isEmpty) return true;
    final q = _sinAcentos(_busqueda.trim());
    final titulo = _sinAcentos('${ficha['titulo'] ?? ''}');
    final equipo = _sinAcentos(_nombreEquipo('${ficha['equipoId'] ?? ''}'));
    final musc = _sinAcentos(
        ((ficha['musculosPrincipales'] as List?) ?? []).join(' '));
    final sinon =
        _sinAcentos(((ficha['sinonimos'] as List?) ?? []).join(' '));
    return titulo.contains(q) ||
        equipo.contains(q) ||
        musc.contains(q) ||
        sinon.contains(q);
  }

  Map<String, dynamic> _docBorrador(Map<String, dynamic> b) {
    try {
      final m = Map<String, dynamic>.from(
          jsonDecode('${b['data']}') as Map);
      m['id'] = '${b['slug']}';
      return m;
    } catch (_) {
      return {'id': '${b['slug']}', 'titulo': ''};
    }
  }

  Future<void> _abrirEditor(
      {Map<String, dynamic>? publicado,
      Map<String, dynamic>? borrador}) async {
    await Navigator.of(context).push(RutaIron(
      builder: (_) => GuiaEditorScreen(
        publicado: publicado,
        borrador: borrador,
      ),
    ));
    await _cargar();
  }

  Future<void> _publicarLote() async {
    // 1.22 GY-02: publicar en lote es solo del dueño.
    if (!AuthService().isOwner) return;
    if (_publicandoLote || _borradores.isEmpty) return;
    // Argón Guía HIGH 2 (1.19), pre-paso: candidatos reales (no
    // obsoletos + válidos) y regla D7. Sin este pre-paso el lote
    // encolaba a ciegas: si quedaban 0 esenciales, el servidor
    // rechazaba las ops y el espejo optimista ya las daba por
    // publicadas. Sin esenciales tras el lote, se aborta antes
    // de encolar nada.
    bool esEsencial(Object? v) => v == true || v == 1;
    final candidatos = <Map<String, dynamic>>[];
    final motivos = <String>[];
    for (final b in _borradores) {
      // 1.22 GY-04: ya publicado desde este teléfono (op en
      // cola): no se vuelve a encolar.
      if (_enCola.contains('${b['slug']}')) {
        motivos.add(
            '${b['slug']}: ya está en cola de publicación.');
        continue;
      }
      if (_obsoleto(b)) {
        motivos.add(
            '${b['slug']}: obsoleto (hay una versión publicada más reciente).');
        continue;
      }
      final doc = _docBorrador(b);
      final errores = GuiaValidacion.validar(doc,
          equiposVigentes: _equiposVigentes);
      if (errores.isNotEmpty) {
        motivos.add('${doc['id']}: ${errores.first}');
        continue;
      }
      candidatos.add(b);
    }
    // 1.22 GY-05: fusión por slug con el flag del documento.
    final esencialesTras = esencialesTrasPublicar(
      publicadas: _publicadas,
      candidatosDoc: [for (final b in candidatos) _docBorrador(b)],
    );
    if (esencialesTras == 0) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Falta una ficha esencial'),
          content: const Text(
              'El lote no trae ninguna ficha esencial y aún no hay '
              'esenciales publicadas. Marca al menos una como esencial '
              'antes de publicar en lote.'),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Entendido')),
          ],
        ),
      );
      return;
    }
    if (candidatos.isEmpty) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Ningún borrador pasa la validación'),
          content: SingleChildScrollView(
            child: Text(motivos.map((f) => '• $f').join('\n')),
          ),
          actions: [
            FilledButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('Entendido')),
          ],
        ),
      );
      return;
    }
    // Resumen de contenido antes de confirmar (HIGH 2, segunda
    // mitad): el diálogo anterior solo daba el conteo; ahora el
    // dueño ve QUÉ va a publicar, con su marca de esencial.
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Publicar ${candidatos.length} borradores'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final b in candidatos)
                Text(
                    '• ${_docBorrador(b)['titulo']} '
                    '${esEsencial(b['esencial']) ? '(Esencial)' : ''}'),
              if (motivos.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                    'Se quedan como borradores (${motivos.length}):\n'
                    '${motivos.map((f) => '• $f').join('\n')}'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Publicar')),
        ],
      ),
    );
    if (confirmar != true || !mounted) return;
    setState(() => _publicandoLote = true);
    var ok = 0;
    final fallos = <String>[];
    try {
      for (final b in List.of(_borradores)) {
        // 1.22 GY-04: en cola de publicación no se re-encola.
        if (_enCola.contains('${b['slug']}')) {
          fallos.add(
              '${b['slug']}: ya está en cola de publicación.');
          continue;
        }
        // Argón P2#13: un borrador obsoleto no se encola ni pierde
        // su imagen local; queda en fallos para revisarlo.
        if (_obsoleto(b)) {
          fallos.add(
              '${b['slug']}: borrador obsoleto (hay una versión publicada más reciente).');
          continue;
        }
        final doc = _docBorrador(b);
        final slug = '${doc['id']}';
        final errores = GuiaValidacion.validar(doc,
            equiposVigentes: _equiposVigentes);
        if (errores.isNotEmpty) {
          fallos.add('$slug: ${errores.first}');
          continue;
        }
        final tieneImagen = b['tiene_imagen'] == 1 || b['tiene_imagen'] == true;
        final cambioImagen =
            b['imagen_cambiada'] == 1 || b['imagen_cambiada'] == true;
        final local = '${b['imagen_local'] ?? ''}';
        if (cambioImagen && tieneImagen && local.isNotEmpty) {
          if (!await _subirImagen(slug, local)) {
            fallos.add('$slug: la imagen no se pudo subir.');
            continue;
          }
        }
        final base = (b['base_revision'] as num?)?.toInt() ?? 0;
        final payload = Map<String, dynamic>.from(doc)
          ..['base_revision'] = base
          // Argón Guía HIGH 1 (1.19): igual que en el editor, sin
          // esta llave el servidor no subía imagen_rev al
          // reemplazar una foto existente.
          ..['imagen_cambiada'] = cambioImagen;
        await _db.queueOp(
          opUuid: const Uuid().v4(),
          tipo: 'guia_upsert_publicado',
          payload: payload,
        );
        // imagen_rev base: la publicada para este slug (0 si es
        // nueva). Si la imagen cambió, el servidor la subirá en 1
        // y el espejo local lo refleja al instante.
        var revPub = 0;
        for (final p in _publicadas) {
          if ('${p['id']}' == slug) {
            revPub = (p['imagen_rev'] as num?)?.toInt() ?? 0;
            break;
          }
        }
        final optimista = Map<String, dynamic>.from(doc)
          ..['revision'] = base + 1
          ..['imagen_rev'] = cambioImagen ? revPub + 1 : revPub;
        await _db.upsertMirrorTexto('guia_fichas', slug, optimista, 0);
        await _db.guiaGuardarBorrador({
          ...b,
          'base_revision': base + 1,
          'imagen_cambiada': 0,
          'imagen_local': '',
          'actualizado_ts': isoHabana(ahoraHabana()),
        });
        if (local.isNotEmpty) await _db.guiaBorrarImagenLocal(local);
        // 1.22 GY-03: NO borrar el .webp del bucket al
        // publicar: la op aún no viajó y si el servidor la
        // rechaza, la ficha publicada quedaría apuntando a
        // una imagen borrada. Con tiene_imagen=false las apps
        // dejan de mostrarla; el objeto huérfano se limpia en
        // el servidor (pendiente anotado), nunca por adelantado.
        // 1.22 GY-04: marca de «en cola de publicación».
        await _db.setMeta('guia_en_cola_$slug', '1');
        ok++;
      }
    } finally {
      if (mounted) setState(() => _publicandoLote = false);
    }
    await _cargar();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Publicación en lote'),
        content: SingleChildScrollView(
          child: Text(
            'Publicados: $ok.\n'
            '${fallos.isEmpty ? 'Sin fallos.' : 'Fallos:\n${fallos.map((f) => '• $f').join('\n')}'}',
          ),
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Entendido')),
        ],
      ),
    );
  }

  Future<bool> _subirImagen(String slug, String local) async {
    // 1.22 GY-02: subir al bucket público es solo del dueño.
    if (!AuthService().isOwner) return false;
    try {
      final bytes = await _leerArchivo(local);
      if (bytes == null) return false;
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
      return r.statusCode == 200 || r.statusCode == 201;
    } catch (_) {
      return false;
    }
  }

  Future<List<int>?> _leerArchivo(String ruta) async {
    try {
      return await File(ruta).readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return const Center(
          child: Text('Solo el dueño administra la Biblioteca.'));
    }
    if (_cargando) {
      return const EstadoCargando(texto: 'Cargando guía…');
    }
    final esenciales = _publicadas.where((p) => p['esencial'] == true).length;
    final publicadasFiltradas = _publicadas.where((p) {
      if (_soloEsenciales && p['esencial'] != true) return false;
      return _coincideBusqueda(p);
    }).toList();
    final borradoresFiltrados = _borradores.where((b) {
      final doc = _docBorrador(b);
      if (_soloEsenciales && doc['esencial'] != true) return false;
      return _coincideBusqueda(doc);
    }).toList();
    // Grupos: equipos activos en orden canónico; las fichas de un
    // equipo que ya no está vigente caen en «Otros» al final.
    final grupos = <String>[];
    for (final e in _equipos) {
      if (e['activo'] == true) grupos.add('${e['equipoId']}');
    }
    final porGrupo = <String, List<Map<String, dynamic>>>{};
    for (final p in publicadasFiltradas) {
      final eq = '${p['equipoId'] ?? ''}';
      final clave = grupos.contains(eq) ? eq : 'Otros';
      (porGrupo[clave] ??= []).add(p);
    }
    if (porGrupo.containsKey('Otros')) grupos.add('Otros');
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      children: [
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
                label: const Text('Nueva ficha'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.of(context)
                    .push(RutaIron(
                        builder: (_) => const GuiaEquiposScreen()))
                    .then((_) => _cargar()),
                icon: const Icon(Icons.fitness_center_rounded),
                label: const Text('Equipamiento'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed:
                    _publicandoLote || _borradores.isEmpty ? null : _publicarLote,
                icon: const Icon(Icons.publish_rounded),
                label: Text(_publicandoLote
                    ? 'Publicando…'
                    : 'Publicar borradores (${_borradores.length})'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          decoration: const InputDecoration(
            labelText: 'Buscar (título, equipo, músculo, sinónimo)',
            prefixIcon: Icon(Icons.search_rounded),
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => setState(() => _busqueda = v),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilterChip(
              label: const Text('Solo esenciales'),
              selected: _soloEsenciales,
              onSelected: (v) => setState(() => _soloEsenciales = v),
            ),
            const SizedBox(width: 8),
            Text(
              '$esenciales esenciales (recomendado 4–7)',
              style: AppTexto.metadato.copyWith(color: Colors.grey),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (borradoresFiltrados.isNotEmpty) ...[
          const Text('Borradores', style: AppTexto.subtitulo),
          const SizedBox(height: 4),
          Text(
            'Solo viven en este teléfono hasta que los publiques.',
            style: AppTexto.metadato.copyWith(color: Colors.grey),
          ),
          const SizedBox(height: 8),
          for (final b in borradoresFiltrados)
            Card(
              child: ListTile(
                leading: Icon(Icons.edit_note_rounded,
                    color: AppColores.textoSecundario(context)),
                title: Text(
                    '${_docBorrador(b)['titulo']}'.isEmpty
                        ? '(sin título)'
                        : '${_docBorrador(b)['titulo']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    '${_nombreEquipo('${_docBorrador(b)['equipoId'] ?? ''}')}'
                    ' · ${_docBorrador(b)['siluetaId'] ?? ''}'),
                trailing: _obsoleto(b)
                    ? const Tooltip(
                        message:
                            'La ficha publicada cambió desde que abriste este borrador',
                        child: Icon(Icons.warning_amber_rounded,
                            color: Colors.red),
                      )
                    : _enCola.contains('${b['slug']}')
                        ? const Chip(
                            label: Text('En cola de publicación',
                                style: AppTexto.metadato),
                            visualDensity: VisualDensity.compact,
                          )
                        : const Chip(
                            label: Text('Borrador',
                                style: AppTexto.metadato),
                            visualDensity: VisualDensity.compact,
                          ),
                onTap: () => _abrirEditor(borrador: b),
              ),
            ),
          const SizedBox(height: 16),
        ],
        Text('Publicadas (${publicadasFiltradas.length})',
            style: AppTexto.subtitulo),
        const SizedBox(height: 8),
        if (publicadasFiltradas.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: AppEspacio.xl),
            child: Text(
              'Aún no bajó ninguna ficha. Toca Actualizar con conexión.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        for (final g in grupos)
          if ((porGrupo[g] ?? []).isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: AppEspacio.md, bottom: AppEspacio.xs),
              child: Text(
                g == 'Otros' ? 'Otros' : _nombreEquipo(g),
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColores.naranja),
              ),
            ),
            for (final p in porGrupo[g]!)
              Card(
                child: ListTile(
                  leading: Icon(Icons.circle_rounded,
                      size: 14,
                      color: p['esencial'] == true
                          ? AppColores.naranja
                          : Colors.grey),
                  title: Text('${p['titulo'] ?? ''}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      '${GuiaValidacion.nombreSilueta['${p['siluetaId']}'] ?? p['siluetaId'] ?? ''}'
                      ' · ${((p['musculosPrincipales'] as List?) ?? []).isNotEmpty ? (p['musculosPrincipales'] as List).first : ''}'
                      ' · Rev. ${(p['revision'] as num?)?.toInt() ?? 1}'
                      '${(p['tiene_imagen'] == true || p['tiene_imagen'] == 1) ? ' · con imagen' : ''}'),
                  trailing: p['esencial'] == true
                      ? const Chip(
                          label: Text('Esencial',
                              style: AppTexto.metadato),
                          visualDensity: VisualDensity.compact,
                        )
                      : const Icon(Icons.chevron_right_rounded),
                  onTap: () => _abrirEditor(publicado: p),
                ),
              ),
          ],
        const SizedBox(height: 16),
        const Text('Actividad reciente', style: AppTexto.subtitulo),
        const SizedBox(height: 4),
        Text(
          'Ops aplicadas de este teléfono (GymPedia y Guía).',
          style: AppTexto.metadato.copyWith(color: Colors.grey),
        ),
        const SizedBox(height: 8),
        if (_actividad.isEmpty)
          const Text('Sin actividad todavía.',
              style: TextStyle(color: Colors.grey)),
        for (final a in _actividad)
          ListTile(
            dense: true,
            leading: const Icon(Icons.history_rounded, size: 18),
            title: Text(_tituloActividad(a),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${a['tipo']} · ${_fechaCorta('${a['creada_ts']}')}'),
          ),
        const SizedBox(height: 12),
        Text(
          'Las fichas se leen sin conexión en la app de clientes. '
          'Publicar y retirar se aplica al sincronizar.',
          style: AppTexto.metadato.copyWith(color: Colors.grey),
        ),
      ],
    );
  }

  String _tituloActividad(Map<String, dynamic> a) {
    try {
      final payload =
          Map<String, dynamic>.from(jsonDecode('${a['payload']}') as Map);
      final titulo = '${payload['titulo'] ?? payload['id'] ?? ''}';
      if (titulo.isNotEmpty) return titulo;
    } catch (_) {}
    return '${a['tipo']}';
  }

  String _fechaCorta(String iso) {
    try {
      final d = DateTime.parse(iso);
      return '${d.day}/${d.month}/${d.year}';
    } catch (_) {
      return iso;
    }
  }
}
