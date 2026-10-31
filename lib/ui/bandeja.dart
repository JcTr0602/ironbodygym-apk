/// Bandeja de solicitudes GymPedia (1.19, v49).
///
/// Pestañas: Pendientes, Publicadas, Descartadas, Borradores y
/// Permisos (esta última solo la ve el dueño). La ve el dueño
/// siempre y cada entrenador solo con permiso otorgado (ver
/// `lib/bandeja.dart`): ver + descartar + borradores; publicar
/// sigue siendo solo dueño.
///
/// Las acciones encolan ops: el cambio se refleja al instante en
/// la lista (fusión con ops pendientes) y se confirma al sincronizar.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../bandeja.dart';
import '../localdb.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'gympedia_editor.dart';

class BandejaScreen extends StatefulWidget {
  const BandejaScreen({super.key});
  @override
  State<BandejaScreen> createState() => _BandejaScreenState();
}

class _BandejaScreenState extends State<BandejaScreen>
    with SingleTickerProviderStateMixin {
  final _db = LocalDb.instance;
  bool _cargando = true;
  bool _acceso = false;
  bool _errorCarga = false;
  bool _esDueno = false;
  int? _miTid;
  bool _guardandoPermiso = false;
  List<Map<String, dynamic>> _solicitudes = [];
  List<Map<String, dynamic>> _borradores = [];
  List<Map<String, dynamic>> _entrenadores = [];
  Map<String, String> _clientes = {};
  Map<String, String> _nombresTid = {};
  late final List<String> _tabs;
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _esDueno = AuthService().isOwner;
    _miTid = AuthService().telegramId;
    _tabs = [
      'Pendientes',
      'Publicadas',
      'Descartadas',
      'Borradores',
      if (_esDueno) 'Permisos',
    ];
    _tab = TabController(length: _tabs.length, vsync: this);
    _cargar();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _errorCarga = false;
    });
    // Panel Terra (alta): la puerta VA ANTES de las lecturas — un
    // entrenador sin permiso no debe ver ni el conteo del título.
    // Si la puerta misma falla (sin espejo), es error de lectura,
    // no «sin permiso»: se muestra el estado de error.
    bool acceso;
    try {
      acceso = await tieneAccesoBandeja();
    } catch (_) {
      if (mounted) {
        setState(() {
          _acceso = true;
          _errorCarga = true;
          _cargando = false;
        });
      }
      return;
    }
    if (!mounted) return;
    if (!acceso) {
      setState(() {
        _acceso = false;
        _solicitudes = [];
        _borradores = [];
        _entrenadores = [];
        _cargando = false;
      });
      return;
    }
    try {
      final solicitudes = await solicitudesBandeja();
      final borradores = await borradoresBandeja();
      final entrenadores =
          _esDueno ? await entrenadoresBandeja() : const <Map<String, dynamic>>[];
      // Argón Gmail-15 #3: los nombres de autores se resuelven
      // para TODOS los que ven la bandeja, no solo para el dueño
      // (antes, un entrenador veía «Entrenador <id>» en borradores
      // de su compañero porque _entrenadores quedaba vacío).
      final nombresTid = await mapaNombresBandeja();
      final clientes = <String, String>{};
      try {
        for (final c in await _db.allMirror('clientes')) {
          clientes['${c['id']}'] = '${c['nombre'] ?? ''}';
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _acceso = true;
        _solicitudes = solicitudes;
        _borradores = borradores;
        _entrenadores = entrenadores;
        _clientes = clientes;
        _nombresTid = nombresTid;
        _cargando = false;
      });
    } catch (_) {
      // Panel Terra (media): error ≠ lista vacía. Un fallo de
      // lectura no se presenta como «Sin solicitudes».
      if (mounted) {
        setState(() {
          _acceso = true;
          _errorCarga = true;
          _cargando = false;
        });
      }
    }
  }

  void _snack(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(texto)));
  }

  String _nombreCliente(dynamic clienteId) {
    final nombre = _clientes['$clienteId'] ?? '';
    return nombre.isNotEmpty ? nombre : 'Cliente $clienteId';
  }

  String _nombreAutor(dynamic tid) {
    if ('$tid' == '$_miTid') return 'Tú';
    return _nombresTid['$tid'] ?? 'Entrenador $tid';
  }

  String _fecha(String? iso) {
    if (iso == null || iso.length < 10) return '';
    return iso.substring(0, 10);
  }

  Future<void> _descartar(Map<String, dynamic> s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Descartar solicitud'),
        content: Text('«${s['tema'] ?? ''}» quedará marcada como '
            'descartada y ya no aparecerá en pendientes.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Descartar')),
        ],
      ),
    );
    if (ok != true) return;
    await descartarSolicitudBandeja('${s['id']}');
    _snack('Se descartará al sincronizar.');
    await _cargar();
  }

  /// Dueño: abre el editor pre-llenado con el tema; al publicar, la
  /// op lleva solicitud_id y el servidor cierra la solicitud.
  Future<void> _escribirArticulo(Map<String, dynamic> s) async {
    final publicados = await _db.gympediaPublicados();
    final slugs = {for (final p in publicados) '${p['id']}'};
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => GympediaEditorScreen(
          borrador: {
            'slug': slugBandeja('${s['tema'] ?? ''}'),
            'titulo': '${s['tema'] ?? ''}',
          },
          solicitudId: '${s['id']}',
          slugsPublicados: slugs,
        ),
      ),
    );
    await _cargar();
  }

  /// Entrenador con permiso: borrador compartido en texto (el dueño
  /// lo abre luego en el editor y lo publica).
  Future<void> _crearBorrador(Map<String, dynamic> s) async {
    final tituloCtrl =
        TextEditingController(text: '${s['tema'] ?? ''}');
    final textoCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Borrador compartido'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: tituloCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Título')),
              const SizedBox(height: 8),
              TextField(
                  controller: textoCtrl,
                  maxLines: 5,
                  decoration:
                      const InputDecoration(labelText: 'Texto (opcional)')),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true) {
      tituloCtrl.dispose();
      textoCtrl.dispose();
      return;
    }
    final titulo = tituloCtrl.text.trim();
    final texto = textoCtrl.text.trim();
    // Argón Gmail-15 #4: los controladores se liberan en cuanto
    // se extrae el texto, en todos los caminos de salida.
    tituloCtrl.dispose();
    textoCtrl.dispose();
    if (titulo.isEmpty) {
      _snack('El borrador necesita un título.');
      return;
    }
    // Panel Terra (baja): un título sin letras ni números da un
    // slug vacío y encolaría una op sin borrador representable.
    final slug = slugBandeja(titulo);
    if (slug.isEmpty) {
      _snack('El título debe tener alguna letra o número.');
      return;
    }
    // Argón Gmail-15 Q7.1: dos borradores con el mismo slug
    // chocan en el servidor (el segundo autor es rechazado).
    // Si ya existe uno con este slug: el mío se edita, el ajeno
    // se avisa para no duplicar trabajo.
    Map<String, dynamic>? existente;
    for (final b in _borradores) {
      if ('${b['id']}' == slug) {
        existente = b;
        break;
      }
    }
    if (existente != null) {
      if ('${existente['autor_telegram_id']}' == '$_miTid') {
        await _editarBorrador(existente);
      } else {
        _snack('Ya hay un borrador con ese título, de '
            '${_nombreAutor(existente['autor_telegram_id'])}. '
            'Cambia el título para no duplicarlo.');
      }
      return;
    }
    await guardarBorradorBandeja(
      slug: slug,
      titulo: titulo,
      texto: texto,
      solicitudId: '${s['id']}',
    );
    _snack('Borrador guardado. Se subirá al sincronizar.');
    await _cargar();
  }

  Future<void> _editarBorrador(Map<String, dynamic> b) async {
    final tituloCtrl =
        TextEditingController(text: '${b['titulo'] ?? ''}');
    final textoCtrl =
        TextEditingController(text: '${b['texto'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Editar borrador'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: tituloCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Título')),
              const SizedBox(height: 8),
              TextField(
                  controller: textoCtrl,
                  maxLines: 5,
                  decoration:
                      const InputDecoration(labelText: 'Texto')),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    if (ok != true) {
      tituloCtrl.dispose();
      textoCtrl.dispose();
      return;
    }
    final titulo = tituloCtrl.text.trim();
    final texto = textoCtrl.text.trim();
    // Argón Gmail-15 #4: ver _crearBorrador.
    tituloCtrl.dispose();
    textoCtrl.dispose();
    if (titulo.isEmpty) {
      _snack('El borrador necesita un título.');
      return;
    }
    await guardarBorradorBandeja(
      slug: '${b['id']}',
      titulo: titulo,
      texto: texto,
    );
    _snack('Borrador actualizado. Se subirá al sincronizar.');
    await _cargar();
  }

  Future<void> _eliminarBorrador(Map<String, dynamic> b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Eliminar borrador'),
        content: Text('«${b['titulo'] ?? ''}» se marcará como '
            'eliminado en todos los teléfonos.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    await eliminarBorradorBandeja('${b['id']}');
    _snack('Se eliminará al sincronizar.');
    await _cargar();
  }

  Future<void> _abrirBorradorEnEditor(Map<String, dynamic> b) async {
    final publicados = await _db.gympediaPublicados();
    final slugs = {for (final p in publicados) '${p['id']}'};
    if (!mounted) return;
    final publicado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => GympediaEditorScreen(
          borrador: {
            'slug': '${b['id']}',
            'titulo': '${b['titulo'] ?? ''}',
            'explicacion_md': '${b['texto'] ?? ''}',
          },
          solicitudId: '${b['solicitud_id'] ?? ''}'.isNotEmpty
              ? '${b['solicitud_id']}'
              : null,
          slugsPublicados: slugs,
        ),
      ),
    );
    // Argón Gmail-15 #1 (2ª parte): al publicar desde un borrador
    // compartido, el borrador ya cumplió su función y quedaba vivo
    // para siempre en la pestaña. Se archiva solo (soft-delete, el
    // texto se conserva en el servidor y se puede restaurar).
    if (publicado == true) {
      await eliminarBorradorBandeja('${b['id']}');
      _snack('Publicado. El borrador compartido se archiva al '
          'sincronizar.');
    }
    await _cargar();
  }

  Widget _vacio(String texto) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(texto, textAlign: TextAlign.center),
        ),
      );

  Widget _tarjetaSolicitud(Map<String, dynamic> s, String estado) {
    final tema = '${s['tema'] ?? ''}';
    final detalle = '${s['detalle'] ?? ''}';
    final pendiente = estado == kBandejaPendiente;
    // Argón Gmail-15 Q7.2: si ya hay un borrador para esta
    // solicitud, se avisa para no redactar dos veces lo mismo.
    String? tituloBorrador;
    for (final b in _borradores) {
      if ('${b['solicitud_id'] ?? ''}' == '${s['id']}') {
        tituloBorrador = '${b['titulo'] ?? ''}';
        break;
      }
    }
    // Argón Gmail-15 #2: la publicación optimista (op en cola)
    // llega aquí con estado 'publicada' y 'pendiente': true.
    final publicacionEnCola =
        !pendiente && s['pendiente'] == true;
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tema, style: AppTexto.subtitulo),
          const SizedBox(height: 4),
          Text(
            '${_nombreCliente(s['cliente_id'])} · '
            '${_fecha('${s['creada_en'] ?? ''}')}',
            style: TextStyle(
                fontSize: 12,
                color: AppColores.textoSecundario(context)),
          ),
          if (detalle.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(detalle),
          ],
          if (pendiente && tituloBorrador != null) ...[
            const SizedBox(height: 6),
            Text(
              'Con borrador: «$tituloBorrador»',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColores.textoSecundario(context)),
            ),
          ],
          if (!pendiente) ...[
            const SizedBox(height: 6),
            Text(
              publicacionEnCola
                  ? 'Publicación en cola · Por subir'
                  : estado == kBandejaPublicada
                      ? 'Publicada como «${s['articulo_id'] ?? ''}»'
                          ' · ${_fecha('${s['cerrada_en'] ?? ''}')}'
                      : 'Descartada · ${_fecha('${s['cerrada_en'] ?? ''}')}',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColores.textoSecundario(context)),
            ),
          ],
          if (pendiente) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () => _descartar(s),
                  child: const Text('Descartar'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _esDueno
                      ? () => _escribirArticulo(s)
                      : () => _crearBorrador(s),
                  child: Text(_esDueno
                      ? 'Escribir artículo'
                      : 'Crear borrador'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _listaSolicitudes(String estado) {
    final lista = solicitudesPorEstado(_solicitudes, estado);
    if (lista.isEmpty) {
      return _vacio(estado == kBandejaPendiente
          ? 'Sin solicitudes pendientes.\nLas nuevas llegan al sincronizar.'
          : estado == kBandejaPublicada
              ? 'Aún no se publicó ningún artículo desde la bandeja.'
              : 'Ninguna solicitud descartada.');
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final s in lista) ...[
          _tarjetaSolicitud(s, estado),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _listaBorradores() {
    if (_borradores.isEmpty) {
      return _vacio('Sin borradores compartidos.\nCrea uno desde una '
          'solicitud pendiente.');
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final b in _borradores) ...[
          Tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('${b['titulo'] ?? ''}',
                          style: AppTexto.subtitulo),
                    ),
                    if (b['pendiente'] == true)
                      const Chip(label: Text('Por subir')),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_nombreAutor(b['autor_telegram_id'])} · '
                  '${_fecha('${b['actualizado_en'] ?? ''}')}'
                  '${'${b['solicitud_id'] ?? ''}'.isNotEmpty ? ' · De una solicitud' : ''}',
                  style: TextStyle(
                      fontSize: 12,
                      color: AppColores.textoSecundario(context)),
                ),
                if ('${b['texto'] ?? ''}'.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('${b['texto']}',
                      maxLines: 3, overflow: TextOverflow.ellipsis),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    // Argón Gmail-15 #1 (1ª parte): el dueño también
                    // edita y elimina borradores (antes solo veía
                    // «Abrir en editor» y no podía limpiar basura
                    // de los entrenadores). El servidor conserva el
                    // autor original cuando edita el dueño.
                    if (_esDueno) ...[
                      FilledButton(
                        onPressed: () => _abrirBorradorEnEditor(b),
                        child: const Text('Abrir en editor'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => _editarBorrador(b),
                        child: const Text('Editar'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => _eliminarBorrador(b),
                        child: const Text('Eliminar'),
                      ),
                    ] else if ('${b['autor_telegram_id']}' == '$_miTid') ...[
                      TextButton(
                        onPressed: () => _editarBorrador(b),
                        child: const Text('Editar'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => _eliminarBorrador(b),
                        child: const Text('Eliminar'),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _listaPermisos() {
    if (_entrenadores.isEmpty) {
      return _vacio('Sin entrenadores registrados en la app.');
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text('Con permiso, el entrenador ve la bandeja, '
              'descarta solicitudes y crea borradores. Publicar '
              'sigue siendo solo tuyo.'),
        ),
        for (final e in _entrenadores) ...[
          Tarjeta(
            child: Row(
              children: [
                Expanded(
                  child: Text('${e['nombre']}', style: AppTexto.subtitulo),
                ),
                Switch(
                  value: e['permiso'] == true,
                  // Argón Gmail-15 Q7.3: el onChanged es async y
                  // cada toque encolaba una op antes de que
                  // terminara _cargar. Doble toque = cola sucia.
                  onChanged: (_cargando || _guardandoPermiso)
                      ? null
                      : (v) async {
                          final tid =
                              int.tryParse('${e['telegram_id']}');
                          if (tid == null) return;
                          setState(() => _guardandoPermiso = true);
                          try {
                            await cambiarPermisoBandeja(tid, v);
                            _snack(v
                                ? 'Permiso otorgado. Se aplicará al sincronizar.'
                                : 'Permiso revocado. Se aplicará al sincronizar.');
                            await _cargar();
                          } finally {
                            if (mounted) {
                              setState(
                                  () => _guardandoPermiso = false);
                            }
                          }
                        },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Sin acceso, el título no muestra conteos (panel Terra).
    final pendientes = _acceso
        ? solicitudesPorEstado(_solicitudes, kBandejaPendiente).length
        : 0;
    return Scaffold(
      appBar: AppBar(
        title: Text('Bandeja GymPedia'
            '${pendientes > 0 ? ' ($pendientes)' : ''}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
            tooltip: 'Actualizar',
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabs: [for (final t in _tabs) Tab(text: t)],
        ),
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando bandeja…')
          : !_acceso
              ? _vacio('No tienes permiso para ver la bandeja.\n'
                  'Pídele al dueño que te lo otorgue.')
              : _errorCarga
                  ? _vacio('No se pudo leer la bandeja.\n'
                      'Toca Actualizar para reintentar.')
                  : TabBarView(
                  controller: _tab,
                  children: [
                    _listaSolicitudes(kBandejaPendiente),
                    _listaSolicitudes(kBandejaPublicada),
                    _listaSolicitudes(kBandejaDescartada),
                    _listaBorradores(),
                    if (_esDueno) _listaPermisos(),
                  ],
                ),
    );
  }
}
