// lib/ui/campana_wa.dart
// v1.4.1 (Pieza 9): cola asistida de WhatsApp, 1 a 1 — NUNCA un
// envío masivo automático. El operador revisa cada mensaje y lo
// envía a mano desde SU WhatsApp (wa.me); la app solo ordena la
// tanda (tope 40), prellena el texto desde las plantillas de los
// ajustes sincronizados y registra el avance.
//
// Diseño 9.1 (adenda de Argón): el progreso se persiste en disco
// ANTES de cada salto a WhatsApp; si Android mata la app al
// abrir WhatsApp, al volver la tanda se puede reanudar justo
// donde iba ("Reanudar tanda (N/40)"). Un destinatario marcado
// "abierto" no se da por enviado: al reanudar se pregunta.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../acceso_app_cache.dart';
import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import 'diseno.dart';

class CampanaWaScreen extends StatefulWidget {
  const CampanaWaScreen({super.key});

  @override
  State<CampanaWaScreen> createState() => _CampanaWaScreenState();
}

class _CampanaWaScreenState extends State<CampanaWaScreen> {
  static const _clavePrefs = 'campana_wa_v1';
  static const _tope = 40;

  static const _textoActivacion =
      'Hola {nombre} 👋 Soy de Iron Body Gym. Tu acceso a la app de '
      'clientes ya está creado: entra con tu número de teléfono y la '
      'clave que te entregamos en recepción. Si aún no la tienes, '
      'pásate por recepción y te la damos al momento. ¡Te esperamos! 💪';
  static const _textoInvitacion =
      'Hola {nombre} 👋 Soy de Iron Body Gym. Ya puedes usar nuestra '
      'app de clientes para ver tu plan, tus pagos y tu progreso. '
      'Pásate por recepción y te creamos tu acceso al momento. '
      '¡Te esperamos! 💪';

  String _fase = 'setup'; // setup | run | fin
  String _audiencia = 'sin_activar';
  List<Map<String, dynamic>> _plantillas = [];
  String _plantillaSel = ''; // nombre de plantilla o '' = texto libre
  String _textoLibre = _textoActivacion;
  final _libreCtrl = TextEditingController(text: _textoActivacion);
  bool _cargando = true;
  String? _errorAudiencia;

  // Tanda persistida
  List<Map<String, dynamic>> _items = [];
  String _textoTanda = '';
  bool _hayTandaPrevia = false;
  bool _abriendoWa = false;
  int _prevResueltos = 0;
  int _prevTotal = 0;

  @override
  void initState() {
    super.initState();
    _preparar();
  }

  @override
  void dispose() {
    _libreCtrl.dispose();
    super.dispose();
  }

  /// Cambia el texto libre (y su controlador) al cambiar de grupo.
  void _ponerTextoLibre(String texto) {
    _textoLibre = texto;
    _libreCtrl.text = texto;
  }

  Future<void> _preparar() async {
    try {
      await AccesoAppCache.instance.cargar();
    } catch (_) {}
    try {
      final aj = await LocalDb.instance.getAjustes();
      final p = aj['plantillas_wa'];
      if (p is List) {
        _plantillas = [
          for (final e in p) Map<String, dynamic>.from(e as Map)
        ];
        // Defensa: nombres duplicados romperían el desplegable;
        // se conserva la primera de cada nombre.
        final vistos = <String>{};
        _plantillas = [
          for (final pl in _plantillas)
            if (vistos.add('${pl['nombre']}'.toLowerCase())) pl
        ];
      }
    } catch (_) {}
    await _revisarTandaPrevia();
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _revisarTandaPrevia() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_clavePrefs);
      if (raw == null || raw.isEmpty) return;
      final t = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final items = [
        for (final e in (t['items'] as List? ?? []))
          Map<String, dynamic>.from(e as Map)
      ];
      final resueltos = items
          .where((i) => i['estado'] == 'enviado' || i['estado'] == 'saltado')
          .length;
      if (items.isNotEmpty && resueltos < items.length) {
        _hayTandaPrevia = true;
        _prevResueltos = resueltos;
        _prevTotal = items.length;
        _items = items;
        _textoTanda = '${t['texto'] ?? ''}';
        _audiencia = '${t['audiencia'] ?? 'sin_activar'}';
      } else {
        await prefs.remove(_clavePrefs);
      }
    } catch (_) {}
  }

  /// Devuelve false si el guardado falló: quien llama decide si
  /// puede seguir (panel T5: jamás saltar a WhatsApp sin haber
  /// persistido el paso, garantía 9.1).
  Future<bool> _persistir() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(
        _clavePrefs,
        jsonEncode({
          'version': 1,
          'audiencia': _audiencia,
          'texto': _textoTanda,
          'items': _items,
        }),
      );
    } catch (_) {
      return false;
    }
  }

  /// Recalcula el aviso "Reanudar tanda (N/M)" desde _items
  /// (panel T5: pausar una tanda de ESTA sesión también debe
  /// ofrecer reanudarla, con el contador al día).
  void _refrescarPrevia() {
    _prevResueltos = _resueltos;
    _prevTotal = _items.length;
    _hayTandaPrevia = _items.any((i) =>
        i['estado'] == 'pendiente' || i['estado'] == 'abierto');
  }

  Future<void> _descartarTanda() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_clavePrefs);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _hayTandaPrevia = false;
        _items = [];
        _fase = 'setup';
      });
    }
  }

  // ---------------- audiencias ----------------

  bool _telValido(String tel) => normalizarTelefonoWaMe(tel).isNotEmpty;

  List<Map<String, dynamic>> _audienciaDesdeCache() {
    final todos = AccesoAppCache.instance.todos ?? [];
    final sel = switch (_audiencia) {
      'sin_activar' => todos.where(
          (a) => a.activo && a.ultimoAccesoEn == null && _telValido(a.telefono)),
      'activos' => todos.where((a) => a.activo && _telValido(a.telefono)),
      _ => const <AccesoCliente>[],
    };
    return [
      for (final a in sel)
        {
          'cliente_id': a.clienteId,
          'nombre': a.nombre,
          'telefono': a.telefono,
          'estado': 'pendiente',
        }
    ];
  }

  Future<List<Map<String, dynamic>>> _audienciaSinAcceso() async {
    final res = await Supabase.instance.client.rpc('clientes_sin_acceso');
    return [
      for (final e in (res as List? ?? []))
        if (_telValido('${(e as Map)['telefono'] ?? ''}'))
          {
            'cliente_id': int.tryParse('${e['cliente_id'] ?? ''}') ?? 0,
            'nombre': '${e['nombre'] ?? ''}',
            'telefono': '${e['telefono'] ?? ''}',
            'estado': 'pendiente',
          }
    ];
  }

  Future<List<Map<String, dynamic>>> _construirAudiencia() async {
    final lista = _audiencia == 'sin_acceso'
        ? await _audienciaSinAcceso()
        : _audienciaDesdeCache();
    lista.sort((a, b) =>
        '${a['nombre']}'.toLowerCase().compareTo('${b['nombre']}'.toLowerCase()));
    return lista.take(_tope).toList();
  }

  // ---------------- tanda ----------------

  String get _textoElegido {
    if (_plantillaSel.isEmpty) return _textoLibre;
    for (final p in _plantillas) {
      if (p['nombre'] == _plantillaSel) return '${p['texto'] ?? ''}';
    }
    return _textoLibre;
  }

  Future<void> _iniciarTanda() async {
    // No pisar una tanda sin terminar sin confirmarlo (panel T5):
    // se perdería su avance y un destinatario "abierto" podría
    // recibir el mensaje dos veces.
    if (_hayTandaPrevia) {
      final sigue = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ya hay una tanda sin terminar'),
          content: Text(
              'Va $_prevResueltos de $_prevTotal. Si inicias otra, '
              'se pierde ese avance.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Iniciar otra'),
            ),
          ],
        ),
      );
      if (sigue != true || !mounted) return;
    }
    setState(() => _errorAudiencia = null);
    List<Map<String, dynamic>> lista;
    try {
      lista = await _construirAudiencia();
    } catch (_) {
      if (!mounted) return;
      setState(() => _errorAudiencia =
          'No se pudo cargar la audiencia. Revisa la conexión.');
      return;
    }
    if (!mounted) return;
    if (lista.isEmpty) {
      setState(() => _errorAudiencia =
          'No hay destinatarios con teléfono válido en este grupo.');
      return;
    }
    _items = lista;
    _textoTanda = _textoElegido;
    // Persistir ANTES de mostrar el primer paso (diseño 9.1); si
    // el guardado falla, NO se entra a la tanda (panel T5).
    if (!await _persistir()) {
      if (mounted) {
        setState(() => _errorAudiencia =
            'No se pudo guardar la tanda en el dispositivo.');
      }
      return;
    }
    _refrescarPrevia();
    if (mounted) setState(() => _fase = 'run');
  }

  Map<String, dynamic>? get _actual {
    for (final i in _items) {
      if (i['estado'] == 'pendiente' || i['estado'] == 'abierto') {
        return i;
      }
    }
    return null;
  }

  int get _enviados =>
      _items.where((i) => i['estado'] == 'enviado').length;
  int get _saltados =>
      _items.where((i) => i['estado'] == 'saltado').length;
  int get _resueltos => _enviados + _saltados;

  String _mensajePara(Map<String, dynamic> item) =>
      _textoTanda.replaceAll('{nombre}', '${item['nombre'] ?? ''}');

  Future<void> _abrirWhatsApp(Map<String, dynamic> item) async {
    if (_abriendoWa) return; // doble toque (panel T5)
    _abriendoWa = true;
    try {
      // 9.1: persistir el paso ("abierto") ANTES de saltar a
      // WhatsApp. Si el guardado falla, NO se salta (panel T5):
      // sin el "abierto" persistido, al volver no se podría
      // preguntar si se envió y cabría un reenvío.
      item['estado'] = 'abierto';
      if (!await _persistir()) {
        item['estado'] = 'pendiente';
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'No se pudo guardar el avance; no se abrió WhatsApp.')));
        }
        return;
      }
      if (mounted) setState(() {});
      final wa = normalizarTelefonoWaMe('${item['telefono'] ?? ''}');
      final url = Uri.parse(
          'https://wa.me/$wa?text=${Uri.encodeComponent(_mensajePara(item))}');
      try {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No se pudo abrir WhatsApp')));
        }
      }
    } finally {
      _abriendoWa = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _resolver(Map<String, dynamic> item, String estado) async {
    item['estado'] = estado;
    final ok = await _persistir();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Ojo: no se pudo guardar el avance en el dispositivo.')));
    }
    _refrescarPrevia();
    if (_actual == null) {
      setState(() => _fase = 'fin');
    } else {
      setState(() {});
    }
  }

  // ---------------- plantillas (solo dueño) ----------------

  Future<void> _guardarPlantillas(
      List<Map<String, dynamic>> nuevas) async {
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'ajuste',
      payload: {'clave': 'plantillas_wa', 'valor': nuevas},
    );
    final aj = await LocalDb.instance.getAjustes();
    aj['plantillas_wa'] = nuevas;
    await LocalDb.instance.setAjustes(aj);
    if (mounted) {
      setState(() {
        _plantillas = nuevas;
        if (_plantillaSel.isNotEmpty &&
            !nuevas.any((p) => p['nombre'] == _plantillaSel)) {
          _plantillaSel = '';
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Plantillas guardadas (se sincronizarán)')));
    }
  }

  Future<void> _editarPlantilla({Map<String, dynamic>? existente}) async {
    final nomCtrl =
        TextEditingController(text: existente?['nombre'] as String? ?? '');
    final txtCtrl =
        TextEditingController(text: existente?['texto'] as String? ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existente == null ? 'Nueva plantilla' : 'Editar plantilla'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nomCtrl,
                decoration: const InputDecoration(labelText: 'Nombre'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: txtCtrl,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Texto (usa {nombre} para el cliente)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      nomCtrl.dispose();
      txtCtrl.dispose();
      return;
    }
    final nombre = nomCtrl.text.trim();
    final texto = txtCtrl.text.trim();
    nomCtrl.dispose();
    txtCtrl.dispose();
    if (nombre.isEmpty || texto.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('La plantilla necesita nombre y texto')));
      return;
    }
    // El servidor también lo rechaza, pero el estado optimista
    // local rompería el desplegable antes de sincronizar.
    final duplicada = _plantillas.any((p) =>
        p['nombre'] != existente?['nombre'] &&
        '${p['nombre']}'.toLowerCase() == nombre.toLowerCase());
    if (duplicada) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ya existe una plantilla con ese nombre.')));
      return;
    }
    final nuevas = [
      for (final p in _plantillas)
        if (p['nombre'] != existente?['nombre']) p,
      {'nombre': nombre, 'texto': texto},
    ];
    await _guardarPlantillas(nuevas);
  }

  Future<void> _gestionarPlantillas() async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text('Plantillas de WhatsApp',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(
                  'Se comparten en todos los dispositivos del negocio'),
            ),
            for (final p in _plantillas)
              ListTile(
                title: Text('${p['nombre']}'),
                subtitle: Text('${p['texto']}',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _editarPlantilla(existente: p);
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () async {
                        Navigator.of(ctx).pop();
                        await _guardarPlantillas([
                          for (final x in _plantillas)
                            if (x['nombre'] != p['nombre']) x
                        ]);
                      },
                    ),
                  ],
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Nueva plantilla'),
              onTap: () {
                Navigator.of(ctx).pop();
                _editarPlantilla();
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Campaña WhatsApp')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : switch (_fase) {
              'run' => _vistaRun(),
              'fin' => _vistaFin(),
              _ => _vistaSetup(),
            },
    );
  }

  Widget _vistaSetup() {
    final esDueno = AuthService().isOwner;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_hayTandaPrevia)
          Card(
            color: AppColores.naranja.withValues(alpha: 0.12),
            child: ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: Text(
                  'Reanudar tanda ($_prevResueltos/$_prevTotal)'),
              subtitle: const Text(
                  'Quedó una tanda sin terminar en este teléfono'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Descartar',
                onPressed: _descartarTanda,
              ),
              onTap: () => setState(() => _fase = 'run'),
            ),
          ),
        const Text(
          'Envío asistido, uno a uno, desde tu WhatsApp. La app '
          'prepara el texto y lleva la cuenta; tú tocas enviar en '
          'cada chat. Máximo 40 por tanda.',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        Text('¿A quién?',
            style: AppTexto.subtitulo
                .copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
              label: const Text('Con acceso sin activar'),
              selected: _audiencia == 'sin_activar',
              onSelected: (_) => setState(() {
                _audiencia = 'sin_activar';
                if (_plantillaSel.isEmpty) {
                  _ponerTextoLibre(_textoActivacion);
                }
              }),
            ),
            ChoiceChip(
              label: const Text('Sin acceso'),
              selected: _audiencia == 'sin_acceso',
              onSelected: (_) => setState(() {
                _audiencia = 'sin_acceso';
                if (_plantillaSel.isEmpty) {
                  _ponerTextoLibre(_textoInvitacion);
                }
              }),
            ),
            ChoiceChip(
              label: const Text('Activos con app'),
              selected: _audiencia == 'activos',
              onSelected: (_) =>
                  setState(() => _audiencia = 'activos'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: Text('Mensaje',
                  style: AppTexto.subtitulo
                      .copyWith(fontWeight: FontWeight.bold)),
            ),
            if (esDueno)
              TextButton.icon(
                icon: const Icon(Icons.edit_note, size: 18),
                label: const Text('Plantillas'),
                onPressed: _gestionarPlantillas,
              ),
          ],
        ),
        if (_plantillas.isNotEmpty) ...[
          DropdownButton<String>(
            isExpanded: true,
            value: _plantillaSel.isEmpty ||
                    _plantillas.any((p) => p['nombre'] == _plantillaSel)
                ? _plantillaSel
                : '',
            items: [
              const DropdownMenuItem(
                  value: '', child: Text('Texto libre (abajo)')),
              for (final p in _plantillas)
                DropdownMenuItem(
                    value: '${p['nombre']}',
                    child: Text('${p['nombre']}')),
            ],
            onChanged: (v) => setState(() => _plantillaSel = v ?? ''),
          ),
          const SizedBox(height: 8),
        ],
        if (_plantillaSel.isEmpty)
          TextField(
            controller: _libreCtrl,
            maxLines: 5,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Escribe el mensaje… usa {nombre}',
            ),
            onChanged: (v) => _textoLibre = v,
          )
        else
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_textoElegido),
          ),
        if (_errorAudiencia != null) ...[
          const SizedBox(height: 12),
          Text(_errorAudiencia!,
              style: const TextStyle(color: AppColores.error)),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          icon: const Icon(Icons.playlist_play),
          label: const Text('Iniciar tanda'),
          onPressed: _iniciarTanda,
        ),
      ],
    );
  }

  Widget _vistaRun() {
    final actual = _actual;
    if (actual == null) {
      // Todo resuelto pero la fase no cambió (p. ej. reanudada ya
      // completa): ir a fin.
      WidgetsBinding.instance
          .addPostFrameCallback((_) {
        if (mounted) setState(() => _fase = 'fin');
      });
      return const Center(child: CircularProgressIndicator());
    }
    final abierto = actual['estado'] == 'abierto';
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        LinearProgressIndicator(
          value: _items.isEmpty ? 0 : _resueltos / _items.length,
        ),
        const SizedBox(height: 8),
        Text(
          'Resueltos $_resueltos de ${_items.length} · '
          'enviados $_enviados · saltados $_saltados',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${actual['nombre']}',
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                Text('Tel. ${actual['telefono']}',
                    style: const TextStyle(color: Colors.grey)),
                const Divider(height: 24),
                Text(_mensajePara(actual)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (abierto) ...[
          const Text(
            'Abriste WhatsApp para este cliente. ¿Lo enviaste?',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Sí, enviado'),
                  onPressed: () => _resolver(actual, 'enviado'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _resolver(actual, 'saltado'),
                  child: const Text('No, saltar'),
                ),
              ),
            ],
          ),
        ] else ...[
          FilledButton.icon(
            icon: const Icon(Icons.chat, size: 18),
            label: const Text('Abrir WhatsApp'),
            onPressed:
                _abriendoWa ? null : () => _abrirWhatsApp(actual),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: () => _resolver(actual, 'saltado'),
            child: const Text('Saltar este cliente'),
          ),
        ],
        const SizedBox(height: 20),
        TextButton(
          onPressed: () {
            _refrescarPrevia();
            setState(() => _fase = 'setup');
          },
          child: const Text(
              'Pausar tanda (queda guardada para reanudar)'),
        ),
      ],
    );
  }

  Widget _vistaFin() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline,
                size: 56, color: AppColores.exito),
            const SizedBox(height: 12),
            Text('Tanda terminada',
                style: AppTexto.titulo.copyWith(fontSize: 20)),
            const SizedBox(height: 8),
            Text(
              'Enviados: $_enviados · Saltados: $_saltados · '
              'Total: ${_items.length}',
              textAlign: TextAlign.center,
              style: AppTexto.secundario,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () async {
                await _descartarTanda();
              },
              child: const Text('Cerrar'),
            ),
          ],
        ),
      ),
    );
  }
}
