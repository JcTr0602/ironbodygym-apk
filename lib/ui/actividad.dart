import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';

/// Feed de actividad reciente (v1.0.15).
///
/// Muestra inscripciones, pagos y otras acciones de todos los entrenadores,
/// agrupadas por día, con marcador de no leídas.
class ActividadScreen extends StatefulWidget {
  const ActividadScreen({super.key});

  @override
  State<ActividadScreen> createState() => _ActividadScreenState();
}

class _ActividadScreenState extends State<ActividadScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _cargando = true;
  // v1.3.3: 6 filtros de categoría (diseño Argón).
  String _filtro =
      'todo'; // todo | mensualidades | inscripciones | diarios | suplementos | entregas
  String _filtroActor = 'todos'; // todos | nombre del actor
  // v1.2.1: mejoras de actividad
  String _filtroFecha = 'todo'; // todo | hoy | ayer | 7dias | mes | rango
  DateTime? _rangoIni;
  DateTime? _rangoFin;
  String _busqueda = '';
  String _agruparPor = 'dia'; // dia | entrenador
  final _busquedaCtrl = TextEditingController();
  // Caché: cliente_id -> nombre y foto_storage
  final Map<int, String> _nombres = {};
  final Map<int, String?> _fotos = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final raw = await LocalDb.instance.getMeta('sync_estado_actividad');
    final lista = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final a in jsonDecode(raw) as List) {
          lista.add(Map<String, dynamic>.from(a as Map));
        }
      } catch (_) {}
    }
    // v1.3.3: fusión híbrida — ops locales aún no aplicadas.
    // El servidor NO trae op_uuid; para no duplicar solo se toman las
    // ops en estado pendiente/error/necesita_revision (las 'aplicada'
    // ya vienen en sync_estado_actividad).
    try {
      final db = await LocalDb.instance.db;
      final opsPend = await db.query('ops_queue',
          where: "estado IN ('pendiente', 'error', 'necesita_revision')",
          orderBy: 'creada_ts DESC');
      final actorLocal = AuthService().displayName;
      for (final op in opsPend) {
        final tipo = '${op['tipo'] ?? ''}';
        Map<String, dynamic> payload = {};
        try {
          payload =
              jsonDecode(op['payload'] as String) as Map<String, dynamic>;
        } catch (_) {}
        final cup = await montoCobradoCupOp(op);
        final usd = montoCobradoUsdOp(op);
        lista.add({
          'ts': '${op['creada_ts'] ?? ''}',
          'actor': actorLocal,
          'rol': '',
          'accion': tipo,
          'detalle': _detalleOpLocal(tipo, payload, cup, usd),
          'cliente_id': _clienteIdDePayload(payload),
          '_en_cola': true,
          '_monto_cup': cup,
          '_monto_usd': usd,
        });
      }
      // Reordenar la fusión por ts descendente.
      lista.sort(
          (a, b) => '${b['ts'] ?? ''}'.compareTo('${a['ts'] ?? ''}'));
    } catch (_) {}
    // v1.2.1: resolver nombres y fotos de clientes para cada item.
    _nombres.clear();
    _fotos.clear();
    for (final a in lista) {
      final id = _clienteIdDe(a);
      if (id != null && !_nombres.containsKey(id)) {
        final c = await clientePorId(id);
        if (c != null) {
          _nombres[id] = '${c['nombre'] ?? 'Cliente $id'}';
          _fotos[id] = c['foto_storage'] as String?;
        } else {
          _nombres[id] = 'Cliente $id';
          _fotos[id] = null;
        }
      }
    }
    if (mounted) {
      setState(() {
        _items = lista;
        _cargando = false;
      });
    }
    // Marcar como leídas al abrir
    _marcarLeidas();
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  Future<void> _marcarLeidas() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('actividad_vista_ts',
        DateTime.now().toUtc().toIso8601String());
  }

  List<Map<String, dynamic>> get _filtrados {
    final q = _busqueda.trim().toLowerCase();
    return _items.where((a) {
      // v1.3.3: filtro por categoría (diseño Argón).
      if (_filtro != 'todo') {
        if (_categoriaDe('${a['accion'] ?? ''}') != _filtro) {
          return false;
        }
      }
      // v1.0.15: filtro por entrenador/actor
      if (_filtroActor != 'todos') {
        if ('${a['actor'] ?? ''}' != _filtroActor) return false;
      }
      // v1.2.1: filtro por fecha
      if (_filtroFecha != 'todo') {
        final ts = '${a['ts'] ?? ''}';
        final dia = ts.length >= 10 ? ts.substring(0, 10) : '';
        final ahora = DateTime.now();
        final hoyStr = _isoDia(ahora);
        final ayerStr =
            _isoDia(ahora.subtract(const Duration(days: 1)));
        switch (_filtroFecha) {
          case 'hoy':
            if (dia != hoyStr) return false;
            break;
          case 'ayer':
            if (dia != ayerStr) return false;
            break;
          case '7dias':
            final limite = _isoDia(
                ahora.subtract(const Duration(days: 7)));
            if (dia.compareTo(limite) < 0) return false;
            break;
          case 'mes':
            final pref =
                '${ahora.year}-${ahora.month.toString().padLeft(2, '0')}';
            if (!dia.startsWith(pref)) return false;
            break;
          case 'rango':
            if (_rangoIni != null) {
              if (dia.compareTo(_isoDia(_rangoIni!)) < 0) {
                return false;
              }
            }
            if (_rangoFin != null) {
              if (dia.compareTo(_isoDia(_rangoFin!)) > 0) {
                return false;
              }
            }
            break;
        }
      }
      // v1.2.1: buscador por nombre de cliente o texto del detalle
      if (q.isNotEmpty) {
        final id = _clienteIdDe(a);
        final nombre = id != null ? (_nombres[id] ?? '') : '';
        final detalle = '${a['detalle'] ?? ''}'.toLowerCase();
        final actor = '${a['actor'] ?? ''}'.toLowerCase();
        if (!nombre.toLowerCase().contains(q) &&
            !detalle.contains(q) &&
            !actor.contains(q)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  String _isoDia(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// v1.0.15: actores únicos para el filtro por entrenador.
  List<String> get _actores {
    final s = <String>{};
    for (final a in _items) {
      final actor = '${a['actor'] ?? ''}'.trim();
      if (actor.isNotEmpty) s.add(actor);
    }
    final l = s.toList()..sort();
    return l;
  }

  /// v1.1: usa cliente_id del servidor; fallback a regex para
  /// entradas antiguas (v1.0.15).
  int? _clienteIdDe(Map<String, dynamic> a) {
    final cid = a['cliente_id'];
    if (cid is int) return cid;
    if (cid is String) return int.tryParse(cid);
    final det = '${a['detalle'] ?? ''}';
    final m = RegExp(r'cliente\s+(\d+)').firstMatch(det);
    if (m != null) return int.tryParse(m.group(1)!);
    return null;
  }

  /// v1.3.3: extrae cliente_id del payload de una op local.
  int? _clienteIdDePayload(Map<String, dynamic> payload) {
    for (final k in ['cliente_id', 'id']) {
      final v = payload[k];
      if (v is int) return v;
      if (v is String) {
        final n = int.tryParse(v);
        if (n != null) return n;
      }
    }
    final c = payload['cliente'];
    if (c is Map<String, dynamic>) {
      final v = c['id'];
      if (v is int) return v;
      if (v is String) return int.tryParse(v);
    }
    return null;
  }

  /// v1.3.3: detalle legible para una op local en cola.
  String _detalleOpLocal(String tipo, Map<String, dynamic> payload,
      double cup, double usd) {
    final montoTxt = usd > 0
        ? '${fmtMonto(usd)} USD'
        : (cup > 0 ? '${fmtMonto(cup)} CUP' : '');
    switch (tipo) {
      case 'pago_mensual':
      case 'pago':
      case 'mensual':
        final per = '${payload['periodo'] ?? 'mensual'}';
        final met = '${payload['metodo'] ?? 'efectivo'}';
        return 'Pago mensual ($per, $met)${montoTxt.isNotEmpty ? ' — $montoTxt' : ''}';
      case 'pago_diario':
      case 'diario':
        final cant = payload['cantidad'] ?? '';
        return 'Pago diario x$cant${montoTxt.isNotEmpty ? ' — $montoTxt' : ''}';
      case 'inscribir':
        return 'Inscripción${montoTxt.isNotEmpty ? ' — $montoTxt' : ''}';
      case 'inscripcion_venta_suplemento':
        return 'Inscripción + venta${montoTxt.isNotEmpty ? ' — $montoTxt' : ''}';
      case 'venta_suplemento':
        final nombre = '${payload['nombre'] ?? 'Suplemento'}';
        final cant = payload['cantidad'] ?? '';
        final moneda = '${payload['moneda'] ?? 'CUP'}';
        return '$nombre x$cant — $montoTxt $moneda'.trim();
      case 'confirmar_entrega':
        return 'Confirmar entrega de cobros';
      case 'regalar_mes_cumpleanos':
      case 'regalo_cumpleanos':
        return 'Mes gratis (cumpleaños)';
      case 'foto':
        return 'Foto de cliente';
      case 'foto_suplemento':
        return 'Foto de suplemento';
      default:
        return tipo.replaceAll('_', ' ');
    }
  }

  /// v1.3.3: categoría de la actividad según la acción
  /// (diseño Argón, 6 filtros).
  String _categoriaDe(String accion) {
    final a = accion.toLowerCase();
    if (a.contains('inscri')) return 'inscripciones';
    if (a.contains('pago_diario') || a == 'diario') return 'diarios';
    if (a.contains('suplemento') || a.contains('categoria')) {
      return 'suplementos';
    }
    if (a.contains('confirmar_entrega') || a.contains('entrega')) {
      return 'entregas';
    }
    if (a.contains('regalo_cumpleanos') ||
        a.contains('regalar_mes')) {
      return 'mensualidades';
    }
    if (a.contains('pago') && !a.contains('diario')) {
      return 'mensualidades';
    }
    if (a == 'mensual') return 'mensualidades';
    return 'otra';
  }

  /// v1.3.3: ¿la acción del servidor representa un cobro real?
  /// Solo cobros suman al KPI (no anulaciones, ediciones, gastos,
  /// entregas ni ajustes de precios).
  bool _esCobroServidor(String accion) {
    final a = accion.toLowerCase();
    if (a.contains('anular_')) return false;
    if (a.contains('editar_')) return false;
    if (a.contains('gasto')) return false;
    if (a.contains('entrega')) return false;
    if (a.contains('ajuste')) return false;
    if (a.contains('regalo_cumpleanos')) return false;
    return a.contains('pago') ||
        a.contains('inscri') ||
        a.contains('venta_suplemento');
  }

  /// v1.3.3: extrae (monto, moneda) del detalle del servidor.
  /// Devuelve null si no hay monto.
  (double, String)? _montoServidor(String detalle) {
    final m =
        RegExp(r'(\d+(?:\.\d+)?)\s*(CUP|USD)').firstMatch(detalle);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!) ?? 0;
    return (v, m.group(2)!);
  }

  Future<void> _abrirFicha(Map<String, dynamic> a) async {
    final id = _clienteIdDe(a);
    if (id == null) return;
    // Verificar que el cliente existe localmente
    final c = await clientePorId(id);
    if (c == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Cliente no disponible offline')),
        );
      }
      return;
    }
    if (mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => FichaScreen(clienteId: id)),
      );
    }
  }

  /// v1.2.1: leading de la fila: foto del cliente si hay,
  /// o el icono de la acción en círculo.
  Widget _leadingActividad(
      String? fotoPath, Color color, String accion) {
    if (fotoPath != null && fotoPath.isNotEmpty) {
      return FutureBuilder(
        future: FotoCache.instance.obtener(fotoPath),
        builder: (ctx, snap) {
          final f = snap.data;
          if (f != null) {
            return ClipRRect(
              borderRadius:
                  BorderRadius.circular(AppRadio.md),
              child: Image.file(f,
                  width: 44, height: 44, fit: BoxFit.cover),
            );
          }
          return _iconoLeading(color, accion);
        },
      );
    }
    return _iconoLeading(color, accion);
  }

  Widget _iconoLeading(Color color, String accion) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        shape: BoxShape.circle,
      ),
      child: Icon(
        _iconoAccion(accion),
        color: color,
        size: 22,
      ),
    );
  }

  /// Icono Material por tipo de acción (v1.1: sin emojis).
  IconData _iconoAccion(String accion) {
    if (accion.contains('inscri')) return Icons.person_add;
    if (accion.contains('pago_diario')) return Icons.receipt_long;
    if (accion.contains('pago')) return Icons.payments;
    // v1.3.3: iconos por categoría (diseño Argón).
    if (accion.contains('regalo_cumpleanos') ||
        accion.contains('regalar_mes')) {
      return Icons.card_giftcard;
    }
    if (accion.contains('suplemento') || accion.contains('categoria')) {
      return Icons.medication;
    }
    if (accion.contains('entrega')) return Icons.delivery_dining;
    if (accion.contains('incidencia')) return Icons.report_problem_outlined;
    if (accion.contains('foto')) return Icons.photo_camera;
    if (accion.contains('editar')) return Icons.edit;
    if (accion.contains('eliminar')) return Icons.delete_outline;
    if (accion.contains('restaur')) return Icons.restore_from_trash;
    if (accion.contains('congel')) return Icons.ac_unit;
    if (accion.contains('verific')) return Icons.verified_user;
    return Icons.assignment;
  }

  /// Color semántico por tipo de acción.
  Color _colorAccion(BuildContext context, String accion) {
    if (accion.contains('inscri')) return AppColores.exito;
    if (accion.contains('pago')) return AppColores.naranja;
    // v1.3.3: colores por categoría (diseño Argón).
    if (accion.contains('suplemento') || accion.contains('categoria')) {
      return AppColores.info;
    }
    if (accion.contains('entrega')) return AppColores.exito;
    if (accion.contains('regalo_cumpleanos') ||
        accion.contains('regalar_mes')) {
      return AppColores.alerta;
    }
    if (accion.contains('eliminar')) return AppColores.error;
    if (accion.contains('editar')) return AppColores.info;
    return AppColores.textoSecundario(context);
  }

  /// v1.2.1: agrupa por entrenador/actor en vez de por día.
  List<MapEntry<String, List<Map<String, dynamic>>>> _agruparPorEntrenador(
      List<Map<String, dynamic>> items) {
    final grupos = <String, List<Map<String, dynamic>>>{};
    final orden = <String>[];
    for (final a in items) {
      final actor = '${a['actor'] ?? '—'}'.trim();
      final key = actor.isEmpty ? '—' : actor;
      if (!grupos.containsKey(key)) {
        grupos[key] = [];
        orden.add(key);
      }
      grupos[key]!.add(a);
    }
    orden.sort();
    return orden.map((t) => MapEntry(t, grupos[t]!)).toList();
  }

  /// v1.2.1: selector de rango de fechas personalizado.
  Future<void> _elegirRango() async {
    final ini = await showDatePicker(
      context: context,
      initialDate: _rangoIni ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      helpText: 'Fecha inicial',
    );
    if (ini == null || !mounted) return;
    final fin = await showDatePicker(
      context: context,
      initialDate: _rangoFin ?? DateTime.now(),
      firstDate: ini,
      lastDate: DateTime.now(),
      helpText: 'Fecha final',
    );
    if (fin == null || !mounted) return;
    setState(() {
      _rangoIni = ini;
      _rangoFin = fin;
      _filtroFecha = 'rango';
    });
  }

  /// v1.2.1: resalta montos (ej "2000 CUP", "30.00 USD") en naranja/negrita,
  /// y cambios de campo en ediciones (ej "teléfono: 5xxxx → 5yyyy") en info.
  List<TextSpan> _resaltarMontos(String texto) {
    final spans = <TextSpan>[];
    // Montos y cambios de campo (con →).
    final regex = RegExp(
        r'\d[\d.,]*\s*(CUP|USD|MN)|[^:,\n]+:\s*[^\n,]*?→[^\n,]*');
    var pos = 0;
    for (final m in regex.allMatches(texto)) {
      if (m.start > pos) {
        spans.add(TextSpan(text: texto.substring(pos, m.start)));
      }
      final esMonto = !m.group(0)!.contains('→');
      spans.add(TextSpan(
        text: m.group(0),
        style: TextStyle(
          color:
              esMonto ? AppColores.naranja : AppColores.info,
          fontWeight: FontWeight.bold,
        ),
      ));
      pos = m.end;
    }
    if (pos < texto.length) {
      spans.add(TextSpan(text: texto.substring(pos)));
    }
    if (spans.isEmpty) spans.add(TextSpan(text: texto));
    return spans;
  }

  /// v1.2.1: reemplaza "cliente 123" por el nombre real en el detalle.
  String _detalleConNombre(Map<String, dynamic> a) {
    var det = '${a['detalle'] ?? ''}';
    final id = _clienteIdDe(a);
    if (id != null) {
      final nombre = _nombres[id];
      if (nombre != null && !nombre.startsWith('Cliente ')) {
        det = det.replaceAll(
            RegExp('cliente\\s+$id\\b', caseSensitive: false), nombre);
      }
    }
    return det;
  }

  /// Agrupa por día: devuelve lista de (tituloDia, items).
  List<MapEntry<String, List<Map<String, dynamic>>>> _agruparPorDia(
      List<Map<String, dynamic>> items) {
    final grupos = <String, List<Map<String, dynamic>>>{};
    final orden = <String>[];
    final hoy = DateTime.now();
    final hoyStr =
        '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}-${hoy.day.toString().padLeft(2, '0')}';
    final ayer = hoy.subtract(const Duration(days: 1));
    final ayerStr =
        '${ayer.year}-${ayer.month.toString().padLeft(2, '0')}-${ayer.day.toString().padLeft(2, '0')}';
    for (final a in items) {
      final ts = '${a['ts'] ?? ''}';
      final dia = ts.length >= 10 ? ts.substring(0, 10) : '?';
      String titulo;
      if (dia == hoyStr) {
        titulo = 'Hoy';
      } else if (dia == ayerStr) {
        titulo = 'Ayer';
      } else {
        titulo = fmtFecha(dia);
      }
      if (!grupos.containsKey(titulo)) {
        grupos[titulo] = [];
        orden.add(titulo);
      }
      grupos[titulo]!.add(a);
    }
    return orden.map((t) => MapEntry(t, grupos[t]!)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtrados = _filtrados;
    // v1.2.1: agrupar por día o por entrenador.
    final grupos = _agruparPor == 'dia'
        ? _agruparPorDia(filtrados)
        : _agruparPorEntrenador(filtrados);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Actividad reciente'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: Column(
        children: [
          // v1.2.1: buscador por cliente, suplemento o texto.
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _busquedaCtrl,
              decoration: InputDecoration(
                hintText: 'Buscar por cliente, suplemento…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _busqueda.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _busquedaCtrl.clear();
                          setState(() => _busqueda = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                ),
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
              ),
              onChanged: (v) =>
                  setState(() => _busqueda = v),
            ),
          ),
          // v1.3.3: 6 filtros de categoría (diseño Argón).
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _chipFiltro('todo', 'Todo'),
                const SizedBox(width: 8),
                _chipFiltro('mensualidades', 'Mensualidades'),
                const SizedBox(width: 8),
                _chipFiltro('inscripciones', 'Inscripciones'),
                const SizedBox(width: 8),
                _chipFiltro('diarios', 'Diarios'),
                const SizedBox(width: 8),
                _chipFiltro('suplementos', 'Suplementos'),
                const SizedBox(width: 8),
                _chipFiltro('entregas', 'Entregas'),
              ],
            ),
          ),
          // v1.3.3: cinta de resumen financiero (KPI bar).
          _kpiBar(filtrados),
          // v1.2.1: filtro por fecha
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 0),
            child: Row(
              children: [
                _chipFecha('todo', 'Siempre'),
                const SizedBox(width: 8),
                _chipFecha('hoy', 'Hoy'),
                const SizedBox(width: 8),
                _chipFecha('ayer', 'Ayer'),
                const SizedBox(width: 8),
                _chipFecha('7dias', '7 días'),
                const SizedBox(width: 8),
                _chipFecha('mes', 'Este mes'),
                const SizedBox(width: 8),
                _chipFechaRango(),
              ],
            ),
          ),
          // v1.0.15: filtro por entrenador
          if (_actores.length > 1)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  _chipActor('todos', 'Todos'),
                  const SizedBox(width: 8),
                  for (final actor in _actores) ...[
                    _chipActor(actor, actor),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          // v1.2.1: agrupar por día o por entrenador
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const Text('Agrupar: ',
                    style: TextStyle(fontSize: 13)),
                ChoiceChip(
                  label: const Text('Por día',
                      style: TextStyle(fontSize: 12)),
                  selected: _agruparPor == 'dia',
                  onSelected: (_) =>
                      setState(() => _agruparPor = 'dia'),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Por entrenador',
                      style: TextStyle(fontSize: 12)),
                  selected: _agruparPor == 'entrenador',
                  onSelected: (_) => setState(
                      () => _agruparPor = 'entrenador'),
                ),
              ],
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : filtrados.isEmpty
                    ? const EstadoVacio(
                        icono: Icons.history_outlined,
                        titulo: 'Sin actividad reciente',
                        subtitulo:
                            'Sincroniza para actualizar.',
                      )
                    : RefreshIndicator(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          itemCount: grupos.length,
                          itemBuilder: (ctx, gi) {
                            final grupo = grupos[gi];
                            return Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                      16, 12, 16, 4),
                                  child: Text(
                                    grupo.key,
                                    style: AppTexto.subtitulo.copyWith(
                                        color: AppColores
                                            .textoSecundario(
                                                context)),
                                  ),
                                ),
                                ...grupo.value.map((a) {
                                  final accion =
                                      '${a['accion'] ?? ''}';
                                  final cliId = _clienteIdDe(a);
                                  final tieneCliente =
                                      cliId != null;
                                  final color =
                                      _colorAccion(context, accion);
                                  // v1.2.1: nombre y foto del cliente.
                                  final nombreCli = cliId != null
                                      ? _nombres[cliId]
                                      : null;
                                  final fotoPath = cliId != null
                                      ? _fotos[cliId]
                                      : null;
                                  // v1.2.1: detalle con nombre real y
                                  // montos resaltados.
                                  final detalle =
                                      _detalleConNombre(a);
                                  // v1.3.3: chip "En cola" y badge de
                                  // monto (diseño Argón).
                                  final enCola =
                                      a['_en_cola'] == true;
                                  double badgeCup = 0, badgeUsd = 0;
                                  if (enCola) {
                                    badgeCup =
                                        (a['_monto_cup'] as num?)
                                                ?.toDouble() ??
                                            0;
                                    badgeUsd =
                                        (a['_monto_usd'] as num?)
                                                ?.toDouble() ??
                                            0;
                                  } else if (_esCobroServidor(
                                      accion)) {
                                    final m = _montoServidor(
                                        '${a['detalle'] ?? ''}');
                                    if (m != null) {
                                      if (m.$2 == 'USD') {
                                        badgeUsd = m.$1;
                                      } else {
                                        badgeCup = m.$1;
                                      }
                                    }
                                  }
                                  final titulo = (nombreCli != null &&
                                          !nombreCli.startsWith(
                                              'Cliente '))
                                      ? nombreCli
                                      : _tituloAccion(accion);
                                  return Padding(
                                    padding: const EdgeInsets
                                        .symmetric(
                                        horizontal: 12,
                                        vertical: 4),
                                    child: InkWell(
                                      borderRadius:
                                          BorderRadius.circular(
                                              AppRadio.md),
                                      onTap: tieneCliente
                                          ? () =>
                                              _abrirFicha(a)
                                          : null,
                                      child: Padding(
                                        padding:
                                            const EdgeInsets
                                                .symmetric(
                                                horizontal:
                                                    8,
                                                vertical:
                                                    8),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment
                                                  .start,
                                          children: [
                                            // v1.2.1: foto del cliente
                                            // o icono de la acción.
                                            _leadingActividad(
                                                fotoPath,
                                                color,
                                                accion),
                                            const SizedBox(
                                                width:
                                                    AppEspacio
                                                        .md),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment
                                                        .start,
                                                children: [
                                                  // v1.3.3: título +
                                                  // badge de monto +
                                                  // chip "En cola".
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child: Text(
                                                          titulo,
                                                          style: AppTexto
                                                              .subtitulo
                                                              .copyWith(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold),
                                                          maxLines:
                                                              1,
                                                          overflow:
                                                              TextOverflow
                                                                  .ellipsis,
                                                        ),
                                                      ),
                                                      if (badgeCup > 0 ||
                                                          badgeUsd >
                                                              0)
                                                        _badgeMonto(
                                                            badgeCup,
                                                            badgeUsd),
                                                      if (enCola) ...[
                                                        const SizedBox(
                                                            width:
                                                                6),
                                                        _chipEnCola(),
                                                      ],
                                                    ],
                                                  ),
                                                  const SizedBox(
                                                      height:
                                                          2),
                                                  RichText(
                                                    maxLines: 3,
                                                    overflow:
                                                        TextOverflow
                                                            .ellipsis,
                                                    text: TextSpan(
                                                      style: AppTexto
                                                          .cuerpo.copyWith(
                                                              color: Theme.of(
                                                                      context)
                                                                  .colorScheme
                                                                  .onSurface),
                                                      children:
                                                          _resaltarMontos(
                                                              detalle),
                                                    ),
                                                  ),
                                                  const SizedBox(
                                                      height:
                                                          4),
                                                  Row(
                                                    children: [
                                                      Icon(
                                                          Icons
                                                              .person_outline,
                                                          size:
                                                              13,
                                                          color: Theme.of(
                                                                  context)
                                                              .colorScheme
                                                              .onSurfaceVariant),
                                                      const SizedBox(
                                                          width:
                                                              4),
                                                      Expanded(
                                                        child:
                                                            Text(
                                                          _subtituloActividad(
                                                              a),
                                                          style:
                                                              AppTexto
                                                                  .etiqueta
                                                                  .copyWith(
                                                            color: Theme.of(context)
                                                                .colorScheme
                                                                .onSurfaceVariant,
                                                          ),
                                                          overflow:
                                                              TextOverflow
                                                                  .ellipsis,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (tieneCliente)
                                              Icon(
                                                  Icons
                                                      .chevron_right,
                                                  size: 20,
                                                  color: AppColores
                                                      .textoSecundario(
                                                          context)),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                }),
                              ],
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  /// v1.3.3: calcula (n_acciones, total_cup, total_usd) sobre los
  /// items filtrados. Servidor: regex sobre detalle (solo cobros
  /// reales). Local: montos del payload ya calculados al cargar.
  (int, double, double) _kpi(List<Map<String, dynamic>> items) {
    double cup = 0, usd = 0;
    for (final a in items) {
      if (a['_en_cola'] == true) {
        cup += (a['_monto_cup'] as num?)?.toDouble() ?? 0;
        usd += (a['_monto_usd'] as num?)?.toDouble() ?? 0;
      } else {
        final accion = '${a['accion'] ?? ''}';
        if (!_esCobroServidor(accion)) continue;
        final m = _montoServidor('${a['detalle'] ?? ''}');
        if (m != null) {
          if (m.$2 == 'USD') {
            usd += m.$1;
          } else {
            cup += m.$1;
          }
        }
      }
    }
    return (items.length, cup, usd);
  }

  /// v1.3.3: cinta de resumen financiero debajo de los filtros.
  Widget _kpiBar(List<Map<String, dynamic>> filtrados) {
    final kpi = _kpi(filtrados);
    final n = kpi.$1;
    final cup = kpi.$2;
    final usd = kpi.$3;
    final totalTxt = StringBuffer('${fmtMonto(cup)} CUP');
    if (usd > 0) totalTxt.write(' (+ ${fmtMonto(usd)} USD)');
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Tarjeta(
        padding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.analytics_outlined,
                size: 20, color: AppColores.naranja),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$n acciones',
                      style: AppTexto.etiqueta.copyWith(
                          color: AppColores.textoSecundario(
                              context))),
                  const SizedBox(height: 2),
                  Text('Total cobrado: $totalTxt',
                      style: AppTexto.subtitulo.copyWith(
                          fontWeight: FontWeight.bold,
                          color: AppColores.exito)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// v1.3.3: título legible a partir de la acción
  /// ("pago_sync" -> "Pago mensual", "venta_suplemento" -> "Venta").
  String _tituloAccion(String accion) {
    final a = accion.toLowerCase();
    if (a.contains('inscripcion_venta')) return 'Inscripción + venta';
    if (a.contains('inscri')) return 'Inscripción';
    if (a.contains('pago_diario') || a == 'diario') {
      return 'Pago diario';
    }
    if (a.contains('regalo_cumpleanos') ||
        a.contains('regalar_mes')) {
      return 'Mes gratis (cumpleaños)';
    }
    if (a.contains('pago') && !a.contains('diario')) {
      return 'Pago mensual';
    }
    if (a.contains('venta_suplemento')) return 'Venta suplemento';
    if (a.contains('suplemento')) return 'Suplemento';
    if (a.contains('confirmar_entrega')) return 'Entrega confirmada';
    if (a.contains('categoria')) return 'Categoría';
    final t =
        accion.replaceAll('_sync', '').replaceAll('_', ' ').trim();
    if (t.isEmpty) return 'Actividad';
    return t[0].toUpperCase() + t.substring(1);
  }

  /// v1.3.3: chip ámbar "⏳ En cola" para ops locales.
  Widget _chipEnCola() {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColores.alerta.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: AppColores.alerta.withValues(alpha: 0.5)),
      ),
      child: const Text(
        '⏳ En cola',
        style: TextStyle(
            color: AppColores.alerta,
            fontSize: 10,
            fontWeight: FontWeight.bold),
      ),
    );
  }

  /// v1.3.3: badge de monto a la derecha (+2,000 CUP).
  Widget _badgeMonto(double cup, double usd) {
    final txt = usd > 0
        ? '+${fmtMonto(usd)} USD'
        : '+${fmtMonto(cup)} CUP';
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColores.exito.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        txt,
        style: const TextStyle(
            color: AppColores.exito,
            fontSize: 12,
            fontWeight: FontWeight.bold),
      ),
    );
  }

  /// v1.3.3: subtítulo "actor · HH:mm (hace X min)".
  String _subtituloActividad(Map<String, dynamic> a) {
    final actor = '${a['actor'] ?? '—'}';
    final ts = a['ts'] as String?;
    final hora = _horaCorta(ts);
    final rel = tiempoRelativo(ts);
    final horaTxt = hora.isNotEmpty ? ' · $hora' : '';
    return '$actor$horaTxt ($rel)';
  }

  /// v1.3.3: "HH:mm" local a partir del ts.
  String _horaCorta(String? ts) {
    if (ts == null || ts.isEmpty) return '';
    try {
      final dt = DateTime.parse(ts).toLocal();
      return '${dt.hour.toString().padLeft(2, '0')}:'
          '${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  Widget _chipFiltro(String valor, String etiqueta) {
    final activo = _filtro == valor;
    return ChoiceChip(
      label: Text(etiqueta),
      selected: activo,
      onSelected: (_) => setState(() => _filtro = valor),
    );
  }

  /// v1.0.15: chip de filtro por entrenador/actor.
  Widget _chipActor(String valor, String etiqueta) {
    final activo = _filtroActor == valor;
    return ChoiceChip(
      label: Text(etiqueta,
          style: const TextStyle(fontSize: 12)),
      selected: activo,
      onSelected: (_) =>
          setState(() => _filtroActor = valor),
    );
  }

  /// v1.2.1: chip de filtro por fecha.
  Widget _chipFecha(String valor, String etiqueta) {
    final activo = _filtroFecha == valor;
    return ChoiceChip(
      label: Text(etiqueta,
          style: const TextStyle(fontSize: 12)),
      selected: activo,
      onSelected: (_) =>
          setState(() => _filtroFecha = valor),
    );
  }

  /// v1.2.1: chip de rango personalizado (abre date pickers).
  Widget _chipFechaRango() {
    final activo = _filtroFecha == 'rango';
    String etiqueta = 'Rango…';
    if (_rangoIni != null && _rangoFin != null) {
      etiqueta =
          '${fmtFecha(_isoDia(_rangoIni!))}–${fmtFecha(_isoDia(_rangoFin!))}';
    }
    return ChoiceChip(
      label: Text(etiqueta,
          style: const TextStyle(fontSize: 12)),
      selected: activo,
      onSelected: (_) => _elegirRango(),
    );
  }
}

/// Cuenta las actividades no leídas (para el badge).
Future<int> actividadNoLeidas() async {
  try {
    final p = await SharedPreferences.getInstance();
    final vista = p.getString('actividad_vista_ts') ?? '';
    final raw =
        await LocalDb.instance.getMeta('sync_estado_actividad');
    if (raw == null || raw.isEmpty) return 0;
    // v1.0.15 fix: comparar como DateTime, no como texto.
    // El servidor manda 'YYYY-MM-DD HH:MM:SS' y la APK guarda ISO8601;
    // la comparación lexicográfica siempre daba falso.
    final vistaDt =
        vista.isEmpty ? null : DateTime.tryParse(vista)?.toUtc();
    int n = 0;
    for (final a in jsonDecode(raw) as List) {
      final ts = '${(a as Map)['ts'] ?? ''}';
      if (vistaDt == null) {
        n++;
        continue;
      }
      // El servidor guarda ts en UTC sin zona; lo tratamos como UTC.
      var tsDt = DateTime.tryParse(ts);
      if (tsDt != null && tsDt.isUtc == false) {
        tsDt = DateTime.utc(tsDt.year, tsDt.month, tsDt.day, tsDt.hour,
            tsDt.minute, tsDt.second);
      }
      if (tsDt != null && tsDt.isAfter(vistaDt)) n++;
    }
    return n;
  } catch (_) {
    return 0;
  }
}
