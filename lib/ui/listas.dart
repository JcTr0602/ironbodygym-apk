/// Listas: vencen hoy, atrasados, por vencer. Con mini foto y pago rápido.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../congelaciones_gestion.dart';
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
import 'primitivas.dart';
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
/// 1.36 (136-252): memoria local de cobrados de Listas
/// que sobrevive a la visita (ver _cobradosPersistidos).
const kCobradosListasKey = 'listas_cobrados_v1';

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
  // 1.36 (136-246): el orden manual es POR PESTAÑA — antes
  // un solo booleano lo apagaba todo para siempre y el
  // defecto de cada pestaña moría en silencio para toda la
  // sesión. Aquí vive el orden elegido a mano en cada
  // pestaña; el menú de orden ofrece además «Defecto de la
  // pestaña», que lo restaura.
  final Map<int, String> _ordenManualPorPestana = {};

  String _defectoOrden(int pestana) => pestana == 4 ? 'nombre' : 'dias';
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
  // 1.36 (136-252): la memoria de cobrados SOBREVIVE a la
  // visita — se persiste en este teléfono (SharedPreferences,
  // clave de abajo) como {id: {antes, nuevo}}: al recargar,
  // un cobrado cuyo espejo aún trae el pagado_hasta ANTERIOR
  // sigue fuera de las pestañas de atraso y colocado según
  // su NUEVO vencimiento; en cuanto el espejo refleja el
  // cobro (pagado_hasta distinto del anterior), la entrada
  // se poda sola. Es local y segura: no crea sincronización
  // y caduca con el propio dato. LÍMITE DECLARADO (136-252):
  // la marca «avisado» y esta memoria viven SOLO en este
  // teléfono — no viajan al resto del equipo; quien avise o
  // cobre desde otro aparato no deja rastro aquí.
  final Map<int, ({String? antes, String? nuevo})> _cobradosPersistidos = {};
  // El nuevo pagado_hasta del cobro en curso (del payload
  // del diálogo, la misma cifra del Preview), para colocar
  // al cliente en su pestaña al completar la salida.
  final Map<int, String?> _nuevoHastaCobro = {};
  // La fila que está saliendo ahora mismo (una sola: el
  // cobro rápido ya tiene su guarda anti-doble-toque).
  int? _saliendoCobroId;
  // 1.36 (136-241): clientes en pausa en curso, para pasar
  // `enPausa` a la fila (su chip y su anillo dicen pausa).
  // En el teléfono del entrenador el conjunto viene vacío
  // por diseño (espejo de congelaciones solo-dueño): la
  // señal queda cableada y pinta donde el dato existe.
  Set<int> _pausados = {};

  /// 1.28 (M4-A2/R3M4-H5): estimado SÍNCRONO de una lista
  /// con las tarifas ya resueltas EN LOTE — antes cada
  /// cliente disparaba su propia resolución de tarifa, que
  /// recargaba TODAS las tarifas por llamada (N lecturas
  /// completas para N clientes).
  double _estimadoDe(List<Map<String, dynamic>> lista) {
    var total = 0.0;
    for (final c in lista) {
      final especial =
          _especialesFoto[(c['id'] as num?)?.toInt()];
      // 1.36 (136-236): si el cliente tiene tarifa especial,
      // el estimado usa SU método (una especial de solo
      // transferencia ya no se ignora cayendo a efectivo).
      // Sin especial no hay período/método del cliente que
      // leer: rige la convención declarada en la cabecera
      // («una mensualidad en efectivo de cada uno»).
      final metodoEsp = '${especial?['metodo'] ?? ''}';
      total += precioCobroConEspecial(
        cliente: c,
        periodo: 'mensual',
        metodo: (metodoEsp == 'transferencia' || metodoEsp == 'efectivo')
            ? metodoEsp
            : 'efectivo',
        precios: _preciosFoto,
        especial: especial,
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
    _orden = _defectoOrden(widget.inicial);
    _tab.addListener(() {
      if (!mounted) return;
      // 1.36 (136-259): cambiar de sub-pestaña da la misma
      // respuesta háptica que cambiar de segmento en el
      // pilar que contiene a esta pantalla.
      if (_tab.indexIsChanging) Tacto.seleccion();
      // 1.36 (136-246): al llegar a una pestaña manda SU
      // orden: el manual si lo tiene, su defecto si no.
      final nuevo =
          _ordenManualPorPestana[_tab.index] ?? _defectoOrden(_tab.index);
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

  /// Aplica una vista guardada: pestaña, orden (manual
  /// DE ESA PESTAÑA: manda sobre su defecto, 136-246) y
  /// búsqueda.
  void _aplicarVista(VistaLista v) {
    setState(() {
      _ordenManualPorPestana[v.pestana] = v.orden;
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
    // 1.36 (136-255): duplicado exacto de alcance — la
    // misma pestaña+orden+búsqueda ya guardada no se
    // guarda dos veces (coincideCon existía y no se usaba
    // al guardar).
    if (_vistas.any((v) => v.coincideCon(
        pestana: _tab.index, orden: _orden, busqueda: _busqueda))) {
      mostrarSnack(context, 'Esa vista ya está guardada',
          significado: SignificadoChip.alerta);
      return;
    }
    final nombre = await showDialog<String>(
      context: context,
      builder: (_) => const _DialogoNombreVista(),
    );
    if (nombre == null || nombre.trim().isEmpty || !mounted) return;
    // 1.36 (136-255): tampoco dos vistas con el mismo
    // nombre — los chips se leerían idénticos.
    if (_vistas.any(
        (v) => v.nombre.toLowerCase() == nombre.trim().toLowerCase())) {
      mostrarSnack(context, 'Ya hay una vista con ese nombre',
          significado: SignificadoChip.alerta);
      return;
    }
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
  /// 1.36 (136-257): sin vistas guardadas la fila NO ocupa
  /// sitio permanente — queda solo el acceso plegado (un
  /// botón de texto «Guardar vista»); la fila de chips
  /// nace con la primera vista.
  /// 1.36 (136-242): la fila scrollea con la pista de la
  /// casa (ScrollHorizontalConPista), no con un scroll
  /// crudo. 1.36 (136-256): los chips tocan a 48 dp
  /// (materialTapTargetSize padded, el patrón UI-24).
  /// 1.36 (136-255): a cupo lleno, «Guardar vista» queda
  /// deshabilitado en vez de responder solo con un snack.
  Widget _filaVistas() {
    if (_vistas.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 16, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            icon: const Icon(Icons.bookmark_add_rounded, size: 18),
            label: const Text('Guardar vista'),
            onPressed: _guardarVistaActual,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ScrollHorizontalConPista(
        colorFondo: Theme.of(context).scaffoldBackgroundColor,
        child: Row(
          children: [
            for (final v in _vistas) ...[
              // 1.36 H-B2 (136-586): el nombre largo se corta
              // con ellipsis y el alcance completo vive en el
              // tooltip (antes el chip crecía sin límite).
              InputChip(
                materialTapTargetSize: MaterialTapTargetSize.padded,
                label: Tooltip(
                  message: '${v.nombre} · ${v.alcance}',
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text('${v.nombre} · ${v.alcance}',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
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
              materialTapTargetSize: MaterialTapTargetSize.padded,
              avatar: const Icon(Icons.bookmark_add_rounded, size: 18),
              label: const Text('Guardar vista'),
              onPressed: _vistas.length >= kMaxVistasListas
                  ? null
                  : _guardarVistaActual,
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
    // 1.36 (136-241): el conjunto de pausados en curso,
    // para la señal `enPausa` de la fila.
    final pausados = await CongelacionesService.instance
        .idsCongeladosEnCurso(ahoraHabana());
    // 1.36 (136-252): cobrados persistidos de visitas
    // anteriores — siguen colocados según su nuevo
    // vencimiento mientras el espejo traiga el ANTERIOR;
    // cuando el espejo ya refleja el cobro, se podan.
    await _cargarCobradosPersistidos();
    final colocados = <String, List<Map<String, dynamic>>>{
      'hoy': [],
      'pv': [],
      'ad': [],
    };
    var podados = false;
    for (final e in _cobradosPersistidos.entries.toList()) {
      Map<String, dynamic>? fila;
      for (final c in activos) {
        if ((c['id'] as num?)?.toInt() == e.key) {
          fila = c;
          break;
        }
      }
      if (fila == null ||
          (fila['pagado_hasta'] as String?) != e.value.antes) {
        _cobradosPersistidos.remove(e.key);
        podados = true;
        continue;
      }
      _cobradosSesion.add(e.key);
      if (esVistaProtegida(fila)) continue;
      final copia = Map<String, dynamic>.of(fila)
        ..['pagado_hasta'] = e.value.nuevo;
      final d = diasRestantes(e.value.nuevo);
      if (d == 0) {
        colocados['hoy']!.add(copia);
      } else if (d != null && d > 0 && d <= 3) {
        colocados['pv']!.add(copia);
      } else {
        colocados['ad']!.add(copia);
      }
    }
    if (podados) await _persistirCobrados();
    if (!mounted || gen != _cargaGen) return;
    setState(() {
      _pausados = pausados;
      _hoy = [...sinProtegidos(h), ...colocados['hoy']!];
      _menos30 = sinProtegidos(m30);
      _sinFecha = sinProtegidos(sinFecha);
      _mas30 = sinProtegidos(p30);
      _porVencer = [...sinProtegidos(pv), ...colocados['pv']!];
      _alDia = [...sinProtegidos(ad), ...colocados['ad']!];
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

  /// 1.36 (136-252): lee la memoria local de cobrados
  /// persistida (ver kCobradosListasKey). Un fallo de
  /// lectura deja la memoria vacía: Listas funciona como
  /// siempre, solo sin la persistencia entre visitas.
  Future<void> _cargarCobradosPersistidos() async {
    _cobradosPersistidos.clear();
    try {
      final prefs = await SharedPreferences.getInstance();
      final crudo = prefs.getString(kCobradosListasKey);
      if (crudo == null || crudo.isEmpty) return;
      final mapa = Map<String, dynamic>.from(jsonDecode(crudo) as Map);
      for (final e in mapa.entries) {
        final id = int.tryParse(e.key);
        final v = e.value;
        if (id == null || v is! Map) continue;
        _cobradosPersistidos[id] = (
          antes: v['antes'] as String?,
          nuevo: v['nuevo'] as String?,
        );
      }
    } catch (_) {}
  }

  Future<void> _persistirCobrados() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          kCobradosListasKey,
          jsonEncode({
            for (final e in _cobradosPersistidos.entries)
              '${e.key}': {'antes': e.value.antes, 'nuevo': e.value.nuevo},
          }));
    } catch (_) {}
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
      // 1.36 (136-253/252): se guarda el nuevo vencimiento
      // del payload (la cifra del Preview) y el anterior,
      // para colocar al cliente en la pestaña de su nuevo
      // estado al completar la salida y persistir la
      // memoria del cobro entre visitas.
      final id = (c['id'] as num?)?.toInt() ?? 0;
      if (id > 0) {
        _nuevoHastaCobro[id] = payload['pagado_hasta'] as String?;
        _cobradosPersistidos[id] = (
          antes: c['pagado_hasta'] as String?,
          nuevo: payload['pagado_hasta'] as String?,
        );
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
  /// 1.36 (136-253): no desaparece de la pantalla — entra
  /// en la pestaña de su NUEVO vencimiento (hoy si vence
  /// hoy, «Por vencer» si cae en la ventana de 3 días y
  /// «Al día» en lo demás), con la fila actualizada al
  /// nuevo pagado_hasta del cobro. Cobrar desde la propia
  /// «Al día» ya no lo borra hasta la próxima recarga.
  /// 1.36 (136-252): la memoria se persiste (ver
  /// _cobradosPersistidos) para sobrevivir a la visita.
  void _completarSalidaCobro(int id) {
    if (!mounted) return;
    Map<String, dynamic>? filaPrevia;
    for (final l in [_hoy, _menos30, _sinFecha, _mas30, _porVencer, _alDia]) {
      for (final c in l) {
        if (((c['id'] as num?)?.toInt() ?? -1) == id) filaPrevia = c;
      }
    }
    final previo = filaPrevia;
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
      if (previo != null) {
        final copia = Map<String, dynamic>.of(previo)
          ..['pagado_hasta'] = _nuevoHastaCobro[id];
        final d = diasRestantes(_nuevoHastaCobro[id]);
        if (d == 0) {
          _hoy = [..._hoy, copia];
        } else if (d != null && d > 0 && d <= 3) {
          _porVencer = [..._porVencer, copia];
        } else {
          _alDia = [..._alDia, copia];
        }
      }
      if (_saliendoCobroId == id) _saliendoCobroId = null;
      _recalcularVisibles();
    });
    _persistirCobrados();
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

  /// 1.36 (136-240): el estado de UNA pasada guiada de
  /// avisos sobre una pestaña entera — la cadena corre
  /// sobre la lista unificada (con fecha + grupo sin
  /// fecha) y al terminar (o al cortarse) deja resumen:
  /// avisados, sin teléfono (nombrados) y pendientes.
  /// 1.36 (136-239): el sin-teléfono se SALTA y se reporta
  /// aquí; nunca se marca «avisado» sin avisar a nadie.
  int _pasadaAvisados = 0;
  int _pasadaTotal = 0;
  final List<String> _pasadaSinTelefono = [];

  /// Índice del próximo sin avisar CON teléfono desde
  /// [desde] en la cadena unificada; los sin-teléfono del
  /// camino se registran en la pasada (136-239) y se
  /// saltan. -1 si no queda nadie avisables.
  int _siguienteAvisable(List<Map<String, dynamic>> cadena, int desde) {
    for (var j = desde; j < cadena.length; j++) {
      final c = cadena[j];
      final id = (c['id'] as num?)?.toInt() ?? 0;
      if (_avisados.contains(id)) continue;
      if (_movilCliente(c) == null) {
        final nombre = '${c['nombre'] ?? 'Cliente'}';
        if (!_pasadaSinTelefono.contains(nombre)) {
          _pasadaSinTelefono.add(nombre);
        }
        continue;
      }
      return j;
    }
    return -1;
  }

  void _resumenPasada({bool cortada = false}) {
    final pendientes =
        _pasadaTotal - _pasadaAvisados - _pasadaSinTelefono.length;
    final partes = <String>[
      '$_pasadaAvisados avisado${_pasadaAvisados == 1 ? '' : 's'}',
      if (_pasadaSinTelefono.isNotEmpty)
        '${_pasadaSinTelefono.length} sin teléfono '
            '(${_pasadaSinTelefono.join(', ')})',
      if (pendientes > 0) '$pendientes sin avisar',
    ];
    mostrarSnack(
      context,
      '${cortada ? 'Pasada cortada' : 'Pasada terminada'}: '
      '${partes.join(' · ')}',
      significado: SignificadoChip.exito,
      duracion: const Duration(seconds: 8),
    );
  }

  /// 1.28 (M4-B5): «Avisar a los atrasados de esta
  /// pestaña» — arranca la pasada GUIADA sobre la lista
  /// visible: cada aviso sigue siendo toque a toque por
  /// persona (WhatsApp se abre con la plantilla aprobada
  /// y la línea automática de la casa, vía _avisarEnCadena)
  /// y cada marcado queda registrado como siempre.
  /// 1.36 (136-240): la cadena es ÚNICA sobre la pestaña
  /// entera (la lista principal y el grupo sin fecha son
  /// una sola cola) y deja resumen final (ver _resumenPasada).
  void _avisarPestana(
      List<Map<String, dynamic>> rows,
      List<Map<String, dynamic>>? cola) {
    final cadena = [...rows, ...?cola];
    _pasadaAvisados = 0;
    _pasadaSinTelefono.clear();
    _pasadaTotal =
        cadena.where((c) => !_avisados.contains((c['id'] as num?)?.toInt() ?? 0)).length;
    final i = _siguienteAvisable(cadena, 0);
    if (i < 0) {
      _resumenPasada();
      return;
    }
    _avisarEnCadena(cadena, i, enPasada: true);
  }

  /// 1.36 (136-259): el fundido de la casa entre el vacío
  /// y la lista de una pestaña al buscar (el corte seco
  /// esqueleto→contenido va en el CruceEstados del cuerpo).
  Widget _conCruce(Widget w, bool vacio) =>
      CruceEstados(estado: vacio ? 'vacio' : 'contenido', child: w);

  /// 1.32: la barra de pestañas de vencimientos, compartida
  /// entre el AppBar (pantalla suelta) y el cuerpo (embebida
  /// en el Pilar 2).
  // 1.36 (136-250): el rótulo de una pestaña SIN la cifra
  // en cero — la pestaña existe (es navegación); la cifra
  // sobra cuando vale 0 (regla del cero de Jc, la misma
  // que la insignia del pilar cumple con su `> 0`).
  String _rotuloPestana(String nombre, int n) =>
      n > 0 ? '$nombre ($n)' : nombre;

  TabBar _barraPestanas() => TabBar(
          controller: _tab,
          // 1.36 (136-307/317): las pestañas no heredan la
          // ranura del framework: etiqueta fijada a la
          // escala de la casa.
          labelStyle: AppTexto.subtitulo,
          unselectedLabelStyle: AppTexto.secundario,
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
                builder: (_, v) => Text(
                    _rotuloPestana('Hoy', v.round()),
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
                builder: (_, v) => Text(
                    _rotuloPestana('Por vencer · 3 días', v.round()),
                    style: TextStyle(
                        color: AppColores.alertaTexto(context),
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Tab(
              child: _NumeroAnimado(
                valor: (_visMenos30.length + _visSinFecha.length)
                    .toDouble(),
                builder: (_, v) => Text(
                    _rotuloPestana('Atrasados -30d', v.round()),
                    style: TextStyle(
                        color: AppColores.errorTexto(context),
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Tab(
              child: _NumeroAnimado(
                valor: _visMas30.length.toDouble(),
                builder: (_, v) => Text(
                    _rotuloPestana('Atrasados +30d', v.round()),
                    style: TextStyle(
                        color: AppColores.errorTexto(context),
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Tab(
              child: _NumeroAnimado(
                valor: _visAlDia.length.toDouble(),
                builder: (_, v) => Text(
                    _rotuloPestana('Al día', v.round()),
                    style: TextStyle(
                        color: AppColores.exitoTexto(context),
                        fontWeight: FontWeight.w600)),
              ),
            ), // v1.2.1
          ],
        );

  /// 1.36 (136-242): la barra de sub-pestañas con la pista
  /// de desborde de la casa — al abrir con una pestaña
  /// distinta de la primera, la seleccionada nacía cortada
  /// sin señal de que hubiera más a los lados.
  Widget _barraPestanasConPista() => SizedBox(
        height: 48,
        child: ScrollHorizontalConPista(
          colorFondo: Theme.of(context).scaffoldBackgroundColor,
          child: _barraPestanas(),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
            appBar: widget.embebida
          ? null
          : appBarIron(context, 'Vencimientos',
              bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(48),
                  child: _barraPestanasConPista())),
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
                      if (widget.embebida) _barraPestanasConPista(),
                      // 16/25: buscador (nombre o teléfono, en las 5 pestañas).
                      Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: CampoTexto(
                    controller: _busquedaCtrl,
                    // 1.36 (136-261): el hint dice el
                    // alcance real del buscador — también
                    // encuentra por teléfono (dígitos del
                    // teléfono efectivo, prefijo 53
                    // normalizado), no solo por nombre.
                    hint: 'Buscar cliente o teléfono…',
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
                    // 1.36 (136-246): manda SOLO en esta
                    // pestaña, y «defecto» la restaura.
                    if (v == 'defecto') {
                      _ordenManualPorPestana.remove(_tab.index);
                      _orden = _defectoOrden(_tab.index);
                    } else {
                      _ordenManualPorPestana[_tab.index] = v;
                      _orden = v;
                    }
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
                    // 1.36 (136-246): el gesto de
                    // restauración del orden por defecto
                    // de la pestaña, visible en el menú.
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                        value: 'defecto',
                        child: Text('Defecto de la pestaña')),
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
            // 1.36 (136-259): el paso esqueleto→contenido va
            // con el fundido de la casa (CruceEstados), no
            // con corte seco.
            child: CruceEstados(
              estado: _cargando ? 'cargando' : 'contenido',
              child: _cargando
                // 1.28 (M4-C1): el esqueleto tiene la FORMA
                // de las filas reales de esta pantalla
                // (avatar, dos líneas, dos botones redondos),
                // no tarjetas genéricas.
                ? const SkeletonFilasListas(items: 6)
                : TabBarView(
              controller: _tab,
              children: [
                // 1.36 (136-249): el vacío de «Hoy» se
                // acota a su pestaña — «Todo al día.» era
                // una afirmación global falsa con decenas
                // de atrasados detrás.
                _conCruce(
                    _lista(_visHoy, Icons.celebration_rounded,
                        'Nadie vence hoy', 'Ningún cliente vence hoy.',
                        avisadosPre: _avisHoy,
                        ilustracionVacio: 'assets/vacio_reloj.webp'),
                    _visHoy.isEmpty),
                // 1.25 T116 (F1-25): fuera la celebración
                // en pestañas de deuda y en «Por vencer»:
                // icono tranquilo y, en atrasados, el paso
                // siguiente (ir a «Al día»).
                _conCruce(
                    _lista(_visPorVencer,
                        Icons.check_circle_rounded, 'Nadie por vencer',
                        'Nada en los próximos 3 días.',
                        avisadosPre: _avisPorVencer),
                    _visPorVencer.isEmpty),
                _conCruce(
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
                    _visMenos30.isEmpty && _visSinFecha.isEmpty),
                _conCruce(
                    _lista(_visMas30,
                        Icons.check_circle_rounded, 'Sin atrasados',
                        'Nada de más de un mes.',
                        esColaCobro: true,
                        estimado: _estimadoMas30,
                        avisadosPre: _avisMas30,
                        textoAccionVacio: 'Ver «Al día»',
                        onAccionVacio: () => _tab.animateTo(4)),
                    _visMas30.isEmpty),
                _conCruce(
                    _lista(_visAlDia, // v1.2.1
                        Icons.check_circle_rounded, 'Nadie al día',
                        'Todos los activos están vencidos.',
                        avisadosPre: _avisAlDia),
                    _visAlDia.isEmpty),
              ],
            ),
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
    // 1.36 (136-239): sin teléfono NO se devuelve 'marcar'
    // — marcar sin avisar a nadie dejaba al cliente verde
    // «avisado» sin contacto alguno. La vía es 'sinTelefono':
    // quien llama lo salta, lo dice y lo reporta aparte.
    if (_movilCliente(c) == null) return 'sinTelefono';
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
    // 1.36 (136-251): la plantilla es la ÚNICA de la casa
    // (mensajeWaSegunEstado de negocio.dart, la misma de
    // Bandeja y Buscar) — Listas ya no compone la suya, y
    // el sin-fecha recibe su texto propio de «nunca pagó»
    // en vez del falso «está por vencer».
    final msg = mensajeWaSegunEstado(c);
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
      List<Map<String, dynamic>> rows, int idx,
      {bool enPasada = false}) async {
    final c = rows[idx];
    final id = (c['id'] as num?)?.toInt() ?? 0;
    // v1.2.4 (C7): avisar por WhatsApp con el mensaje ya
    // escrito si tiene teléfono.
    final via = await _elegirAviso(c);
    if (!mounted) return;
    // 1.36 (136-239): sin teléfono no se marca nada — se
    // dice en el acto y, en pasada, se reporta en el
    // resumen y la cadena sigue con el siguiente avisable.
    if (via == 'sinTelefono') {
      mostrarSnack(context,
          '${c['nombre']} no tiene teléfono: no se marcó como avisado',
          significado: SignificadoChip.alerta);
      if (enPasada) {
        final nombre = '${c['nombre'] ?? 'Cliente'}';
        if (!_pasadaSinTelefono.contains(nombre)) {
          _pasadaSinTelefono.add(nombre);
        }
        final i = _siguienteAvisable(rows, idx + 1);
        if (i >= 0) {
          _avisarEnCadena(rows, i, enPasada: true);
        } else {
          _resumenPasada();
        }
      }
      return;
    }
    if (via == null) {
      // Hoja cerrada sin elegir: en pasada, el corte se
      // declara con su resumen (136-240), no en silencio.
      if (enPasada) _resumenPasada(cortada: true);
      return;
    }
    if (via == 'whatsapp') {
      final ok = await _abrirWhatsapp(c);
      if (!ok) {
        if (enPasada && mounted) _resumenPasada(cortada: true);
        return;
      }
      // K5-4: sin confirmación de envío no hay marca ni
      // cadena: el cliente no sale de la pasada de avisos.
      final nombre = '${c['nombre'] ?? ''}'.split(' ').first;
      if (!await _confirmarEnvioWhatsApp(nombre)) {
        if (enPasada && mounted) _resumenPasada(cortada: true);
        return;
      }
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
    if (enPasada) _pasadaAvisados++;
    // 1.36 (136-240): el siguiente se busca en la cadena
    // ENTERA y también tras un «Solo marcar» (antes esa
    // vía cortaba la pasada en silencio); los sin-teléfono
    // del camino se saltan y se reportan (136-239).
    final idxSiguiente = _siguienteAvisable(rows, idx + 1);
    if (!mounted) return;
    if (idxSiguiente >= 0) {
      final nombreSig =
          '${rows[idxSiguiente]['nombre'] ?? ''}'.split(' ').first;
      mostrarSnack(
        context,
        '${c['nombre']} marcado como avisado',
        significado: SignificadoChip.exito,
        accion: 'Siguiente: $nombreSig',
        alAccion: () =>
            _avisarEnCadena(rows, idxSiguiente, enPasada: enPasada),
      );
    } else if (enPasada) {
      _resumenPasada();
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
      // 1.36 H-C1 (136-584): con el vacío pintado, la pila
      // (búsqueda/orden/pestañas) vuelve a desplegarse: es
      // el control que permite salir del vacío y no puede
      // quedar plegado detrás del scroll.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_pilaVisible) {
          setState(() => _pilaVisible = true);
        }
      });
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
    // 1.36 (136-235): la cabecera existe sobre el conjunto
    // ENTERO de la pestaña (con fecha + sin fecha): si
    // todos son sin-fecha también hay cabecera, y su «N
    // clientes» es el mismo total que la pestaña promete.
    // 1.25 T50: progreso de la sesión de avisos sobre ESTA
    // lista — «N de M avisados» con su barra. Solo aparece
    // cuando ya hay alguien avisado (la sesión empezó);
    // sin avisos, la lista queda como siempre.
    final totalLista = rows.length + (cola?.length ?? 0);
    final desplaza = esColaCobro && totalLista > 0 ? 1 : 0;
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
        itemCount: (_falloCarga ? 1 : 0) +
            desplaza +
            rows.length +
            (hayCola ? cola.length + 1 : 0),
        separatorBuilder: (_, __) => Divider(
            height: 1,
            indent: 84,
            color: AppColores.borde(context)),
        itemBuilder: (ctx, i) {
          // 1.36 H-C1 (136-585): con filas en memoria, una
          // recarga fallida se AVISA arriba (datos
          // desactualizados + Reintentar), no se calla.
          if (_falloCarga && i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  const Icon(Icons.cloud_off_rounded,
                      size: 18, color: AppColores.alerta),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                        'Datos desactualizados: la última '
                        'recarga falló.',
                        style: AppTexto.secundario),
                  ),
                  TextButton(
                    onPressed: _cargar,
                    child: const Text('Reintentar'),
                  ),
                ],
              ),
            );
          }
          if (_falloCarga) i -= 1;
          if (desplaza == 1 && i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              // 1.28 (M4-C6): al cobrar, la cabecera
              // DESCUENTA la cantidad con una cuenta
              // animada hasta el nuevo estimado.
              child: _NumeroAnimado(
                valor: estimado,
                // 1.36 (136-235): el «N clientes» es el
                // total de la pestaña (con fecha + sin
                // fecha), el mismo conjunto que el estimado
                // suma y que la pestaña promete.
                // 1.36 (136-236): la convención se declara
                // ENTERA: mensualidad en efectivo, salvo
                // tarifa especial vigente (que manda la suya).
                // 1.36 (136-254): en el teléfono del
                // entrenador la declaración dice además que
                // su estimado no ve las especiales del dueño
                // (espejo prohibido para su rol): la
                // diferencia queda declarada en la superficie.
                builder: (_, v) => Text(
                  '$totalLista clientes · '
                  '≈ ${fmtMonto(v)} CUP por cobrar '
                  '(una mensualidad en efectivo de cada uno; '
                  'con tarifa especial, la suya'
                  '${AuthService().isOwner ? '' : '; en este '
                      'teléfono, sin las tarifas especiales '
                      'del dueño'})',
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
            // 1.36 (136-245): Listas desambigua homónimos
            // como Buscar — la línea «📞 teléfono / Carnet
            // ··xxxx» distingue a dos clientes del mismo
            // nombre sin entrar en la ficha.
            desambiguar: true,
            // 1.36 (136-241): la fila del pausado dice su
            // pausa (chip y anillo), no su vencimiento.
            enPausa: _pausados.contains(id),
            // 1.36 (136-248): en esta pantalla la ventana
            // «por vencer» es de 3 días — anillo y chip se
            // alinean con la pestaña, no con los 7 de otras
            // superficies.
            umbralPorVencer: 3,
            // 1.36 (136-244): en las pestañas de atrasados
            // toda fila reserva el alto de la barra, la
            // lleve o no (alto único por pestaña).
            reservarBarra: esColaCobro,
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
                          // 1.36 (136-258): desmarcar lleva
                          // Deshacer en el propio snack — un
                          // toque accidental sobre el ✓ ya no
                          // devuelve al cliente a la cola sin
                          // vía de vuelta (asimetría con el
                          // cobro y con quitar vista, cerrada).
                          final fechaPrevia = _avisadoEl[id];
                          await LocalDb.instance
                              .desmarcarAvisado(id);
                          if (mounted) {
                            mostrarSnack(context,
                                'Marca de avisado quitada para ${c['nombre']}',
                                significado: SignificadoChip.exito,
                                accion: 'Deshacer',
                                alAccion: () async {
                                  await LocalDb.instance.marcarAvisado(id,
                                      pagadoHasta:
                                          c['pagado_hasta'] as String?);
                                  if (!mounted) return;
                                  setState(() {
                                    _avisados.add(id);
                                    if (fechaPrevia != null) {
                                      _avisadoEl[id] = fechaPrevia;
                                    }
                                    _refrescarConteosAvisados();
                                  });
                                  widget.alCambiarDatos?.call();
                                });
                            setState(() {
                              _avisados.remove(id);
                              _avisadoEl.remove(id);
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
                  // 1.36 (136-243): el botón de cobro, la
                  // acción principal de la pantalla, toca a
                  // 48×48 dp — el objetivo de la casa (UI-24);
                  // medía 44×44.
                  child: Container(
                    width: 48,
                    height: 48,
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
    // 1.36 (136-260): una recarga fallida CON datos en
    // pantalla se declara sobre la lista — antes _falloCarga
    // solo se consultaba en el vacío y los datos viejos
    // quedaban pintados sin marca (en la vía embebida ni
    // hay SyncBanner que lo diga).
    if (_falloCarga) {
      cuerpo = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
            child: Row(
              children: [
                Icon(Icons.cloud_off_rounded,
                    size: 16, color: AppColores.errorTexto(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                      'No se pudo recargar: se muestran los datos anteriores.',
                      style: AppTexto.secundario.copyWith(
                          fontWeight: FontWeight.w700)),
                ),
                TextButton(
                    onPressed: _cargar, child: const Text('Reintentar')),
              ],
            ),
          ),
          Expanded(child: cuerpo),
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
    // 1.36 H-B2 (136-587): el ancho de la pestaña queda
    // RESERVADO por el rótulo final (invisible debajo): el
    // contador anima sin que la barra baile de ancho.
    return Stack(
      alignment: Alignment.centerLeft,
      children: [
        Visibility(
          visible: false,
          maintainSize: true,
          maintainState: true,
          maintainAnimation: true,
          child: widget.builder(context, widget.valor),
        ),
        AnimatedBuilder(
          animation: _anim,
          builder: (ctx, _) => widget.builder(ctx, _anim.value),
        ),
      ],
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
      // 1.36 H-B2 (136-587): con «Reducir movimiento» la
      // salida se completa tras ESTE frame, sin esperar los
      // 520 ms del sello.
      if (MediaQuery.of(context).disableAnimations) {
        _completar();
        return;
      }
      setState(() => _sello = true);
      _temporizadorSalida =
          Timer(const Duration(milliseconds: 520), () {
        if (!mounted) return;
        _ctrl.forward().whenComplete(_completar);
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
                              fontWeight: FontWeight.w700)),
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
        // 1.36 H-B2 (136-586): la acción principal del
        // diálogo es un FilledButton, no un texto más.
        FilledButton(
            onPressed: _guardar,
            child: const Text('Guardar')),
      ],
    );
  }
}
