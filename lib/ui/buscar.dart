/// Búsqueda de clientes (consulta/gestión): lista completa por defecto,
/// filtrado por nombre, carnet, teléfono y —opcional— notas.
/// El tap abre la ficha del cliente. El cobro vive en "Agregar pago".
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../congelaciones_gestion.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../perfil.dart';
import '../negocio.dart';
import '../permisos_entrenador.dart';
import '../tiempo.dart';
import '../sync.dart';
import '../cliente_protegido.dart';
import 'acciones_acceso.dart';
import 'app_bar.dart';
import 'diagnostico_espejo_card.dart';
import 'componentes.dart';
import 'permisos_ui.dart';
import 'dialogo_pago.dart';
import 'pago_diario.dart';
import 'preview_cobro.dart';
import 'suplementos.dart';
import 'inscribir.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

/// FIN-28 de Argón (1.20): ultimo_pull_ts se guarda con
/// isoHabana() (con offset) y tryParse lo devuelve en UTC;
/// ahoraHabana() es reloj de pared. Sin normalizar, el cartel
/// de «lista desactualizada» se desplazaba 4-5 h según la zona
/// del teléfono. Devuelve el instante en pared Habana.
DateTime? _pullEnHabana(String ts) {
  final d = DateTime.tryParse(ts);
  if (d == null) return null;
  return d.isUtc ? aHabana(d) : d;
}

class BuscarScreen extends StatefulWidget {
  /// 1.32 «Mostrador Táctico»: embebida = vista «Directorio»
  /// del Pilar 2 (sin su AppBar) y [filtroInicial] = el filtro
  /// de estado con el que nace (el Pulso del Día salta aquí
  /// con «vencidos»/«aldia» ya puesto: D-3 absorbido).
  final bool embebida;
  final String? filtroInicial;
  const BuscarScreen({super.key, this.embebida = false, this.filtroInicial});
  @override
  State<BuscarScreen> createState() => _BuscarScreenState();
}

class _BuscarScreenState extends State<BuscarScreen> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _res = [];

  // 1.25 T11: conteo de nombres entre los resultados para
  // desambiguar homónimos (memoizado por la lista vigente:
  // _res se reasigna en cada búsqueda).
  List<Map<String, dynamic>>? _resContados;
  Map<String, int> _conteoNombres = {};
  Map<String, int> get conteoNombres {
    if (!identical(_resContados, _res)) {
      _resContados = _res;
      final m = <String, int>{};
      for (final c in _res) {
        final n = '${c['nombre'] ?? ''}'.trim().toLowerCase();
        m[n] = (m[n] ?? 0) + 1;
      }
      _conteoNombres = m;
    }
    return _conteoNombres;
  }
  bool _busco = false;
  String _filtro = 'todos'; // todos | aldia | vencidos | porvencer | sinfoto
  bool _enNotas = false; // v1.0.15: búsqueda avanzada en notas
  String _rangoEdad = 'todas'; // todas | menores | 18-25 | 26-35 | 36-50 | 50+
  // Bloque 1: contadores por estado (siempre visibles), frescura
  // de la lista, deslizables configurables y salto por letra.
  Map<String, int> _conteos = {};
  DateTime? _ultimoPull;
  String _swipeDer = 'cobrar';
  String _swipeIzq = 'ninguna';
  // B1 (estéticas 1.19): aviso único del gesto deslizar.
  bool _mostrarAvisoSwipe = false;
  final _scroll = ScrollController();
  // 1.24.2 (paquete Buscar): orden a elegir, densidad compacta,
  // búsqueda avanzada plegada tras el botón de embudo y selección
  // múltiple para avisar por WhatsApp. Orden y densidad se
  // recuerdan entre visitas (meta local).
  String _orden = 'nombre'; // nombre | venceAntes | vencidosPrimero | recientes
  bool _compacta = false;
  bool _mostrarAvanzada = false;
  bool _modoSeleccion = false;
  final Set<int> _seleccionados = {};
  // Yunque de cambios 1.31 (M1): pausados en curso de la
  // última búsqueda (para el chip/anillo de la fila).
  Set<int> _pausados = {};
  // 1.25 T116 (F1-55): ids con aviso de WhatsApp YA
  // registrado hoy (el registro del día de la bandeja):
  // la fila lo enseña y el flujo en lote los salta.
  Set<int> _avisadosHoyIds = {};
  // 1.35 (UI-06): últimos clientes abiertos desde el
  // Directorio (solo local, sin sync): con el campo vacío
  // se enseñan como fila «Recientes» sobre la lista.
  List<Map<String, dynamic>> _recientes = [];
  static const _kRecientesDirectorio = 'directorio_recientes_v1';
  static const _kMaxRecientesDirectorio = 5;

  Future<void> _cargarRecientes() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_kRecientesDirectorio) ?? const [];
      if (ids.isEmpty) return;
      final todos = await listaClientes('');
      final porId = {
        for (final c in todos) (c['id'] as num?)?.toInt(): c,
      };
      if (!mounted) return;
      setState(() {
        _recientes = [
          for (final s in ids)
            if (porId[int.tryParse(s)] != null) porId[int.tryParse(s)]!,
        ];
      });
    } catch (_) {
      // Sin recientes legibles, el Directorio abre como
      // siempre: la lista completa.
    }
  }

  Future<void> _registrarReciente(int id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = [
        '$id',
        ...(prefs.getStringList(_kRecientesDirectorio) ?? const [])
            .where((s) => s != '$id'),
      ].take(_kMaxRecientesDirectorio).toList();
      await prefs.setStringList(_kRecientesDirectorio, ids);
      await _cargarRecientes();
    } catch (_) {}
  }

  void _abrirFichaReciente(Map<String, dynamic> c) {
    final id = (c['id'] as num?)?.toInt();
    if (id == null) return;
    _registrarReciente(id);
    Navigator.of(context)
        .push(RutaIron(
            builder: (_) =>
                FichaScreen(clienteId: id, origenHero: 'buscar')))
        .then((_) {
      if (mounted) {
        _buscar();
        _cargarRecientes();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // 1.32: el filtro pedido por el marco (salto con contexto
    // desde el Pulso del Día) se aplica ANTES de la primera
    // búsqueda; un valor desconocido se ignora.
    final f = widget.filtroInicial;
    if (f != null &&
        const {'todos', 'aldia', 'vencidos', 'porvencer', 'sinfoto'}
            .contains(f)) {
      _filtro = f;
    }
    _cargarConfig();
    _buscar(); // lista completa por defecto
    _cargarRecientes(); // 1.35 (UI-06)
  }

  /// Bloque 1: config local de deslizables + última bajada
  /// registrada por el motor de sync (meta ultimo_pull_ts).
  /// Un valor guardado fuera de la lista cerrada se ignora y
  /// vuelve al default (nunca se ejecuta una acción desconocida).
  Future<void> _cargarConfig() async {
    const cerrada = {'ninguna', 'cobrar', 'diario', 'venta', 'editar'};
    final der = await PerfilService.instance.getSwipeBuscarDer();
    final izq = await PerfilService.instance.getSwipeBuscarIzq();
    final ts = await LocalDb.instance.getMeta('ultimo_pull_ts');
    final ordenGuardado =
        await LocalDb.instance.getMeta('buscar_orden');
    final compactaGuardada =
        await LocalDb.instance.getMeta('buscar_compacta');
    if (!mounted) return;
    setState(() {
      _swipeDer = cerrada.contains(der) ? der : 'cobrar';
      _swipeIzq = cerrada.contains(izq) ? izq : 'ninguna';
      _ultimoPull = ts == null ? null : _pullEnHabana(ts);
      const ordenes = {
        'nombre',
        'venceAntes',
        'vencidosPrimero',
        'recientes'
      };
      if (ordenGuardado != null && ordenes.contains(ordenGuardado)) {
        _orden = ordenGuardado;
      }
      _compacta = compactaGuardada == '1';
    });
    // B1 (estéticas 1.19): aviso único la primera vez que hay
    // deslizables configurados. Se marca visto al mostrarse, así
    // no vuelve aunque no lo cierre.
    final visto = await LocalDb.instance.getMeta('aviso_swipe_visto');
    if (!mounted) return;
    if ((visto ?? '').isEmpty &&
        (_swipeDer != 'ninguna' || _swipeIzq != 'ninguna')) {
      await LocalDb.instance.setMeta('aviso_swipe_visto', '1');
      if (!mounted) return;
      setState(() => _mostrarAvisoSwipe = true);
    }
  }

  int _gen = 0;

  // D-09 (1.21): debounce de tecleo — buscar en cada tecla
  // cargaba el espejo completo varias veces por palabra.
  Timer? _debounceBusqueda;

  void _buscarConDebounce() {
    _debounceBusqueda?.cancel();
    _debounceBusqueda =
        Timer(const Duration(milliseconds: 200), _buscar);
  }

  Future<void> _buscar() async {
    // v1.3.1: descartar resultados obsoletos (race condition).
    final gen = ++_gen;
    final q = _q.text.trim();
    // Argón Clientes #12: si lo pegado es un TELÉFONO con
    // formato (+53 5819 1577, 5 819 1577…), la búsqueda va por
    // sus 8 dígitos limpios (así se guarda en la ficha): con
    // los espacios y el prefijo no coincidía con nada.
    var qBusqueda = q;
    final digitos = q.replaceAll(RegExp(r'[^0-9]'), '');
    if (digitos.length == 10 && digitos.startsWith('53')) {
      qBusqueda = digitos.substring(2);
    } else if (digitos.length == 8 && q != digitos) {
      qBusqueda = digitos;
    }
    // 1.28 (M4-A9): con texto, la búsqueda es la tolerante
    // de la casa (buscarClientes: multi-token insensible a
    // tildes, FTS5 y respaldo de typos en isolate) —
    // listaClientes(q) era subcadena simple y «jose perez»
    // no encontraba a «José Pérez». Sin texto se conserva
    // la foto completa del padrón (buscarClientes('') = []).
    var r = qBusqueda.isEmpty
        ? await listaClientes('')
        : await buscarClientes(qBusqueda);
    if (gen != _gen) return;
    // D-09 (1.21): la lista completa se carga UNA vez por
    // búsqueda aunque la pidan dos rutas (notas e id exacto).
    List<Map<String, dynamic>>? todosCache;
    Future<List<Map<String, dynamic>>> todos() async =>
        todosCache ??= await listaClientes('');
    // v1.0.15: búsqueda avanzada — también en notas.
    if (_enNotas && q.isNotEmpty) {
      final nq = q.toLowerCase();
      final todosL = await todos();
      if (gen != _gen) return;
      final vistos = <dynamic>{for (final c in r) c['id']};
      // Cliente protegido (2026-10-26, Protegido 2 H2): las notas
      // de un protegido nunca lo hacen aparecer en la búsqueda.
      final extra = todosL.where((c) =>
          !vistos.contains(c['id']) &&
          !esVistaProtegida(c) &&
          '${c['notas'] ?? ''}'.toLowerCase().contains(nq));
      r = [...r, ...extra];
      r.sort(
          compararPorNombre);
    }
    // 1.29 (FB-02 · D-B1-01): la BASE de los conteos de
    // cabecera se captura AQUÍ — tras la fusión de notas y
    // ANTES de todo filtro. Los filtros reasignan `r` a
    // listas nuevas, así que la referencia queda intacta.
    final baseConteos = r;
    // Yunque de cambios 1.31 (M1): el conjunto de pausados en
    // curso (espejo solo-dueño; en el teléfono del entrenador
    // sale vacío y nada cambia) para que el filtro «vencidos»
    // y los conteos del directorio no clasifiquen como vencido
    // a quien está en pausa aprobada — la misma exclusión de
    // los predicados centrales de negocio.dart.
    final pausados = await CongelacionesService.instance
        .idsCongeladosEnCurso(ahoraHabana());
    if (gen != _gen) return;
    // Filtros de estado de mensualidad.
    // v1.3.1: sin fecha = vencido (no "al día").
    if (_filtro != 'todos' && _filtro != 'sinfoto') {
      r = r.where((c) {
        // Cliente protegido (2026-10-26, Protegido 2 H2): ningún
        // filtro de estado lo deja pasar (su estado no se revela).
        if (esVistaProtegida(c)) return false;
        // FIN-28 de Argón (1.20): la Casa pasa el filtro «al
        // día» y ningún otro de estado.
        if (esCuentaCasa(c)) return _filtro == 'aldia';
        // Yunque de cambios 1.31 (M1): el cliente en pausa
        // aprobada en curso no es «vencido» en el directorio
        // (misma regla que los predicados de Listas): queda
        // fuera de ese filtro; en «todos» y en los demás
        // filtros sigue saliendo por su fecha, como antes.
        final dias = diasRestantes(c['pagado_hasta'] as String?);
        switch (_filtro) {
          case 'aldia':
            return dias != null && dias > 7;
          case 'vencidos':
            return (dias == null || dias < 0) &&
                !pausados.contains((c['id'] as num?)?.toInt());
          case 'porvencer':
            // Yunque 1.34 (C5-1): la pausa en curso TAMBIÉN
            // sale de «por vencer» (la rama de vencidos ya la
            // excluía desde M1; esta quedó atrás y la pantalla
            // se contradecía con la ficha y con Listas).
            return dias != null &&
                dias >= 0 &&
                dias <= 7 &&
                !pausados.contains((c['id'] as num?)?.toInt());
          default:
            return true;
        }
      }).toList();
    }
    // v1.0.15: filtro por rango de edad (edad desde el carnet).
    if (_rangoEdad != 'todas') {
      r = r.where((c) {
        // Cliente protegido (2026-10-26, Protegido 2 H2): la edad
        // sale del carnet, que es dato protegido.
        if (esVistaProtegida(c)) return false;
        final edad = edadDeCarnet('${c['carnet'] ?? ''}');
        if (edad == null) return false;
        switch (_rangoEdad) {
          // 1.25 T116 (F1-53): los menores existen como
          // categoría (tarifa propia) y no se podían aislar:
          // los rangos empezaban en 18.
          case 'menores':
            return edad < 18;
          case '18-25':
            return edad >= 18 && edad <= 25;
          case '26-35':
            return edad >= 26 && edad <= 35;
          case '36-50':
            return edad >= 36 && edad <= 50;
          case '50+':
            return edad > 50;
          default:
            return true;
        }
      }).toList();
    }
    // v1.1 fix: solo clientes sin foto asignada. Antes verificaba
    // el caché local, así que clientes CON foto pero sin descargar
    // aparecían erróneamente aquí. Yunque 3 (K5-8): el criterio es
    // el predicado compartido clienteSinFotoBuscar — sin foto en el
    // servidor Y sin foto local de este teléfono.
    if (_filtro == 'sinfoto') {
      r = r.where((c) {
        // Ronda 17 M7-H2: el filtro sinfoto tampoco deja
        // pasar protegidos.
        if (esVistaProtegida(c)) return false;
        // Yunque 3 (K5-8): «sin foto» con el predicado
        // compartido (también foto_local).
        return clienteSinFotoBuscar(c);
      }).toList();
    }
    // 1.24.2: orden a elegir (antes del rescate por id exacto,
    // que siempre manda y deja su cliente primero). Con la
    // búsqueda en notas activa manda la relevancia (nombre
    // primero, notas después), no el orden elegido.
    if (!(_enNotas && q.isNotEmpty)) {
      _aplicarOrden(r);
    }
    // F11 (1.20): si lo escrito es un número que coincide
    // EXACTO con el id de un cliente, ese cliente va PRIMERO
    // (y entra aunque la búsqueda normal no lo trajera):
    // abrir la ficha desde un id copiado de una captura, de
    // la nómina o de un error. La ficha aplica la vista
    // protegida si corresponde, como siempre.
    // Argón Clientes #2: con un FILTRO activo (estado, edad o
    // sin foto) el rescate NO inyecta desde fuera: el filtro
    // es una lente deliberada y colar un «al día» bajo el chip
    // «Vencidos» (o un protegido que el filtro excluye)
    // contradice lo que la pantalla está afirmando. Sin
    // filtros, el rescate sigue como se diseñó.
    final sinFiltros = _filtro == 'todos' && _rangoEdad == 'todas';
    if (RegExp(r'^\d+$').hasMatch(q)) {
      final idBuscado = int.tryParse(q);
      if (idBuscado != null) {
        final i = r.indexWhere(
            (c) => (c['id'] as num?)?.toInt() == idBuscado);
        if (i > 0) {
          r.insert(0, r.removeAt(i));
        } else if (i < 0 && sinFiltros) {
          final todosL2 = await todos();
          if (gen != _gen) return;
          final porId = todosL2
              .where((c) =>
                  (c['id'] as num?)?.toInt() == idBuscado)
              .toList();
          if (porId.isNotEmpty) r = [...porId, ...r];
        }
      }
    }
    // 1.28 (M4-A9/R1M4-B1): los conteos se calculan AQUÍ,
    // DESPUÉS del rescate por id exacto y de la fusión
    // de notas — antes el rescate podía AÑADIR un cliente
    // tras contar y la cabecera decía N enseñando N+1.
    // Bloque 1: contadores por estado (sobre la búsqueda,
    // ANTES del filtro de estado: siempre visibles).
    // 1.29 (FB-02 · D-B1-01): esa promesa se cumple por fin
    // del todo — el cálculo (puro, conteosDeBuscar) corre
    // sobre la BASE capturada antes de los filtros cuando
    // hay alguno activo; sin filtros, la lista final (con
    // el rescate ya aplicado) ES la base y se cuenta ella,
    // conservando la corrección de la 1.28.
    final conteos = conteosDeBuscar(
        sinFiltros ? r : baseConteos,
        congelados: pausados);
    // 1.25 T116 (F1-55): ids ya avisados hoy según el
    // registro del día (SQLite de la bandeja).
    final tocados =
        await LocalDb.instance.avisosWaContactados(hoyHabanaIso());
    final idsHoy = <int>{
      for (final k in tocados)
        if (int.tryParse(k.split('_').last) != null)
          int.parse(k.split('_').last),
    };
    if (mounted && gen == _gen) {
      setState(() {
        _res = r;
        _busco = true;
        _conteos = conteos;
        _avisadosHoyIds = idsHoy;
        _pausados = pausados;
      });
    }
  }

  /// 1.25 T116 (F1-52): el estado vacío según la causa —
  /// antes todo vacío culpaba a la búsqueda («prueba con
  /// otro nombre») aunque lo causara un filtro o un espejo
  /// aún sin clientes, y no ofrecía salida.
  Widget _vacioBuscar() {
    final totalEspejo = _conteos['todos'] ?? 0;
    final conFiltros = _filtro != 'todos' || _rangoEdad != 'todas';
    if (_busco &&
        totalEspejo == 0 &&
        !conFiltros &&
        _q.text.trim().isEmpty) {
      return EstadoVacio(
        icono: Icons.people_outline_rounded,
        titulo: 'Aún no hay clientes en este teléfono',
        subtitulo:
            'Actualiza la lista o inscribe el primero.',
        textoAccion: 'Inscribir cliente',
        onAccion: () => Navigator.of(context)
            .push(RutaIron(
                builder: (_) => const InscribirScreen()))
            .then((_) => _buscar()),
      );
    }
    if (conFiltros) {
      return EstadoVacio(
        icono: Icons.filter_alt_off_rounded,
        titulo: 'Nadie cumple este filtro',
        subtitulo:
            'Ningún cliente coincide con los filtros elegidos.',
        textoAccion: 'Quitar filtros',
        onAccion: () {
          setState(() {
            _filtro = 'todos';
            _rangoEdad = 'todas';
          });
          _buscar();
        },
      );
    }
    return EstadoVacio(
      ilustracion: 'assets/vacio_lupa.webp',
      icono: Icons.search_off_rounded,
      titulo: _busco ? 'Sin resultados' : 'Busca un cliente',
      subtitulo: _busco
          // 1.28 (M4-C4): sin resultados con búsqueda
          // activa, el vacío ofrece la salida natural:
          // ¿es un cliente nuevo?
          ? 'Prueba con otro nombre, carnet o teléfono. '
              '¿Es un cliente nuevo?'
          : null,
      textoAccion: _busco ? 'Inscribir a esta persona' : null,
      onAccion: _busco
          ? () => Navigator.of(context)
              .push(RutaIron(
                  builder: (_) => const InscribirScreen()))
              .then((_) => _buscar())
          : null,
    );
  }

  /// 1.25 T116 (F1-51): el texto del aviso del gesto, desde
  /// las acciones configuradas (vacío en una dirección =
  /// esa dirección no hace nada y no se nombra).
  String _textoAvisoSwipe() {
    final partes = <String>[
      if (_etiquetaSwipeAccion(_swipeDer).isNotEmpty)
        _etiquetaSwipeAccion(_swipeDer),
      if (_etiquetaSwipeAccion(_swipeIzq).isNotEmpty)
        _etiquetaSwipeAccion(_swipeIzq),
    ];
    if (partes.isEmpty) {
      return 'Desliza una fila para ver sus acciones';
    }
    return 'Desliza una fila → ${partes.join(' · ')}';
  }

  /// 1.24.2: aplica el orden elegido a la lista ya filtrada.
  /// Comparadores por clave (transitivos): el protegido nunca
  /// revela su estado por la posición — en «vence antes» va al
  /// final por nombre y en «vencidos primero» cae en su propio
  /// grupo final, también por nombre.
  void _aplicarOrden(List<Map<String, dynamic>> r) {
    switch (_orden) {
      case 'venceAntes':
        r.sort((a, b) {
          // 1.28 (M4-A9/R1M4-B2): la Cuenta a la Casa tampoco
          // «vence antes» — no vence nunca; con clave '' (sin
          // fecha) encabezaba la lista. Va al final, como el
          // protegido, desempatando por nombre.
          String clave(Map<String, dynamic> c) =>
              (esVistaProtegida(c) || esCuentaCasa(c))
                  ? '~~~~'
                  : '${c['pagado_hasta'] ?? ''}';
          final cmp = clave(a).compareTo(clave(b));
          return cmp != 0 ? cmp : compararPorNombre(a, b);
        });
      case 'vencidosPrimero':
        int grupo(Map<String, dynamic> c) {
          if (esVistaProtegida(c)) return 4;
          if (esCuentaCasa(c)) return 3;
          final d = diasRestantes(c['pagado_hasta'] as String?);
          if (d == null || d < 0) return 0;
          if (d <= 7) return 1;
          return 2;
        }

        r.sort((a, b) {
          final ga = grupo(a);
          final gb = grupo(b);
          if (ga != gb) return ga.compareTo(gb);
          if (ga <= 1) {
            final cmp = '${a['pagado_hasta'] ?? ''}'
                .compareTo('${b['pagado_hasta'] ?? ''}');
            if (cmp != 0) return cmp;
          }
          return compararPorNombre(a, b);
        });
      case 'recientes':
        r.sort((a, b) {
          final ia = (a['id'] as num?)?.toInt() ?? 0;
          final ib = (b['id'] as num?)?.toInt() ?? 0;
          final cmp = ib.compareTo(ia);
          return cmp != 0 ? cmp : compararPorNombre(a, b);
        });
      default:
        r.sort(compararPorNombre);
    }
  }

  /// Botón "Actualizar": baja cambios del servidor y recarga la lista.
  Future<void> _actualizar() async {
    // v1.3.1: manejar fallo de red (offline-first en Cuba).
    try {
      // 1.34 Campo 2 (P-7): regla de Jc — con datos
      // frescos (≤10 min) el gesto solo relee lo local
      // (el aviso «Lista actualizada» cubre la relectura,
      // como manda la regla); viejos → pull real primero.
      if (await SyncEngine.instance.datosFrescos()) {
        final ts = await LocalDb.instance.getMeta('ultimo_pull_ts');
        if (mounted && ts != null) {
          setState(() => _ultimoPull = _pullEnHabana(ts));
        }
        await _buscar();
        if (!mounted) return;
        mostrarSnack(context, 'Lista actualizada', significado: SignificadoChip.exito);
        return;
      }
      final res = await SyncEngine.instance.pull();
      // 1.23.1 (bug de campo 2026-11-04): si el pull NO corrió
      // (otra sincronización en curso o sin sesión), NO se anuncia
      // «Lista actualizada»: no bajó nada y los carteles de
      // novedades/desactualizada seguirían visibles, en
      // contradicción con el aviso. El motor ya trae el resumen
      // veraz (resumenCorto); se muestra como alerta y la lista
      // se relee igual (datos locales).
      if (!res.corrio) {
        await _buscar();
        if (!mounted) return;
        mostrarSnack(context, res.resumenCorto,
            significado: SignificadoChip.alerta);
        return;
      }
      // Bloque 1: la bajada quedó registrada en ultimo_pull_ts.
      final ts = await LocalDb.instance.getMeta('ultimo_pull_ts');
      if (mounted && ts != null) {
        setState(() => _ultimoPull = _pullEnHabana(ts));
      }
      await _buscar();
      if (!mounted) return;
      mostrarSnack(context, 'Lista actualizada', significado: SignificadoChip.exito);
    } catch (_) {
      await _buscar();
      if (!mounted) return;
      mostrarSnack(context, 'Sin conexión: mostrando datos locales', significado: SignificadoChip.alerta);
    }
  }

  @override
  void dispose() {
    _debounceBusqueda?.cancel();
    _q.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Frescura de la lista para la franja de resumen:
  /// las mismas palabras del SyncBanner («hace X min»).
  String get _frescura {
    final u = _ultimoPull;
    if (u == null) return 'Actualizado nunca';
    final d = ahoraHabana().difference(u);
    if (d.inMinutes < 1) return 'Actualizado ahora mismo';
    if (d.inMinutes < 60) {
      return 'Actualizado hace ${d.inMinutes} min';
    }
    if (d.inHours < 24) return 'Actualizado hace ${d.inHours} h';
    return 'Actualizado hace ${d.inDays} d';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embebida
          ? null
          : appBarIron(
        context,
        'Buscar cliente',
        acciones: [
          IconButton(
            tooltip: 'Actualizar (bajar cambios)',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _actualizar,
          ),
        ],
      ),
      // 1.32 (Oleada 2, Fase 0 — residuo 9a del veredicto
      // g132dis_): la cabecera de BuscarScreen vive DENTRO
      // del scroll (antes fija sobre la lista: desbordaba
      // al 200 % y comía alto permanente). Un solo
      // CustomScrollView: la cabecera como slivers y la
      // lista como SliverList — la cabecera nunca se
      // remonta al cruzar de vacío a resultados (el campo
      // conserva foco y texto) y el RefreshIndicator, que
      // antes solo envolvía la lista, ahora cubre la vista
      // entera, también en vacío.
      body: RefrescoIron(
        onRefresh: _actualizar,
        child: CustomScrollView(
          controller: _scroll,
          slivers: [
            // 1.24.2 (cabecera compacta): banner en su variante
            // estrecha y buscador con las acciones en la misma fila
            // (embudo = búsqueda avanzada, orden, densidad y
            // selección múltiple). La lista gana ~90 px de alto.
            const SliverToBoxAdapter(
              child: SyncBanner(compact: true),
            ),
            SliverToBoxAdapter(
              child:           Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.md,
                AppEspacio.sm, AppEspacio.sm, AppEspacio.xs),
            child: Row(
              children: [
                Expanded(
                  child: CampoTexto(
                    controller: _q,
                    hint: 'Nombre, carnet o teléfono',
                    icono: Icons.search_rounded,
                    onChanged: (_) => _buscarConDebounce(),
                  ),
                ),
                IconButton(
                  tooltip: 'Búsqueda avanzada',
                  icon: Icon(Icons.tune_rounded,
                      color: (_mostrarAvanzada ||
                              _enNotas ||
                              _rangoEdad != 'todas')
                          ? AppColores.naranja
                          : null),
                  onPressed: () => setState(
                      () => _mostrarAvanzada = !_mostrarAvanzada),
                ),
                // 1.30 (Oleada D6, UI130-20): la fila de
                // iconos pasa de 4 a 2 — embudo de avanzada
                // y UN menú «más» con ordenar (las 4
                // opciones, con su marca), la vista
                // compacta/normal y seleccionar varios.
                // Todo se conserva; cambia dónde vive.
                PopupMenuButton<String>(
                  popUpAnimationStyle: estiloAparicionMenu,
                  tooltip: 'Más acciones',
                  icon: const Icon(Icons.more_vert_rounded),
                  onSelected: (sel) {
                    if (sel.startsWith('orden:')) {
                      final v = sel.substring(6);
                      setState(() => _orden = v);
                      LocalDb.instance.setMeta('buscar_orden', v);
                      _buscar();
                    } else if (sel == 'vista') {
                      setState(() => _compacta = !_compacta);
                      LocalDb.instance.setMeta(
                        'buscar_compacta', _compacta ? '1' : '0');
                    } else if (sel == 'seleccionar') {
                      setState(() => _modoSeleccion = true);
                    }
                  },
                  itemBuilder: (ctx) => [
                    CheckedPopupMenuItem(
                        value: 'orden:nombre',
                        checked: _orden == 'nombre',
                        child: const Text('Por nombre (A–Z)')),
                    CheckedPopupMenuItem(
                        value: 'orden:venceAntes',
                        checked: _orden == 'venceAntes',
                        child:
                            const Text('Vence antes primero')),
                    CheckedPopupMenuItem(
                        value: 'orden:vencidosPrimero',
                        checked: _orden == 'vencidosPrimero',
                        child: const Text('Vencidos primero')),
                    CheckedPopupMenuItem(
                        value: 'orden:recientes',
                        checked: _orden == 'recientes',
                        child: const Text(
                            'Más recientes primero')),
                    const PopupMenuDivider(),
                    PopupMenuItem(
                        value: 'vista',
                        child: Text(_compacta
                            ? 'Vista normal'
                            : 'Vista compacta')),
                    if (!_modoSeleccion)
                      const PopupMenuItem(
                          value: 'seleccionar',
                          child: Text(
                              'Seleccionar varios para avisar')),
                  ],
                ),
              ],
            ),
          ),
            ),
            SliverToBoxAdapter(
              child:           // 1.30 (Oleada D6, UI130-20): fuera el héroe
          // carbón de la 1.25 T51 — en su lugar, la franja
          // de resumen de UNA línea (total + frescura) y
          // los chips de filtro en su propia fila, sin
          // contenedor: los conteos por estado viven SOLO
          // en los chips.
          FranjaResumenLista(
            principal: '${_conteos['todos'] ?? 0} clientes',
            secundario: _frescura,
          ),
            ),
            SliverToBoxAdapter(
              child:           SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.xs, AppEspacio.lg, AppEspacio.sm),
            child: Row(
              children: [
                _chipFiltro('todos',
                    'Todos (${_conteos['todos'] ?? 0})'),
                const SizedBox(width: 8),
                _chipFiltro('aldia',
                    'Al día (${_conteos['aldia'] ?? 0})',
                    punto: AppColores.exito),
                const SizedBox(width: 8),
                _chipFiltro('porvencer',
                    'Por vencer (${_conteos['porvencer'] ?? 0})',
                    punto: AppColores.alerta),
                const SizedBox(width: 8),
                _chipFiltro('vencidos',
                    'Vencidos (${_conteos['vencidos'] ?? 0})',
                    punto: AppColores.error),
                const SizedBox(width: 8),
                _chipFiltro('sinfoto',
                    'Sin foto (${_conteos['sinfoto'] ?? 0})'),
              ],
            ),
          ),
            ),
            // Bloque 1: cartel de lista vieja a las 24 h sin bajar
            // cambios (12 h alertaría cada mañana; 24 h no).
            if (_ultimoPull != null &&
                ahoraHabana().difference(_ultimoPull!).inHours >= 24)
              SliverToBoxAdapter(
                child:             Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppEspacio.md, vertical: AppEspacio.sm),
                decoration: BoxDecoration(
                  color: AppColores.alerta.withValues(alpha: 0.12),
                  borderRadius:
                      BorderRadius.circular(AppRadio.md),
                  border: Border.all(color: AppColores.alerta),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 18, color: AppColores.alerta),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                          'Lista desactualizada: hace más de 24 h sin bajar cambios',
                          style: AppTexto.etiqueta),
                    ),
                    TextButton(
                      onPressed: _actualizar,
                      child: const Text('Actualizar'),
                    ),
                  ],
                ),
              ),
            ),
              ),
            // v1.0.15: búsqueda avanzada (notas + rango de edad).
            // 1.24.2: vive tras el botón de embudo de la cabecera
            // (antes un ExpansionTile siempre visible que comía
            // alto de lista aunque no se usara).
            if (_mostrarAvanzada)
              SliverToBoxAdapter(
                child:             SwitchListTile(
              dense: true,
              visualDensity: VisualDensity.compact,
              title: const Text('Buscar también en notas',
                  style: AppTexto.secundario),
              value: _enNotas,
              onChanged: (v) {
                setState(() => _enNotas = v);
                _buscar();
              },
            ),
              ),
            if (_mostrarAvanzada)
              SliverToBoxAdapter(
                child:             Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Rango de edad',
                      style: AppTexto.metadato),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    children: [
                      _chipEdad('todas', 'Todas'),
                      _chipEdad('menores', '<18 · Menores'),
                      _chipEdad('18-25', '18–25'),
                      _chipEdad('26-35', '26–35'),
                      _chipEdad('36-50', '36–50'),
                      _chipEdad('50+', '50+'),
                    ],
                  ),
                ],
              ),
            ),
              ),
            // 1.24.2: barra de selección múltiple para avisar.
            if (_modoSeleccion)
              SliverToBoxAdapter(
                child:             Container(
              color: AppColores.naranja.withValues(alpha: 0.12),
              padding: const EdgeInsets.symmetric(
                  horizontal: AppEspacio.md, vertical: AppEspacio.xs),
              child: Row(
                children: [
                  // Pasada (Argón): el contador va en
                  // Flexible: con la fuente escalada es él
                  // quien cede, no el botón de avisar.
                  Flexible(
                    child: Text(
                        '${_seleccionados.length} seleccionado(s)',
                        style: AppTexto.etiqueta,
                        overflow: TextOverflow.ellipsis),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.chat_rounded, size: 18),
                    label: const Text('Avisar por WhatsApp'),
                    onPressed: _seleccionados.isEmpty
                        ? null
                        : _avisarSeleccionados,
                  ),
                  IconButton(
                    tooltip: 'Salir de la selección',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() {
                      _modoSeleccion = false;
                      _seleccionados.clear();
                    }),
                  ),
                ],
              ),
            ),
              ),
            // 1.23 (W1): si el espejo de clientes está vacío
            // habiendo tenido clientes, la tarjeta de diagnóstico
            // va sobre la lista (se auto-oculta si está sano).
            const SliverToBoxAdapter(
              child: TarjetaDiagnosticoEspejo(),
            ),
            // 1.35 (UI-06): «Recientes» — los últimos
            // clientes abiertos, solo con el campo vacío y
            // fuera del modo selección; al teclear manda el
            // resultado normal y la fila desaparece.
            if (_q.text.trim().isEmpty &&
                !_modoSeleccion &&
                _recientes.isNotEmpty)
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const EncabezadoSeccion(titulo: 'RECIENTES'),
                    for (final c in _recientes)
                      FilaCliente(
                        cliente: c,
                        compacta: true,
                        desambiguar: !esVistaProtegida(c),
                        onTap: () => _abrirFichaReciente(c),
                      ),
                  ],
                ),
              ),
            // 1.25 T116 (F1-52): el vacío dice SU causa
            // (espejo vacío, filtro o búsqueda) y da la
            // salida de cada una.
            if (_res.isEmpty)
              // El vacío fluye como un sliver más (sin
              // SliverFillRemaining: ese sliver pide las
              // dimensiones intrínsecas del hijo y el
              // EstadoVacio elástico, LayoutBuilder, no
              // puede responderlas — reventaba en layout).
              SliverToBoxAdapter(child: _vacioBuscar())
            else ...[
              // B1 (estéticas 1.19): aviso único del gesto.
              if (_mostrarAvisoSwipe)
                SliverToBoxAdapter(
                  child:                         Padding(
                          padding: const EdgeInsets.fromLTRB(
                              12, 0, 12, 4),
                          child: Tarjeta(
                            padding: const EdgeInsets.symmetric(
                                horizontal: AppEspacio.md, vertical: AppEspacio.sm),
                            child: Row(
                              children: [
                                const Icon(Icons.swipe_rounded,
                                    size: 18,
                                    color: AppColores.info),
                                const SizedBox(width: 8),
                                Expanded(
                                  // 1.25 T116 (F1-51): el aviso
                                  // compone las acciones
                                  // CONFIGURADAS en Ajustes —
                                  // el texto fijo prometía
                                  // «cobrar, vender o editar»
                                  // aunque el gesto hiciera
                                  // otra cosa (o nada).
                                  child: Text(
                                    _textoAvisoSwipe(),
                                    style: AppTexto.secundario,
                                  ),
                                ),
                                InkWell(
                                  onTap: () => setState(() =>
                                      _mostrarAvisoSwipe = false),
                                  child: const Icon(Icons.close_rounded,
                                      size: 18),
                                ),
                              ],
                            ),
                          ),
                        ),
                ),
              SliverList.builder(
                itemCount: _res.length,
                itemBuilder: (context, i) =>
                    // Higiene (Argón): el escalonado se acota
                    // a la ventana inicial pasándole el índice
                    // (sin él, TODAS las filas animaban).
                    FadeEntrada(
                        indice: i, child: _filaResultado(context, i)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Fila de resultado: la tarjeta del cliente con su
  /// deslizamiento configurado (la unidad del SliverList).
  /// 1.32 (Oleada 2, Fase 0): sale del build al pasar la
  /// lista a slivers; el fundido de bloque que envolvía la
  /// lista entera ahora envuelve cada fila al montar (ver
  /// el itemBuilder del SliverList).
  Widget _filaResultado(BuildContext context, int i) {
    final c = _res[i];
    final cidFila =
        (c['id'] as num?)?.toInt();
    final protegidoFila =
        esVistaProtegida(c);
    final diasFila = diasRestantes(
        c['pagado_hasta'] as String?);
    // 1.29 (FB-01): teléfono EFECTIVO
    // (movil primero) — el de `telefono`
    // a pelo dejaba sin WhatsApp al
    // migrado y «con teléfono» al carnet.
    final telWaFila =
        telefonoEfectivoWa(c).isNotEmpty;
    // Bloque 1 (A1): cada fila es una
    // tarjeta; el tap abre la ficha.
    // v1.3.1: ValueKey por id.
    final fila = Card(
      margin: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: AppEspacio.xs),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.circular(
                AppRadio.md),
        side: BorderSide(
            color: AppColores.borde(
                context)),
      ),
      child: FilaCliente(
        cliente: c,
        diasRestantesPre: diasFila,
        enPausa: cidFila != null &&
            _pausados.contains(cidFila),
        origenHero: 'buscar',
        compacta: _compacta,
        // 1.25 T116 (F1-55): rastro
        // visible de quién ya fue
        // avisado hoy.
        avisoChip: !protegidoFila &&
                cidFila != null &&
                _avisadosHoyIds
                    .contains(cidFila)
            ? 'Avisado hoy'
            : null,
        // 1.25 T11: homónimos en los
        // resultados o búsqueda por
        // teléfono → la fila enseña su
        // contacto. Nunca en protegidos.
        desambiguar: !protegidoFila &&
            (_q.text
                        .replaceAll(
                            RegExp(
                                r'[^0-9]'),
                            '')
                        .length >=
                    4 ||
                (conteoNombres['${c['nombre'] ?? ''}'
                        .trim()
                        .toLowerCase()] ??
                    0) >
                    1),
        leading: (_modoSeleccion &&
                !protegidoFila &&
                cidFila != null)
            ? Checkbox(
                value: _seleccionados
                    .contains(cidFila),
                onChanged: (_) =>
                    _alternarSeleccion(c),
              )
            : null,
        // 1.24.2: botón WhatsApp directo
        // en vencidos y por vencer (con
        // teléfono válido y sin ser Casa:
        // la Casa no vence).
        // 1.25 T52: próxima acción
        // según el estado (la fila
        // protegida o en selección
        // no la lleva).
        accionPrincipal: _accionFilaBuscar(
            c,
            dias: diasFila,
            protegido: protegidoFila),
        accionWhatsapp: (!_modoSeleccion &&
                !protegidoFila &&
                !esCuentaCasa(c) &&
                // Yunque 1.34 (C5-1): sin aviso de vencimiento
                // a quien está en pausa aprobada en curso.
                !_pausados.contains(cidFila) &&
                telWaFila &&
                (diasFila == null ||
                    diasFila <= 7))
            ? () => _abrirWhatsapp(c)
            : null,
        onLongPress: (_modoSeleccion ||
                protegidoFila)
            ? null
            : () => _menuRapido(c),
        onTap: _modoSeleccion
            ? () => _alternarSeleccion(c)
            : () {
                if (cidFila == null) {
                  return;
                }
                // 1.35 (UI-06): abrir la ficha lo deja en
                // los recientes del Directorio.
                _registrarReciente(cidFila);
                Navigator.of(context)
                    .push(RutaIron(
                        builder: (_) =>
                            FichaScreen(
                                clienteId:
                                    cidFila,
                                origenHero:
                                    'buscar')))
                    .then((_) {
                  if (mounted) {
                    _buscar();
                    _cargarRecientes();
                  }
                });
              },
      ),
    );
    // Ronda 17 M7-H1: cliente protegido
    // nunca se envuelve en Dismissible:
    // el gesto abriría cobro o edición
    // saltándose el bloqueo visual.
    // 1.24.2: en modo selección tampoco
    // (el toque selecciona, no desliza).
    if (protegidoFila || _modoSeleccion) {
      return fila;
    }
    // Bloque 1: deslizables configurables
    // desde Ajustes (lista cerrada). Sin
    // acción configurada no hay Dismissible.
    final tieneDer =
        _swipeDer != 'ninguna';
    final tieneIzq =
        _swipeIzq != 'ninguna';
    if (!tieneDer && !tieneIzq) {
      return fila;
    }
    final dir = tieneDer && tieneIzq
        ? DismissDirection.horizontal
        : tieneDer
            ? DismissDirection
                .startToEnd
            : DismissDirection
                .endToStart;
    return Dismissible(
      key: ValueKey(
          'buscar_${c['id']}'),
      direction: dir,
      background: _fondoSwipe(
          _swipeDer, true),
      secondaryBackground: _fondoSwipe(
          _swipeIzq, false),
      // La fila nunca se borra: la acción
      // se ejecuta y la fila se queda.
      confirmDismiss: (d) async {
        final accion = d ==
                DismissDirection
                    .startToEnd
            ? _swipeDer
            : _swipeIzq;
        await _ejecutarSwipe(accion, c);
        return false;
      },
      child: fila,
    );
  }

  String _etiquetaSwipeAccion(String v) => switch (v) {
        'cobrar' => 'Cobrar mes',
        // 1.25 T12: el pago diario es ANÓNIMO por diseño (sin
        // cliente): el gesto no promete actuar sobre la fila;
        // dice «Ir a…». La venta SÍ preselecciona al cliente.
        'diario' => 'Ir a Pago diario',
        'venta' => 'Venta',
        'editar' => 'Editar',
        _ => '',
      };

  Widget _fondoSwipe(String accion, bool derecha) {
    Color color;
    IconData icono;
    switch (accion) {
      case 'cobrar':
        color = AppColores.exito;
        icono = Icons.payments_rounded;
      case 'diario':
        color = AppColores.info;
        icono = Icons.today_rounded;
      case 'venta':
        color = AppColores.naranja;
        icono = Icons.shopping_bag_rounded;
      case 'editar':
        color = Colors.grey;
        icono = Icons.edit_rounded;
      default:
        color = Colors.grey;
        icono = Icons.block_rounded;
    }
    return Container(
      color: color,
      alignment:
          derecha ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Text(_etiquetaSwipeAccion(accion),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// Bloque 1: ejecuta la acción al deslizar. Cobrar pasa por el
  /// Preview obligatorio (nunca cobra directo); el resto navega
  /// a su pantalla (Editar abre la ficha directo en Editar).
  Future<void> _ejecutarSwipe(
      String accion, Map<String, dynamic> c) async {
    // Ronda 17 M7-H1 (defensa en profundidad): aunque la fila
    // protegida ya no lleva Dismissible, el swipe nunca actúa
    // sobre un cliente protegido.
    if (esVistaProtegida(c)) {
      if (mounted) {
        mostrarSnack(context, mensajeClienteProtegido, significado: SignificadoChip.alerta);
      }
      return;
    }
    switch (accion) {
      case 'cobrar':
        // 1.26 (auditoría de botones, MEDIA 2): el swipe y
        // el menú rápido cobran por el MISMO camino que el
        // botón de la fila (_cobrarDesdeBuscar), que trae
        // la guarda _pagoEnCursoBuscar. Antes este caso
        // duplicaba el flujo SIN guarda: un doble gesto
        // apilaba dos pagoDialogo y completar ambos
        // encolaba dos cobros del mismo cliente.
        await _cobrarDesdeBuscar(c);
        return;
      case 'diario':
        if (!mounted) return;
        await Navigator.of(context).push(
            RutaIron(builder: (_) => const PagoDiarioScreen()));
        if (mounted) await _buscar();
        return;
      case 'venta':
        if (!mounted) return;
        // 1.25 T12: la venta nace con ESTE cliente elegido
        // en el selector de comprador (antes abría la tienda
        // genérica y había que buscarlo otra vez, con riesgo
        // de venderle a otro).
        await Navigator.of(context).push(RutaIron(
            builder: (_) => SuplementosScreen(
                clienteInicialId: (c['id'] as num?)?.toInt(),
                clienteInicialNombre: '${c['nombre'] ?? ''}')));
        if (mounted) await _buscar();
        return;
      case 'editar':
        final id = c['id'];
        final cid = id is int ? id : int.tryParse('$id');
        if (cid == null || !mounted) return;
        await Navigator.of(context).push(RutaIron(
            builder: (_) =>
                FichaScreen(
                    clienteId: cid,
                    editarAlAbrir: true,
                    origenHero: 'buscar')));
        if (mounted) await _buscar();
        return;
      default:
        return;
    }
  }

  // ==================================================================
  // 1.24.2 (paquete Buscar): menú rápido, WhatsApp directo y
  // selección múltiple para avisar.
  // ==================================================================

  void _alternarSeleccion(Map<String, dynamic> c) {
    if (esVistaProtegida(c)) return;
    final cid = (c['id'] as num?)?.toInt();
    if (cid == null) return;
    setState(() {
      if (!_seleccionados.remove(cid)) _seleccionados.add(cid);
    });
  }

  /// Abre WhatsApp con el aviso que corresponde al estado del
  /// cliente (o el chat pelado si no hace falta aviso).
  Future<void> _abrirWhatsapp(Map<String, dynamic> c,
      {bool conMensaje = true}) async {
    // Congelación 0.5 · Yunque B (YB-FLU-02): con mensaje de
    // vencimiento, el cliente en pausa NO se avisa (está en
    // pausa aprobada, no vencido). El chat pelado (sin
    // mensaje) no se toca: hablar con él sigue permitido.
    if (conMensaje) {
      final cid = (c['id'] as num?)?.toInt();
      final congelados = await CongelacionesService.instance
          .idsCongeladosEnCurso(ahoraHabana());
      if (!mounted) return;
      if (cid != null && congelados.contains(cid)) {
        mostrarSnack(
            context,
            'Este cliente está en pausa (congelación aprobada): '
            'no le corresponde aviso de vencimiento.',
            significado: SignificadoChip.alerta);
        return;
      }
    }
    // 1.29 (FB-01): teléfono efectivo (movil primero).
    final wa = telefonoEfectivoWa(c);
    if (wa.isEmpty) {
      if (mounted) {
        mostrarSnack(
            context, 'Este cliente no tiene teléfono válido registrado.',
            significado: SignificadoChip.alerta);
      }
      return;
    }
    final url = Uri.parse(conMensaje
        ? 'https://wa.me/$wa?text=${Uri.encodeComponent(mensajeWaSegunEstado(c))}'
        : 'https://wa.me/$wa');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo abrir WhatsApp.',
            significado: SignificadoChip.alerta);
      }
    }
  }

  /// Menú rápido al mantener presionada una fila: las acciones
  /// del deslizable sin deslizar, más WhatsApp, llamada y la
  /// entrada a la selección múltiple.
  Future<void> _menuRapido(Map<String, dynamic> c) async {
    if (esVistaProtegida(c)) return;
    // 1.29 (FB-01): teléfono efectivo (movil primero).
    final telOk = telefonoEfectivoWa(c).isNotEmpty;
    final accion = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('${c['nombre'] ?? 'Cliente'}',
                  style: AppTexto.subtitulo),
              subtitle: const Text('Acciones rápidas'),
            ),
            ListTile(
              leading: const Icon(Icons.payments_rounded),
              title: const Text('Cobrar mes'),
              onTap: () => Navigator.pop(ctx, 'cobrar'),
            ),
            ListTile(
              leading: const Icon(Icons.today_rounded),
              // 1.25 T12: el diario es anónimo; no promete
              // registrarle el día a ESTE cliente.
              title: const Text('Ir a Pago diario'),
              onTap: () => Navigator.pop(ctx, 'diario'),
            ),
            ListTile(
              leading: const Icon(Icons.shopping_bag_rounded),
              title: const Text('Vender suplemento'),
              onTap: () => Navigator.pop(ctx, 'venta'),
            ),
            if (telOk)
              ListTile(
                leading: const Icon(Icons.chat_rounded,
                    color: AppColores.whatsapp),
                title: const Text('WhatsApp'),
                onTap: () => Navigator.pop(ctx, 'whatsapp'),
              ),
            if (telOk)
              ListTile(
                leading: const Icon(Icons.call_rounded),
                title: const Text('Llamar'),
                onTap: () => Navigator.pop(ctx, 'llamar'),
              ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Editar cliente'),
              onTap: () => Navigator.pop(ctx, 'editar'),
            ),
            // 1.28 (M4-B1): el acceso también desde el menú
            // rápido de Buscar (solo dueño — el helper
            // compartido decide según el estado verificado
            // del acceso qué se puede hacer).
            if (AuthService().isOwner)
              ListTile(
                leading: const Icon(Icons.key_rounded),
                title: const Text('Acceso a la app'),
                onTap: () => Navigator.pop(ctx, 'acceso'),
              ),
            ListTile(
              leading: const Icon(Icons.checklist_rounded),
              title: const Text('Seleccionar varios para avisar'),
              onTap: () => Navigator.pop(ctx, 'seleccionar'),
            ),
          ],
        ),
      ),
    );
    if (accion == null || !mounted) return;
    switch (accion) {
      case 'cobrar':
      case 'diario':
      case 'venta':
      case 'editar':
        await _ejecutarSwipe(accion, c);
      case 'whatsapp':
        final d = diasRestantes(c['pagado_hasta'] as String?);
        final urgente =
            !esCuentaCasa(c) && (d == null || d <= 7);
        await _abrirWhatsapp(c, conMensaje: urgente);
      case 'llamar':
        // 1.29 (FB-01): se llama al teléfono EFECTIVO (movil
        // primero, 8 dígitos limpios): antes se tomaban los
        // últimos 8 dígitos de `telefono` crudo — en un migrado
        // eso era la cola de su carnet, no su número.
        final telLocal = telefonoEfectivoLocal(c);
        if (telLocal != '—') {
          await launchUrl(Uri.parse('tel:+53$telLocal'));
        }
      case 'seleccionar':
        setState(() => _modoSeleccion = true);
        _alternarSeleccion(c);
      case 'acceso':
        // 1.28 (M4-B1): menú de acceso del helper
        // compartido, sin salir de Buscar.
        await abrirMenuAccesoDesdeLista(
          context,
          clienteId: (c['id'] as num?)?.toInt() ?? 0,
          alTerminar: () async {
            if (mounted) await _buscar();
          },
          alAbrirFicha: () async {
            await Navigator.of(context).push(RutaIron(
                builder: (_) => FichaScreen(
                    clienteId: (c['id'] as num?)?.toInt() ?? 0,
                    origenHero: 'buscar')));
            if (mounted) await _buscar();
          },
          alDarAcceso: () async {
            await Navigator.of(context).push(RutaIron(
                builder: (_) => FichaScreen(
                    clienteId: (c['id'] as num?)?.toInt() ?? 0,
                    origenHero: 'buscar',
                    irAAccesoAlAbrir: true)));
            if (mounted) await _buscar();
          },
        );
    }
  }

  /// Cadena de avisos a los seleccionados: uno por uno, en orden
  /// de urgencia (sin fecha/vencido primero). Cada paso muestra
  /// el cliente y espera confirmación — abrir WhatsApp no cuenta
  /// como avisado hasta que el usuario dice «Ya avisé».
  /// 1.25 T116 (F1-55): el tipo de aviso de la bandeja
  /// según los días — la marca del lote cae en el MISMO
  /// registro del día que usa la Bandeja WhatsApp.
  String _tipoAvisoPorDias(int? d) =>
      d == 0 ? 'vence_hoy' : (d != null && d > 0) ? 'por_vencer' : 'vencido';

  Future<void> _avisarSeleccionados() async {
    // 1.25 T116 (F1-54): la base es la SELECCIÓN, no la
    // lista filtrada visible — un seleccionado que dejó de
    // pasar el filtro actual desaparecía del flujo en
    // silencio aunque la barra lo seguía contando. Y las
    // exclusiones se CUENTAN Y SE NOMBRAN: antes todo
    // terminaba en «sin teléfono válido», falso cuando la
    // causa era ser Casa o protegido.
    final todosL = await listaClientes('');
    if (!mounted) return;
    final hoy = hoyHabanaIso();
    final tocados = await LocalDb.instance.avisosWaContactados(hoy);
    // Congelación 0.5 · Yunque B (YB-FLU-02): el cliente con
    // la pausa aprobada EN CURSO queda fuera de la cadena (y
    // se cuenta y se nombra, como las demás exclusiones).
    final congelados = await CongelacionesService.instance
        .idsCongeladosEnCurso(ahoraHabana());
    var nProtegidos = 0, nCasa = 0, nSinTel = 0, nYaHoy = 0, nPausa = 0;
    final conTel = <Map<String, dynamic>>[];
    for (final c in todosL) {
      final cid = (c['id'] as num?)?.toInt();
      if (cid == null || !_seleccionados.contains(cid)) continue;
      if (esVistaProtegida(c)) {
        nProtegidos++;
      } else if (esCuentaCasa(c)) {
        nCasa++;
      } else if (congelados.contains(cid)) {
        nPausa++;
      } else if (telefonoEfectivoWa(c).isEmpty) {
        // 1.29 (FB-01): sin teléfono EFECTIVO (movil primero):
        // el migrado con número en `movil` SÍ entra en la cadena.
        nSinTel++;
      } else if (tocados.contains(
          '${_tipoAvisoPorDias(diasRestantes(c['pagado_hasta'] as String?))}_$cid')) {
        // F1-55: ya avisado hoy (por aquí o por la bandeja):
        // no se le escribe dos veces.
        nYaHoy++;
      } else {
        conTel.add(c);
      }
    }
    conTel.sort((a, b) => '${a['pagado_hasta'] ?? ''}'
        .compareTo('${b['pagado_hasta'] ?? ''}'));
    String causas() {
      final p = <String>[
        if (nSinTel > 0) '$nSinTel sin teléfono',
        if (nCasa > 0) '$nCasa Cuenta a la Casa',
        if (nPausa > 0) '$nPausa en pausa (congelación)',
        if (nProtegidos > 0) '$nProtegidos protegido(s)',
        if (nYaHoy > 0) '$nYaHoy ya avisado(s) hoy',
      ];
      return p.join(' · ');
    }

    if (conTel.isEmpty) {
      mostrarSnack(context,
          'Sin avisos posibles: ${causas().isEmpty ? 'la selección quedó vacía' : causas()}',
          significado: SignificadoChip.alerta);
      return;
    }
    if (causas().isNotEmpty) {
      mostrarSnack(context,
          'Se avisará a ${conTel.length}; quedan fuera: ${causas()}',
          significado: SignificadoChip.alerta);
    }
    var i = 0;
    var avisados = 0;
    while (mounted && i < conTel.length) {
      final c = conTel[i];
      final d = diasRestantes(c['pagado_hasta'] as String?);
      final detalle = d == null
          ? 'Sin fecha de vencimiento'
          : d < 0
              ? 'Vencido hace ${d.abs()} día(s)'
              : d == 0
                  ? 'Vence hoy'
                  : 'Vence en $d día(s)';
      final r = await showModalBottomSheet<String>(
        context: context,
        isDismissible: false,
        builder: (ctx) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppEspacio.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Aviso ${i + 1} de ${conTel.length}',
                    style: AppTexto.metadato),
                const SizedBox(height: 4),
                Text('${c['nombre'] ?? 'Cliente'}',
                    style: AppTexto.subtitulo),
                Text(detalle, style: AppTexto.secundario),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.chat_rounded),
                    label: const Text('Abrir WhatsApp'),
                    onPressed: () => Navigator.pop(ctx, 'abrir'),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, 'avise'),
                        child: const Text('Ya avisé · Siguiente'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx, 'saltar'),
                        child: const Text('Saltar'),
                      ),
                    ),
                  ],
                ),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx, 'fin'),
                    child: const Text('Terminar avisos'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      if (r == 'abrir') {
        await _abrirWhatsapp(c);
        // Sin avanzar: al volver de WhatsApp el mismo paso se
        // muestra otra vez para confirmar con «Ya avisé».
        continue;
      }
      if (r == 'avise') {
        avisados++;
        // 1.25 T116 (F1-55): el «Ya avisé» deja RASTRO en
        // el registro del día — si el flujo se interrumpe,
        // al reabrirlo esos clientes se saltan y su fila
        // enseña «Avisado hoy».
        final cidOk = (c['id'] as num?)?.toInt();
        if (cidOk != null) {
          await LocalDb.instance.marcarAvisoWaContactado(
              cidOk, _tipoAvisoPorDias(d), hoy);
          if (mounted) {
            setState(() => _avisadosHoyIds.add(cidOk));
          }
        }
      }
      if (r == 'avise' || r == 'saltar') {
        i++;
        continue;
      }
      break; // 'fin' o cierre inesperado
    }
    if (!mounted) return;
    setState(() {
      _modoSeleccion = false;
      _seleccionados.clear();
    });
    mostrarSnack(
        context,
        avisados > 0
            ? 'Avisos completados: $avisados de ${conTel.length}'
            : 'Avisos cancelados',
        significado:
            avisados > 0 ? SignificadoChip.exito : SignificadoChip.alerta);
  }

  /// 1.25 T52: la acción fantasma de una fila de Buscar,
  /// ya resuelta a botón (o null). La decisión (qué acción
  /// toca) vive en la función pura accionPrincipalBuscar.
  ({String texto, IconData icono, VoidCallback alTocar})?
      _accionFilaBuscar(Map<String, dynamic> c,
          {required int? dias, required bool protegido}) {
    final cual = accionPrincipalBuscar(
      dias: dias,
      esCasa: esCuentaCasa(c),
      protegido: protegido,
      seleccion: _modoSeleccion,
      // 1.29 (FB-01): teléfono efectivo (movil primero).
      tieneTelefonoWa: telefonoEfectivoWa(c).isNotEmpty,
      // Yunque 2.34 (D-4): pausa en curso (sistema nuevo) o
      // congelado legado: sin acción fantasma.
      enPausa: _pausados.contains((c['id'] as num?)?.toInt()) ||
          (c['estado'] as String?) == 'congelado',
    );
    return switch (cual) {
      'cobrar' => (
          texto: 'Cobrar',
          icono: Icons.payments_rounded,
          alTocar: () => _cobrarDesdeBuscar(c)
        ),
      'avisar' => (
          texto: 'Avisar',
          icono: Icons.chat_rounded,
          alTocar: () => _abrirWhatsapp(c)
        ),
      _ => null,
    };
  }

  bool _pagoEnCursoBuscar = false;

  /// 1.25 T52: cobrar desde la fila de Buscar — el MISMO
  /// flujo que el cobro rápido de Listas (permiso con
  /// refresco, bloqueo de Casa, diálogo, Preview con
  /// Recibo y Deshacer). Nada de un segundo camino.
  Future<void> _cobrarDesdeBuscar(Map<String, dynamic> c) async {
    if (_pagoEnCursoBuscar) return;
    _pagoEnCursoBuscar = true;
    try {
      if (!await permisoOperativoOkConRefresco(context,
          () => PermisosEntrenador().canCobrarPagos, 'cobrar pagos')) {
        return;
      }
      if (await mostrarBloqueoCasa(context, c)) return;
      if (!mounted) return;
      final payload = await pagoDialogo(context, c);
      if (payload == null || !mounted) return;
      final r = await cobrarConPreviewYRecibo(
        context: context,
        nombreCliente: '${c['nombre'] ?? ''}',
        payload: payload,
      );
      if (!mounted) return;
      if (r == ResultadoCobro.deshecho) {
        mostrarSnack(context, 'Cobro deshecho',
            significado: SignificadoChip.exito);
      }
      _buscar();
      SyncEngine.instance.push();
    } finally {
      _pagoEnCursoBuscar = false;
    }
  }

  Widget _chipFiltro(String valor, String etiqueta,
      {Color? punto, bool sobreOscuro = false}) {
    final activo = _filtro == valor;
    return ChoiceChip(
      label: Text(etiqueta,
          style: AppTexto.metadato.copyWith(
              color: sobreOscuro && !activo ? Colors.white : null)),
      avatar: punto == null
          ? null
          : Icon(Icons.circle_rounded, size: 10, color: punto),
      selected: activo,
      backgroundColor: sobreOscuro
          ? Colors.white.withValues(alpha: 0.14)
          : null,
      side: sobreOscuro ? BorderSide.none : null,
      // 1.32 (integración, RD-5): son los filtros
      // PRINCIPALES del Directorio, tocados con el dedo en
      // movimiento: fuera la densidad compacta (≈32 dp) y
      // objetivo táctil acolchado de 48.
      materialTapTargetSize: MaterialTapTargetSize.padded,
      onSelected: (_) {
        setState(() => _filtro = valor);
        _buscar();
      },
    );
  }

  /// v1.0.15: chip de rango de edad (búsqueda avanzada).
  Widget _chipEdad(String valor, String etiqueta) {
    final activo = _rangoEdad == valor;
    return ChoiceChip(
      label: Text(etiqueta, style: AppTexto.metadato),
      selected: activo,
      // 1.32 (integración, RD-5): como _chipFiltro — sin
      // densidad compacta y con objetivo de 48.
      materialTapTargetSize: MaterialTapTargetSize.padded,
      onSelected: (_) {
        setState(() => _rangoEdad = valor);
        _buscar();
      },
    );
  }
}

/// Fila de cliente con mini foto (reutilizable en listas).
class FilaCliente extends StatelessWidget {
  final Map<String, dynamic> cliente;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Widget? leading;

  /// T2 (Bloque 2): origen del Hero de la foto ('buscar',
  /// 'listas'…). Sin origen, la fila no vuela.
  final String? origenHero;

  /// 1.24.2 (Buscar): densidad compacta — avatar más pequeño y
  /// menos aire vertical. Por defecto la fila de siempre.
  final bool compacta;

  /// 1.24.2 (Buscar): si viene, la fila muestra el botón directo
  /// de WhatsApp (aviso según el estado del cliente) en vez del
  /// chevron. Un [trailing] explícito sigue mandando.
  final VoidCallback? accionWhatsapp;

  /// 1.25 T11: enseñar la línea de contacto (teléfono o cola
  /// del carnet) para distinguir homónimos. El llamador la
  /// apaga en filas protegidas: nunca filtra el contacto de
  /// un protegido a un no-dueño.
  final bool desambiguar;

  /// 1.25 T116 (F1-26): texto del chip «Avisado · 12/10»
  /// cuando el llamador (Listas) sabe que la marca sigue
  /// vigente; null = sin chip. La marca deja de decirse
  /// solo con color y borde.
  final String? avisoChip;

  /// 1.25 T46: días de atraso (> 0) para pintar la barra de
  /// antigüedad bajo la fila (la pasan las pestañas de
  /// atrasados de Listas). Null = sin barra.
  final int? diasAtraso;

  /// 1.25 T52: la «próxima acción» probable de la fila,
  /// como botón fantasma bajo el chip de estado (Buscar la
  /// calcula por estado: cobrar si vencido, avisar si por
  /// vencer). Null = sin botón.
  final ({String texto, IconData icono, VoidCallback alTocar})?
      accionPrincipal;

  /// 1.29 (D-13): el importe de la fila, en cifras TABULARES
  /// alineadas a la derecha (la columna de importes no baila
  /// entre filas). Es el hueco que le faltaba a la fila única
  /// para servir también en «por cobrar», que componía su
  /// propia fila con el importe a su manera. [importeEtiqueta]
  /// es la palabra bajo el importe («tarifa mensual»).
  final String? importeTexto;
  final String? importeEtiqueta;

  /// Yunque de cambios 1.31 (M1): en pausa aprobada en curso
  /// (solo lo pasa el directorio de Buscar, que tiene el
  /// conjunto): la fila dice pausa, no vencido.
  final bool enPausa;

  /// 1.34 Campo 2 (P-5): días restantes ya calculados
  /// por el llamador (el directorio los calcula para el
  /// deslizamiento): la fila no los recalcula en su build.
  final int? diasRestantesPre;

  const FilaCliente(
      {super.key,
      required this.cliente,
      this.diasRestantesPre,
      this.enPausa = false,
      this.onTap,
      this.onLongPress,
      this.trailing,
      this.leading,
      this.origenHero,
      this.compacta = false,
      this.desambiguar = false,
      this.avisoChip,
      this.diasAtraso,
      this.accionPrincipal,
      this.accionWhatsapp,
      this.importeTexto,
      this.importeEtiqueta});

  @override
  Widget build(BuildContext context) => _FilaCliente(
      key: ValueKey(cliente['id']),
      cliente: cliente,
      diasRestantesPre: diasRestantesPre,
      enPausa: enPausa,
      onTap: onTap,
      onLongPress: onLongPress,
      trailing: trailing,
      leading: leading,
      origenHero: origenHero,
      compacta: compacta,
      desambiguar: desambiguar,
      avisoChip: avisoChip,
      diasAtraso: diasAtraso,
      accionPrincipal: accionPrincipal,
      accionWhatsapp: accionWhatsapp,
      importeTexto: importeTexto,
      importeEtiqueta: importeEtiqueta);
}

class _FilaCliente extends StatefulWidget {
  /// Yunque de cambios 1.31 (M1): el cliente está en pausa
  /// aprobada en curso (conjunto del directorio): su chip y
  /// su anillo dicen pausa, no vencido.
  final bool enPausa;
  final int? diasRestantesPre;
  final Map<String, dynamic> cliente;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Widget? leading;
  final String? origenHero;
  final bool compacta;
  final bool desambiguar;
  final String? avisoChip;
  final int? diasAtraso;
  final ({String texto, IconData icono, VoidCallback alTocar})?
      accionPrincipal;
  final VoidCallback? accionWhatsapp;
  final String? importeTexto;
  final String? importeEtiqueta;
  const _FilaCliente(
      {super.key,
      required this.cliente,
      this.diasRestantesPre,
      this.enPausa = false,
      this.onTap,
      this.onLongPress,
      this.trailing,
      this.leading,
      this.origenHero,
      this.compacta = false,
      this.desambiguar = false,
      this.avisoChip,
      this.diasAtraso,
      this.accionPrincipal,
      this.accionWhatsapp,
      this.importeTexto,
      this.importeEtiqueta});

  @override
  State<_FilaCliente> createState() => _FilaClienteState();
}

class _FilaClienteState extends State<_FilaCliente> {
  File? _foto;
  String? _resueltoPara;

  // 1.31 (campo 2026-11-09): escucha de aterrizajes de la
  // cola de precarga — cuando la foto de ESTA fila llega a
  // la caché, se re-resuelve desde disco y la miniatura
  // aparece sin esperar a un scroll o a volver de la ficha.
  StreamSubscription<String>? _subFoto;

  @override
  void initState() {
    super.initState();
    _subFoto = FotoCache.instance.aterrizajes.listen((ruta) {
      if (ruta == _resueltoPara && _foto == null) _resolverFoto();
    });
    _resolverFoto();
  }

  @override
  void dispose() {
    _subFoto?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(_FilaCliente old) {
    super.didUpdateWidget(old);
    // 1.34 Campo 2 (P-4): solo se re-resuelve si cambió la
    // ruta (foto_storage o foto_local). Antes se re-chequeaba
    // disco en CADA reconstrucción del padre para las filas
    // aún sin foto. La intención original de v1.1 (la foto
    // descargada en la ficha aparece al volver) la cubre la
    // escucha de aterrizajes de la cola: FotoCache.obtener
    // registra el aterrizaje y esta fila re-resuelve sola.
    if (old.cliente['foto_storage'] != widget.cliente['foto_storage'] ||
        old.cliente['foto_local'] != widget.cliente['foto_local']) {
      _resolverFoto();
    }
  }

  /// Resuelve la foto en DOS FASES (1.31, campo 2026-11-09):
  /// la fila solo espera DISCO — primero `foto_local` (la foto
  /// recién tomada en ESTE teléfono, el paso que la ficha
  /// tiene desde 1.28 y la lista nunca heredó) y luego la
  /// caché de FotoCache. Si no está en disco, la red va por
  /// la cola de precarga (concurrencia baja, timeout corto,
  /// caché negativa) y la miniatura entra por la escucha de
  /// aterrizajes. Antes la fila esperaba un GET de 30 s que
  /// con 3G malo moría a mitad y dejaba iniciales toda la
  /// sesión, relanzado en cada reconstrucción.
  Future<void> _resolverFoto() async {
    final sp = widget.cliente['foto_storage'] as String?;
    // D-09 (1.21): si ESTA foto ya está resuelta y mostrada, la
    // re-comprobación de disco por reconstrucción no aporta
    // nada y se salta. Si aún no hay foto, se sigue re-chequeando
    // (la miniatura aparece al volver de la ficha, intención
    // original de v1.1).
    if (sp == _resueltoPara && _foto != null) return;
    // Argón: limpiar siempre que cambie el cliente, antes de async.
    if (sp != _resueltoPara && _foto != null && mounted) {
      setState(() => _foto = null);
    }
    _resueltoPara = sp;
    // FASE DISCO 1: la foto local de este teléfono manda
    // (vale aunque foto_storage aún sea null: no ha subido).
    final local = widget.cliente['foto_local'] as String?;
    if (local != null && local.isNotEmpty) {
      final f = File(local);
      if (await f.exists()) {
        if (!mounted || _resueltoPara != sp) return;
        setState(() => _foto = f);
        return;
      }
    }
    if (sp == null || sp.isEmpty) return;
    // FASE DISCO 2: la caché descargada.
    // 1.34 Campo 2 (P-3): resolución de lista — si la
    // original no está pero su hermana ligera sí, se
    // pinta la ligera.
    final enCache =
        await FotoCache.instance.enCacheParaLista(sp);
    if (!mounted || _resueltoPara != sp) return;
    if (enCache != null) {
      setState(() => _foto = enCache);
      return;
    }
    // FASE RED (fuera de la fila): precarga encolada.
    FotoCache.instance.precargar([sp]);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.cliente;
    final ph = c['pagado_hasta'] as String?;
    // P-5: una sola vez por fila — si el directorio ya lo
    // calculó para el deslizamiento, se reutiliza.
    final d = widget.diasRestantesPre ?? diasRestantes(ph);
    // Iniciales para el placeholder (ej: "Juan Pérez" -> "JP")
    // 1.28 (M4-A9/R3M4-H10): nombre visible de la casa — una
    // fila sin nombre se pinta «Sin nombre», no «null».
    final nombre = nombreVisibleCliente(c);
    final partes = nombre.trim().split(RegExp(r'\s+'));
    String iniciales = '';
    if (partes.isNotEmpty) {
      iniciales = partes[0].isNotEmpty ? partes[0][0].toUpperCase() : '';
      if (partes.length > 1 && partes.last.isNotEmpty) {
        iniciales += partes.last[0].toUpperCase();
      }
    }
    if (iniciales.isEmpty) iniciales = '?';
    // Foto (mismo widget en la rama normal y en la protegida).
    final foto = AvatarCliente(
      nombre: nombre,
      foto: _foto,
      tamano: TamanoAvatar.l,
      heroTag: widget.origenHero == null
          ? null
          : tagHeroCliente(widget.origenHero!, c['id']),
    );
    // 1.24.2 (Buscar): semáforo en el avatar de la rama normal —
    // el anillo dice el estado sin leer la fila: verde al día,
    // ámbar por vencer (≤7 días), rojo vencido o sin fecha y
    // dorado para la Cuenta a la Casa. La rama protegida no lo
    // lleva (no debe filtrar el estado).
    final esCasaAnillo = esCuentaCasa(c);
    final colorSemaforo = esCasaAnillo
        ? AppColores.casaIcono
        : widget.enPausa
            ? AppColores.info
            : (d == null || d < 0)
                ? AppColores.error
                : d <= 7
                    ? AppColores.alerta
                    : AppColores.exito;
    final fotoSemaforo = AvatarCliente(
      nombre: nombre,
      foto: _foto,
      tamano: widget.compacta ? TamanoAvatar.m : TamanoAvatar.l,
      heroTag: widget.origenHero == null
          ? null
          : tagHeroCliente(widget.origenHero!, c['id']),
      colorBorde: colorSemaforo,
      grosorBorde: 2.5,
    );
    final tieneNotas =
        '${c['notas'] ?? ''}'.trim().isNotEmpty;
    // Cliente protegido (2026-10-26, A1 Argón): el entrenador solo
    // ve avatar, nombre y candado. Sin badge, sin días, sin
    // leading (selección de papelera) y sin trailing (acciones
    // rápidas como cobro o WhatsApp). El onTap se conserva: abrir
    // la ficha muestra la vista bloqueada (foto + nombre).
    if (esVistaProtegida(c)) {
      return InkWell(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.lg, vertical: AppEspacio.sm),
          child: Row(
            children: [
              foto,
              const SizedBox(width: AppEspacio.md),
              Expanded(
                child: Text(nombre,
                    style:
                        AppTexto.subtitulo),
              ),
              const Icon(Icons.lock_rounded, color: AppColores.naranja),
            ],
          ),
        ),
      );
    }
    // v1.1: badge según días restantes (con icono + texto, nunca solo color)
    // FIN-28 de Argón (1.20): la Cuenta a la Casa no vence —
    // distintivo dorado «Casa» (patrón de Control de Acceso) en
    // vez del badge de días, que la pintaba «Vencido»/«Sin
    // fecha» por su pagado_hasta nulo o viejo.
    final esCasa = esCuentaCasa(c);
    // 1.25 T47: UN solo chip con el estado Y la fecha —
    // la insignia corta y la línea de días se funden (la
    // fecha exacta de F1-21 vive ahora dentro del chip).
    // Sin fecha: chip «SIN PAGOS» gris (el truco de
    // convertir null en 999999 días pintaba «AL DÍA» a
    // quien nunca pagó; T04 lo curó en el modelo y aquí
    // llega a la fila).
    final chipFila =
        chipEstadoFila(dias: d, pagadoHasta: ph, enPausa: widget.enPausa);
    // 1.25 T47: el texto de días vive dentro del chip
    // (chipEstadoFila); Casa conserva su chip dorado con
    // el texto completo.
    final textoDiasCasa = 'Cuenta a la Casa · sin vencimiento';
    // 1.25 T11: línea de contacto para desambiguar homónimos
    // (teléfono si hay; si no, la cola del carnet).
    // 1.29 (FB-01 · D-B1-02): el teléfono que se pinta es el
    // EFECTIVO (movil primero, 8 dígitos limpios): antes se
    // tomaban los dígitos crudos de `telefono` y, en un
    // migrado, la línea «📞» enseñaba la cola de su CARNET
    // como si fuera su número.
    String? lineaContacto;
    if (widget.desambiguar) {
      final telLocal = telefonoEfectivoLocal(c);
      if (telLocal != '—') {
        lineaContacto = '📞 $telLocal';
      } else {
        final carnet =
            '${c['carnet'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
        if (carnet.length >= 4) {
          lineaContacto =
              'Carnet ··${carnet.substring(carnet.length - 4)}';
        }
      }
    }
    final filaPrincipal = InkWell(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: AppEspacio.lg,
            vertical: widget.compacta ? AppEspacio.xs : AppEspacio.sm),
        child: Row(
          children: [
            // v1.1 papelera: el leading (checkbox) convive con la foto,
            // no la reemplaza.
            if (widget.leading != null) ...[
              widget.leading!,
              const SizedBox(width: AppEspacio.sm),
            ],
            // Foto con semáforo (la rama protegida usa la pelada).
            fotoSemaforo,
            const SizedBox(width: AppEspacio.md),
            // Nombre (+ icono si tiene notas) + badge + días
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(nombre,
                            style: AppTexto.subtitulo,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (tieneNotas) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.sticky_note_2_outlined,
                            size: 15,
                            color: AppColores.textoSecundario(
                                context)),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 1.25 T47: un solo chip de estado con
                  // fecha (Casa: su chip dorado de siempre,
                  // con el texto completo).
                  if (esCasa)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppEspacio.sm,
                          vertical: AppEspacio.xs),
                      decoration: BoxDecoration(
                        color: AppColores.casaFondo,
                        borderRadius: BorderRadius.circular(
                            AppRadio.circular),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.home_rounded,
                              size: 16, color: AppColores.casaIcono),
                          const SizedBox(width: 4),
                          // Jornada 1 de la 1.34: el texto
                          // completo desbordaba 3,1 px en la
                          // fila con los dos botones del
                          // trailing (Listas); flexible con
                          // elipsis en vez de recorte seco.
                          Flexible(
                            child: Text(textoDiasCasa,
                                overflow: TextOverflow.ellipsis,
                                style: AppTexto.etiqueta.copyWith(
                                    color: AppColores.casaTexto)),
                          ),
                        ],
                      ),
                    )
                  else
                    BadgeEstado(
                        estado: chipFila.estado,
                        texto: chipFila.texto),
                  if (lineaContacto != null) ...[
                    const SizedBox(height: 2),
                    Text(lineaContacto,
                        style: AppTexto.secundario.copyWith(
                            color: AppColores.textoSecundario(
                                context))),
                  ],
                  // 1.25 T52: la próxima acción probable,
                  // como botón fantasma bajo el estado — la
                  // lista trabaja como cola, no como
                  // directorio. No sustituye al WhatsApp del
                  // trailing ni al gesto: es el atajo visible.
                  if (widget.accionPrincipal != null) ...[
                    const SizedBox(height: 2),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: Icon(widget.accionPrincipal!.icono,
                            size: 16),
                        label: Text(widget.accionPrincipal!.texto),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: AppEspacio.sm),
                          minimumSize: Size.zero,
                          tapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          foregroundColor: AppColores.naranja,
                        ),
                        onPressed: widget.accionPrincipal!.alTocar,
                      ),
                    ),
                  ],
                  // 1.25 T116 (F1-26): el chip de avisado
                  // en TEXTO, junto a los días.
                  if (widget.avisoChip != null) ...[
                    const SizedBox(height: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppEspacio.sm,
                          vertical: AppEspacio.xs),
                      decoration: BoxDecoration(
                        color: AppColores.exito
                            .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(
                            AppRadio.circular),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.check_rounded,
                              size: 13,
                              color: AppColores.exitoTexto(context)),
                          const SizedBox(width: 3),
                          Text(widget.avisoChip!,
                              style: AppTexto.etiqueta.copyWith(
                                  // Pasada (Argón): el texto
                                  // del chip (12 px) va en el
                                  // token resuelto, no en el
                                  // exito de relleno.
                                  color: AppColores.exitoTexto(context),
                                  fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 1.29 (D-13): la columna de importe de la fila
            // única — cifras tabulares alineadas a la derecha
            // (no bailan entre filas) y su palabra debajo
            // cuando el llamador la da («tarifa mensual»).
            if (widget.importeTexto != null) ...[
              const SizedBox(width: AppEspacio.sm),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    widget.importeTexto!,
                    style: AppTexto.subtitulo.copyWith(
                      fontFeatures: const [
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  if (widget.importeEtiqueta != null)
                    Text(
                      widget.importeEtiqueta!,
                      style: AppTexto.minuscula.copyWith(
                          color:
                              AppColores.textoSecundario(context)),
                    ),
                ],
              ),
            ],
            // Acción rápida, botón de WhatsApp (1.24.2) o chevron.
            widget.trailing ??
                (widget.accionWhatsapp != null
                    ? IconButton(
                        icon: const Icon(Icons.chat_rounded,
                            color: AppColores.whatsapp),
                        tooltip: 'Avisar por WhatsApp',
                        visualDensity: VisualDensity.compact,
                        onPressed: widget.accionWhatsapp,
                      )
                    : Icon(Icons.chevron_right_rounded,
                        color:
                            AppColores.textoSecundario(context))),
          ],
        ),
      ),
    );
    // 1.25 T46: barra de antigüedad bajo la fila (solo la
    // piden las pestañas de atrasados): el largo crece con
    // los días de atraso hasta los 60 y el color pasa de
    // ámbar a rojo a los 30, como el semáforo de siempre.
    final atraso = widget.diasAtraso;
    if (atraso == null || atraso <= 0) return filaPrincipal;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        filaPrincipal,
        Padding(
          padding: const EdgeInsets.fromLTRB(84, 0, 16, 6),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadio.sm),
            child: SizedBox(
              height: 4,
              child: Row(
                children: [
                  Expanded(
                    flex: (fraccionBarraAtraso(atraso) * 1000).round(),
                    child: Container(
                      color: atraso >= 30
                          ? AppColores.error
                          : AppColores.alerta,
                    ),
                  ),
                  Expanded(
                    flex: 1000 -
                        (fraccionBarraAtraso(atraso) * 1000).round(),
                    child: Container(color: AppColores.borde(context)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 1.25 T46: fracción de la barra de antigüedad — crece
/// lineal con los días de atraso y se llena a los 60 días
/// (más allá, todos se leen «muy atrasado» por igual).
double fraccionBarraAtraso(int dias) =>
    dias <= 0 ? 0.0 : (dias / 60).clamp(0.0, 1.0);

/// 1.25 T47: el chip único de estado de la fila — estado
/// (para el color/icono de BadgeEstado) y texto completo
/// con la fecha exacta. Sin fecha de vencimiento: estado
/// sinPagos (gris), nunca «AL DÍA».
({EstadoMembresia estado, String texto}) chipEstadoFila({
  required int? dias,
  required String? pagadoHasta,
  bool enPausa = false,
}) {
  // Yunque de cambios 1.31 (M1): en pausa aprobada en curso
  // el chip dice la pausa, no el vencimiento que no corre.
  if (enPausa) {
    return (
      estado: EstadoMembresia.congelado,
      texto: 'EN PAUSA · no vence mientras dura'
    );
  }
  if (dias == null) {
    return (
      estado: EstadoMembresia.sinPagos,
      texto: 'SIN PAGOS · sin fecha'
    );
  }
  final fecha = fmtFecha(pagadoHasta);
  if (dias < 0) {
    final n = -dias;
    return (
      estado: EstadoMembresia.vencido,
      texto: 'Venció $fecha · hace $n ${n == 1 ? 'día' : 'días'}'
    );
  }
  if (dias == 0) {
    return (
      estado: EstadoMembresia.porVencer,
      texto: 'Vence hoy · $fecha'
    );
  }
  if (dias <= 7) {
    return (
      estado: EstadoMembresia.porVencer,
      texto: 'Vence $fecha · en $dias ${dias == 1 ? 'día' : 'días'}'
    );
  }
  return (estado: EstadoMembresia.alDia, texto: 'Al día · vence $fecha');
}

/// 1.25 T52: la «próxima acción» probable de una fila de
/// Buscar según su estado. Vencido o sin fecha → cobrar;
/// por vencer (≤7 días, hoy incluido) con teléfono →
/// avisar; al día → ninguna (el toque ya abre la ficha).
/// Casa, protegidos y el modo selección nunca llevan
/// acción.
String? accionPrincipalBuscar({
  required int? dias,
  required bool esCasa,
  required bool protegido,
  required bool seleccion,
  required bool tieneTelefonoWa,
  bool enPausa = false,
}) {
  if (protegido || seleccion || esCasa) return null;
  // Yunque 2.34 (D-4): en pausa no hay acción fantasma — la
  // fila ya pinta «EN PAUSA» y el envío/cobro se frenaba
  // dentro, dejando un botón muerto («Avisar»/«Cobrar» que
  // no hacía nada). Simétrico a C5-1 (el botón de WhatsApp
  // de esta misma fila ya excluía la pausa).
  if (enPausa) return null;
  if (dias == null || dias < 0) return 'cobrar';
  if (dias <= 7) return tieneTelefonoWa ? 'avisar' : null;
  return null;
}

/// 1.29 (Oleada 3, FB-02 · D-B1-01): los conteos de la
/// cabecera de Buscar, como función PURA sobre la BASE de la
/// búsqueda (el resultado tras la fusión de notas y ANTES de
/// los filtros de estado, edad y sin-foto). Antes se contaba
/// sobre la lista YA filtrada: con el chip «Vencidos» puesto,
/// la cabecera enseñaba como total el propio subconjunto
/// filtrado y los demás chips salían a cero o al resto
/// filtrado — los conteos se movían al tocar un chip, cuando
/// su promesa («sobre la búsqueda, antes del filtro») es que
/// sean estables. Reglas vivas que se conservan: el protegido
/// no alimenta ningún contador (su estado no se revela); la
/// Cuenta a la Casa cuenta como al día y también alimenta
/// «sin foto»; sin fecha = vencido.

/// Yunque 3 (K5-8): «sin foto» para Buscar = `foto_storage`
/// vacío Y `foto_local` vacío. El criterio v1.1 (solo
/// foto_storage) dejaba fuera la señal simétrica: la foto
/// tomada EN este teléfono aún no subida vive en foto_local,
/// y ese cliente entraba en el filtro y en el contador «Sin
/// foto» mientras su propia fila — que resuelve primero la
/// local, como la ficha (FB-04) — mostraba su foto. Lo usan
/// el filtro `sinfoto` y el contador de [conteosDeBuscar]
/// para que ambos juzguen igual.
bool clienteSinFotoBuscar(Map<String, dynamic> c) {
  final ref = c['foto_storage'] as String?;
  final local = c['foto_local'] as String?;
  return (ref == null || ref.isEmpty) &&
      (local == null || local.isEmpty);
}

Map<String, int> conteosDeBuscar(List<Map<String, dynamic>> base,
    {Set<int> congelados = const {}}) {
  final conteos = <String, int>{
    'todos': base.length,
    'aldia': 0,
    'porvencer': 0,
    'vencidos': 0,
    'sinfoto': 0,
  };
  for (final c in base) {
    // Cliente protegido (2026-10-26, Protegido 2 H2): su estado
    // de pago no alimenta los contadores (revelaría si pagó).
    if (!esVistaProtegida(c)) {
      // FIN-28 de Argón (1.20): una Cuenta a la Casa nunca
      // vence — cuenta como al día (como clientesAlDia()).
      // Sin continue: el conteo de «sin foto» de abajo también
      // debe alimentarse de las cuentas Casa.
      if (esCuentaCasa(c)) {
        conteos['aldia'] = conteos['aldia']! + 1;
      } else {
        final dias = diasRestantes(c['pagado_hasta'] as String?);
        // Yunque de cambios 1.31 (M1): en pausa aprobada en
        // curso no cuenta como vencido (sigue en «todos» y en
        // «sin foto» si le toca): el directorio no lo clasifica
        // como moroso, igual que Listas.
        final enPausa =
            congelados.contains((c['id'] as num?)?.toInt());
        if (dias != null && dias > 7) {
          conteos['aldia'] = conteos['aldia']! + 1;
        } else if (dias != null &&
            dias >= 0 &&
            dias <= 7 &&
            !enPausa) {
          // Yunque 1.34 (C5-1): el contador de «por vencer»
          // tampoco suma pausas en curso (como el de vencidos).
          conteos['porvencer'] = conteos['porvencer']! + 1;
        } else if ((dias == null || dias < 0) && !enPausa) {
          conteos['vencidos'] = conteos['vencidos']! + 1;
        }
      }
    }
    // Ronda 17 M7-H2: el contador sinfoto tampoco se alimenta
    // con protegidos (igual que aldia/porvencer/vencidos).
    // Yunque 3 (K5-8): el predicado compartido con el filtro.
    if (clienteSinFotoBuscar(c) && !esVistaProtegida(c)) {
      conteos['sinfoto'] = conteos['sinfoto']! + 1;
    }
  }
  return conteos;
}
