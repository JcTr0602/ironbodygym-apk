/// Listas: vencen hoy, atrasados, por vencer. Con mini foto y pago rápido.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../permisos_entrenador.dart';
import '../tiempo.dart';
import '../sync.dart';
import '../cliente_protegido.dart';
import '../precio_cobro.dart';
import '../tarifa_especial.dart';
import 'acciones_acceso.dart';
import 'app_bar.dart';
import 'buscar.dart';
import 'skeleton.dart';
import 'componentes.dart';
import 'permisos_ui.dart';
import 'dialogo_pago.dart';
import 'hoja_accion.dart';
import 'preview_cobro.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

/// 1.23 (Delta Argón 4ª#6): un solo RegExp reutilizado — antes
/// se construía uno nuevo por cliente en cada búsqueda.
final _reNoDigitosListas = RegExp(r'[^0-9]');

/// Buscador de Listas (16/25, PURO): coincide por nombre (sin
/// mayúsculas) o por dígitos del teléfono.
/// 1.29 (Oleada 3, FB-01 · D-B1-02): los dígitos se contrastan
/// con el teléfono EFECTIVO (movil primero; ver
/// telefonoEfectivoLocal en negocio.dart): antes solo se miraba
/// `telefono`, así que un migrado — cuyo número real vive en
/// `movil` y cuyo `telefono` puede traer el carnet — no se
/// encontraba buscando su número, y buscar los dígitos de su
/// carnet lo «encontraba» como si fueran su teléfono.
bool coincideBusquedaListas(Map<String, dynamic> c, String texto) {
  final q = texto.trim().toLowerCase();
  if (q.isEmpty) return true;
  if ('${c['nombre'] ?? ''}'.toLowerCase().contains(q)) return true;
  var digQ = q.replaceAll(_reNoDigitosListas, '');
  // Pegado con prefijo país: se contrasta por los 8 dígitos.
  if (digQ.length == 10 && digQ.startsWith('53')) {
    digQ = digQ.substring(2);
  }
  if (digQ.isNotEmpty) {
    final tel = telefonoEfectivoLocal(c);
    if (tel != '—' && tel.contains(digQ)) return true;
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

  /// 1.32 «Mostrador Táctico»: embebida = vista del Pilar 2
  /// (Clientes) — sin su AppBar; la TabBar de vencimientos
  /// baja al cuerpo (patrón de ActividadScreen en el Centro
  /// de control).
  final bool embebida;

  /// 1.35 (corrección E3, C5-02): aviso de «los datos
  /// cambiaron» para el contenedor: se invoca tras marcar
  /// o desmarcar un avisado en local, tras cobrar y al
  /// volver de la ficha. El pilar lo usa para recontar la
  /// insignia de Vencimientos al momento — sin esto, la
  /// insignia seguía prometiendo trabajo ya hecho hasta
  /// que la sync quedara en reposo.
  final VoidCallback? alCambiarDatos;
  const ListasScreen(
      {super.key,
      this.inicial = 0,
      this.embebida = false,
      this.alCambiarDatos});
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
  // 1.35 (CAMPO-3, corrección de la reconciliación §3.3):
  // la pila propia de esta pantalla (sub-pestañas cuando
  // va embebida + buscador con su menú de orden + fila de
  // vistas) se PLIEGA al bajar por la lista y vuelve al
  // subir o al llegar arriba — el mismo patrón de la
  // cabecera de Suplementos. CAMPO-13 ya había plegado
  // las acciones del PILAR y suprimido la banda duplicada;
  // faltaba esta pila, que es la que Jc midió ocupando
  // más de la mitad de la pantalla (campo nº 3 y nº 13).
  // El botón «Avisar a los N sin avisar» de las pestañas
  // de cobro se recoge con la misma señal (ver _lista).
  bool _pilaVisible = true;

  /// El pliegue de la pila según el scroll de cualquiera
  /// de las listas: bajar la pliega; subir la despliega
  /// (y volver arriba ES subir: llega desplegada). Solo
  /// reacciona al scroll VERTICAL (el gesto horizontal
  /// entre pestañas no pliega nada). El listener vive
  /// DENTRO del RefrescoIron de cada lista (ver _lista):
  /// el RefreshIndicator se queda las notificaciones que
  /// procesa y un listener fuera nunca las vería — la
  /// misma razón que en Suplementos.
  bool _alDesplazarLista(UserScrollNotification n) {
    final eje = n.metrics.axisDirection;
    if (eje != AxisDirection.down && eje != AxisDirection.up) {
      return false;
    }
    final bool debe;
    if (n.direction == ScrollDirection.reverse) {
      debe = false;
    } else if (n.direction == ScrollDirection.forward) {
      debe = true;
    } else {
      return false;
    }
    if (debe != _pilaVisible && mounted) {
      setState(() => _pilaVisible = debe);
    }
    return false;
  }
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
  // 1.34 Campo 2 (P-5): conteos de avisados por pestaña
  // MEMOIZADOS. Antes cada _lista() del build copiaba su
  // lista ([...rows, ...?cola]) y la escaneaba O(n) contra
  // _avisados — ×5 pestañas en cada reconstrucción. Ahora
  // se calculan al recalcular los visibles y al marcar/
  // desmarcar un aviso (las dos únicas mutaciones).
  int _avisHoy = 0;
  int _avisPorVencer = 0;
  int _avisMenos30 = 0;
  int _avisMas30 = 0;
  int _avisAlDia = 0;

  int _contarAvisados(List<Map<String, dynamic>> l) => l
      .where((c) => _avisados.contains((c['id'] as num?)?.toInt() ?? 0))
      .length;

  void _refrescarConteosAvisados() {
    _avisHoy = _contarAvisados(_visHoy);
    _avisPorVencer = _contarAvisados(_visPorVencer);
    _avisMenos30 =
        _contarAvisados(_visMenos30) + _contarAvisados(_visSinFecha);
    _avisMas30 = _contarAvisados(_visMas30);
    _avisAlDia = _contarAvisados(_visAlDia);
  }
  // 1.25 T116 (F1-24): hasta que el usuario elija orden a
  // mano, cada pestaña usa SU defecto (urgencia en las de
  // trabajo, nombre en «Al día»).
  bool _ordenManual = false;
  // 1.25 Panel 12: vistas guardadas (SharedPreferences).
  List<VistaLista> _vistas = [];
  // 1.25 Panel 14: la última carga falló — los vacíos de
  // las pestañas deben decir ESO, no «nadie vence».
  bool _falloCarga = false;
  // 1.28 (M4-A2): estado «cargando» honesto — hasta que la
  // primera foto del espejo aterriza, la pantalla enseña el
  // esqueleto y NO afirma «Todo al día» con pestañas en (0).
  bool _cargando = true;
  // 1.28 (M4-A2): generación de carga — una carga vieja que
  // termina tarde no pinta su foto sobre una más nueva.
  int _cargaGen = 0;
  // 1.28 (M4-A2): precios y tarifas especiales de la foto
  // vigente, para recalcular los estimados SÍNCRONOS sobre
  // los visibles cada vez que cambia la búsqueda.
  Map<String, double> _preciosFoto = {};
  Map<int, Map<String, dynamic>> _especialesFoto = {};
  // 1.28 (M4-C6): cobros hechos EN ESTA VISITA que el
  // espejo aún no refleja (la op nace con retención de
  // Deshacer y sube después): sin esta memoria, la recarga
  // inmediata resucitaba al cliente en su pestaña y el
  // cobro no «se veía» cobrado. La fila sale animada y no
  // vuelve en esta visita; al reabrir la pantalla manda
  // el espejo (ya sincronizado).
  final Set<int> _cobradosSesion = {};
  // La fila que está saliendo ahora mismo (una sola: el
  // cobro rápido ya tiene su guarda anti-doble-toque).
  int? _saliendoCobroId;

  /// 1.28 (M4-A2/R3M4-H5): estimado SÍNCRONO de una lista
  /// con las tarifas ya resueltas EN LOTE — antes cada
  /// cliente disparaba su propia resolución de tarifa, que
  /// recargaba TODAS las tarifas por llamada (N lecturas
  /// completas para N clientes).
  double _estimadoDe(List<Map<String, dynamic>> lista) {
    var total = 0.0;
    for (final c in lista) {
      total += precioCobroConEspecial(
        cliente: c,
        periodo: 'mensual',
        metodo: 'efectivo',
        precios: _preciosFoto,
        especial: _especialesFoto[(c['id'] as num?)?.toInt()],
      ).monto;
    }
    return total;
  }

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
    // 1.28 (M4-A2/R1M4-M3): el estimado de la cabecera se
    // calcula sobre los VISIBLES de la pestaña — antes era
    // el total sin filtrar mientras la cabecera contaba
    // solo los visibles, y con búsqueda activa las dos
    // cifras no cuadraban.
    // Corrección A1-D5: la pestaña «Atrasados -30d» cuenta y
    // muestra TAMBIÉN el grupo sin fecha (contador de la
    // pestaña y cola del cuerpo), así que su estimado suma
    // ambos grupos: antes los sin-fecha no aportaban ni un
    // peso al «≈ por cobrar» de su propia pestaña.
    _estimadoMenos30 = _estimadoDe([..._visMenos30, ..._visSinFecha]);
    _estimadoMas30 = _estimadoDe(_visMas30);
    // P-5: los conteos de avisados se fijan aquí, no en
    // cada build de _lista().
    _refrescarConteosAvisados();
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
      // Autoauditoría 1.25: el tope también manda al
      // cargar (preferencias escritas por otra versión
      // o a mano no dejan el guardado bloqueado).
      if (vistas.length > kMaxVistasListas) {
        vistas.removeRange(kMaxVistasListas, vistas.length);
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
    // 1.35 (UI-12, oleada 1): confirmación de la casa.
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Quitar vista',
      mensaje: '¿Quitar la vista «${v.nombre}» (${v.alcance})?',
      aceptar: 'Quitar',
    );
    if (!ok || !mounted) return;
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
    // 1.28 (M4-A2): cada carga nace con su generación; si
    // otra carga la supera, la vieja no pinta ni marca fallo.
    final gen = ++_cargaGen;
    try {
      await _cargarInterno(gen);
      if (_falloCarga && mounted && gen == _cargaGen) {
        setState(() => _falloCarga = false);
      }
    } catch (_) {
      if (mounted && gen == _cargaGen) {
        setState(() {
          _falloCarga = true;
          _cargando = false;
        });
      }
    }
  }

  Future<void> _cargarInterno(int gen) async {
    // 1.28 (M4-A2/R1M4-A2 + R3M4-H5): UNA sola foto del
    // espejo — el padrón activo se lee una vez y se comparte
    // (activosPre) en las cinco derivaciones; antes cada
    // pestaña releía el padrón entero y, sin guarda de
    // generación, un cobro o un pull a mitad de carga dejaba
    // pintar la foto vieja sobre la nueva.
    final activos = await clientesActivos();
    final h = await vencenHoy(activosPre: activos);
    final m30crudo =
        await atrasados(masDe30: false, activosPre: activos);
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
    final p30 = await atrasados(masDe30: true, activosPre: activos);
    final pv = await porVencer(dias: 3, activosPre: activos);
    // 1.25 T03: la pestaña usa la variante SIN los de hoy
    // ni los por vencer (clientesAlDia a secas es el
    // predicado de acceso y los incluye: duplicaba).
    final ad = await clientesAlDiaPestana(activosPre: activos);
    if (!mounted || gen != _cargaGen) return;
    // Cliente protegido (2026-10-26, Protegido 2 H6): estas listas
    // muestran teléfono y botón de WhatsApp; un no-dueño no ve
    // protegidos en ninguna.
    List<Map<String, dynamic>> sinProtegidos(
        List<Map<String, dynamic>> l) =>
        l
            .where((c) =>
                !esVistaProtegida(c) &&
                // 1.28 (M4-C6): lo cobrado en esta visita no
                // resucita en la recarga aunque el espejo
                // aún no refleje el cobro.
                !_cobradosSesion
                    .contains((c['id'] as num?)?.toInt() ?? -1))
            .toList();
    // 1.25 T02: solo las marcas del vencimiento ACTUAL —
    // una marca de un vencimiento anterior no esconde al
    // cliente de la lista de por avisar.
    final avisados =
        await LocalDb.instance.avisadosVigentesConFecha();
    // 1.25 T46: estimados de las pestañas de atrasados.
    // 1.28 (M4-A2): precios una vez y tarifas resueltas EN
    // LOTE; el estimado se deriva de los visibles en
    // _recalcularVisibles (síncrono).
    final pr = await preciosVigentes();
    final especiales = await tarifasActivasPorCliente('mensual');
    if (!mounted || gen != _cargaGen) return;
    setState(() {
      _hoy = sinProtegidos(h);
      _menos30 = sinProtegidos(m30);
      _sinFecha = sinProtegidos(sinFecha);
      _mas30 = sinProtegidos(p30);
      _porVencer = sinProtegidos(pv);
      _alDia = sinProtegidos(ad);
      _preciosFoto = pr;
      _especialesFoto = especiales;
      // Yunque 3 (K5-4, latente cazado por su test):
      // avisadosVigentesConFecha devuelve const {} cuando no
      // hay avisados — asignarlo tal cual dejaba _avisadoEl
      // INMODIFICABLE y la primera marca del ciclo reventaba
      // en el setState de _avisarEnCadena (la marca de BD ya
      // había quedado persistida). Copia mutable siempre.
      _avisadoEl = Map<int, DateTime>.of(avisados);
      _avisados = avisados.keys.toSet();
      _cargando = false;
      _recalcularVisibles();
    });
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
      _cargar();
    } else if (resultadoCobro == ResultadoCobro.guardado) {
      // 1.28 (M4-C6): el cobro SE VE — la fila se marca
      // «Cobrado» y sale animada de su pestaña (la
      // cabecera descuenta con su contador animado al
      // completar la salida). Sin recarga inmediata: el
      // espejo aún no trae el cobro y la fila resucitaría.
      final id = (c['id'] as num?)?.toInt() ?? 0;
      if (id > 0) {
        setState(() => _saliendoCobroId = id);
      } else {
        _cargar();
      }
    } else {
      _cargar();
    }
    SyncEngine.instance.push();
    // E3 (C5-02): el cobro saca al cliente de los
    // atrasados: la insignia del contenedor se recuenta ya.
    widget.alCambiarDatos?.call();
  }

  /// 1.28 (M4-C6): la animación de salida terminó — el
  /// cliente sale de todas las listas en memoria y queda
  /// en la memoria de la visita (ver _cobradosSesion).
  void _completarSalidaCobro(int id) {
    if (!mounted) return;
    setState(() {
      _cobradosSesion.add(id);
      bool noEs(Map<String, dynamic> c) =>
          ((c['id'] as num?)?.toInt() ?? -1) != id;
      _hoy = _hoy.where(noEs).toList();
      _menos30 = _menos30.where(noEs).toList();
      _sinFecha = _sinFecha.where(noEs).toList();
      _mas30 = _mas30.where(noEs).toList();
      _porVencer = _porVencer.where(noEs).toList();
      _alDia = _alDia.where(noEs).toList();
      if (_saliendoCobroId == id) _saliendoCobroId = null;
      _recalcularVisibles();
    });
  }

  /// 1.28 (M4-B1): pulsación larga en una fila = el menú
  /// de acciones de acceso del helper compartido (A5),
  /// sin salir de la lista. Solo dueño (el dominio de
  /// accesos es suyo; el entrenador da el alta desde la
  /// ficha, como siempre).
  Future<void> _menuAccesoLista(Map<String, dynamic> c) async {
    final id = (c['id'] as num?)?.toInt() ?? 0;
    if (id <= 0) return;
    await abrirMenuAccesoDesdeLista(
      context,
      clienteId: id,
      alTerminar: () async {
        _cargar();
        // E3 (C5-02): el menú de acceso también muta datos.
        widget.alCambiarDatos?.call();
      },
      alAbrirFicha: () async {
        await Navigator.of(context).push(RutaIron(
            builder: (_) =>
                FichaScreen(clienteId: id, origenHero: 'listas')));
        _cargar();
        widget.alCambiarDatos?.call();
      },
      alDarAcceso: () async {
        await Navigator.of(context).push(RutaIron(
            builder: (_) => FichaScreen(
                clienteId: id,
                origenHero: 'listas',
                irAAccesoAlAbrir: true)));
        _cargar();
        widget.alCambiarDatos?.call();
      },
    );
  }

  /// 1.28 (M4-B5): «Avisar a los atrasados de esta
  /// pestaña» — arranca la pasada GUIADA sobre la lista
  /// visible: cada aviso sigue siendo toque a toque por
  /// persona (WhatsApp se abre con la plantilla aprobada
  /// y la línea automática de la casa, vía _avisarEnCadena)
  /// y cada marcado queda registrado como siempre. Empieza
  /// por el primer sin avisar de la lista principal; si
  /// allí no queda nadie, por el grupo sin fecha.
  void _avisarPestana(
      List<Map<String, dynamic>> rows,
      List<Map<String, dynamic>>? cola) {
    for (var i = 0; i < rows.length; i++) {
      final id = (rows[i]['id'] as num?)?.toInt() ?? 0;
      if (!_avisados.contains(id)) {
        _avisarEnCadena(rows, i);
        return;
      }
    }
    if (cola != null) {
      for (var i = 0; i < cola.length; i++) {
        final id = (cola[i]['id'] as num?)?.toInt() ?? 0;
        if (!_avisados.contains(id)) {
          _avisarEnCadena(cola, i);
          return;
        }
      }
    }
  }

  /// 1.32: la barra de pestañas de vencimientos, compartida
  /// entre el AppBar (pantalla suelta) y el cuerpo (embebida
  /// en el Pilar 2).
  TabBar _barraPestanas() => TabBar(
          controller: _tab,
          isScrollable: true,
          tabs: [
            // L1 (estéticas 1.19): cada pestaña lleva su color
            // semántico — ámbar para Hoy/Por vencer, rojo para
            // los dos Atrasados, verde para Al día — para ver la
            // urgencia sin leer el número.
            // 1.28 (M4-C1): las cifras de las pestañas
            // CUENTAN hasta su número al cargar (y se
            // mueven al cambiar), en vez de saltar de (0)
            // al total.
            Tab(
              child: _NumeroAnimado(
                valor: _visHoy.length.toDouble(),
                builder: (_, v) => Text('Hoy (${v.round()})',
                    style: TextStyle(
                        color: AppColores.alertaTexto(context),
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Tab(
              // 1.25 T116 (F1-22): la pestaña dice su
              // ventana — el semáforo del avatar se pone
              // ámbar a los 7 días y sin el rótulo parecía
              // que faltaban clientes de 4-7 días.
              child: _NumeroAnimado(
                valor: _visPorVencer.length.toDouble(),
                builder: (_, v) =>
                    Text('Por vencer · 3 días (${v.round()})',
                        style: TextStyle(
                            color: AppColores.alertaTexto(context),
                            fontWeight: FontWeight.w600)),
              ),
            ),
            Tab(
              child: _NumeroAnimado(
                valor: (_visMenos30.length + _visSinFecha.length)
                    .toDouble(),
                builder: (_, v) =>
                    Text('Atrasados -30d (${v.round()})',
                        style: TextStyle(
                            color: AppColores.errorTexto(context),
                            fontWeight: FontWeight.w600)),
              ),
            ),
            Tab(
              child: _NumeroAnimado(
                valor: _visMas30.length.toDouble(),
                builder: (_, v) =>
                    Text('Atrasados +30d (${v.round()})',
                        style: TextStyle(
                            color: AppColores.errorTexto(context),
                            fontWeight: FontWeight.w600)),
              ),
            ),
            Tab(
              child: _NumeroAnimado(
                valor: _visAlDia.length.toDouble(),
                builder: (_, v) => Text('Al día (${v.round()})',
                    style: TextStyle(
                        color: AppColores.exitoTexto(context),
                        fontWeight: FontWeight.w600)),
              ),
            ), // v1.2.1
          ],
        );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
            appBar: widget.embebida
          ? null
          : appBarIron(context, 'Vencimientos',
              bottom: _barraPestanas()),
      body: Column(
        children: [
          // 1.30 (Oleada D6, UI130-20): banner compacto,
          // como en Buscar, y la fila «Ordenar:» se funde
          // en la fila del buscador como menú de orden
          // (los mismos 3 órdenes y la misma semántica
          // F1-24: la elección manual manda).
          // 1.35 (campo nº 13): embebida, la banda no se
          // pinta — el estado de sync lo dice una sola vez
          // la píldora de la cabecera de la app. La banda
          // queda FUERA de la pila plegable: es de CAMPO-13,
          // no de esta pila.
          if (!widget.embebida) const SyncBanner(compact: true),
          // 1.35 (CAMPO-3): la pila propia de la pantalla
          // (sub-pestañas si va embebida + buscador con su
          // menú de orden + fila de vistas) se recoge al
          // bajar y vuelve al subir, con el AnimatedSize
          // del patrón de Suplementos. Ningún bloque se
          // elimina: todo vuelve a estar a un gesto.
          AnimatedSize(
            duration: AppMovimiento.media,
            curve: AppMovimiento.curvaSuave,
            alignment: Alignment.topCenter,
            child: _pilaVisible
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (widget.embebida) _barraPestanas(),
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
                PopupMenuButton<String>(
                  popUpAnimationStyle: estiloAparicionMenu,
                  tooltip: 'Ordenar la lista',
                  icon: const Icon(Icons.sort_rounded),
                  onSelected: (v) => setState(() {
                    // F1-24: la elección manual manda
                    // sobre el defecto por pestaña.
                    _ordenManual = true;
                    _orden = v;
                    _recalcularVisibles();
                  }),
                  itemBuilder: (ctx) => [
                    CheckedPopupMenuItem(
                        value: 'nombre',
                        checked: _orden == 'nombre',
                        child: const Text('Nombre')),
                    CheckedPopupMenuItem(
                        value: 'vencimiento',
                        checked: _orden == 'vencimiento',
                        child: const Text('Vencimiento')),
                    CheckedPopupMenuItem(
                        value: 'dias',
                        checked: _orden == 'dias',
                        child: const Text('Días restantes')),
                  ],
                ),
              ],
            ),
                      ),
                      _filaVistas(),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          Expanded(
            // 1.28 (M4-A2/R1M4-M2): mientras la primera foto
            // carga, esqueleto honesto en vez de las pestañas
            // vacías afirmando «Todo al día».
            child: _cargando
                // 1.28 (M4-C1): el esqueleto tiene la FORMA
                // de las filas reales de esta pantalla
                // (avatar, dos líneas, dos botones redondos),
                // no tarjetas genéricas.
                ? const SkeletonFilasListas(items: 6)
                : TabBarView(
              controller: _tab,
              children: [
                _lista(_visHoy, Icons.celebration_rounded,
                    'Nadie vence hoy', 'Todo al día.',
                    avisadosPre: _avisHoy,
                    ilustracionVacio: 'assets/vacio_reloj.webp'),
                // 1.25 T116 (F1-25): fuera la celebración
                // en pestañas de deuda y en «Por vencer»:
                // icono tranquilo y, en atrasados, el paso
                // siguiente (ir a «Al día»).
                _lista(_visPorVencer,
                    Icons.check_circle_rounded, 'Nadie por vencer',
                    'Nada en los próximos 3 días.',
                    avisadosPre: _avisPorVencer),
                _lista(_visMenos30,
                    Icons.check_circle_rounded, 'Sin atrasados',
                    'Nada de menos de un mes.',
                    esColaCobro: true,
                    estimado: _estimadoMenos30,
                    cola: _visSinFecha,
                    avisadosPre: _avisMenos30,
                    tituloCola: 'Sin fecha de vencimiento',
                    textoAccionVacio: 'Ver «Al día»',
                    onAccionVacio: () => _tab.animateTo(4)),
                _lista(_visMas30,
                    Icons.check_circle_rounded, 'Sin atrasados',
                    'Nada de más de un mes.',
                    esColaCobro: true,
                    estimado: _estimadoMas30,
                    avisadosPre: _avisMas30,
                    textoAccionVacio: 'Ver «Al día»',
                    onAccionVacio: () => _tab.animateTo(4)),
                _lista(_visAlDia, // v1.2.1
                    Icons.check_circle_rounded, 'Nadie al día',
                    'Todos los activos están vencidos.',
                    avisadosPre: _avisAlDia),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v1.2.4 (C7): móvil cubano del cliente para wa.me (con prefijo
  /// 53) o null. Argón P3#5: normalizarTelefonoWaMe acepta 5 y 6.
  /// 1.29 (Oleada 3, FB-01): es el teléfono EFECTIVO (movil
  /// primero) — el de `telefono` a pelo dejaba sin aviso al
  /// migrado cuyo número vive en `movil`.
  String? _movilCliente(Map<String, dynamic> c) {
    final normalizado = telefonoEfectivoWa(c);
    return normalizado.isEmpty ? null : normalizado;
  }

  Future<String?> _elegirAviso(Map<String, dynamic> c) async {
    if (_movilCliente(c) == null) return 'marcar';
    // SL-3 (G02-3, familia UI-12): la elección del aviso de
    // WhatsApp se presenta con la hoja de la casa
    // (showHojaIron), como el resto de la app — antes era un
    // showModalBottomSheet crudo con SafeArea propio. El
    // contrato no cambia: 'whatsapp' | 'marcar' | null.
    // (Las otras dos presentaciones del aviso viven en
    // buscar.dart, fuera del mapa de este carril.)
    return showHojaIron<String>(
      context,
      titulo: 'Avisar a ${c['nombre'] ?? 'este cliente'}',
      icono: Icons.chat_rounded,
      cuerpo: Builder(
        builder: (ctx) => Column(
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

  /// Yunque 3 (K5-4): espejo del patrón de Cumpleaños
  /// (1.26, MEDIA 4): abrir WhatsApp NO prueba que el mensaje
  /// se envió (launchUrl solo confirma que la app abrió con
  /// el texto listo). La marca «avisado» — que aquí dura todo
  /// el ciclo del vencimiento — solo se pone si el usuario
  /// confirma el envío al volver. Sin confirmación, el
  /// cliente sigue sin avisar y la pasada guiada lo vuelve a
  /// ofrecer. La vía «Solo marcar como avisado» de
  /// _elegirAviso sigue marcando directo: es el gesto expreso.
  Future<bool> _confirmarEnvioWhatsApp(String nombre) async {
    if (!mounted) return false;
    final r = await showDialog<bool>(
      context: context,
      // 1.35 (UI-12, oleada 1): con el diálogo de la casa;
      // los botones conservan su peso (el «Sí, enviado»
      // sigue siendo el principal).
      builder: (ctx) => DialogoApp(
        titulo: '¿Se envió el aviso?',
        contenido: Text('WhatsApp se abrió con el mensaje listo '
            'para $nombre. Solo se marca «Avisado» si '
            'confirmas que lo enviaste.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No lo envié')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sí, enviado')),
        ],
      ),
    );
    return r == true;
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
      // K5-4: sin confirmación de envío no hay marca ni
      // cadena: el cliente no sale de la pasada de avisos.
      final nombre = '${c['nombre'] ?? ''}'.split(' ').first;
      if (!await _confirmarEnvioWhatsApp(nombre)) return;
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
      _refrescarConteosAvisados();
    });
    // E3 (C5-02): la marca es local y la sync no tiene por
    // qué enterarse: el contenedor recuenta su insignia ya.
    widget.alCambiarDatos?.call();
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
      // 1.30 (Oleada D6, UI130-22): ilustración del
      // vacío de ESTA pestaña (solo «Hoy» la trae).
      String? ilustracionVacio,
      double estimado = 0,
      List<Map<String, dynamic>>? cola,
      // 1.34 Campo 2 (P-5): conteo de avisados memoizado
      // por la pantalla (ver _refrescarConteosAvisados);
      // sin él se cae al escaneo de siempre.
      int? avisadosPre,
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
          ilustracion: ilustracionVacio,
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
    // P-5: el conteo llega memoizado; el escaneo queda
    // solo como respaldo si un llamador no lo pasa.
    final avisadosLista = avisadosPre ??
        [...rows, ...?cola]
            .where((c) => _avisados.contains((c['id'] as int?) ?? 0))
            .length;
    // 1.34 Campo 2 (P-7): el gesto sigue la regla de Jc
    // vía refrescoGeneralIron — fresco (≤10 min) solo
    // relee lo local; viejo corre un ciclo completo
    // antes de releer. Sin avisos, como siempre aquí.
    final lista = RefrescoIron(
      onRefresh: () => refrescoGeneralIron(releer: _cargar),
      // 1.35 (CAMPO-3): el oído del pliegue de la pila,
      // DENTRO del RefrescoIron (el RefreshIndicator se
      // queda las notificaciones que procesa; fuera no
      // llegarían) — el patrón de Suplementos.
      child: NotificationListener<UserScrollNotification>(
        onNotification: _alDesplazarLista,
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
              // 1.28 (M4-C6): al cobrar, la cabecera
              // DESCUENTA la cantidad con una cuenta
              // animada hasta el nuevo estimado.
              child: _NumeroAnimado(
                valor: estimado,
                builder: (_, v) => Text(
                  '${rows.length} clientes · '
                  '≈ ${fmtMonto(v)} CUP por cobrar '
                  '(una mensualidad de cada uno)',
                  style: AppTexto.secundario
                      .copyWith(fontWeight: FontWeight.w700),
                ),
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
          // 1.34 Campo 2 (P-8): cada fila es su propia capa
          // de raster — al desplazar, el compositor traslada
          // la fila sin repintarla (su botón de cobro lleva
          // la sombra blur 12 de la casa; repintarla por
          // frame era parte de los tirones de la lista). La
          // sombra NO se abarata: es el valor de diseño del
          // botón primario (D-18) y no se degrada por lista.
          final filaPintada = RepaintBoundary(
            child: FadeEntrada(
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
                .then((_) {
                  _cargar();
                  // E3 (C5-02): de la ficha se puede venir
                  // de cobrar o de avisar: el contenedor
                  // recuenta su insignia al volver.
                  widget.alCambiarDatos?.call();
                }),
            // 1.28 (M4-B1): pulsación larga = menú de
            // acciones de acceso del helper compartido
            // (solo dueño: el dominio de accesos es suyo).
            onLongPress: AuthService().isOwner
                ? () => _menuAccesoLista(c)
                : null,
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
                            setState(() {
                              _avisados.remove(id);
                              _refrescarConteosAvisados();
                            });
                            // E3 (C5-02): desmarcar también
                            // cambia la cifra de la insignia.
                            widget.alCambiarDatos?.call();
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
                      // 1.29 D-18: valor exacto de la sombra del
                      // botón primario de la clase deprecada,
                      // escrito en el sitio.
                      boxShadow: [
                        BoxShadow(
                          color: AppColores.naranja
                              .withValues(alpha: 0.35),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: InkWell(
                      customBorder:
                          const CircleBorder(),
                      onTap: () => _pagoRapido(c),
                      child: const Icon(
                          Icons.payments_rounded,
                          // Norma 2 (Argón): sobre la marca
                          // manda sobreMarca (6,32:1); el
                          // blanco daba 2,75:1.
                          color: AppColores.sobreMarca,
                          size: 22),
                    ),
                  ),
                ),
              ],
                ),
              ),
            ),
            ),
          );
          // 1.28 (M4-C6): si esta fila es la del cobro que
          // acaba de guardarse, se sella «Cobrado» y sale
          // animada de la pestaña.
          if (id == _saliendoCobroId) {
            return _FilaSalidaCobro(
              key: ValueKey('saliendo_$id'),
              alCompletar: () => _completarSalidaCobro(id),
              child: filaPintada,
            );
          }
          return filaPintada;
        },
        ),
      ),
    );
    // 1.25 T50: con la sesión de avisos empezada, el
    // progreso va fijo sobre la lista.
    Widget cuerpo = lista;
    if (avisadosLista > 0) {
      cuerpo = Column(
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
    // 1.28 (M4-B5): en las pestañas de cobro, la pasada
    // guiada de avisos se ofrece arriba mientras quede
    // alguien sin avisar EN LO VISIBLE: un toque arranca
    // la cadena (que sigue siendo toque a toque).
    final sinAvisar = totalLista - avisadosLista;
    if (esColaCobro && sinAvisar > 0) {
      cuerpo = Column(
        children: [
          // 1.35 (CAMPO-3): el botón se recoge con la pila
          // (misma señal _pilaVisible): al bajar por la
          // lista de cobro cede también su alto, y vuelve
          // al subir — no se elimina, queda a un gesto.
          AnimatedSize(
            duration: AppMovimiento.media,
            curve: AppMovimiento.curvaSuave,
            alignment: Alignment.topCenter,
            child: _pilaVisible
                ? Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonalIcon(
                        icon: const Icon(
                            Icons.notifications_rounded,
                            size: 18),
                        label: Text(sinAvisar == 1
                            ? 'Avisar al que falta de esta pestaña'
                            : 'Avisar a los $sinAvisar sin avisar de '
                                'esta pestaña'),
                        onPressed: () => _avisarPestana(rows, cola),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Expanded(child: cuerpo),
        ],
      );
    }
    return cuerpo;
  }
}

/// 1.28 (M4-C1/C6): número que CUENTA hasta su valor al
/// aparecer y se mueve con cuenta animada cuando el valor
/// cambia (las pestañas de Listas y la cabecera «≈ por
/// cobrar»). Con «reducir movimiento» activo, el valor se
/// pinta directo. El constructor recibe el valor actual
/// del frame ya animado.
class _NumeroAnimado extends StatefulWidget {
  final double valor;
  final Widget Function(BuildContext, double) builder;
  const _NumeroAnimado({required this.valor, required this.builder});

  @override
  State<_NumeroAnimado> createState() => _NumeroAnimadoState();
}

class _NumeroAnimadoState extends State<_NumeroAnimado>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: AppMovimiento.larga);
    _anim = Tween<double>(begin: 0, end: widget.valor)
        .animate(CurvedAnimation(
            parent: _ctrl, curve: AppMovimiento.curvaSuave));
    _ctrl.forward();
  }

  @override
  void didUpdateWidget(_NumeroAnimado oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valor != widget.valor) {
      _anim = Tween<double>(begin: _anim.value, end: widget.valor)
          .animate(CurvedAnimation(
              parent: _ctrl, curve: AppMovimiento.curvaSuave));
      _ctrl
        ..reset()
        ..forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) {
      return widget.builder(context, widget.valor);
    }
    return AnimatedBuilder(
      animation: _anim,
      builder: (ctx, _) => widget.builder(ctx, _anim.value),
    );
  }
}

/// 1.28 (M4-C6): la fila del cobro recién guardado — se
/// sella «✓ Cobrado» sobre la fila (sin botones: la fila
/// ya no acepta toques) y luego se pliega hasta salir de
/// la pestaña; al completar avisa para que la pantalla la
/// retire de sus listas. Con «reducir movimiento», la
/// salida es inmediata tras el sello.
class _FilaSalidaCobro extends StatefulWidget {
  final Widget child;
  final VoidCallback alCompletar;
  const _FilaSalidaCobro(
      {super.key, required this.child, required this.alCompletar});

  @override
  State<_FilaSalidaCobro> createState() => _FilaSalidaCobroState();
}

class _FilaSalidaCobroState extends State<_FilaSalidaCobro>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _tamano;
  bool _sello = false;
  bool _avisado = false;
  // Higiene (Argón): el retardo de 520 ms es un Timer con
  // dueño, cancelable en dispose — no un Future.delayed
  // huérfano.
  Timer? _temporizadorSalida;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        // 1.35 (UI-13): duración por el token.
        vsync: this, duration: AppMovimiento.larga);
    _tamano = Tween<double>(begin: 1, end: 0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _sello = true);
      _temporizadorSalida =
          Timer(const Duration(milliseconds: 520), () {
        if (!mounted) return;
        if (MediaQuery.of(context).disableAnimations) {
          _completar();
        } else {
          _ctrl.forward().whenComplete(_completar);
        }
      });
    });
  }

  void _completar() {
    if (_avisado) return;
    _avisado = true;
    widget.alCompletar();
  }

  @override
  void dispose() {
    _temporizadorSalida?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _tamano,
      alignment: Alignment.topCenter,
      child: Stack(
        children: [
          IgnorePointer(child: widget.child),
          if (_sello)
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: _sello ? 1 : 0,
                duration: AppMovimiento.media,
                child: Container(
                  color: AppColores.exito.withValues(alpha: 0.14),
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_circle_rounded,
                          color: AppColores.exito, size: 22),
                      const SizedBox(width: 6),
                      Text('Cobrado',
                          style: AppTexto.subtitulo.copyWith(
                              color: AppColores.exitoOscuro,
                              fontWeight: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
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

  // 1.26 (auditoría de botones, BAJA): error dentro del
  // diálogo — antes «Guardar» con el nombre vacío cerraba
  // sin guardar y sin avisar (parecía que había guardado).
  String? _error;

  void _guardar() {
    if (_ctrl.text.trim().isEmpty) {
      setState(() => _error = 'Ponle un nombre a la vista');
      return;
    }
    Navigator.pop(context, _ctrl.text);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 1.35 (UI-12, oleada 1): con el diálogo de la casa.
    return DialogoApp(
      titulo: 'Guardar vista',
      contenido: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: 30,
        decoration: InputDecoration(
          hintText: 'Ej. Deudores del lunes',
          helperText: 'Guarda la pestaña, el orden y la búsqueda actuales',
          errorText: _error,
        ),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _guardar(),
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        TextButton(
            onPressed: _guardar,
            child: const Text('Guardar')),
      ],
    );
  }
}
