/// Listas: vencen hoy, atrasados, por vencer. Con mini foto y pago rápido.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../permisos_entrenador.dart';
import '../tiempo.dart';
import '../sync.dart';
import '../cliente_protegido.dart';
import '../precio_cobro.dart';
import 'buscar.dart';
import 'componentes.dart';
import 'permisos_ui.dart';
import 'dialogo_pago.dart';
import 'preview_cobro.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

/// 1.23 (Delta Argón 4ª#6): un solo RegExp reutilizado — antes
/// se construía uno nuevo por cliente en cada búsqueda.
final _reNoDigitosListas = RegExp(r'[^0-9]');

/// Buscador de Listas (16/25, PURO): coincide por nombre (sin
/// mayúsculas) o por dígitos del teléfono.
bool coincideBusquedaListas(Map<String, dynamic> c, String texto) {
  final q = texto.trim().toLowerCase();
  if (q.isEmpty) return true;
  if ('${c['nombre'] ?? ''}'.toLowerCase().contains(q)) return true;
  final digQ = q.replaceAll(_reNoDigitosListas, '');
  if (digQ.isNotEmpty) {
    final tel =
        '${c['telefono'] ?? ''}'.replaceAll(_reNoDigitosListas, '');
    if (tel.contains(digQ)) return true;
  }
  return false;
}

/// 1.25 Panel 12: una vista guardada de Listas = pestaña +
/// orden + búsqueda, con nombre propio. El chip enseña su
/// ALCANCE («Atrasados -30d · Días restantes») para saber
/// qué cubre sin abrirla.
class VistaLista {
  final String nombre;
  final int pestana;
  final String orden;
  final String busqueda;

  const VistaLista({
    required this.nombre,
    required this.pestana,
    required this.orden,
    this.busqueda = '',
  });

  static const nombresPestana = [
    'Hoy',
    'Por vencer',
    'Atrasados -30d',
    'Atrasados +30d',
    'Al día',
  ];
  static const ordenes = ['nombre', 'vencimiento', 'dias'];

  String get alcance {
    final o = switch (orden) {
      'vencimiento' => 'Vencimiento',
      'dias' => 'Días restantes',
      _ => 'Nombre',
    };
    final base = '${nombresPestana[pestana]} · $o';
    return busqueda.isEmpty ? base : '$base · «$busqueda»';
  }

  bool coincideCon(
          {required int pestana,
          required String orden,
          required String busqueda}) =>
      this.pestana == pestana &&
      this.orden == orden &&
      this.busqueda == busqueda;

  Map<String, dynamic> toJson() => {
        'nombre': nombre,
        'pestana': pestana,
        'orden': orden,
        'busqueda': busqueda,
      };

  /// Null si el JSON no describe una vista válida (rangos
  /// y tipos se verifican: las preferencias se pueden
  /// corromper o venir de otra versión).
  static VistaLista? fromJson(Map<String, dynamic> j) {
    final nombre = '${j['nombre'] ?? ''}'.trim();
    final pestana = (j['pestana'] as num?)?.toInt();
    final orden = '${j['orden'] ?? ''}';
    if (nombre.isEmpty ||
        pestana == null ||
        pestana < 0 ||
        pestana >= nombresPestana.length ||
        !ordenes.contains(orden)) {
      return null;
    }
    return VistaLista(
      nombre: nombre,
      pestana: pestana,
      orden: orden,
      busqueda: '${j['busqueda'] ?? ''}',
    );
  }
}

const kVistasListasKey = 'listas_vistas_v1';
const kMaxVistasListas = 6;

class ListasScreen extends StatefulWidget {
  /// Pestaña inicial: 0=Hoy, 1=Por vencer, 2=Atrasados <30d, 3=Atrasados +30d,
  /// 4=Al día (v1.2.1).
  final int inicial;
  const ListasScreen({super.key, this.inicial = 0});
  @override
  State<ListasScreen> createState() => _ListasScreenState();
}

class _ListasScreenState extends State<ListasScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  // 1.24 Bloque 4: anti-doble-toque síncrono del cobro rápido.
  bool _pagoEnCurso = false;
  List<Map<String, dynamic>> _hoy = [];
  List<Map<String, dynamic>> _menos30 = [];
  List<Map<String, dynamic>> _mas30 = [];
  List<Map<String, dynamic>> _porVencer = [];
  List<Map<String, dynamic>> _alDia = []; // v1.2.1
  // 1.25 T46: estimado por cobrar de cada pestaña de
  // atrasados (una mensualidad por cliente, con su tarifa
  // real vía precioCobroParaCliente — la misma fuente que
  // «Vencidos por cobrar»).
  double _estimadoMenos30 = 0;
  double _estimadoMas30 = 0;
  String _orden = 'nombre'; // nombre | vencimiento | dias
  // 16/25: buscador dentro de Listas (nombre o teléfono).
  String _busqueda = '';
  final _busquedaCtrl = TextEditingController();
  // D-08 (1.21): visibles memoizados (antes _visibles() corría
  // 5× por build, ordenando y filtrando todo en cada tecla) y
  // avisados precargados (antes un FutureBuilder por fila).
  List<Map<String, dynamic>> _visHoy = [];
  List<Map<String, dynamic>> _visMenos30 = [];
  // 1.25 T09: los SIN FECHA (nunca pagaron) salen de
  // «Atrasados -30d» a un grupo propio al final de la
  // pestaña, con posición fija sea cual sea el orden.
  List<Map<String, dynamic>> _sinFecha = [];
  List<Map<String, dynamic>> _visSinFecha = [];
  List<Map<String, dynamic>> _visMas30 = [];
  List<Map<String, dynamic>> _visPorVencer = [];
  List<Map<String, dynamic>> _visAlDia = [];
  Set<int> _avisados = {};
  // 1.25 T116 (F1-26): cuándo se avisó a cada vigente,
  // para el chip de texto de la fila.
  Map<int, DateTime> _avisadoEl = {};
  // 1.25 T116 (F1-24): hasta que el usuario elija orden a
  // mano, cada pestaña usa SU defecto (urgencia en las de
  // trabajo, nombre en «Al día»).
  bool _ordenManual = false;
  // 1.25 Panel 12: vistas guardadas (SharedPreferences).
  List<VistaLista> _vistas = [];
  // 1.25 Panel 14: la última carga falló — los vacíos de
  // las pestañas deben decir ESO, no «nadie vence».
  bool _falloCarga = false;

  void _recalcularVisibles() {
    _visHoy = _visibles(_hoy);
    _visMenos30 = _visibles(_menos30);
    // T09: el grupo sin fecha NO pasa por _ordenar (su
    // posición es fija: al final; dentro, por nombre) pero
    // SÍ por la búsqueda (T10: lo que se ve es lo que hay).
    _visSinFecha = _sinFecha
        .where((c) => coincideBusquedaListas(c, _busqueda))
        .toList();
    _visMas30 = _visibles(_mas30);
    _visPorVencer = _visibles(_porVencer);
    _visAlDia = _visibles(_alDia);
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    _tab.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    FadeEntrada.reiniciarVentana(); // T3: ventana de cascada
    _tab = TabController(
        length: 5, vsync: this, initialIndex: widget.inicial);
    // 1.25 T116 (F1-24): el defecto de orden depende de la
    // pestaña — en las de deuda manda la urgencia («Días
    // restantes»: el más atrasado primero); «Nombre» solo
    // es el defecto de «Al día». Si el usuario elige otro
    // orden en el desplegable, su elección manda en todas.
    _orden = widget.inicial == 4 ? 'nombre' : 'dias';
    _tab.addListener(() {
      if (_ordenManual || !mounted) return;
      final nuevo = _tab.index == 4 ? 'nombre' : 'dias';
      if (nuevo != _orden) {
        setState(() {
          _orden = nuevo;
          _recalcularVisibles();
        });
      }
    });
    _cargar();
    _cargarVistas();
  }

  Future<void> _cargarVistas() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final crudas = prefs.getStringList(kVistasListasKey) ?? [];
      final vistas = <VistaLista>[];
      for (final t in crudas) {
        try {
          final v = VistaLista.fromJson(
              Map<String, dynamic>.from(jsonDecode(t) as Map));
          if (v != null) vistas.add(v);
        } catch (_) {
          // Una vista corrupta no tumba a las demás.
        }
      }
      if (!mounted) return;
      setState(() => _vistas = vistas);
    } catch (_) {
      // Sin preferencias, Listas funciona como siempre.
    }
  }

  Future<void> _persistirVistas() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(kVistasListasKey,
          [for (final v in _vistas) jsonEncode(v.toJson())]);
    } catch (_) {}
  }

  /// Aplica una vista guardada: pestaña, orden (manual:
  /// manda sobre el defecto por pestaña) y búsqueda.
  void _aplicarVista(VistaLista v) {
    setState(() {
      _ordenManual = true;
      _orden = v.orden;
      _busqueda = v.busqueda;
      _busquedaCtrl.text = v.busqueda;
      _recalcularVisibles();
    });
    if (_tab.index != v.pestana) _tab.animateTo(v.pestana);
  }

  Future<void> _guardarVistaActual() async {
    if (_vistas.length >= kMaxVistasListas) {
      mostrarSnack(context,
          'Ya hay $kMaxVistasListas vistas guardadas; quita una primero',
          significado: SignificadoChip.alerta);
      return;
    }
    final nombre = await showDialog<String>(
      context: context,
      builder: (_) => const _DialogoNombreVista(),
    );
    if (nombre == null || nombre.trim().isEmpty || !mounted) return;
    setState(() {
      _vistas = [
        ..._vistas,
        VistaLista(
          nombre: nombre.trim(),
          pestana: _tab.index,
          orden: _orden,
          busqueda: _busqueda,
        ),
      ];
    });
    await _persistirVistas();
    if (!mounted) return;
    mostrarSnack(context, 'Vista «${nombre.trim()}» guardada',
        significado: SignificadoChip.exito);
  }

  Future<void> _quitarVista(VistaLista v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitar vista'),
        content: Text('¿Quitar la vista «${v.nombre}» (${v.alcance})?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Quitar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _vistas = _vistas.where((x) => x != v).toList());
    await _persistirVistas();
  }

  /// La fila de chips de vistas (Panel 12): cada chip dice
  /// su alcance; la ✕ lo quita; el último guarda la actual.
  Widget _filaVistas() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final v in _vistas) ...[
              InputChip(
                label: Text('${v.nombre} · ${v.alcance}'),
                selected: v.coincideCon(
                    pestana: _tab.index,
                    orden: _orden,
                    busqueda: _busqueda),
                onPressed: () => _aplicarVista(v),
                onDeleted: () => _quitarVista(v),
              ),
              const SizedBox(width: 8),
            ],
            ActionChip(
              avatar: const Icon(Icons.bookmark_add_rounded, size: 18),
              label: const Text('Guardar vista'),
              onPressed: _guardarVistaActual,
            ),
          ],
        ),
      ),
    );
  }

  /// 1.25 Panel 14: envoltorio de la carga — si la lectura
  /// del espejo falla, la pantalla lo DECLARA (causa «no se
  /// pudo cargar» con Reintentar) en vez de pintar cinco
  /// vacíos falsos de «nadie vence».
  Future<void> _cargar() async {
    try {
      await _cargarInterno();
      if (_falloCarga && mounted) {
        setState(() => _falloCarga = false);
      }
    } catch (_) {
      if (mounted) setState(() => _falloCarga = true);
    }
  }

  Future<void> _cargarInterno() async {
    final h = await vencenHoy();
    final m30crudo = await atrasados(masDe30: false);
    // 1.25 T09: atrasados(masDe30:false) incluye a los sin
    // pagado_hasta (nunca pagaron); aquí se separan: no son
    // «atrasados de hace X días», son otro grupo.
    final m30 = m30crudo
        .where((c) => c['pagado_hasta'] != null)
        .toList();
    final sinFecha = m30crudo
        .where((c) => c['pagado_hasta'] == null)
        .toList()
      ..sort(compararPorNombre);
    final p30 = await atrasados(masDe30: true);
    final pv = await porVencer(dias: 3);
    // 1.25 T03: la pestaña usa la variante SIN los de hoy
    // ni los por vencer (clientesAlDia a secas es el
    // predicado de acceso y los incluye: duplicaba).
    final ad = await clientesAlDiaPestana();
    // Cliente protegido (2026-10-26, Protegido 2 H6): estas listas
    // muestran teléfono y botón de WhatsApp; un no-dueño no ve
    // protegidos en ninguna.
    List<Map<String, dynamic>> sinProtegidos(
        List<Map<String, dynamic>> l) =>
        l.where((c) => !esVistaProtegida(c)).toList();
    // 1.25 T02: solo las marcas del vencimiento ACTUAL —
    // una marca de un vencimiento anterior no esconde al
    // cliente de la lista de por avisar.
    final avisados =
        await LocalDb.instance.avisadosVigentesConFecha();
    // 1.25 T46: estimados de las pestañas de atrasados,
    // calculados sobre las listas ya sin protegidos.
    final pr = await preciosVigentes();
    Future<double> estimadoDe(
            List<Map<String, dynamic>> lista) async =>
        (await Future.wait(lista.map((c) async =>
            (await precioCobroParaCliente(
                    cliente: c,
                    periodo: 'mensual',
                    metodo: 'efectivo',
                    precios: pr))
                .monto))).fold<double>(0, (a, b) => a + b);
    final estMenos = await estimadoDe(sinProtegidos(m30));
    final estMas = await estimadoDe(sinProtegidos(p30));
    if (mounted) {
      setState(() {
        _hoy = sinProtegidos(h);
        _menos30 = sinProtegidos(m30);
        _sinFecha = sinProtegidos(sinFecha);
        _mas30 = sinProtegidos(p30);
        _porVencer = sinProtegidos(pv);
        _alDia = sinProtegidos(ad);
        _estimadoMenos30 = estMenos;
        _estimadoMas30 = estMas;
        _avisadoEl = avisados;
        _avisados = avisados.keys.toSet();
        _recalcularVisibles();
      });
    }
  }

  /// Ordena una lista según el criterio elegido (punto 26).
  List<Map<String, dynamic>> _ordenar(
      List<Map<String, dynamic>> rows) {
    final r = [...rows];
    switch (_orden) {
      case 'vencimiento':
        r.sort((a, b) {
          final c = '${a['pagado_hasta'] ?? ''}'
              .compareTo('${b['pagado_hasta'] ?? ''}');
          return c != 0
              ? c
              : compararPorNombre(a, b);
        });
        break;
      case 'dias':
        r.sort((a, b) {
          final da =
              diasRestantes(a['pagado_hasta'] as String?) ?? 999999;
          final db =
              diasRestantes(b['pagado_hasta'] as String?) ?? 999999;
          final c = da.compareTo(db);
          return c != 0
              ? c
              : compararPorNombre(a, b);
        });
        break;
      default:
        r.sort(compararPorNombre);
    }
    return r;
  }

  /// 16/25: lista ordenada y filtrada por la búsqueda (aplica a
  /// las 5 pestañas por igual).
  List<Map<String, dynamic>> _visibles(
      List<Map<String, dynamic>> rows) {
    return _ordenar(rows)
        .where((c) => coincideBusquedaListas(c, _busqueda))
        .toList();
  }

  Future<void> _pagoRapido(Map<String, dynamic> c) async {
    // 1.24 Bloque 4: anti-doble-toque síncrono.
    if (_pagoEnCurso) return;
    _pagoEnCurso = true;
    try {
      await _pagoRapidoFlujo(c);
    } finally {
      _pagoEnCurso = false;
    }
  }

  Future<void> _pagoRapidoFlujo(Map<String, dynamic> c) async {
    // 1.24 Bloque 3: permiso operativo al tocar.
    if (!await permisoOperativoOkConRefresco(
        context, () => PermisosEntrenador().canCobrarPagos, 'cobrar pagos')) {
      return;
    }
    // Bloque 1 (Argón AMARILLO): Casa no paga mensualidad, y el
    // «cobro en 2 toques» ya no existe: todo cobro pasa por el
    // Preview obligatorio + Recibo con Deshacer, sin excepciones.
    if (await mostrarBloqueoCasa(context, c)) return;
    if (!mounted) return;
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    final resultadoCobro = await cobrarConPreviewYRecibo(
      context: context,
      nombreCliente: '${c['nombre'] ?? ''}',
      payload: payload,
    );
    if (!mounted) return;
    if (resultadoCobro == ResultadoCobro.deshecho) {
      mostrarSnack(context, 'Cobro deshecho', significado: SignificadoChip.exito);
    }
    _cargar();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vencimientos'), // v1.3.6: renombrado (era 'Listas')
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabs: [
            // L1 (estéticas 1.19): cada pestaña lleva su color
            // semántico — ámbar para Hoy/Por vencer, rojo para
            // los dos Atrasados, verde para Al día — para ver la
            // urgencia sin leer el número.
            Tab(
              child: Text('Hoy (${_visHoy.length})',
                  style: const TextStyle(
                      color: AppColores.alerta,
                      fontWeight: FontWeight.w600)),
            ),
            Tab(
              // 1.25 T116 (F1-22): la pestaña dice su
              // ventana — el semáforo del avatar se pone
              // ámbar a los 7 días y sin el rótulo parecía
              // que faltaban clientes de 4-7 días.
              child: Text('Por vencer · 3 días (${_visPorVencer.length})',
                  style: const TextStyle(
                      color: AppColores.alerta,
                      fontWeight: FontWeight.w600)),
            ),
            Tab(
              child: Text(
                  'Atrasados -30d (${_visMenos30.length + _visSinFecha.length})',
                  style: const TextStyle(
                      color: AppColores.error,
                      fontWeight: FontWeight.w600)),
            ),
            Tab(
              child: Text('Atrasados +30d (${_visMas30.length})',
                  style: const TextStyle(
                      color: AppColores.error,
                      fontWeight: FontWeight.w600)),
            ),
            Tab(
              child: Text('Al día (${_visAlDia.length})',
                  style: const TextStyle(
                      color: AppColores.exito,
                      fontWeight: FontWeight.w600)),
            ), // v1.2.1
          ],
        ),
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                const Text('Ordenar: ',
                    style: AppTexto.secundario),
                DropdownButton<String>(
                  value: _orden,
                  items: const [
                    DropdownMenuItem(
                        value: 'nombre',
                        child: Text('Nombre')),
                    DropdownMenuItem(
                        value: 'vencimiento',
                        child: Text('Vencimiento')),
                    DropdownMenuItem(
                        value: 'dias',
                        child: Text('Días restantes')),
                  ],
                  onChanged: (v) => setState(() {
                        // F1-24: la elección manual manda
                        // sobre el defecto por pestaña.
                        _ordenManual = true;
                        _orden = v ?? 'nombre';
                        _recalcularVisibles();
                      }),
                ),
              ],
            ),
          ),
          // 16/25: buscador (nombre o teléfono, en las 5 pestañas).
          Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: CampoTexto(
                    controller: _busquedaCtrl,
                    hint: 'Buscar cliente…',
                    icono: Icons.search_rounded,
                    onChanged: (v) =>
                        setState(() {
                          _busqueda = v.trim();
                          _recalcularVisibles();
                        }),
                  ),
                ),
                if (_busqueda.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    tooltip: 'Limpiar búsqueda',
                    onPressed: () {
                      _busquedaCtrl.clear();
                      setState(() {
                        _busqueda = '';
                        _recalcularVisibles();
                      });
                    },
                  ),
              ],
            ),
          ),
          _filaVistas(),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _lista(_visHoy, Icons.celebration_rounded,
                    'Nadie vence hoy', 'Todo al día.'),
                // 1.25 T116 (F1-25): fuera la celebración
                // en pestañas de deuda y en «Por vencer»:
                // icono tranquilo y, en atrasados, el paso
                // siguiente (ir a «Al día»).
                _lista(_visPorVencer,
                    Icons.check_circle_rounded, 'Nadie por vencer',
                    'Nada en los próximos 3 días.'),
                _lista(_visMenos30,
                    Icons.check_circle_rounded, 'Sin atrasados',
                    'Nada de menos de un mes.',
                    esColaCobro: true,
                    estimado: _estimadoMenos30,
                    cola: _visSinFecha,
                    tituloCola: 'Sin fecha de vencimiento',
                    textoAccionVacio: 'Ver «Al día»',
                    onAccionVacio: () => _tab.animateTo(4)),
                _lista(_visMas30,
                    Icons.check_circle_rounded, 'Sin atrasados',
                    'Nada de más de un mes.',
                    esColaCobro: true,
                    estimado: _estimadoMas30,
                    textoAccionVacio: 'Ver «Al día»',
                    onAccionVacio: () => _tab.animateTo(4)),
                _lista(_visAlDia, // v1.2.1
                    Icons.check_circle_rounded, 'Nadie al día',
                    'Todos los activos están vencidos.'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v1.2.4 (C7): móvil cubano del cliente para wa.me (con prefijo
  /// 53) o null. Argón P3#5: normalizarTelefonoWaMe acepta 5 y 6.
  String? _movilCliente(Map<String, dynamic> c) {
    final normalizado =
        normalizarTelefonoWaMe('${c['telefono'] ?? ''}');
    return normalizado.isEmpty ? null : normalizado;
  }

  Future<String?> _elegirAviso(Map<String, dynamic> c) async {
    if (_movilCliente(c) == null) return 'marcar';
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat_rounded, color: AppColores.exito),
              title: const Text('Avisar por WhatsApp'),
              subtitle: const Text('Abre WhatsApp con el mensaje escrito'),
              onTap: () => Navigator.pop(ctx, 'whatsapp'),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline_rounded),
              title: const Text('Solo marcar como avisado'),
              onTap: () => Navigator.pop(ctx, 'marcar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _abrirWhatsapp(Map<String, dynamic> c) async {
    final movil = _movilCliente(c);
    if (movil == null) return false;
    final nombre = '${c['nombre'] ?? ''}'.split(' ').first;
    final hasta = '${c['pagado_hasta'] ?? ''}';
    final f = hasta.length >= 10 ? fmtFecha(hasta) : '';
    final venceTxt = f.isEmpty
        ? 'tu mensualidad está por vencer'
        : (hasta.substring(0, 10).compareTo(
                    hoyHabanaIso()) <
                0
            ? 'tu mensualidad venció el $f'
            : 'tu mensualidad vence el $f');
    // FIN-27 de Argón (1.20): este recordatorio lo compone la
    // app, así que cierra con la línea automática aprobada
    // (respuestas al 58191577), como los de la bandeja.
    final msg = 'Hola $nombre 👋, te recordamos de Iron Body Gym que '
        '$venceTxt. ¡Te esperamos para seguir entrenando! 💪'
        ' $lineaMensajeAutomatico';
    final ok = await launchUrl(
        Uri.parse('https://wa.me/$movil?text=${Uri.encodeComponent(msg)}'),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      mostrarSnack(context, 'No se pudo abrir WhatsApp', significado: SignificadoChip.error);
    }
    return ok;
  }

  /// F10 (1.20): avisar a un cliente de la lista y, si
  /// quedan más sin avisar DESPUÉS de él, ofrecer en el
  /// propio aviso el paso directo al siguiente (sin volver
  /// a buscarlo en la lista). La cadena sigue mientras el
  /// usuario la acepte; solo aplica al aviso por WhatsApp.
  Future<void> _avisarEnCadena(
      List<Map<String, dynamic>> rows, int idx) async {
    final c = rows[idx];
    final id = (c['id'] as num?)?.toInt() ?? 0;
    // v1.2.4 (C7): avisar por WhatsApp con el mensaje ya
    // escrito si tiene teléfono.
    final via = await _elegirAviso(c);
    if (via == null || !mounted) return;
    if (via == 'whatsapp') {
      final ok = await _abrirWhatsapp(c);
      if (!ok) return;
    }
    await LocalDb.instance
        .marcarAvisado(id, pagadoHasta: c['pagado_hasta'] as String?);
    if (!mounted) return;
    // D-08: el conjunto en memoria refleja la marca al momento
    // (la búsqueda del siguiente no relee la BD por candidato).
    // F1-26: también la fecha, para que el chip salga ya.
    setState(() {
      _avisados.add(id);
      _avisadoEl[id] = ahoraHabana();
    });
    Map<String, dynamic>? siguiente;
    var idxSiguiente = -1;
    if (via == 'whatsapp') {
      for (var j = idx + 1; j < rows.length; j++) {
        final oid = (rows[j]['id'] as num?)?.toInt();
        if (oid == null || oid == id) continue;
        if (!_avisados.contains(oid)) {
          siguiente = rows[j];
          idxSiguiente = j;
          break;
        }
      }
    }
    if (!mounted) return;
    final sig = siguiente;
    if (sig != null) {
      final nombreSig =
          '${sig['nombre'] ?? ''}'.split(' ').first;
      mostrarSnack(
        context,
        '${c['nombre']} marcado como avisado',
        significado: SignificadoChip.exito,
        accion: 'Siguiente: $nombreSig',
        alAccion: () => _avisarEnCadena(rows, idxSiguiente),
      );
    } else {
      mostrarSnack(
          context, '${c['nombre']} marcado como avisado',
          significado: SignificadoChip.exito);
    }
    setState(() {});
  }

  Widget _lista(List<Map<String, dynamic>> rows, IconData iconoVacio,
      String tituloVacio, String subtituloVacio,
      {// 1.25 T46: cabecera de cola de cobro (atrasados).
      bool esColaCobro = false,
      double estimado = 0,
      List<Map<String, dynamic>>? cola,
      String? tituloCola,
      // 1.25 T116 (F1-25): acción del vacío (p. ej. ir a
      // «Al día» desde un «Sin atrasados»).
      String? textoAccionVacio,
      VoidCallback? onAccionVacio}) {
    // 1.25 T09: grupo final separado (los sin fecha en
    // «Atrasados -30d»): cabecera propia y posición fija
    // tras la lista principal, con sus mismas filas.
    final hayCola = cola != null && cola.isNotEmpty;
    if (rows.isEmpty && !hayCola) {
      // 1.25 Panel 14: la causa manda — si la carga falló,
      // el vacío lo dice y ofrece reintentar (antes que la
      // búsqueda y que el «nadie vence» de la pestaña).
      if (_falloCarga) {
        return EstadoVacio(
          icono: Icons.cloud_off_rounded,
          titulo: 'No se pudo cargar esta lista',
          subtitulo: 'Los datos de este teléfono no '
              'respondieron; lo de las demás pestañas '
              'también puede estar incompleto.',
          textoAccion: 'Reintentar',
          onAccion: _cargar,
        );
      }
      // 16/25: con búsqueda activa, el vacío es por la búsqueda
      // (no porque nadie venza) y ofrece limpiarla.
      if (_busqueda.isNotEmpty) {
        return EstadoVacio(
          icono: Icons.search_off_rounded,
          titulo: 'Sin coincidencias',
          subtitulo: 'Ningún cliente de esta lista coincide '
              'con «$_busqueda».',
          textoAccion: 'Limpiar búsqueda',
          onAccion: () {
            _busquedaCtrl.clear();
            setState(() {
              _busqueda = '';
              _recalcularVisibles();
            });
          },
        );
      }
      return EstadoVacio(
          icono: iconoVacio,
          titulo: tituloVacio,
          subtitulo: subtituloVacio,
          textoAccion: textoAccionVacio,
          onAccion: onAccionVacio);
    }
    // 1.25 T46: la cabecera cuenta como primer ítem y
    // desplaza los índices de filas y de la cola.
    final desplaza = esColaCobro && rows.isNotEmpty ? 1 : 0;
    // 1.25 T50: progreso de la sesión de avisos sobre ESTA
    // lista — «N de M avisados» con su barra. Solo aparece
    // cuando ya hay alguien avisado (la sesión empezó);
    // sin avisos, la lista queda como siempre.
    final totalLista = rows.length + (cola?.length ?? 0);
    final avisadosLista = [...rows, ...?cola]
        .where((c) => _avisados.contains((c['id'] as int?) ?? 0))
        .length;
    final lista = RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.separated(
        itemCount:
            desplaza + rows.length + (hayCola ? cola.length + 1 : 0),
        separatorBuilder: (_, __) => Divider(
            height: 1,
            indent: 84,
            color: AppColores.borde(context)),
        itemBuilder: (ctx, i) {
          if (desplaza == 1 && i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                '${rows.length} clientes · '
                '≈ ${fmtMonto(estimado)} CUP por cobrar '
                '(una mensualidad de cada uno)',
                style: AppTexto.secundario
                    .copyWith(fontWeight: FontWeight.w700),
              ),
            );
          }
          i -= desplaza;
          if (hayCola && i == rows.length) {
            return Padding(
              padding:
                  const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                  '${tituloCola ?? 'Sin fecha'} (${cola.length})',
                  style: AppTexto.secundario.copyWith(
                      fontWeight: FontWeight.bold)),
            );
          }
          final enCola = hayCola && i > rows.length;
          final c = enCola ? cola[i - rows.length - 1] : rows[i];
          final listaCadena = enCola ? cola : rows;
          final iCadena = enCola ? i - rows.length - 1 : i;
          final id = (c['id'] as int?) ?? 0;
          // L2 (estéticas 1.19): la fila avisada lleva acento
          // verde en el borde izquierdo.
          // D-08 (1.21): avisado sale del conjunto precargado,
          // no de un FutureBuilder por fila y reconstrucción.
          final avisado = _avisados.contains(id);
          // 1.22 Diseño Bloque 1 (T3): cascada acotada —
          // FadeEntrada solo anima los primeros 10 ítems y
          // dentro de la ventana de 400 ms del montaje.
          return FadeEntrada(
            indice: i,
            child: Container(
                decoration: avisado
                    ? const BoxDecoration(
                        border: Border(
                          left: BorderSide(
                              color: AppColores.exito, width: 4),
                        ),
                      )
                    : null,
                child: FilaCliente(
            cliente: c,
            // 1.25 T46: en las pestañas de atrasados, la
            // barra de antigüedad (los sin fecha no la
            // llevan: sin fecha no hay antigüedad).
            diasAtraso: esColaCobro && !enCola
                ? -(diasRestantes(c['pagado_hasta'] as String?) ?? 0)
                : null,
            // 1.25 T116 (F1-26): chip de texto con el día
            // del aviso, junto al borde verde de siempre.
            avisoChip: avisado && _avisadoEl[id] != null
                ? 'Avisado · ${_avisadoEl[id]!.day.toString().padLeft(2, '0')}/${_avisadoEl[id]!.month.toString().padLeft(2, '0')}'
                : null,
            origenHero: 'listas',
            onTap: () => Navigator.of(context)
                .push(RutaIron(
                    builder: (_) => FichaScreen(
                        clienteId: id, origenHero: 'listas')))
                .then((_) => _cargar()),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Botón avisar (toggle)
                    IconButton(
                      icon: Icon(
                          avisado
                              ? Icons.check_circle_rounded
                              : Icons
                                  .notifications_rounded,
                          color: avisado
                              ? AppColores.exito
                              : AppColores.textoSecundario(
                                  context)),
                      tooltip: avisado
                          ? 'Avisado (toca para quitar)'
                          : 'Marcar como avisado',
                      onPressed: () async {
                        if (avisado) {
                          await LocalDb.instance
                              .desmarcarAvisado(id);
                          if (mounted) {
                            mostrarSnack(context, 'Marca de avisado quitada para ${c['nombre']}', significado: SignificadoChip.exito);
                            setState(() => _avisados.remove(id));
                          }
                        } else {
                          await _avisarEnCadena(listaCadena, iCadena);
                        }
                      },
                    ),
                // Botón cobro rápido (naranja circular)
                // 1.25 T116 (F1-23): con Tooltip — era la
                // acción principal de la pantalla y la única
                // sin nombre (el botón de avisar sí lo tenía).
                Tooltip(
                  message: 'Cobrar',
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient:
                          AppColores.gradienteNaranja,
                      shape: BoxShape.circle,
                      boxShadow:
                          AppSombra.botonPrimario,
                    ),
                    child: InkWell(
                      customBorder:
                          const CircleBorder(),
                      onTap: () => _pagoRapido(c),
                      child: const Icon(
                          Icons.payments_rounded,
                          color: Colors.white,
                          size: 22),
                    ),
                  ),
                ),
              ],
                ),
              ),
            ),
          );
      },
      ),
    );
    // 1.25 T50: con la sesión de avisos empezada, el
    // progreso va fijo sobre la lista.
    if (avisadosLista == 0) return lista;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
          child: Row(
            children: [
              const Icon(Icons.check_circle_rounded,
                  size: 16, color: AppColores.exito),
              const SizedBox(width: 6),
              Text('$avisadosLista de $totalLista avisados',
                  style: AppTexto.secundario
                      .copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadio.sm),
            child: LinearProgressIndicator(
              value: totalLista > 0 ? avisadosLista / totalLista : 0,
              minHeight: 5,
              backgroundColor: AppColores.borde(context),
              color: AppColores.exito,
            ),
          ),
        ),
        Expanded(child: lista),
      ],
    );
  }
}


/// Diálogo del nombre de la vista (Panel 12): controlador
/// propio con dispose, como manda el estándar de la casa.
class _DialogoNombreVista extends StatefulWidget {
  const _DialogoNombreVista();

  @override
  State<_DialogoNombreVista> createState() =>
      _DialogoNombreVistaState();
}

class _DialogoNombreVistaState extends State<_DialogoNombreVista> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Guardar vista'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 30,
        decoration: const InputDecoration(
          hintText: 'Ej. Deudores del lunes',
          helperText: 'Guarda la pestaña, el orden y la búsqueda actuales',
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        TextButton(
            onPressed: () => Navigator.pop(context, _ctrl.text),
            child: const Text('Guardar')),
      ],
    );
  }
}
