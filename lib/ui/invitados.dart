/// Bloque G de Invitados (v1.5.0): bandeja de Gestión.
///
/// Lista y detalle de los invitados registrados desde la app de
/// clientes. TODO vive en Supabase y se lee por RPC de staff
/// (lib/invitados.dart): la bandeja necesita conexión; a cambio no
/// hay espejo local que se desactualice. La lista NO muestra datos
/// corporales (diseño §8); las medidas autodeclaradas viven en el
/// detalle, visibles ANTES de Convertir junto con la última sync
/// (ajuste 5 de Argón).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_log.dart';
import '../auth.dart';
import '../bloque3.dart';
import '../invitados.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../plus_reportes.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../visitas_invitados.dart';
import 'panel_resto_caja.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'horario_gym.dart';
import 'inscribir.dart';
import 'reportes_plus.dart';
import 'skeleton.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Bandeja (lista)
// ---------------------------------------------------------------------------

class InvitadosScreen extends StatefulWidget {
  /// v1.6.0: embebida como pestaña de «Usuarios» (sin Scaffold ni
  /// AppBar propios; las acciones de la AppBar van en una fila).
  final bool embebido;

  /// Filtro con el que abre la bandeja ('todos' por defecto; el
  /// Panel del dueño enlaza directo con 'solicitudes').
  final String filtroInicial;

  const InvitadosScreen(
      {super.key, this.embebido = false, this.filtroInicial = 'todos'});
  @override
  State<InvitadosScreen> createState() => _InvitadosScreenState();
}

/// v1.8.0: ciclo del op_id de los lotes COMPARTIDO por la lista
/// y el detalle (la huella distingue cada intención).
final _loteInvitados = AccionLoteInvitados();

/// Dorado de la pastilla y la línea Plus (rango «Invitado Plus»).
const _doradoPlus = AppColores.doradoPlus;

/// 1.29 (FB-05 · D-B1-05): costuras de test (patrón de la casa,
/// cf. leerNominaPermisosParaTest en panel_permisos.dart): el
/// servicio de la bandeja y la fuente del conteo de reportes
/// Plus, inyectables. En producción valen null y manda lo real.
@visibleForTesting
InvitadosService? servicioInvitadosParaTest;

@visibleForTesting
Future<int> Function()? conteoReportesPlusParaTest;

class _InvitadosScreenState extends State<InvitadosScreen> {
  final _svcReal = InvitadosService();
  InvitadosService get _svc => servicioInvitadosParaTest ?? _svcReal;
  static const _filtros = <({String id, String etiqueta})>[
    (id: 'todos', etiqueta: 'Todos'),
    (id: 'solicitudes', etiqueta: 'Solicitudes'),
    (id: 'nuevos', etiqueta: 'Nuevos'),
    (id: 'por_expirar', etiqueta: 'Cuenta por expirar'),
    // v1.12.0 (A): filtro de caducados (vía del servidor: mismo
    // vocabulario de filtros de invitados_listar).
    (id: 'caducados', etiqueta: 'Caducados'),
    (id: 'plus', etiqueta: 'Plus'),
    (id: 'plus_por_vencer', etiqueta: 'Plus por vencer'),
    (id: 'convertidos', etiqueta: 'Convertidos'),
  ];
  String _filtro = 'todos';
  bool _cargando = true;
  String? _error;
  // 1.28 (M4-A11): generación de carga de la lista — una
  // carga vieja que termina tarde no pisa la foto nueva.
  int _cargaGen = 0;
  List<InvitadoResumen> _lista = [];
  Map<String, ConversionInvitado> _locales = {};
  // 1.25 T87: visitas (30 días) por invitado, para la
  // insignia de candidato SIN entrar uno a uno. Se
  // cargan tras la lista, sin bloquear la pintura.
  Map<String, int> _visitasLista = {};
  int _umbralLista = umbralVisitasDefecto;
  // v1.6.0: ids de clientes de la base LOCAL, para contar la historia
  // completa del convertido (si su cliente ya no existe aquí, fue
  // eliminado después de la conversión).
  // v1.12.0 (B3/B4): mapa id → fila del espejo (para leer estado y
  // fecha de eliminación) + fechas del registro local de bajas.
  Map<String, Map<String, dynamic>> _clientesPorId = {};
  Map<int, String> _fechasEliminados = {};
  // v1.8.0: conteos de cabecera (del servidor), modo offline de
  // SOLO LECTURA (J3/G1) y multiselección para acciones en lote.
  InvitadosConteos? _conteos;
  bool _offline = false;
  DateTime? _cacheAt;
  final Set<String> _seleccion = {};
  bool get _modoSeleccion => _seleccion.isNotEmpty;
  // v1.12.0 (A): buscador, orden y barra de letras sobre la página
  // cargada (la bandeja pagina en el servidor: se ordena y busca
  // sobre lo cargado y se muestra «X de Y cargados»).
  final _busquedaCtrl = TextEditingController();
  final _scroll = ScrollController();
  // 1.25 T119 (F3-30): el salto por letra estimaba 120 px por
  // tarjeta que miden ~170 (el propio comentario lo decía):
  // ahora el alto se MIDE de la primera tarjeta pintada.
  final _primeraTarjetaKey = GlobalKey();
  // 1.36 H-B3 (136-706): clave estable por invitado para que
  // el salto por letra use ensureVisible sobre la fila real
  // cuando ya está construida (sin estimar altos).
  final _clavesTarjeta = <String, GlobalKey>{};
  GlobalKey _claveTarjeta(String id) =>
      _clavesTarjeta.putIfAbsent(id, () => GlobalKey());
  double _altoTarjeta = 170;
  String _busqueda = '';
  String _orden = 'servidor';
  // v1.12.0 (C5): reportes Plus por atender (best-effort; null si
  // no se pudo consultar: no se pinta nada en vez de un 0 falso).
  int? _reportesPlusPendientes;

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Lista visible: filtro de caducados defensivo (si el servidor
  /// aún no soporta el filtro, las filas que no son caducadas se
  /// descartan aquí en vez de mostrarse como caducadas) + búsqueda
  /// + orden. Los conteos de cabecera NO se recalculan desde aquí:
  /// siguen siendo los del servidor (F4).
  List<InvitadoResumen> get _listaVisible {
    var lista = _lista;
    if (_filtro == 'caducados') {
      lista = [for (final i in lista) if (i.caducado) i];
    }
    lista = filtrarInvitadosBusqueda(lista, _busqueda);
    if (_orden != 'servidor') lista = ordenarInvitados(lista, _orden);
    return lista;
  }

  Map<String, int> get _indiceLetras => letrasInvitados(_listaVisible);

  /// Estado B3/B4 de un convertido de la lista (veredicto de Argón:
  /// 3 estados, nunca «eliminado» falso por retraso del espejo).
  ({EstadoConvertido estado, String? eliminadoEn}) _estadoConvertidoLista(
      InvitadoResumen inv) {
    final local = _locales[inv.id];
    final enCurso = local != null &&
        (local.estado == EstadoConversion.preparada ||
            local.estado == EstadoConversion.opEncolada);
    final fila = inv.clienteId == null
        ? null
        : _clientesPorId['${inv.clienteId}'];
    final fecha = inv.clienteId == null
        ? null
        : _fechasEliminados[inv.clienteId];
    return resolverEstadoConvertido(
      conversionEnCurso: enCurso,
      filaCliente: fila,
      enRegistroEliminados: fecha != null,
      fechaRegistroEliminados: fecha,
    );
  }

  @override
  void initState() {
    super.initState();
    _filtro = widget.filtroInicial;
    _cargar();
  }

  void _limpiarSeleccion() {
    if (_seleccion.isNotEmpty) setState(() => _seleccion.clear());
  }

  Future<void> _cargar({bool verificar = true}) async {
    final gen = ++_cargaGen;
    setState(() {
      _cargando = true;
      _error = null;
    });
    // 1.32 (H-B5-2): el cierre de conversiones SALE del camino
    // de pintado. verificarConversiones puede disparar
    // confirmarConversion, una ESCRITURA sin timeout a
    // propósito (un corte del lado cliente no debe fingir que
    // el servidor no aplicó): esperarla aquí dejaba el spinner
    // eterno con la red colgada, antes de pintar nada. Ahora
    // va en segundo plano y, si confirma alguna conversión, la
    // lista se recarga sola (sin re-verificar).
    if (verificar) {
      unawaited(_verificarConversionesEnFondo(gen));
    }
    // 1.32 (H-B5-1): la caché local pinta en el primer frame
    // (la vista «Todos», la única cacheada): la lista ya no
    // espera a la RPC (12 s) para enseñar lo que el teléfono
    // ya sabe. Se pinta en modo sin conexión (solo lectura) y
    // la respuesta fresca la sustituye al llegar, como la
    // ficha. Antes la caché solo entraba en el catch, tras el
    // timeout entero.
    var pintoCache = false;
    if (_filtro == 'todos') {
      final cache = await _svc.leerCacheInvitados();
      if (!mounted || gen != _cargaGen) return;
      if (cache != null && cache.lista.isNotEmpty) {
        pintoCache = true;
        setState(() {
          _lista = cache.lista;
          _conteos = cache.resumen;
          _offline = true;
          _cacheAt = cache.cachedAt;
          _seleccion.clear();
          _cargando = false;
          _error = null;
        });
        // Jornada 2 · 1.35: las visitas son dato LOCAL
        // (tabla visitas_invitados + umbral en meta): el
        // conteo de candidato también corre sobre la lista
        // en caché. Sin esta llamada, el chip de candidato
        // —la conversión que la banda offline de la lista
        // promete— no se pintaba jamás sin conexión y la
        // rama offline de _convertirDesdeLista era código
        // inalcanzable: la banda decía «conversión
        // disponible» y desde la lista no se podía.
        _cargarVisitasLista(cache.lista);
      }
    }
    try {
      final lista = await _svc.listar(filtro: _filtro);
      final conteos = await _svc.resumen();
      final locales = await ConversionInvitadoStore().todas();
      final clientes = await LocalDb.instance.allMirror('clientes');
      // v1.12.0 (B4): fechas de bajas ya registradas + sellar las
      // shells estado='eliminado' que se ven por primera vez (solo
      // las que faltan: INSERT OR IGNORE, sin reescribir fechas).
      var fechas = await LocalDb.instance.fechasClientesEliminados();
      var hayShellEliminada = false;
      for (final c in clientes) {
        if ('${c['estado'] ?? ''}' != 'eliminado') continue;
        hayShellEliminada = true;
        final cid = (c['id'] as num?)?.toInt();
        if (cid == null || fechas.containsKey(cid)) continue;
        await LocalDb.instance.registrarClienteEliminadoVisto(cid);
      }
      if (hayShellEliminada) {
        fechas = await LocalDb.instance.fechasClientesEliminados();
      }
      // 1.29 (FB-05 · D-B1-05): el conteo de reportes Plus ya
      // NO se espera aquí: es una RPC con su propio timeout y
      // la lista — que ya está disponible — pintaba tras ella
      // (hasta 12 s de «cargando» con todo en local). Se pide
      // en segundo plano tras pintar (ver
      // _actualizarConteoReportes); la insignia aparece sola.
      if (!mounted || gen != _cargaGen) return;
      // G1: la caché guarda SOLO el par {resumen, lista «Todos»}.
      if (_filtro == 'todos') {
        await _svc.guardarCacheInvitados(
            resumen: conteos, listaTodos: lista);
      }
      setState(() {
        _lista = lista;
        _conteos = conteos;
        _offline = false;
        _cacheAt = null;
        _seleccion.clear();
        _locales = {for (final c in locales) c.invitadoId: c};
        _clientesPorId = {
          for (final c in clientes) '${c['id']}': c,
        };
        _fechasEliminados = fechas;
        _cargando = false;
      });
      _cargarVisitasLista(lista);
      // 1.36 H-B3 (136-711): filas omitidas por sucias ya no
      // se tragan: la bandeja avisa de datos parciales.
      if (_svc.omitidasUltimaLista > 0 && mounted) {
        mostrarSnack(context,
            'Datos parciales: ${_svc.omitidasUltimaLista} '
            'registro(s) no se pudieron leer y no se muestran.',
            significado: SignificadoChip.alerta);
      }
      // 1.29 (FB-05): con la lista YA pintada, el conteo de
      // reportes Plus se pide en segundo plano.
      unawaited(_actualizarConteoReportes(gen));
    } catch (e) {
      if (!mounted || gen != _cargaGen) return;
      // 1.32 (H-B5-1): con la caché ya pintada en solo lectura,
      // un fallo al refrescar no tumba la vista a la pantalla
      // de error: se conserva la copia y se avisa.
      if (pintoCache) {
        setState(() => _cargando = false);
        mostrarSnack(context,
            e is InvitadoError
                ? e.mensaje
                // 1.36 H-B1 (136-319): un error sin
                // clasificar NO se atribuye a la conexión.
                : 'No se pudo actualizar: se muestra la '
                    'última lista guardada.',
            significado: SignificadoChip.alerta);
        return;
      }
      // 1.28 (M4-A11/R2M4-H6): si la pantalla YA enseña datos
      // frescos, un fallo de red de una recarga NO los pisa
      // con la caché vieja ni resetea el filtro elegido: se
      // conserva la vista y se avisa. La caché solo manda
      // cuando no hay nada fresco que conservar.
      if (e is InvitadoError && e.codigo == 'RED' && _lista.isNotEmpty) {
        setState(() => _cargando = false);
        // 136-319: «RED» del clasificador es «red O
        // servidor» — el aviso no atribuye la causa.
        mostrarSnack(context,
            'No se pudo actualizar: se mantiene la última '
            'lista cargada.',
            significado: SignificadoChip.alerta);
        return;
      }
      // J3/G1: sin conexión, la caché manda en SOLO LECTURA y la
      // vista se clava en «Todos» (sin chips, búsqueda ni acciones).
      if (e is InvitadoError && e.codigo == 'RED') {
        final cache = await _svc.leerCacheInvitados();
        if (!mounted || gen != _cargaGen) return;
        if (cache != null && cache.lista.isNotEmpty) {
          setState(() {
            _lista = cache.lista;
            _conteos = cache.resumen;
            _offline = true;
            _cacheAt = cache.cachedAt;
            _filtro = 'todos';
            _seleccion.clear();
            _cargando = false;
            _error = null;
          });
          // Jornada 2 · 1.35: la misma carga local de
          // visitas que en la pintura de primer frame —
          // el chip de candidato también vive en esta
          // vía de caché.
          _cargarVisitasLista(cache.lista);
          return;
        }
      }
      setState(() {
        _error = e is InvitadoError
            ? e.mensaje
            : 'Sin conexión o error del servidor.';
        _cargando = false;
      });
    }
  }

  /// 1.32 (H-B5-2): el cierre de conversiones en SEGUNDO
  /// PLANO (ver _cargar): la escritura de confirmación no
  /// lleva timeout a propósito y jamás espera en el camino de
  /// pintado. Si confirma alguna, la lista se recarga (sin
  /// re-verificar) para reflejar al convertido; la guarda de
  /// generación descarta el aterrizaje si la carga que lo
  /// lanzó ya fue superada.
  Future<void> _verificarConversionesEnFondo(int gen) async {
    int confirmadas = 0;
    try {
      confirmadas = await _svc.verificarConversiones();
    } catch (_) {}
    if (confirmadas <= 0) return;
    if (!mounted || gen != _cargaGen) return;
    await _cargar(verificar: false);
  }

  /// 1.29 (FB-05 · D-B1-05): el conteo de reportes Plus por
  /// atender, en SEGUNDO PLANO tras pintar la lista (antes
  /// _cargar lo esperaba y la pantalla quedaba en «cargando»
  /// con la lista ya disponible). Best-effort con la semántica
  /// de siempre: si la lectura falla, el conteo queda en null
  /// y la insignia no sale. La guarda de generación descarta
  /// el aterrizaje de una carga ya superada.
  Future<void> _actualizarConteoReportes(int gen) async {
    int? n;
    try {
      final fuente = conteoReportesPlusParaTest;
      n = fuente != null
          ? await fuente()
          : (await PlusReportesService().pendientes()).length;
    } catch (_) {
      n = null;
    }
    if (!mounted || gen != _cargaGen) return;
    setState(() => _reportesPlusPendientes = n);
  }

  String? _badgeLocal(ConversionInvitado? c) {
    if (c == null) return null;
    switch (c.estado) {
      case EstadoConversion.preparada:
        // v1.12.0 (B5): wording del veredicto.
        return 'Conversión en curso';
      case EstadoConversion.opEncolada:
        // 1.31 (Yunque A): con un fallo de confirmación ya
        // registrado, la insignia dice el problema, no un
        // genérico «en curso».
        return confirmacionConversionPendiente(c)
            ? 'Conversión pendiente de confirmar'
            : 'Conversión en curso (pendiente de sincronizar)';
      case EstadoConversion.confirmada:
        return 'Convertido desde este teléfono';
      case EstadoConversion.opRechazada:
        return 'Inscripción rechazada';
      case EstadoConversion.cancelada:
        return null;
    }
  }

  /// 1.25 T119 (F3-19): etiqueta de un chip de filtro con su
  /// conteo del servidor («Plus · 5»). Sin conteo conocido
  /// (caducados/convertidos aún sin enviar por el servidor)
  /// el chip va con su nombre a secas.
  String _etiquetaChip(({String id, String etiqueta}) f) {
    final c = _conteos;
    if (c == null) return f.etiqueta;
    final n = switch (f.id) {
      'todos' => c.total,
      'solicitudes' => c.solicitudes,
      'nuevos' => c.nuevos,
      'por_expirar' => c.porExpirar,
      'caducados' => c.caducados,
      'plus' => c.plus,
      'plus_por_vencer' => c.plusPorVencer,
      'convertidos' => c.convertidos,
      _ => null,
    };
    return n == null ? f.etiqueta : '${f.etiqueta} · $n';
  }

  /// 1.25 T87: conteos de visitas de la lista cargada
  /// (best-effort, en segundo plano): la insignia de
  /// candidato se ve SIN abrir cada invitado.
  Future<void> _cargarVisitasLista(
      List<InvitadoResumen> lista) async {
    try {
      final umbral = await umbralVisitasInvitado();
      final mapa = <String, int>{};
      for (final inv in lista) {
        if (inv.convertido) continue;
        final n = await conteoVisitasInvitadoPorId(inv.id);
        if (n > 0) mapa[inv.id] = n;
      }
      if (!mounted || !identical(_lista, lista)) return;
      setState(() {
        _visitasLista = mapa;
        _umbralLista = umbral;
      });
    } catch (_) {}
  }

  // 1.28 (M4-B2): invitado cuya conversión arrancó desde
  // la lista (guarda de un solo vuelo: el toque en el chip
  // no apila dos preparaciones).
  String? _convirtiendoId;

  /// 1.28 (M4-B2): «convertir en un toque» desde la lista:
  /// el chip de candidato abre el MISMO flujo que el
  /// detalle (prepararConversion → Inscribir con los datos
  /// del invitado), sin pasar por la pantalla de detalle.
  /// Guardas en el mismo orden que _convertir del detalle
  /// y el caducado se extiende antes. Desde 1.35 (campo
  /// nº 14 de Clientes) sin conexión se convierte con el
  /// detalle en caché y preparación local.
  Future<void> _convertirDesdeLista(InvitadoResumen inv) async {
    // Lote 1.35 (SL-1 · A-17, BLOQUEANTE): la guarda se activa
    // en la PRIMERA línea, antes de cualquier await y del
    // diálogo. Antes solo se activaba tras el diálogo y la
    // lectura de caché de la rama offline: dos toques rápidos
    // pasaban la guarda (aún null), abrían dos flujos y nacían
    // dos conversiones del mismo invitado. La liberación va en
    // finally: ningún camino de salida la deja puesta.
    if (_convirtiendoId != null) return;
    setState(() => _convirtiendoId = inv.id);
    try {
      await _convertirDesdeListaFlujo(inv);
    } finally {
      if (mounted) setState(() => _convirtiendoId = null);
    }
  }

  Future<void> _convertirDesdeListaFlujo(InvitadoResumen inv) async {
    // 1.35 (campo nº 14 de Clientes): sin conexión también
    // se convierte, con el detalle guardado en caché (el
    // mismo flujo sin red del detalle). Sin caché no hay
    // datos del invitado en el teléfono y no se inventan.
    if (_offline) {
      final cache = await _svc.leerDetalleCache(inv.id);
      if (!mounted) return;
      if (cache == null) {
        mostrarSnack(
            context,
            'Sin conexión y sin datos guardados de este '
            'invitado: ábrelo una vez con conexión antes de '
            'convertirlo.',
            significado: SignificadoChip.alerta);
        return;
      }
      final det = cache.detalle;
      if (det.caducado) {
        mostrarSnack(
            context,
            'Este invitado está caducado: extiende su vida antes '
            'de convertirlo.',
            significado: SignificadoChip.alerta);
        return;
      }
      final ok = await DialogoApp.confirmar(
        context,
        titulo: 'Convertir sin conexión',
        mensaje: 'Se convierte ahora en este teléfono y el '
            'acceso a su app se crea cuando haya conexión.',
        aceptar: 'Convertir',
        cancelar: 'Ahora no',
        icono: Icons.person_add_rounded,
      );
      if (ok != true || !mounted) return;
      // A-17: sin setState propio — la guarda ya la activó
      // _convertirDesdeLista al entrar y la libera su finally.
      final datos = await _svc.prepararConversionLocal(det);
      if (!mounted) return;
      await Navigator.of(context).push(RutaIron(
        builder: (_) => InscribirScreen(conversion: datos),
      ));
      await _cargar();
      return;
    }
    if (inv.caducado) {
      mostrarSnack(
          context,
          'Este invitado está caducado: extiende su vida antes '
          'de convertirlo.',
          significado: SignificadoChip.alerta);
      return;
    }
    // A-17: la guarda ya va activa desde _convertirDesdeLista.
    try {
      final detalle = await _svc.detalle(inv.id);
      if (!mounted) return;
      if (detalle.caducado) {
        mostrarSnack(
            context,
            'Este invitado está caducado: extiende su vida antes '
            'de convertirlo.',
            significado: SignificadoChip.alerta);
        return;
      }
      final datos = await _svc.prepararConversion(detalle);
      if (!mounted) return;
      await Navigator.of(context).push(RutaIron(
        builder: (_) => InscribirScreen(conversion: datos),
      ));
      await _cargar();
    } on InvitadoError catch (e) {
      if (mounted) {
        mostrarSnack(context, e.mensaje,
            significado: SignificadoChip.error);
      }
    } catch (_) {
      if (mounted) {
        mostrarSnack(
            context, 'No se pudo abrir la conversión. '
            'Revisa la conexión.',
            significado: SignificadoChip.error);
      }
    }
    // A-17: la guarda la libera el finally de
    // _convertirDesdeLista, único dueño del ciclo.
  }

  /// Barra inferior del modo selección: SOLO las tres acciones de
  /// lote del diseño (Plus = dueño; vida = staff). Jamás convertir,
  /// ajustar clave ni eliminar en masa.
  Widget _barraLote() {
    final esDueno = AuthService().isOwner;
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 8,
              offset: const Offset(0, -2)),
        ],
      ),
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.sm, vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (esDueno)
            TextButton.icon(
              onPressed: () => _confirmarLote('plus_cortesia'),
              icon: const Icon(Icons.star_rounded, size: 18),
              label: const Text('Dar Plus'),
            ),
          if (esDueno)
            TextButton.icon(
              onPressed: () => _confirmarLote('plus_quitar'),
              icon: const Icon(Icons.star_border_rounded, size: 18),
              label: const Text('Quitar Plus'),
            ),
          TextButton.icon(
            onPressed: () => _confirmarLote('vida_extender'),
            icon: const Icon(Icons.event_available_rounded, size: 18),
            label: const Text('Extender vida'),
          ),
        ],
      ),
    );
  }

  /// Hoja de confirmación del lote con auto-exclusión EXPLICADA
  /// (diseño §4): los no aplicables se listan con nombre y motivo
  /// y NO bloquean al resto.
  Future<void> _confirmarLote(String accion) async {
    final seleccionados = [
      for (final inv in _lista)
        if (_seleccion.contains(inv.id)) inv,
    ];
    if (seleccionados.isEmpty) return;
    // 1.22 IG-01: el lote ve también las conversiones locales.
    final parte =
        partirLote(seleccionados, accion, locales: _locales);
    final aplicables = parte.aplicables;
    final excluidos = parte.excluidos;
    // 136-700: con 0 destinatarios aplicables el diálogo
    // de lote NO se abre (antes se abría vacío y el
    // descarte era silencioso).
    if (aplicables.isEmpty) {
      mostrarSnack(context,
          'Ninguno de los seleccionados admite esta acción.',
          significado: SignificadoChip.alerta);
      return;
    }
    final params = await showDialog<({int dias, String motivo})>(
      context: context,
      builder: (_) => _DialogoLote(
        accion: accion,
        aplicables: aplicables,
        excluidos: excluidos,
      ),
    );
    if (params == null || !mounted || aplicables.isEmpty) return;
    await _ejecutarLote(
      ids: [for (final i in aplicables) i.id],
      accion: accion,
      dias: params.dias,
      motivo: params.motivo,
      nombres: {for (final i in _lista) i.id: i.nombre},
    );
  }

  Future<void> _ejecutarLote({
    required List<String> ids,
    required String accion,
    required int dias,
    required String motivo,
    required Map<String, String> nombres,
  }) async {
    ResultadoLote? res;
    String? error;
    try {
      res = await _loteInvitados.ejecutar(
        _svc,
        ids: ids,
        accion: accion,
        dias: accion == 'plus_quitar' ? null : dias,
        motivo: motivo.isEmpty ? null : motivo,
      );
    } catch (e) {
      error = e is InvitadoError
          ? e.mensaje
          : 'No se pudo aplicar el lote.';
    }
    if (!mounted) return;
    if (error != null || res == null) {
      mostrarSnack(context, error ?? 'Sin respuesta.', significado: SignificadoChip.error);
      return;
    }
    // v1.12.0 (E4): el resumen se persiste en SQLite ANTES de
    // pintarlo, para que sobreviva a muerte del proceso.
    try {
      await LocalDb.instance.guardarResultadoLote(
        loteId: _loteInvitados.opIdActual,
        accion: accion,
        resultadoJson: jsonEncode({
          'accion': res.accion,
          'aplicados': res.aplicados,
          'omitidos': res.omitidos,
          'fallidos': res.fallidos,
          'repetida': res.repetida,
          'items': [
            for (final it in res.items)
              {
                'id': it.id,
                'ok': it.ok,
                'codigo': it.codigo,
                'motivo': it.motivo,
                'plus_hasta': it.plusHasta?.toIso8601String(),
                'caduca_en': it.caducaEn?.toIso8601String(),
              },
          ],
        }),
      );
    } catch (_) {}
    // Los fallidos quedan seleccionados para reintento (con op_id
    // NUEVO, G4.3: la respuesta ya consumió la intención).
    final fallidos = {
      for (final it in res.items)
        if (!it.ok && it.codigo == 'error') it.id,
    };
    setState(() {
      _seleccion
        ..clear()
        ..addAll(fallidos);
    });
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _DialogoResultadoLote(res: res!, nombres: nombres),
    );
    if (mounted) _cargar();
  }

  /// v1.12.0 (F1): limpiar caducados en un toque. NO es un lote:
  /// una sola RPC del dueño (`invitados_purgar_vencidos`, contrato
  /// servidor 59f2ffd) que purga las cuentas vencidas; las ya
  /// convertidas se conservan 90 días desde la conversión. La
  /// confirmación previa explica el alcance con el conteo.
  Future<void> _limpiarCaducados() async {
    // Lote 1.35 (SL-1 · A-18): la RPC purga TODOS los vencidos
    // del servidor, no la página visible (≤50): confirmar con
    // el conteo de la vista era confirmar 3 y purgar 7. El
    // diálogo pide el TOTAL fresco al servidor (resumen) y lo
    // muestra antes de confirmar; si la lectura falla, manda
    // el último conteo conocido de cabecera. Sin total fiable
    // NO se purga: confirmar un número menor que el real es
    // el defecto, no un detalle de forma.
    var total = _conteos?.caducados;
    try {
      final fresco = await _svc.resumen();
      if (fresco?.caducados != null) total = fresco!.caducados;
    } catch (_) {
      // Sin lectura fresca: manda el conteo conocido.
    }
    if (!mounted) return;
    if (total == null) {
      mostrarSnack(
          context,
          'No se pudo confirmar cuántos caducados hay en el '
          'servidor: la limpieza purga TODOS, no solo los que '
          'ves. Revisa la conexión e inténtalo de nuevo.',
          significado: SignificadoChip.error);
      return;
    }
    final n = total;
    final conBusqueda = _busqueda.isNotEmpty;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Limpiar caducados'),
        content: Text(
          'Se eliminarán las $n cuentas de invitado caducadas '
          'que hay en el servidor (en esta vista se ven '
          '${_listaVisible.length}). La limpieza alcanza a '
          'todas, también a las que no están cargadas aquí.'
          '${conBusqueda ? '\n\nOjo: tienes una búsqueda activa, '
              'pero la purga es global: no se limita a lo que '
              'ves.' : ''}\n\nLas ya convertidas en clientes '
          'se conservan 90 días desde su conversión y no se tocan '
          'aquí. Esta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Limpiar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final res = await _svc.purgarVencidos();
      if (!mounted) return;
      // Yunque R3-M6-7c: ok:false (p. ej. respuesta malformada
      // del servidor) no es «limpieza completada con 0»: es
      // fallo y se dice como tal, sin diálogo de éxito.
      if (!res.ok) {
        mostrarSnack(context,
            'No se pudo confirmar la limpieza. Revisa la '
            'conexión e inténtalo de nuevo.',
            significado: SignificadoChip.error);
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Limpieza completada'),
          content: Text(
            res.purgados > 0
                ? 'Se eliminaron ${res.purgados} cuentas de '
                    'invitado caducadas.'
                : 'No quedaba ninguna cuenta caducada por eliminar.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Entendido'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      mostrarSnack(context, e is InvitadoError
              ? e.mensaje
              : 'No se pudo limpiar los caducados.', significado: SignificadoChip.error);
      return;
    }
    if (mounted) _cargar();
  }

  /// Acciones de la cabecera (información pública y actualizar):
  /// en la AppBar en modo pantalla y en una fila propia en modo
  /// embebido, para no perder ninguna función al integrar la
  /// bandeja como pestaña de «Usuarios» (v1.6.0).
  List<Widget> _acciones(bool esAdmin) {
    return [
      if (esAdmin)
        IconButton(
          tooltip: 'Información pública de la app',
          icon: const Icon(Icons.public_rounded),
          onPressed: () => Navigator.of(context).push(
            RutaIron(builder: (_) => const InfoPublicaScreen()),
          ),
        ),
      IconButton(
        tooltip: 'Actualizar',
        icon: const Icon(Icons.refresh_rounded),
        onPressed: _cargando ? null : _cargar,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final esAdmin = AuthService().isAdmin;
    final cuerpo = Column(
      children: [
        // 1.35 (campo nº 13): embebida en el pilar, sin
        // banda — el estado de sync lo dice una sola vez
        // la píldora de la cabecera de la app.
        if (!widget.embebido) const SyncBanner(compact: true),
        if (_offline)
          Container(
            width: double.infinity,
            color: AppColores.alerta.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg, vertical: AppEspacio.sm),
            child: Text(
              '📴 Sin conexión · datos de hace '
              '${_cacheAt != null ? hace(_cacheAt) : 'un rato'} · '
              // Jornada 1.35: también aquí la conversión
              // vive sin conexión (chip de candidato o el
              // detalle); la banda lo nombra, como la del
              // detalle.
              'solo lectura (conversión disponible)',
              style: AppTexto.secundario.copyWith(
                  color: AppColores.alertaOscuro,
                  fontWeight: FontWeight.w600),
            ),
          ),
        if (_modoSeleccion && !_offline)
          Container(
            width: double.infinity,
            color: AppColores.naranja.withValues(alpha: 0.12),
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.lg, vertical: AppEspacio.xs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_seleccion.length} seleccionado(s)',
                    style: AppTexto.secundario
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    // 136-700: el tope de 50 cuenta la
                    // selección PREVIA (antes: 30 previos +
                    // 50 cargados = 80).
                    final hueco = 50 - _seleccion.length;
                    if (hueco > 0) {
                      _seleccion.addAll([
                        for (final i in _listaVisible.take(hueco))
                          i.id,
                      ]);
                    }
                  }),
                  child: const Text('Seleccionar los cargados'),
                ),
                IconButton(
                  tooltip: 'Salir de la selección',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: _limpiarSeleccion,
                ),
              ],
            ),
          ),
        if (widget.embebido)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Registros desde la app de clientes: atiende '
                    'solicitudes y convierte invitados en clientes.',
                    style: AppTexto.secundario,
                  ),
                ),
                ..._acciones(esAdmin),
              ],
            ),
          ),
        if (!_offline)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
            child: Row(
              children: [
                for (final f in _filtros) ...[
                  ChoiceChip(
                    // 1.25 T119 (F3-19): el chip lleva su
                    // conteo dentro — la línea de conteos
                    // tappable duplicaba esta misma
                    // navegación y ocupaba otra fila.
                    label: Text(_etiquetaChip(f)),
                    selected: _filtro == f.id,
                    onSelected: (_) {
                      setState(() {
                        _filtro = f.id;
                        _seleccion.clear();
                        // 1.36 H-B3 (136-707): la búsqueda
                        // no sobrevive en silencio al cambio
                        // de filtro (parecía que el filtro
                        // nuevo estaba vacío).
                        _busqueda = '';
                        _busquedaCtrl.clear();
                      });
                      _cargar();
                    },
                  ),
                  const SizedBox(width: AppEspacio.sm),
                ],
              ],
            ),
          ),
        // v1.12.0 (A): buscador + orden sobre la página cargada.
        // 1.36 H-B3 (136-707): el campo se CONSERVA durante los
        // refrescos (antes desaparecía con _cargando y la
        // búsqueda activa quedaba invisible).
        if (!_offline)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, 0),
            // 1.36 H-B2 (136-704): en pantallas estrechas la
            // fila buscador/orden se APILA (el selector de
            // 184 px dejaba el buscador ilegible).
            child: LayoutBuilder(
              builder: (ctxFila, cons) {
                final estrecha = cons.maxWidth < 560;
                final buscador = TextField(
                    controller: _busquedaCtrl,
                    decoration: InputDecoration(
                      // F3-19: la búsqueda es sobre la página
                      // cargada; el hint lo dice.
                      hintText: 'Buscar en los cargados (nombre o teléfono)',
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      border: const OutlineInputBorder(),
                      isDense: true,
                      // 1.36 H-B3 (136-707): limpiar la
                      // búsqueda desde el propio campo.
                      suffixIcon: _busqueda.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close_rounded,
                                  size: 18),
                              tooltip: 'Limpiar búsqueda',
                              onPressed: () => setState(() {
                                _busqueda = '';
                                _busquedaCtrl.clear();
                                _seleccion.clear();
                              }),
                            ),
                    ),
                    // 1.36 H-B2 (136-700): cambiar la
                    // búsqueda limpia la selección (el
                    // filtro ya lo hacía).
                    onChanged: (v) => setState(() {
                          _busqueda = v;
                          _seleccion.clear();
                        }),
                );
                // DIS-05 (corrección): el botón del SDK se
                // medía por su contenido; el campo cerrado de
                // la casa (InputDecorator) exige ancho finito
                // dentro de un Row — se acota al ancho de su
                // etiqueta más larga («Orden del servidor»)
                // junto al buscador expandido.
                final selector = SizedBox(
                  width: estrecha ? double.infinity : 184,
                  child: SelectorIron<String>(
                    valor: _orden,
                    tituloPanel: 'Ordenar por',
                    opciones: const [
                      OpcionSelector('servidor', 'Orden del servidor'),
                      OpcionSelector('nombre', 'Nombre A–Z'),
                      OpcionSelector('registro', 'Registro reciente'),
                      OpcionSelector('caduca', 'Caduca antes'),
                    ],
                    alCambiar: (v) =>
                        setState(() => _orden = v ?? 'servidor'),
                  ),
                );
                if (estrecha) {
                  return Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.stretch,
                    children: [
                      buscador,
                      const SizedBox(height: AppEspacio.sm),
                      selector,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: buscador),
                    const SizedBox(width: AppEspacio.sm),
                    selector,
                  ],
                );
              },
            ),
          ),
        // v1.12.0 (C5): enlace a los reportes Plus por atender (solo
        // si hay pendientes; sin red o sin pendientes no se pinta).
        if (!_offline &&
            (_reportesPlusPendientes ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.star_rounded, size: 18),
                label: Text('Reportes Plus por atender '
                    '($_reportesPlusPendientes)'),
                onPressed: () => Navigator.of(context).push(
                  RutaIron(
                      builder: (_) => const ReportesPlusScreen()),
                ),
              ),
            ),
          ),
        // v1.12.0 (F1): limpiar caducados en un toque (solo dueño,
        // solo con el filtro de caducados a la vista). La acción va
        // por la MISMA RPC atómica de lote (lote_id), no por bucle.
        if (!_offline &&
            AuthService().isOwner &&
            _filtro == 'caducados' &&
            _listaVisible.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.cleaning_services_rounded,
                    size: 18),
                // 1.36 H-B3 (136-705): SIN número — la purga
                // es GLOBAL en el servidor y el conteo visible
                // (filtrado) mentía el alcance real.
                label: const Text('Limpiar caducados'),
                onPressed: _limpiarCaducados,
              ),
            ),
          ),
        // v1.12.0 (G3): entrada suave transversal.
        // 1.36 H-B3 (136-706): los estados (carga/error/vacío/
        // lista) cruzan con AnimatedSwitcher en vez de
        // sustituirse en seco, y la barra de lote entra/sale
        // con AnimatedSize (sin salto vertical).
        Expanded(
          child: AnimatedSwitcher(
            duration: AppMovimiento.media,
            child: KeyedSubtree(
              key: ValueKey(_cargando && _lista.isEmpty
                  ? 'cargando'
                  : _error != null
                      ? 'error'
                      : _listaVisible.isEmpty
                          ? 'vacio'
                          : 'lista'),
              child: FadeEntrada(child: _cuerpo()),
            ),
          ),
        ),
        AnimatedSize(
          duration: AppMovimiento.media,
          alignment: Alignment.topCenter,
          child: (_modoSeleccion && !_offline)
              ? _barraLote()
              : const SizedBox.shrink(),
        ),
      ],
    );
    if (widget.embebido) return cuerpo;
    return Scaffold(
      appBar: appBarIron(
        context,
        'Invitados',
        acciones: _acciones(esAdmin),
      ),
      body: cuerpo,
    );
  }

  Widget _cuerpo() {
    if (_cargando && _lista.isEmpty) {
      // 1.36 H-B3 (136-706): la carga inicial pinta el
      // esqueleto de tarjetas de la casa, no un spinner
      // aislado. Con lista ya pintada, el refresco la
      // conserva (no vuelve al esqueleto).
      return const Padding(
        padding: EdgeInsets.all(AppEspacio.lg),
        child: SkeletonLista(items: 4),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColores.alerta),
              const SizedBox(height: AppEspacio.md),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'La bandeja de invitados vive en el servidor: '
                'necesita conexión.',
                textAlign: TextAlign.center,
                style: AppTexto.secundario,
              ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                  texto: 'Reintentar',
                  icono: Icons.refresh_rounded,
                  onPressed: _cargar),
            ],
          ),
        ),
      );
    }
    if (_listaVisible.isEmpty) {
      // 1.28 (M4-C4): el vacío pasa del texto plano al
      // patrón EstadoVacio de la casa (icono, título,
      // subtítulo y, si la vista es un filtro, la acción
      // que lo deshace).
      // 1.36 H-B3 (136-705): con búsqueda activa, el vacío
      // ofrece LIMPIARLA (antes ni «Ver todos» la limpiaba y
      // la vista parecía vacía sin salida).
      final conBusqueda = _busqueda.trim().isNotEmpty;
      return EstadoVacio(
        ilustracion: 'assets/vacio_recepcion.webp',
        icono: Icons.people_outline_rounded,
        titulo: 'No hay invitados en esta vista',
        subtitulo: conBusqueda
            ? 'Nada coincide con «${_busqueda.trim()}» en los '
                'cargados.'
            : 'Los registros nuevos desde la app de '
                'clientes aparecen aquí.',
        textoAccion: conBusqueda
            ? 'Limpiar búsqueda'
            : (_filtro != 'todos' ? 'Ver todos' : null),
        onAccion: conBusqueda
            ? () => setState(() {
                  _busqueda = '';
                  _busquedaCtrl.clear();
                  _seleccion.clear();
                })
            : (_filtro != 'todos'
                ? () {
                    setState(() {
                      _filtro = 'todos';
                      _busqueda = '';
                      _busquedaCtrl.clear();
                    });
                    _cargar();
                  }
                : null),
      );
    }
    final visible = _listaVisible;
    final filtrado = visible.length != _lista.length;
    final letras = _indiceLetras;
    return Column(
      children: [
        if (filtrado)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${visible.length} de ${_lista.length} cargados',
                style: AppTexto.secundario,
              ),
            ),
          ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: RefrescoIron(
                  onRefresh: _cargar,
                  child: ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    itemCount: visible.length,
                    itemBuilder: (ctx, i) {
                      final inv = visible[i];
                      final badge = _badgeLocal(_locales[inv.id]);
                      // v1.12.0 (B3/B4): estado del convertido por el
                      // resolver (3 estados, nunca «eliminado» falso).
                      final estConv = inv.convertido
                          ? _estadoConvertidoLista(inv)
                          : null;
          final seleccionado = _seleccion.contains(inv.id);
          void alternar() => setState(() {
                if (seleccionado) {
                  _seleccion.remove(inv.id);
                } else if (_seleccion.length < 50) {
                  _seleccion.add(inv.id);
                } else {
                  mostrarSnack(context, 'Máximo 50 invitados por lote.', significado: SignificadoChip.alerta);
                }
              });
          return Padding(
            // F3-30: la primera tarjeta lleva la llave de
            // medición del salto por letra.
            // 1.36 H-B3 (136-706): cada fila lleva ADEMÁS su
            // clave estable por id (la de medición envuelve).
            key: i == 0 ? _primeraTarjetaKey : _claveTarjeta(inv.id),
            padding: const EdgeInsets.only(bottom: AppEspacio.sm),
            child: GestureDetector(
              onLongPress: _offline ? null : alternar,
              child: Tarjeta(
              color: seleccionado
                  ? AppColores.naranja.withValues(alpha: 0.07)
                  : null,
              onTap: () async {
                if (_offline) {
                  mostrarSnack(context, 'Sin conexión: el detalle no está '
                              'disponible en modo lectura.', significado: SignificadoChip.error);
                  return;
                }
                if (_modoSeleccion) {
                  alternar();
                  return;
                }
                await Navigator.of(context).push(RutaIron(
                  builder: (_) =>
                      InvitadoDetalleScreen(invitadoId: inv.id),
                ));
                if (mounted) _cargar();
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (_modoSeleccion)
                        Checkbox(
                          value: seleccionado,
                          onChanged: (_) => alternar(),
                        )
                      else
                        Icon(Icons.person_outline_rounded,
                            color: AppColores.textoSecundario(context)),
                      const SizedBox(width: AppEspacio.sm),
                      Expanded(
                        child: Text(inv.nombre,
                            style: AppTexto.subtitulo,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (inv.tieneSolicitudPendiente)
                        const Icon(Icons.mark_email_unread_rounded,
                            color: AppColores.alerta),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '📱 ${inv.telefono} · registrado '
                    '${inv.creadoEn != null ? hace(inv.creadoEn) : '—'}',
                    style: AppTexto.secundario,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      if (inv.tieneSolicitudPendiente)
                        _chip('🙋 Quiere inscribirse',
                            AppColores.alerta),
                      // v1.8.0: pastilla de rango. Jerarquía:
                      // Convertido > En conversión > PLUS > regular
                      // (sin pastilla: la ausencia ES la señal).
                      if (inv.convertido)
                        _chip('✓ Convertido', AppColores.exitoOscuro)
                      else if (inv.enConversion)
                        _chip('En conversión', AppColores.infoOscuro)
                      else if (inv.plusActivo)
                        _chip('⭐ PLUS', _doradoPlus)
                      else if (inv.caducado)
                        _chip('Caducado', AppColores.error)
                      else if (inv.caducaPronto)
                        _chip(
                            'Caduca en ${inv.diasRestantes} día(s)',
                            AppColores.alertaOscuro),
                      if (badge != null)
                        _chip(badge, AppColores.infoOscuro),
                      // 1.25 T87: las visitas y el
                      // candidato se ven en la lista, no
                      // solo dentro del detalle.
                      if (!inv.convertido &&
                          (_visitasLista[inv.id] ?? 0) > 0) ...[
                        if ((_visitasLista[inv.id] ?? 0) >=
                            _umbralLista)
                          // 1.28 (M4-B2): el chip de
                          // candidato ES el botón: un toque
                          // abre la conversión (el flujo del
                          // detalle), sin entrar a la ficha
                          // del invitado. En conversión no se
                          // ofrece (ya tiene su camino).
                          if (!inv.enConversion)
                            // 1.36 H-B3 (136-705): el chip ES un
                            // botón — lleva semántica de botón y
                            // su estado de carga se anuncia.
                            Semantics(
                              button: true,
                              enabled: _convirtiendoId != inv.id,
                              label: _convirtiendoId == inv.id
                                  ? 'Preparando conversión'
                                  : 'Convertir candidato a cliente',
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: _convirtiendoId == inv.id
                                    ? null
                                    : () => _convertirDesdeLista(inv),
                                child: _chip(
                                    _convirtiendoId == inv.id
                                        ? '⭐ Preparando conversión…'
                                        : '⭐ Candidato a cliente · '
                                            'Convertir',
                                    _doradoPlus),
                              ),
                            )
                          else
                            _chip('⭐ Candidato a cliente',
                                _doradoPlus),
                        _chip(
                            '👣 ${_visitasLista[inv.id]} visitas (30 días)',
                            AppColores.infoOscuro),
                      ],
                      // v1.12.0 (B3/B4): estado del convertido por el
                      // resolver (3 estados). NUNCA «eliminado» por
                      // retraso del espejo: sin fila y sin registro
                      // de baja es «sincronizando ficha».
                      if (estConv != null) ...[
                        if (estConv.estado ==
                            EstadoConvertido.eliminado)
                          _chip('Cliente eliminado',
                              AppColores.error)
                        else if (estConv.estado ==
                            EstadoConvertido.sincronizandoFicha)
                          _chip('Sincronizando ficha',
                              AppColores.infoOscuro),
                      ],
                    ],
                  ),
                  // v1.12.0 (B3/B4): la línea del convertido según su
                  // estado (sin enlace roto cuando fue eliminado).
                  if (inv.convertido) ...[
                    const SizedBox(height: 4),
                    Text(
                      switch (estConv?.estado) {
                        EstadoConvertido.eliminado =>
                          'Cliente eliminado'
                          '${estConv!.eliminadoEn != null ? ' el ${fechaAbsoluta(parseFecha(estConv.eliminadoEn))}' : ''}',
                        EstadoConvertido.sincronizandoFicha =>
                          'Convertido (sincronizando ficha...)',
                        _ =>
                          'Convertido'
                          '${inv.convertidoEn != null ? ' el ${fechaAbsoluta(inv.convertidoEn)}' : ''}'
                          '${inv.clienteId != null ? ' · Cliente #${inv.clienteId}' : ''}',
                      },
                      style: AppTexto.secundario,
                    ),
                  ],
                  // v1.8.0: línea Plus (el residual de un convertido
                  // NO se pinta: es inerte, diseño §2).
                  if (inv.plusActivo && !inv.convertido) ...[
                    const SizedBox(height: 4),
                    Text(
                      '⭐ Plus hasta el '
                      '${inv.plusHasta != null ? fmtFecha(inv.plusHasta!.toIso8601String()) : '—'}'
                      '${inv.plusDiasRestantes != null ? ' · quedan ${inv.plusDiasRestantes} día(s)' : ''}'
                      '${inv.plusOrigen != null ? ' · ${inv.plusOrigen == 'cortesia' ? 'cortesía' : 'pago'}' : ''}',
                      style: AppTexto.secundario.copyWith(
                        color: inv.plusPorVencer
                            ? AppColores.alertaOscuro
                            : _doradoPlus,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    // v1.12.0 (C2): aviso urgente a 3 días, distinto
                    // del filtro de exploración a 7 días.
                    if (inv.plusPorVencerPronto)
                      const SizedBox(height: 2),
                    if (inv.plusPorVencerPronto)
                      Text(
                        '⚠ El Plus vence en '
                        '${inv.plusDiasRestantes} día(s): avísale '
                        'antes de que se le acabe.',
                        style: AppTexto.secundario.copyWith(
                          color: AppColores.alertaOscuro,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ],
              ),
              ),
            ),
          );
        },
                    ),
                  ),
                ),
                // v1.12.0 (A): barra de letras discreta (patrón de
                // Buscar, Bloque 1): solo letras presentes; al tocar,
                // salta al primer invitado de esa letra (estimación
                // de alto de tarjeta, igual que en Buscar).
                if (letras.isNotEmpty)
                  SizedBox(
                    width: 22,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        for (final letra
                            in (letras.keys.toList()..sort()))
                          GestureDetector(
                            onTap: () => _saltarALetra(letra),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 1.5),
                              child: Text(
                                letra,
                                style: AppTexto.minuscula.copyWith(color: Colors.grey),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }

  /// Salta al primer invitado de la letra. F3-30: el paso es
  /// el alto MEDIDO de la primera tarjeta (con su margen); si
  /// aún no se midió, el estimado de 170. Las tarjetas varían
  /// con los chips: es una aproximación honesta, no exacta.
  void _saltarALetra(String letra) {
    final ctx0 = _primeraTarjetaKey.currentContext;
    final medida = ctx0?.size?.height;
    if (medida != null && medida > 0) _altoTarjeta = medida;
    final idx = _indiceLetras[letra];
    if (idx == null || !_scroll.hasClients) return;
    // 1.36 H-B3 (136-706): si la fila destino YA está
    // construida, ensureVisible la trae exacta (las tarjetas
    // varían de alto con los chips y la estimación aterrizaba
    // lejos); la estimación queda solo como respaldo.
    final visibles = _listaVisible;
    if (idx >= 0 && idx < visibles.length) {
      final destino = visibles[idx];
      final ctxDestino = idx == 0
          ? _primeraTarjetaKey.currentContext
          : _clavesTarjeta[destino.id]?.currentContext;
      if (ctxDestino != null) {
        Scrollable.ensureVisible(
          ctxDestino,
          duration: AppMovimiento.media,
          curve: Curves.easeOut,
          alignment: 0,
        );
        return;
      }
    }
    final max = _scroll.position.maxScrollExtent;
    _scroll.animateTo(
      (idx * _altoTarjeta).clamp(0.0, max),
      // 1.35 (UI-13): duración por el token.
      duration: AppMovimiento.media,
      curve: Curves.easeOut,
    );
  }
}

/// 1.36 (136-270): el chip de Invitados ES la primitiva
/// de la casa (ChipEstado), con el frente resuelto por
/// brillo a los papeles de texto — la pastilla artesanal
/// anterior ponía el color crudo como texto sobre su
/// propio tinte y fallaba el contraste en ambos temas
/// (1,96–3,50 en claro; 2,31–4,08 en oscuro).
Widget _chip(String texto, Color color) {
  return Builder(builder: (context) {
    final Color frente;
    if (color == AppColores.alerta || color == AppColores.alertaOscuro) {
      frente = AppColores.alertaTexto(context);
    } else if (color == AppColores.exitoOscuro) {
      frente = AppColores.exitoTexto(context);
    } else if (color == AppColores.infoOscuro) {
      frente = AppColores.infoTexto(context);
    } else if (color == AppColores.error) {
      frente = AppColores.errorTexto(context);
    } else if (color == _doradoPlus) {
      frente = AppColores.textoNaranja(context);
    } else {
      frente = color;
    }
    return ChipEstado.libre(texto: texto, color: frente);
  });
}

String _n(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

/// Auto-exclusión del lote (diseño §4): parte la selección en
/// aplicables y excluidos CON MOTIVO, para que la hoja de
/// confirmación lo explique con nombres. Los excluidos no
/// bloquean al resto. (La guardia real es el servidor; esto es
/// solo la explicación previa.)
({List<InvitadoResumen> aplicables, List<(InvitadoResumen, String)> excluidos})
    partirLote(List<InvitadoResumen> seleccion, String accion,
        {Map<String, ConversionInvitado> locales = const {}}) {
  final aplicables = <InvitadoResumen>[];
  final excluidos = <(InvitadoResumen, String)>[];
  for (final inv in seleccion) {
    // 1.22 IG-01: el estado LOCAL de conversión manda igual
    // que el del resumen del servidor. Sin esto, a un invitado
    // cuya inscripción ya estaba encolada en ESTE teléfono se
    // le podía quitar el Plus, y al subir la inscripción
    // perdía su Plus residual.
    final local = locales[inv.id];
    if (inv.convertido ||
        local?.estado == EstadoConversion.confirmada) {
      excluidos.add((inv, 'ya es cliente'));
    } else if ((inv.enConversion ||
            (local != null &&
                (local.estado == EstadoConversion.preparada ||
                    local.estado == EstadoConversion.opEncolada))) &&
        accion != 'vida_extender') {
      excluidos.add((inv, 'conversión en curso'));
    } else if (accion == 'plus_quitar' && !inv.plusActivo) {
      excluidos.add((inv, 'no tiene Plus activo'));
    } else if (accion == 'plus_cortesia' && inv.plusActivo) {
      // 1.28 (M4-A11/R1M4-B20): dar cortesía a quien YA tiene
      // Plus activo era aplicable en el lote (el detalle sí
      // lo impedía): la cortesía pisaba el Plus pagado.
      excluidos.add((inv, 'ya tiene Plus activo'));
    } else {
      aplicables.add(inv);
    }
  }
  return (aplicables: aplicables, excluidos: excluidos);
}

String tituloLote(String accion) => switch (accion) {
      'plus_cortesia' => 'Dar Plus de cortesía',
      'plus_quitar' => 'Quitar Plus',
      _ => 'Extender vida',
    };

/// Hoja de confirmación de una acción (individual o en lote):
/// presets de días cerrados (J2) y motivo OBLIGATORIO en las
/// acciones Plus (chips + texto corto).
class _DialogoLote extends StatefulWidget {
  final String accion;
  final List<InvitadoResumen> aplicables;
  final List<(InvitadoResumen, String)> excluidos;
  const _DialogoLote({
    required this.accion,
    required this.aplicables,
    required this.excluidos,
  });
  @override
  State<_DialogoLote> createState() => _DialogoLoteState();
}

class _DialogoLoteState extends State<_DialogoLote> {
  int _dias = 30;
  String? _motivoChip;
  final _motivoCtrl = TextEditingController();
  // v1.12.0 (F3): vida personalizada al extender (contrato
  // servidor 59f2ffd: vida_extender acepta 1–365 días). Si el
  // campo trae un número válido, manda sobre los presets.
  final _diasCtrl = TextEditingController();

  @override
  void dispose() {
    _motivoCtrl.dispose();
    _diasCtrl.dispose();
    super.dispose();
  }

  List<int> get _presets =>
      widget.accion == 'vida_extender' ? const [30, 90] : const [15, 30];
  bool get _motivoObligatorio => widget.accion != 'vida_extender';

  String get _motivo {
    final partes = [
      if (_motivoChip != null) _motivoChip!,
      _motivoCtrl.text.trim(),
    ].where((s) => s.isNotEmpty);
    return partes.join(': ');
  }

  /// v1.12.0 (F3): días efectivos — el personalizado (1–365) manda
  /// sobre el preset; vacío o inválido fuera de rango bloquea el
  /// botón (el servidor rechazaría fuera de 1–365 de todos modos).
  int get _diasEfectivos {
    final n = int.tryParse(_diasCtrl.text.trim());
    if (widget.accion == 'vida_extender' &&
        n != null &&
        n >= 1 &&
        n <= 365) {
      return n;
    }
    return _dias;
  }

  bool get _diasInvalido {
    final t = _diasCtrl.text.trim();
    if (widget.accion != 'vida_extender' || t.isEmpty) return false;
    final n = int.tryParse(t);
    return n == null || n < 1 || n > 365;
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.aplicables.length;
    return AlertDialog(
      title: Text(tituloLote(widget.accion)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(n == 1
                ? 'Para ${widget.aplicables.first.nombre}.'
                : 'Para $n invitado(s).'),
            if (widget.accion == 'plus_cortesia') ...[
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'Es una cortesía: sin pago registrado y NO da '
                'derecho a entrenar en el gym.',
                style: AppTexto.secundario,
              ),
            ],
            if (widget.accion == 'plus_quitar') ...[
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'El Plus se revoca desde ahora. El historial de '
                'pagos y reportes NO se toca.',
                style: AppTexto.secundario,
              ),
            ],
            if (widget.excluidos.isNotEmpty) ...[
              const SizedBox(height: AppEspacio.sm),
              Text(
                '${widget.excluidos.length} no aplica(n):',
                style: AppTexto.secundario
                    .copyWith(fontWeight: FontWeight.w600),
              ),
              for (final (inv, motivo) in widget.excluidos)
                Text('· ${inv.nombre} — $motivo',
                    style: AppTexto.secundario),
            ],
            if (widget.accion != 'plus_quitar') ...[
              const SizedBox(height: AppEspacio.md),
              const Text('Días', style: AppTexto.secundario),
              const SizedBox(height: AppEspacio.xs),
              Wrap(
                spacing: AppEspacio.sm,
                children: [
                  for (final d in _presets)
                    ChoiceChip(
                      label: Text('$d días'),
                      selected: _dias == d,
                      onSelected: (_) => setState(() => _dias = d),
                    ),
                ],
              ),
              // v1.12.0 (F3): días personalizados (1–365) solo al
              // extender vida; vacío = usa el preset elegido.
              if (widget.accion == 'vida_extender') ...[
                const SizedBox(height: AppEspacio.sm),
                TextField(
                  controller: _diasCtrl,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Días personalizados (1–365, opcional)',
                    // 136-703: el rango se valida EN el campo
                    // y el valor efectivo queda visible.
                    errorText: _diasInvalido
                        ? 'Entre 1 y 365 días'
                        : null,
                    helperText: _diasCtrl.text.trim().isEmpty
                        ? null
                        : 'Días efectivos: $_diasEfectivos',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ],
            const SizedBox(height: AppEspacio.md),
            Text(
                _motivoObligatorio
                    ? 'Motivo (obligatorio)'
                    : 'Motivo (opcional)',
                style: AppTexto.secundario),
            const SizedBox(height: AppEspacio.xs),
            Wrap(
              spacing: AppEspacio.sm,
              children: [
                for (final m in const [
                  'Cortesía',
                  'Promo',
                  'Compensación',
                  'Error mío',
                ])
                  ChoiceChip(
                    label: Text(m),
                    selected: _motivoChip == m,
                    onSelected: (sel) =>
                        setState(() => _motivoChip = sel ? m : null),
                  ),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            TextField(
              controller: _motivoCtrl,
              // 136-703: sin onChanged el botón Confirmar no
              // se enteraba de que el motivo ya existe.
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                hintText: 'Nota corta (opcional)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              maxLength: 80,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: n == 0 ||
                  (_motivoObligatorio && _motivo.isEmpty) ||
                  _diasInvalido
              ? null
              : () => Navigator.of(context)
                  .pop((dias: _diasEfectivos, motivo: _motivo)),
          child: const Text('Confirmar'),
        ),
      ],
    );
  }
}

/// Resultado del lote construido desde la RESPUESTA de la RPC:
/// aunque la recarga de la lista falle después, el dueño ve qué
/// pasó con cada invitado.
class _DialogoResultadoLote extends StatelessWidget {
  final ResultadoLote res;
  final Map<String, String> nombres;
  const _DialogoResultadoLote({required this.res, required this.nombres});

  @override
  Widget build(BuildContext context) {
    String nombreDe(ItemLote it) => nombres[it.id] ?? 'Invitado';
    return AlertDialog(
      title: Text('${tituloLote(res.accion)} — resultado'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '✅ ${res.aplicados} aplicado(s) · '
              '⏭ ${res.omitidos} omitido(s) · '
              '❌ ${res.fallidos} fallido(s)',
              style: AppTexto.secundario
                  .copyWith(fontWeight: FontWeight.w600),
            ),
            if (res.repetida)
              const Text(
                'Esta operación ya se había aplicado: se muestra '
                'el resultado original, sin duplicar.',
                style: AppTexto.secundario,
              ),
            const SizedBox(height: AppEspacio.sm),
            for (final it in res.items)
              Padding(
                padding: const EdgeInsets.only(bottom: AppEspacio.xs),
                child: Text(
                  it.ok
                      ? '✅ ${nombreDe(it)}'
                          '${it.plusHasta != null ? ' — Plus hasta el ${fmtFecha(it.plusHasta!.toIso8601String())}' : ''}'
                          '${it.caducaEn != null ? ' — caduca el ${fmtFecha(it.caducaEn!.toIso8601String())}' : ''}'
                      : '${it.codigo == 'error' ? '❌' : '⏭'} '
                          '${nombreDe(it)} — ${it.motivo ?? it.codigo}',
                  style: AppTexto.secundario,
                ),
              ),
            if (res.fallidos > 0)
              const Text(
                'Los fallidos quedan seleccionados para reintentar.',
                style: AppTexto.secundario,
              ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Entendido'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Detalle
// ---------------------------------------------------------------------------

class InvitadoDetalleScreen extends StatefulWidget {
  final String invitadoId;
  const InvitadoDetalleScreen({super.key, required this.invitadoId});
  @override
  State<InvitadoDetalleScreen> createState() =>
      _InvitadoDetalleScreenState();
}

/// F3-20: traducción del estado crudo del invitado a
/// lenguaje llano para la tarjeta de Datos.
/// Lote 1.35 (SL-1 · G12-7): la rama por defecto ya no
/// devuelve la clave cruda — un estado futuro se lee como
/// «Estado registrado», no como su nombre interno.
String _estadoLegibleInvitado(String estado) => switch (estado) {
      'activo' => 'Activo',
      'en_conversion' => 'Convirtiéndose en cliente',
      'convertido' => 'Ya es cliente',
      'caducado' => 'Caducado',
      _ => 'Estado registrado',
    };

/// Lote 1.35 (SL-1 · G12-7): traducción de una acción del
/// equipo sobre el invitado a lenguaje llano (la tarjeta
/// «Acciones del equipo»). La rama por defecto era la clave
/// cruda (`resetear_pin` y cualquier acción futura salían tal
/// cual a pantalla): ahora las conocidas tienen su texto y
/// las desconocidas se leen «Acción registrada».
String textoAccionStaffInvitado(AccionStaffInvitado a) {
  final motivo = a.detalle['motivo'] as String?;
  final dias = (a.detalle['dias'] as num?)?.toInt();
  final base = switch (a.accion) {
    'plus_cortesia' => '🎁 Dio Plus de cortesía'
        '${dias != null ? ' ($dias días)' : ''}',
    'plus_quitar' => '🚫 Quitó el Plus',
    'vida_extender' => '⏳ Extendió la vida'
        '${dias != null ? ' (+$dias días)' : ''}',
    'eliminar_invitado' => '🗑 Eliminó la cuenta',
    'resetear_pin' => '🔑 Restableció el PIN de acceso',
    'ajustar_clave' => '🔑 Ajustó la clave de acceso',
    'resetear_pin_cliente' => '🔑 Restableció el PIN de acceso',
    'revocar' => '🚫 Revocó el acceso',
    'reactivar' => '✅ Reactivó el acceso',
    _ => 'Acción registrada',
  };
  return '$base'
      '${a.actor != null ? ' · ${a.actor}' : ''}'
      '${a.fecha != null ? ' · ${fmtFecha(a.fecha!.toIso8601String())}' : ''}'
      '${motivo != null ? ' · «$motivo»' : ''}';
}

class _InvitadoDetalleScreenState extends State<InvitadoDetalleScreen> {
  // 1.32 (H-B5-1): la misma costura de test que la lista —
  // sin ella el detalle no se puede probar con RPC simulada.
  final _svcReal = InvitadosService();
  InvitadosService get _svc => servicioInvitadosParaTest ?? _svcReal;
  bool _cargando = true;
  bool _actuando = false;
  String? _error;
  InvitadoDetalle? _d;
  ConversionInvitado? _local;
  // v1.12.0 (B3/B4): estado del convertido por el resolver (3
  // estados) + fecha de la baja si se conoce. D5: detalle en caché
  // con marca de frescura cuando no hay conexión.
  EstadoConvertido? _estadoConvertido;
  String? _eliminadoEn;
  bool _offlineCache = false;
  DateTime? _cacheAt;
  // 1.23 (W7): visitas locales del invitado (ventana 30 días)
  // y el umbral de candidato vigente.
  int _visitas30 = 0;
  int _umbralVisitas = umbralVisitasDefecto;
  String _claveVisitas = '';
  // 1.28 (M4-A1/R2M4-H8): registro de visita en curso.
  bool _registrandoVisita = false;
  // 1.32 (H-B5-1): guarda de generación de la carga (la lista
  // ya la tenía; el detalle solo miraba mounted y una carga
  // vieja podía pintar sobre la nueva).
  int _cargaGen = 0;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar({bool verificar = true}) async {
    final gen = ++_cargaGen;
    setState(() {
      _cargando = true;
      _error = null;
    });
    // 1.32 (H-B5-2): como en la lista, el cierre de
    // conversiones va en segundo plano: su escritura de
    // confirmación (sin timeout a propósito) ya no espera en
    // el camino de pintado de la ficha del invitado.
    if (verificar) {
      unawaited(_verificarConversionesEnFondo(gen));
    }
    // 1.32 (H-B5-1): el detalle cacheado pinta en el primer
    // frame, en solo lectura con su marca de frescura (la
    // misma foto que el fallback del catch), y la RPC lo
    // sustituye al llegar. Antes la caché solo entraba tras
    // agotar el timeout de la RPC.
    var pintoCache = false;
    final cachePrevia = await _svc.leerDetalleCache(widget.invitadoId);
    if (!mounted || gen != _cargaGen) return;
    if (cachePrevia != null) {
      pintoCache = true;
      setState(() {
        _d = cachePrevia.detalle;
        _local = null;
        _estadoConvertido = null;
        _eliminadoEn = null;
        _offlineCache = true;
        _cacheAt = cachePrevia.cachedAt;
        _cargando = false;
        _error = null;
      });
    }
    try {
      final d = await _svc.detalle(widget.invitadoId);
      var local =
          await ConversionInvitadoStore().leer(widget.invitadoId);
      // G1(b): si este teléfono preparó la conversión y el
      // registro local se perdió (cierre entre la RPC y el
      // guardado), se adopta la preparación que ve el servidor.
      local ??= await _svc.adoptarConversionDelServidor(d);
      // G3: una preparación local cuyo lock venció (o que ya no
      // existe en el servidor) se cierra como cancelada: el
      // detalle no ofrecerá «Reanudar» con un uuid muerto y se
      // podrá preparar una conversión nueva.
      if (local != null) {
        local = await _svc.reconciliarPreparadaObsoleta(d, local);
      }
      // v1.12.0 (B3/B4): estado del convertido por el resolver.
      // El espejo de clientes puede traer la shell estado=
      // 'eliminado' (entonces se sella la baja en el registro
      // local) o no traer la fila (tombstone ya procesado: el
      // registro local es la única constancia que queda).
      EstadoConvertido? estadoConvertido;
      String? eliminadoEn;
      if (d.convertido && d.clienteId != null) {
        final clientes = await LocalDb.instance.allMirror('clientes');
        Map<String, dynamic>? fila;
        for (final c in clientes) {
          if ('${c['id']}' == '${d.clienteId}') {
            fila = c;
            break;
          }
        }
        if (fila != null && '${fila['estado'] ?? ''}' == 'eliminado') {
          await LocalDb.instance
              .registrarClienteEliminadoVisto(d.clienteId!);
        }
        final fechas =
            await LocalDb.instance.fechasClientesEliminados();
        final fecha = fechas[d.clienteId];
        final res = resolverEstadoConvertido(
          conversionEnCurso: local != null &&
              (local.estado == EstadoConversion.preparada ||
                  local.estado == EstadoConversion.opEncolada),
          filaCliente: fila,
          enRegistroEliminados: fecha != null,
          fechaRegistroEliminados: fecha,
        );
        estadoConvertido = res.estado;
        eliminadoEn = res.eliminadoEn;
      }
      if (!mounted || gen != _cargaGen) return;
      setState(() {
        _d = d;
        _local = local;
        _estadoConvertido = estadoConvertido;
        _eliminadoEn = eliminadoEn;
        _offlineCache = false;
        _cacheAt = null;
        _cargando = false;
      });
      // 1.23 (W7): conteo local de visitas (no bloquea la
      // ficha: se pinta cuando llega).
      _cargarVisitas(d);
    } catch (e) {
      if (!mounted || gen != _cargaGen) return;
      // 1.32 (H-B5-1): con la copia cacheada ya pintada en
      // solo lectura, el fallo al refrescar no tumba la
      // ficha: se queda la copia (el fallback de abajo
      // pintaría esa misma caché, tras el timeout).
      if (pintoCache) return;
      // v1.12.0 (D5): sin conexión, el detalle en caché se muestra
      // en SOLO LECTURA con su marca de frescura (nunca acciones).
      if (e is InvitadoError && e.codigo == 'RED') {
        final cache = await _svc.leerDetalleCache(widget.invitadoId);
        if (!mounted || gen != _cargaGen) return;
        if (cache != null) {
          setState(() {
            _d = cache.detalle;
            // 1.22 IG-05: el fallback offline limpia el estado
            // local de conversión (solo lectura de verdad: sin
            // una conversión local colgando de una carga vieja).
            _local = null;
            _estadoConvertido = null;
            _eliminadoEn = null;
            _offlineCache = true;
            _cacheAt = cache.cachedAt;
            _cargando = false;
            _error = null;
          });
          return;
        }
      }
      setState(() {
        _error = e is InvitadoError
            ? e.mensaje
            : 'Sin conexión o error del servidor.';
        _cargando = false;
      });
    }
  }

  /// 1.32 (H-B5-2): el cierre de conversiones en SEGUNDO
  /// PLANO (ver _cargar): si confirma alguna, la ficha se
  /// recarga (sin re-verificar) para reflejar al convertido.
  Future<void> _verificarConversionesEnFondo(int gen) async {
    int confirmadas = 0;
    try {
      confirmadas = await _svc.verificarConversiones();
    } catch (_) {}
    if (confirmadas <= 0) return;
    if (!mounted || gen != _cargaGen) return;
    await _cargar(verificar: false);
  }

  void _snack(String texto) {
    if (!mounted) return;
    mostrarSnack(context, texto);
  }

  Future<void> _whatsapp() async {
    final d = _d!;
    final num = normalizarTelefonoWaMe(d.telefono);
    if (num.isEmpty) {
      _snack('El teléfono del invitado no es válido para WhatsApp.');
      return;
    }
    // 1.36 H-B2 (136-701): el lanzamiento puede lanzar
    // (plataforma) además de devolver false — con captura
    // y snack, no excepción sin dueño.
    try {
      final ok = await launchUrl(Uri.parse('https://wa.me/$num'),
          mode: LaunchMode.externalApplication);
      if (!ok) _snack('No se pudo abrir WhatsApp.');
    } catch (e) {
      AppLog.error('invitados', 'whatsapp_fallo', d: '$e');
      _snack('No se pudo abrir WhatsApp.');
    }
  }

  Future<void> _atender() async {
    // v1.12.0 (D5): en caché de solo lectura no hay acciones.
    if (_offlineCache) {
      _snack('Sin conexión: el detalle está en solo lectura.');
      return;
    }
    setState(() => _actuando = true);
    try {
      final n = await _svc.atenderSolicitud(widget.invitadoId);
      _snack(n > 0
          ? 'Solicitud marcada como atendida'
          : 'La solicitud ya estaba atendida');
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _convertir() async {
    final d = _d!;
    // 1.35 (campo nº 14 de Clientes): la conversión es la
    // UNA acción que la caché de solo lectura sí permite —
    // el invitado confirma en persona en el gym y convertir
    // no puede esperar a que vuelva la conexión. Se prepara
    // local con los datos del detalle en caché, la
    // inscripción se encola como cualquier op y el acceso
    // a su app se crea al confirmarse la conversión ya con
    // red. El resto de acciones sigue en solo lectura.
    if (_offlineCache) {
      if (d.caducado) {
        _snack(
            'Este invitado está caducado: extiende su vida antes de convertirlo.');
        return;
      }
      final ok = await DialogoApp.confirmar(
        context,
        titulo: 'Convertir sin conexión',
        mensaje: 'Se convierte ahora en este teléfono y el '
            'acceso a su app se crea cuando haya conexión.',
        aceptar: 'Convertir',
        cancelar: 'Ahora no',
        icono: Icons.person_add_rounded,
      );
      if (ok != true || !mounted) return;
      setState(() => _actuando = true);
      try {
        final datos = await _svc.prepararConversionLocal(d);
        if (!mounted) return;
        await Navigator.of(context).push(RutaIron(
          builder: (_) => InscribirScreen(conversion: datos),
        ));
        // El registro local manda ahora en la tarjeta de
        // conversión (la caché no lo traía): se relee para
        // pintar su estado real al volver del formulario.
        final local =
            await ConversionInvitadoStore().leer(widget.invitadoId);
        if (mounted) setState(() => _local = local);
      } on InvitadoError catch (e) {
        // 136-701: la rama offline no capturaba — el error
        // de la preparación local escapaba sin snack.
        _snack(e.mensaje);
      } catch (e) {
        AppLog.error('invitados', 'conversion_offline_fallo',
            d: '$e');
        _snack('No se pudo preparar la conversión sin '
            'conexión.');
      } finally {
        if (mounted) setState(() => _actuando = false);
      }
      return;
    }
    // AA3 F-I1: la RPC no rechaza al invitado caducado (calcula el
    // flag pero no lo usa como guarda); la vía prevista es extenderle
    // la vida primero. Corte local con mensaje claro.
    if (d.caducado) {
      _snack(
          'Este invitado está caducado: extiende su vida antes de convertirlo.');
      return;
    }
    setState(() => _actuando = true);
    try {
      final datos = await _svc.prepararConversion(d);
      if (!mounted) return;
      await Navigator.of(context).push(RutaIron(
        builder: (_) => InscribirScreen(conversion: datos),
      ));
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  /// «Reanudar inscripción»: reabre Inscribir con el MISMO
  /// conversion_uuid durable (el formulario se cerró a mitad).
  Future<void> _reanudar() async {
    // Autoauditoría 1.22 #1 (2026-11-03): las guardias van
    // ANTES de desenvolver _d/_local. La propia IG-05 hizo
    // alcanzable el null: su fallback offline pone _local=null,
    // y con el orden anterior un _reanudar invocado en ese
    // estado reventaba con el force-unwrap en vez de mostrar
    // el snack de solo lectura (hoy el botón no se ofrece en
    // offline, pero la guarda no puede depender de eso).
    // (136-708) la conversión preparada NACIDA OFFLINE sí se
    // reanuda sin conexión (nació en este teléfono); el resto de
    // reanudaciones en modo caché sigue en solo lectura.
    final localPre = _local;
    if (_offlineCache &&
        !(localPre != null &&
            localPre.nacidaOffline &&
            localPre.estado == EstadoConversion.preparada)) {
      _snack('Sin conexión: el detalle está en solo lectura.');
      return;
    }
    final d = _d;
    final local = _local;
    if (d == null || local == null) {
      _snack('No hay una conversión preparada para reanudar.');
      return;
    }
    // 1.22 IG-05: las mismas guardias que _convertir (aquí
    // faltaban: se podía reanudar desde la caché de solo
    // lectura o con el invitado caducado).
    if (d.caducado) {
      _snack(
          'Este invitado está caducado: extiende su vida antes de reanudar la conversión.');
      return;
    }
    final datos = DatosConversionInvitado(
      invitadoId: d.id,
      conversionUuid: local.conversionUuid,
      nombre: d.nombre,
      telefono: d.telefono,
      fechaNac: d.fechaNac,
      carnet: d.carnet,
      medidas: d.mediciones,
      // (136-708) la marca de nacimiento offline viaja en la
      // reanudación: sin ella la op perdía la marca y la
      // verificación confirmaba con un uuid que el servidor no
      // conoce.
      nacidaOffline: local.nacidaOffline,
    );
    await Navigator.of(context).push(RutaIron(
      builder: (_) => InscribirScreen(conversion: datos),
    ));
    await _cargar();
  }

  Future<void> _cancelarConversion() async {
    final local = _local;
    if (local == null) return;
    // (136-699) cancelar una conversión del SERVIDOR exige red;
    // la nacida offline se cancela local y sí se permite.
    if (_offlineCache && !local.nacidaOffline) {
      _snack('Sin conexión: cancelar esta conversión necesita '
          'conexión. El detalle está en solo lectura.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Cancelar conversión',
        iconoTitulo: Icons.cancel_rounded,
        contenido: const Text(
            'Se cancela la preparación en el servidor y el '
            'invitado vuelve a estar activo normal. Podrás '
            'convertirlo de nuevo cuando quieras.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Volver')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.error,
                foregroundColor: Colors.white,
              ),
              child: const Text('Cancelar conversión')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _actuando = true);
    try {
      await _svc.cancelarConversion(local.conversionUuid,
          invitadoId: widget.invitadoId);
      _snack('Conversión cancelada');
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _sincronizarAhora() async {
    setState(() => _actuando = true);
    try {
      await SyncEngine.instance.push();
      await _svc.verificarConversiones();
      await _cargar();
      // 1.31 (Yunque A): si la confirmación de la conversión
      // sigue pendiente por un fallo registrado, el aviso lo
      // dice con su motivo en vez de un genérico «revisada».
      final reg = await ConversionInvitadoStore()
          .leer(widget.invitadoId);
      if (!mounted) return;
      if (confirmacionConversionPendiente(reg)) {
        _snack('La conversión sigue pendiente de confirmar: '
            '${reg!.errorConfirmacion}');
      } else {
        _snack('Sincronización revisada');
      }
    } catch (e) {
      // 136-701: el push/verificación sin captura dejaba
      // el fallo mudo (solo el finally limpiaba el estado).
      AppLog.error('invitados', 'sincronizar_fallo', d: '$e');
      _snack('No se pudo sincronizar ahora.');
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  /// 1.25 T119 (F3-20): barra de acción fija del detalle.
  /// Lote 1.35 (SL-1 · G12-3): ya no lleva WhatsApp ni
  /// Convertir (duplicaban la tarjeta de acciones y la de
  /// conversión); solo «Reanudar inscripción» cuando una
  /// conversión quedó preparada (T87).
  Widget? _barraAccionesDetalle() {
    final d = _d;
    if (d == null || _cargando) return null;
    final reanudar = reanudarPara(
        local: _local, enServidor: d.conversionPreparada);
    // Lote 1.35 (SL-1 · G12-3, VIS aprobada por Jc): la barra
    // REPETÍA WhatsApp y Convertir, que ya viven en la
    // tarjeta de acciones y en la tarjeta de conversión —
    // tres superficies para las mismas dos acciones. Queda
    // UNA superficie por acción: Convertir en su tarjeta y
    // WhatsApp en la de acciones. La barra conserva solo
    // «Reanudar inscripción» (1.25 T87), la acción del
    // momento cuando una conversión quedó preparada, que no
    // duplica a ninguna de las dos.
    // (136-708) en modo caché solo se ofrece reanudar la
    // conversión nacida offline (la única reanudable sin red).
    final puedeReanudar =
        reanudar == ReanudarConversion.abrirInscribir &&
            (!_offlineCache || (_local?.nacidaOffline ?? false));
    if (!puedeReanudar) {
      return null;
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, AppEspacio.sm),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow_rounded,
                    size: 18),
                label: const Text('Reanudar inscripción'),
                onPressed: _actuando ? null : _reanudar,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Detalle del invitado'),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          // v1.12.0 (G3): entrada suave transversal.
          Expanded(child: FadeEntrada(child: _cuerpo())),
        ],
      ),
      bottomNavigationBar: _barraAccionesDetalle(),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_error != null || _d == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColores.alerta),
              const SizedBox(height: AppEspacio.md),
              Text(_error ?? 'Sin datos', textAlign: TextAlign.center),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                  texto: 'Reintentar',
                  icono: Icons.refresh_rounded,
                  onPressed: _cargar),
            ],
          ),
        ),
      );
    }
    final d = _d!;
    return RefrescoIron(
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          // v1.12.0 (D5): caché en solo lectura con su frescura.
          if (_offlineCache)
            Container(
              padding: const EdgeInsets.all(AppEspacio.md),
              margin: const EdgeInsets.only(bottom: AppEspacio.md),
              decoration: BoxDecoration(
                color: AppColores.alerta.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadio.md),
              ),
              child: Text(
                '📴 Sin conexión · datos de '
                '${_cacheAt != null ? hace(_cacheAt) : 'antes'}'
                // Jornada 1.35: «(sin acciones)» era falso
                // desde el campo nº 14 — esta misma pantalla
                // convierte sin conexión. La banda nombra la
                // excepción en vez de negarla.
                ' · solo lectura (conversión disponible)',
                style: AppTexto.cuerpo.copyWith(
                    fontWeight: FontWeight.w600),
              ),
            ),
          _tarjetaDatos(d),
          if (d.solicitud != null) ...[
            const SizedBox(height: AppEspacio.md),
            _tarjetaSolicitud(d),
          ],
          if (d.plus != null) ...[
            const SizedBox(height: AppEspacio.md),
            _tarjetaPlus(d),
          ],
          const SizedBox(height: AppEspacio.md),
          _tarjetaSync(d),
          if (!d.convertido) ...[
            const SizedBox(height: AppEspacio.md),
            _tarjetaVisitas(d),
          ],
          const SizedBox(height: AppEspacio.md),
          _tarjetaConversion(d),
          if (d.staffAcciones.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.md),
            _tarjetaStaff(d),
          ],
          const SizedBox(height: AppEspacio.md),
          _tarjetaAcciones(d),
          // v1.12.0 (D6): tarjeta separada del dueño. El gate exterior
          // incluye admins: Ajustar acceso es de admin (no solo del
          // dueño); Eliminar sigue gated por isOwner dentro.
          if ((AuthService().isOwner || AuthService().isAdmin) &&
              !d.convertido) ...[
            const SizedBox(height: AppEspacio.md),
            _tarjetaAccionesDueno(d),
          ],
        ],
      ),
    );
  }

  Widget _tarjetaDatos(InvitadoDetalle d) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_rounded,
                  color: AppColores.textoSecundario(context)),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                  child: Text(d.nombre, style: AppTexto.titulo)),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          _chip('⚠ Teléfono no verificado', AppColores.alertaOscuro),
          const SizedBox(height: 2),
          // v1.12.0 (D1): texto aprobado por Jc (letra pequeña).
          const Text(
            'Esta cuenta de invitado no está asociada a una '
            'inscripción del gym.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: AppEspacio.sm),
          _linea('📱 Teléfono', d.telefono),
          if (d.fechaNac != null)
            _linea('🎂 Nacimiento', fmtFecha(d.fechaNac)),
          // Carnet (0.9.1): los viejos no lo tienen → «Sin carnet».
          _linea('🪪 Carnet', d.carnet ?? 'Sin carnet'),
          // Ronda 3-9 #9: aviso si el carnet existe pero no tiene
          // 11 dígitos o su fecha AAMMDD no es real (no bloquea).
          if (d.carnet != null && !validarCarnetInvitado11(d.carnet))
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                '⚠ Carnet inválido: debe tener 11 dígitos y una '
                'fecha real.',
                style: AppTexto.secundario,
              ),
            ),
          _linea('🗓 Registrado', fechaAbsoluta(d.creadoEn)),
          _linea(
              '⏳ Caduca',
              d.convertido
                  ? 'ya convertido'
                  : '${fechaAbsoluta(d.caducaEn)}${d.caducado ? ' (caducado)' : ''}'),
          // F3-20: el estado se traduce a lenguaje llano
          // (antes salía el crudo del servidor: «activo»,
          // «en_conversion»…).
          _linea('Estado', _estadoLegibleInvitado(d.estado)),
          if (d.telefonoYaCliente)
            const Padding(
              padding: EdgeInsets.only(top: AppEspacio.sm),
              child: Text(
                'ℹ️ Este teléfono también es de un cliente. El '
                'Plus y las acciones aplican SOLO a la cuenta de '
                'invitado.',
                style: AppTexto.secundario,
              ),
            ),
        ],
      ),
    );
  }

  Widget _linea(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 130,
              child: Text(etiqueta, style: AppTexto.secundario)),
          Expanded(child: Text(valor, style: AppTexto.cuerpo)),
        ],
      ),
    );
  }

  Widget _tarjetaSolicitud(InvitadoDetalle d) {
    final s = d.solicitud!;
    // v1.12.0 (B2): una solicitud rechazada se distingue de una
    // atendida normal por el resultado que devuelve el servidor.
    final esRechazo =
        (s.resultado ?? '').toLowerCase().contains('rechaz');
    return Tarjeta(
      color: s.pendiente
          ? AppColores.alerta.withValues(alpha: 0.10)
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.mark_email_unread_rounded,
                  color: AppColores.alertaOscuro),
              SizedBox(width: AppEspacio.sm),
              Text('Solicitud «Quiero inscribirme»',
                  style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(
            s.pendiente
                ? 'Pendiente desde ${fechaAbsoluta(s.creadaEn)}'
                : esRechazo
                    ? 'Rechazada ${s.atendidaEn != null ? fechaAbsoluta(s.atendidaEn) : ''}'
                        '${s.atendidoPor != null ? ' por ${s.atendidoPor}' : ''}'
                        '${s.resultado != null ? ' · ${s.resultado}' : ''}'
                    : 'Atendida ${s.atendidaEn != null ? fechaAbsoluta(s.atendidaEn) : ''}'
                        '${s.atendidoPor != null ? ' por ${s.atendidoPor}' : ''}'
                        '${s.resultado != null ? ' · ${s.resultado}' : ''}',
            style: AppTexto.cuerpo,
          ),
          if (s.pendiente) ...[
            const SizedBox(height: AppEspacio.md),
            BotonPrimario(
              texto: 'Marcar atendida',
              icono: Icons.done_all_rounded,
              onPressed: _actuando ? null : _atender,
            ),
            // v1.12.0 (B2): rechazar con motivo (solo dueño; la RPC
            // es rechazar_solicitud_invitado, contrato 59f2ffd).
            if (AuthService().isOwner) ...[
              const SizedBox(height: AppEspacio.sm),
              BotonSecundario(
                texto: 'Rechazar con motivo',
                icono: Icons.block_rounded,
                onPressed: _actuando ? null : _rechazar,
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// v1.12.0 (B2): diálogo de motivo obligatorio → RPC de rechazo.
  /// 1.29 (Oleada 4, barrido): el diálogo vive en un
  /// StatefulWidget dueño de su controlador
  /// (_DialogoRechazarInvitado); antes se disponía al
  /// resolver el showDialog con el campo aún reconstruyéndose
  /// en la animación de salida (defecto D-B1-08).
  Future<void> _rechazar() async {
    // (1.36 H-A2 136-699) en modo caché el rechazo exige red:
    // se bloquea con aviso ANTES de abrir el diálogo (antes el
    // diálogo se llenaba y el fallo caía al confirmar).
    if (_offlineCache) {
      _snack('Sin conexión: rechazar la solicitud necesita '
          'conexión. El detalle está en solo lectura.');
      return;
    }
    final motivo = await showDialog<String>(
      context: context,
      builder: (_) => const _DialogoRechazarInvitado(),
    );
    if (motivo == null || motivo.isEmpty || !mounted) return;
    setState(() => _actuando = true);
    try {
      final ok =
          await _svc.rechazarSolicitud(widget.invitadoId, motivo);
      _snack(ok
          ? 'Solicitud rechazada'
          : 'La solicitud ya estaba atendida');
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  /// Ajuste 5 de Argón: lo sincronizado se ve ANTES de convertir;
  /// lo que siga en el teléfono del invitado se pierde al revocar.
  Widget _tarjetaSync(InvitadoDetalle d) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sync_rounded, color: AppColores.textoSecundario(context)),
              SizedBox(width: AppEspacio.sm),
              Text('Datos sincronizados', style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          _linea('Última sync',
              d.ultimaSync != null ? hace(d.ultimaSync) : '—'),
          _linea('Medidas sincronizadas',
              '${d.medicionesSincronizadas}'),
          if (d.mediciones.isEmpty)
            const Text(
              'El invitado aún no ha sincronizado medidas.',
              style: AppTexto.secundario,
            )
          else
            for (final m in d.mediciones) ...[
              const Divider(height: 16),
              _linea('📅 ${fmtFecha(m.fecha)}',
                  m.resumen.isEmpty ? 'medida registrada' : m.resumen),
              if (_detalleMedida(m).isNotEmpty)
                Text(_detalleMedida(m), style: AppTexto.secundario),
              if (m.notas != null && m.notas!.isNotEmpty)
                Text('«${m.notas}»', style: AppTexto.secundario),
            ],
          const SizedBox(height: AppEspacio.sm),
          const Text(
            'Medidas autodeclaradas por el invitado en su app. '
            'Al convertirlo, su acceso de invitado se revoca: las '
            'medidas que aún estén en su teléfono SIN sincronizar '
            'se pierden.',
            style: AppTexto.secundario,
          ),
          // v1.12.0 (D3): solo lectura — el entrenador NO escribe
          // medidas aquí (D4 queda diferido a la 1.13.0).
          const SizedBox(height: AppEspacio.xs),
          const Text(
            'Solo lectura: las medidas se consultan, no se editan '
            'desde esta pantalla.',
            style: AppTexto.secundario,
          ),
        ],
      ),
    );
  }

  String _detalleMedida(MedidaInvitado m) {
    final p = <String>[];
    if (m.pechoCm != null) p.add('pecho ${_n(m.pechoCm!)}');
    if (m.brazoCm != null) p.add('brazo ${_n(m.brazoCm!)}');
    if (m.cinturaCm != null) p.add('cintura ${_n(m.cinturaCm!)}');
    if (m.caderaCm != null) p.add('cadera ${_n(m.caderaCm!)}');
    if (m.musloCm != null) p.add('muslo ${_n(m.musloCm!)}');
    return p.isEmpty ? '' : '${p.join(' · ')} cm';
  }

  Widget _tarjetaConversion(InvitadoDetalle d) {
    if (d.convertido) {
      return Tarjeta(
        color: AppColores.exito.withValues(alpha: 0.10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.verified_rounded,
                    color: AppColores.exitoOscuro),
                SizedBox(width: AppEspacio.sm),
                Text('Ya es cliente', style: AppTexto.subtitulo),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            Text(
              'Convertido ${d.convertidoEn != null ? fechaAbsoluta(d.convertidoEn) : ''}'
              '${d.clienteId != null ? ' · Cliente #${d.clienteId}' : ''}.',
              style: AppTexto.cuerpo,
            ),
            if (_estadoConvertido == EstadoConvertido.eliminado) ...[
              const SizedBox(height: AppEspacio.sm),
              Text(
                'El cliente vinculado fue eliminado.'
                '${_eliminadoEn != null ? ' (baja registrada el ${fechaAbsoluta(parseFecha(_eliminadoEn))})' : ''}',
                style: AppTexto.cuerpo.copyWith(
                    color: AppColores.error, fontWeight: FontWeight.w600),
              ),
            ],
            if (_estadoConvertido ==
                EstadoConvertido.sincronizandoFicha) ...[
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'Convertido (sincronizando ficha...): el cliente '
                'existe pero su ficha aún no baja a este teléfono.',
                style: AppTexto.secundario,
              ),
            ],
            if (_local?.resultadoMedidas != null) ...[
              const SizedBox(height: AppEspacio.sm),
              Text(_local!.resultadoMedidas!.texto,
                  style: AppTexto.secundario),
            ],
            // Ver ficha solo si el cliente está activo en este
            // teléfono (eliminado → sin enlace roto; sincronizando
            // o en curso → la ficha aún no está aquí).
            if (d.clienteId != null &&
                _estadoConvertido != EstadoConvertido.eliminado &&
                _estadoConvertido !=
                    EstadoConvertido.sincronizandoFicha &&
                _estadoConvertido != EstadoConvertido.enCurso) ...[
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Ver ficha del cliente',
                icono: Icons.badge_rounded,
                onPressed: () => Navigator.of(context).push(
                  RutaIron(
                      builder: (_) =>
                          FichaScreen(clienteId: d.clienteId!)),
                ),
              ),
            ],
          ],
        ),
      );
    }

    final reanudar = reanudarPara(
        local: _local, enServidor: d.conversionPreparada);
    switch (reanudar) {
      case ReanudarConversion.abrirInscribir:
        return Tarjeta(
          color: AppColores.info.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.swap_horiz_rounded,
                      color: AppColores.infoOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('Conversión preparada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'La inscripción quedó a mitad en este teléfono. '
                'Reanúdala con el mismo registro preparado: no se '
                'duplica.',
                style: AppTexto.cuerpo,
              ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Reanudar inscripción',
                icono: Icons.play_arrow_rounded,
                onPressed: _actuando ? null : _reanudar,
              ),
              const SizedBox(height: AppEspacio.sm),
              OutlinedButton.icon(
                icon: const Icon(Icons.cancel_rounded),
                label: const Text('Cancelar conversión'),
                onPressed: _actuando ? null : _cancelarConversion,
              ),
            ],
          ),
        );
      case ReanudarConversion.esperandoSync:
        return Tarjeta(
          color: AppColores.alerta.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.cloud_upload_rounded,
                      color: AppColores.alertaOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('Inscripción guardada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'La inscripción ya se guardó en este teléfono y '
                'está esperando sincronizarse. Al subirse, la '
                'conversión se confirma sola y aquí verás el '
                'resultado de las medidas.',
                style: AppTexto.cuerpo,
              ),
              // 1.31 (Yunque A): la confirmación en el servidor
              // ya se intentó y FALLÓ (el mensaje quedó
              // guardado): se enseña aquí, con el motivo, junto
              // al reintento de abajo.
              if (confirmacionConversionPendiente(_local)) ...[
                const SizedBox(height: AppEspacio.sm),
                Text(
                  '⚠ Conversión pendiente de confirmar',
                  style: AppTexto.cuerpo.copyWith(
                      color: AppColores.error,
                      fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                Text(
                  'El cliente ya se creó, pero la confirmación '
                  'en el servidor falló: '
                  '${_local!.errorConfirmacion} En su app aún '
                  'no aparece como cliente. Reinténtalo con el '
                  'botón de abajo.',
                  style: AppTexto.cuerpo,
                ),
              ],
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Sincronizar / verificar ahora',
                icono: Icons.sync_rounded,
                onPressed: _actuando ? null : _sincronizarAhora,
              ),
            ],
          ),
        );
      case ReanudarConversion.verResultado:
        return Tarjeta(
          color: AppColores.exito.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.verified_rounded,
                      color: AppColores.exitoOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('Conversión confirmada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              if (_local?.resultadoMedidas != null)
                Text(_local!.resultadoMedidas!.texto,
                    style: AppTexto.cuerpo)
              else
                const Text('El invitado ya es cliente.',
                    style: AppTexto.cuerpo),
            ],
          ),
        );
      case ReanudarConversion.revisarFallo:
        return Tarjeta(
          color: AppColores.error.withValues(alpha: 0.10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.error_outline_rounded,
                      color: AppColores.errorOscuro),
                  SizedBox(width: AppEspacio.sm),
                  Text('La inscripción fue rechazada',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'El servidor rechazó la operación de inscripción '
                '(revisa la cola de operaciones para el motivo). '
                'Cancela esta conversión para poder intentarlo de '
                'nuevo.',
                style: AppTexto.cuerpo,
              ),
              const SizedBox(height: AppEspacio.md),
              OutlinedButton.icon(
                icon: const Icon(Icons.cancel_rounded),
                label: const Text('Cancelar conversión'),
                onPressed: _actuando ? null : _cancelarConversion,
              ),
            ],
          ),
        );
      case ReanudarConversion.ninguna:
        final enSrv = d.conversionPreparada;
        return Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.swap_horiz_rounded,
                      color: AppColores.textoSecundario(context)),
                  SizedBox(width: AppEspacio.sm),
                  Text('Convertir en cliente',
                      style: AppTexto.subtitulo),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              if (enSrv != null)
                Text(
                  enSrv.lockVigente
                      ? 'Hay una conversión preparada'
                          '${enSrv.preparadaPor != null ? ' por ${enSrv.preparadaPor}' : ''} '
                          'con bloqueo hasta '
                          '${enSrv.expiraLockEn != null ? fechaAbsoluta(enSrv.expiraLockEn) : '—'}. '
                          'Si la preparaste tú en OTRO teléfono, termínala allá; '
                          'si intentas convertir ahora, el servidor lo rechazará '
                          'hasta que venza el bloqueo.'
                      : 'Hubo una conversión preparada cuyo bloqueo '
                          'ya venció: al convertir se emitirá una nueva.',
                  style: AppTexto.cuerpo,
                )
              else
                const Text(
                  'Abre la inscripción pre-llenada con sus datos. '
                  'Al sincronizarse, el invitado pasa a cliente y '
                  'sus medidas sincronizadas se envían al servidor '
                  'para verificarlas: se importan solo las que el '
                  'servidor confirme como suyas, y el resultado se '
                  'verá al confirmarse la conversión.',
                  style: AppTexto.cuerpo,
                ),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                texto: 'Convertir en cliente',
                icono: Icons.person_add_rounded,
                onPressed: _actuando ? null : _convertir,
              ),
            ],
          ),
        );
    }
  }

  // ------------------------------------------------------------------
  // 1.23 (W7): visitas del invitado — registro mínimo local.
  // ------------------------------------------------------------------

  Future<void> _cargarVisitas(InvitadoDetalle d) async {
    final clave = claveIdentidadInvitado(
        carnet: d.carnet, telefono: d.telefono, nombre: d.nombre);
    var conteo = 0;
    var umbral = umbralVisitasDefecto;
    try {
      if (clave.isNotEmpty) conteo = await conteoVisitasInvitado(clave);
      umbral = await umbralVisitasInvitado();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _claveVisitas = clave;
      _visitas30 = conteo;
      _umbralVisitas = umbral;
    });
  }

  Future<void> _registrarVisita() async {
    final d = _d;
    if (d == null || _claveVisitas.isEmpty || _offlineCache) return;
    // 1.28 (M4-A1/R2M4-H8): guarda síncrona anti-doble-toque
    // (dos toques contaban dos visitas) y el id viaja CRUDO:
    // es un UUID; el int.tryParse anterior lo dejaba en null
    // y la visita quedaba sin ficha.
    if (_registrandoVisita) return;
    _registrandoVisita = true;
    int n;
    try {
      n = await registrarVisitaInvitadoAhora(
        clave: _claveVisitas,
        invitadoId: d.id,
        nombre: d.nombre,
      );
    } finally {
      _registrandoVisita = false;
    }
    if (!mounted) return;
    setState(() => _visitas30 = n);
    // 1.24 Bloque 5 (B-12): por el helper de la casa, no una
    // barra cruda que flotaba sobre la pantalla siguiente.
    mostrarSnack(
        context,
        n >= _umbralVisitas
            ? 'Visita registrada. Ya suma $n en 30 días: es '
                'candidato a cliente.'
            : 'Visita registrada ($n en 30 días en este teléfono).',
        significado: SignificadoChip.exito);
  }

  Widget _tarjetaVisitas(InvitadoDetalle d) {
    final candidato = _claveVisitas.isNotEmpty &&
        _visitas30 >= _umbralVisitas;
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.directions_walk_rounded,
                  color: AppColores.textoSecundario(context)),
              const SizedBox(width: AppEspacio.sm),
              const Text('Visitas', style: AppTexto.subtitulo),
              const Spacer(),
              if (candidato)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.sm,
                      vertical: AppEspacio.xs),
                  decoration: BoxDecoration(
                    color:
                        AppColores.exito.withValues(alpha: 0.15),
                    borderRadius:
                        BorderRadius.circular(AppRadio.sm),
                  ),
                  child: Text('Candidato a cliente',
                      style: AppTexto.etiqueta
                          .copyWith(color: AppColores.exito)),
                ),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(
            _claveVisitas.isEmpty
                ? 'Sin carnet, teléfono ni nombre utilizables: '
                    'no se puede llevar su conteo de visitas.'
                : '$_visitas30 visita(s) en los últimos '
                    '$diasVentanaVisitas días en ESTE teléfono '
                    '(el conteo no viaja entre teléfonos). El '
                    'umbral de candidato es $_umbralVisitas.',
            style: AppTexto.cuerpo,
          ),
          if (_claveVisitas.isNotEmpty && !_offlineCache) ...[
            const SizedBox(height: AppEspacio.md),
            BotonSecundario(
              texto: 'Registrar visita',
              icono: Icons.how_to_reg_rounded,
              // 1.28 (M4-A1/R2M4-H8): deshabilitado mientras
              // el registro anterior sigue en curso.
              onPressed: _registrandoVisita ? null : _registrarVisita,
            ),
          ],
        ],
      ),
    );
  }

  /// v1.8.0 — Bloque Plus del detalle (diseño §5.4): estado con
  /// su nombre (revocado ≠ vencido, G5), origen e historial.
  /// Las acciones son del dueño (dinero) y van por la MISMA RPC
  /// de lote con un array de 1.
  Widget _tarjetaPlus(InvitadoDetalle d) {
    final p = d.plus!;
    final esDueno = AuthService().isOwner;
    // 1.22 IG-02: con una conversión en curso, los botones
    // Plus quedan bloqueados (el mismo criterio que ya
    // bloquea Eliminar: eliminarInvitadoBloqueado). Extender
    // vida NO se bloquea (vive en la tarjeta de Acciones).
    final plusBloqueado = eliminarInvitadoBloqueado(
        local: _local, enServidor: d.conversionPreparada);
    String textoEstado() {
      switch (p.estado) {
        case 'activo':
          return '⭐ Activo hasta el '
              '${p.hasta != null ? fmtFecha(p.hasta!.toIso8601String()) : '—'}'
              '${p.diasRestantes != null ? ' · quedan ${p.diasRestantes} día(s)' : ''}'
              '${p.origen != null ? ' · origen: ${p.origen == 'cortesia' ? 'cortesía' : 'pago'}' : ''}';
        case 'vencido':
          return 'Vencido el '
              '${p.hasta != null ? fmtFecha(p.hasta!.toIso8601String()) : '—'}';
        case 'revocado':
          return 'Revocado (lo quitó el dueño; no venció solo)';
        default:
          return 'Sin Plus';
      }
    }

    String textoHistorial(PlusHistorialItem h) {
      final fecha =
          h.fecha != null ? fmtFecha(h.fecha!.toIso8601String()) : '—';
      switch (h.tipo) {
        case 'plus_cortesia':
          return '🎁 Cortesía de ${h.dias ?? ''} días · $fecha'
              '${h.actor != null ? ' · ${h.actor}' : ''}'
              '${h.motivo != null ? ' · «${h.motivo}»' : ''}';
        case 'plus_quitar':
          return '🚫 Revocado · $fecha'
              '${h.actor != null ? ' · ${h.actor}' : ''}'
              '${h.motivo != null ? ' · «${h.motivo}»' : ''}';
        case 'reporte_confirmado':
          return '💳 Pago confirmado · $fecha'
              '${h.montoCup != null ? ' · ${fmtMonto(h.montoCup!)} CUP' : ''}'
              '${h.hasta != null ? ' → Plus hasta el ${fmtFecha(h.hasta!.toIso8601String())}' : ''}';
        case 'reporte_pendiente':
          return '⏳ Reporte de pago pendiente · $fecha';
        case 'reporte_rechazado':
          return '↩️ Reporte rechazado · $fecha'
              '${h.motivo != null ? ' · «${h.motivo}»' : ''}';
        case 'resetear_pin':
          return '🔑 PIN de acceso restablecido · $fecha';
        default:
          // G12-7: nunca la clave cruda a pantalla.
          return 'Acción registrada · $fecha';
      }
    }

    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Invitado Plus', style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.sm),
          Text(textoEstado(), style: AppTexto.cuerpo),
          // v1.12.0 (C2): aviso urgente a 3 días (mismo umbral que
          // la lista; distinto del filtro de exploración a 7 días).
          if (p.activo &&
              p.diasRestantes != null &&
              p.diasRestantes! <= kDiasAvisoPlusPorVencer)
            Padding(
              padding: const EdgeInsets.only(top: AppEspacio.xs),
              child: Text(
                '⚠ El Plus vence en ${p.diasRestantes} día(s): '
                'avísale antes de que se le acabe.',
                style: AppTexto.cuerpo.copyWith(
                    color: AppColores.alertaOscuro,
                    fontWeight: FontWeight.w600),
              ),
            ),
          if (d.convertido)
            const Padding(
              padding: EdgeInsets.only(top: AppEspacio.xs),
              child: Text(
                // v1.12.0 (C1): regla completa, no cambio de regla.
                'Ya es cliente: su Plus sigue vigente hasta su '
                'vencimiento SIN dar crédito (la mensualidad manda), '
                'queda inerte mientras paga el mes y revive solo si '
                'su mensualidad cae. No se puede quitar desde la app.',
                style: AppTexto.secundario,
              ),
            ),
          if (p.historial.isNotEmpty) ...[
            const SizedBox(height: AppEspacio.sm),
            const Text('Historial', style: AppTexto.secundario),
            // v1.12.0 (C3): historial en tarjetas, no en líneas.
            for (final h in p.historial)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: AppEspacio.sm),
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: AppEspacio.sm),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(AppRadio.md),
                ),
                child: Text(textoHistorial(h),
                    style: AppTexto.secundario),
              ),
          ],
          // v1.12.0 (C4): el precio del Plus se edita en la
          // pantalla de Precios; desde aquí solo un enlace.
          // 1.32 (Oleada 2 F1): el enlace va DIRECTO a Precios
          // (PreciosMetodoScreen), sin abrir el Panel clásico.
          if (esDueno) ...[
            const SizedBox(height: AppEspacio.sm),
            TextButton.icon(
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text(
                  'Editar precio del Plus (en Precios)'),
              onPressed: () => Navigator.of(context).push(
                RutaIron(
                    builder: (_) => const PreciosMetodoScreen()),
              ),
            ),
          ],
          if (esDueno && !d.convertido) ...[
            const SizedBox(height: AppEspacio.md),
            Wrap(
              spacing: AppEspacio.sm,
              children: [
                if (!p.activo)
                  FilledButton.icon(
                    icon: const Icon(Icons.star_rounded, size: 18),
                    label: const Text('Dar Plus de cortesía'),
                    onPressed: _actuando || plusBloqueado
                        ? null
                        : () => _accionUnica('plus_cortesia'),
                  ),
                if (p.activo)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.star_border_rounded,
                        size: 18),
                    label: const Text('Quitar Plus'),
                    onPressed: _actuando || plusBloqueado
                        ? null
                        : () => _accionUnica('plus_quitar'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// v1.8.0 — Historial de acciones de staff (diseño §5.7):
  /// responde «¿quién le regaló el Plus / le extendió la vida?».
  Widget _tarjetaStaff(InvitadoDetalle d) {
    // G12-7: el traductor vive fuera como
    // textoAccionStaffInvitado (testeable y sin clave cruda).
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acciones del equipo',
              style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.sm),
          for (final a in d.staffAcciones)
            Padding(
              padding: const EdgeInsets.only(bottom: AppEspacio.xs),
              child: Text(textoAccionStaffInvitado(a),
                  style: AppTexto.secundario),
            ),
        ],
      ),
    );
  }

  /// Acción individual por la RPC de lote (array de 1): mismo
  /// diálogo, mismo resultado y mismo ciclo de op_id que la
  /// multiselección de la lista.
  Future<void> _accionUnica(String accion) async {
    final d = _d;
    if (d == null) return;
    // v1.12.0 (D5): en caché de solo lectura no hay acciones.
    if (_offlineCache) {
      _snack('Sin conexión: el detalle está en solo lectura.');
      return;
    }
    final resumen = InvitadoResumen(
      id: d.id,
      nombre: d.nombre,
      telefono: d.telefono,
      estado: d.estado,
      plusActivo: d.plus?.activo ?? false,
    );
    // 1.22 IG-02: la acción individual pasa por el MISMO
    // partirLote que la multiselección (antes iba directa al
    // diálogo con aplicables=[resumen] y excluidos vacío: desde
    // el detalle se podía quitar el Plus con la conversión en
    // curso, el hueco de IG-01 por la puerta de al lado).
    final parte = partirLote([resumen], accion,
        locales: _local == null ? const {} : {d.id: _local!});
    if (parte.aplicables.isEmpty) {
      _snack('No se puede aplicar: ${parte.excluidos.first.$2}.');
      return;
    }
    final params = await showDialog<({int dias, String motivo})>(
      context: context,
      builder: (_) => _DialogoLote(
        accion: accion,
        aplicables: parte.aplicables,
        excluidos: parte.excluidos,
      ),
    );
    if (params == null || !mounted) return;
    setState(() => _actuando = true);
    try {
      final res = await _loteInvitados.ejecutar(
        _svc,
        ids: [d.id],
        accion: accion,
        dias: accion == 'plus_quitar' ? null : params.dias,
        motivo: params.motivo.isEmpty ? null : params.motivo,
      );
      if (!mounted) return;
      // v1.12.0 (E4): el resumen se persiste en SQLite ANTES de
      // pintarlo, para que sobreviva a muerte del proceso.
      try {
        await LocalDb.instance.guardarResultadoLote(
          loteId: _loteInvitados.opIdActual,
          accion: accion,
          resultadoJson: jsonEncode({
            'accion': res.accion,
            'aplicados': res.aplicados,
            'omitidos': res.omitidos,
            'fallidos': res.fallidos,
            'repetida': res.repetida,
            'items': [
              for (final it in res.items)
                {
                  'id': it.id,
                  'ok': it.ok,
                  'codigo': it.codigo,
                  'motivo': it.motivo,
                  'plus_hasta': it.plusHasta?.toIso8601String(),
                  'caduca_en': it.caducaEn?.toIso8601String(),
                },
            ],
          }),
        );
      } catch (_) {}
      await showDialog<void>(
        context: context,
        builder: (_) => _DialogoResultadoLote(
            res: res, nombres: {d.id: d.nombre}),
      );
      if (mounted) _cargar();
    } catch (e) {
      if (!mounted) return;
      mostrarSnack(context, e is InvitadoError
              ? e.mensaje
              : 'No se pudo aplicar la acción.', significado: SignificadoChip.error);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Widget _tarjetaAcciones(InvitadoDetalle d) {
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acciones', style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.md),
          OutlinedButton.icon(
            icon: const Icon(Icons.chat_rounded),
            label: const Text('Escribir por WhatsApp'),
            onPressed: _whatsapp,
          ),
          if (!d.convertido) ...[
            const SizedBox(height: AppEspacio.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_available_rounded),
              // 1.36 H-B3 (136-705): la etiqueta dice lo que
              // el diálogo ofrece de verdad (1–365 días).
              label: const Text('Extender vida (1–365 días)'),
              onPressed: _actuando
                  ? null
                  : () => _accionUnica('vida_extender'),
            ),
          ],
        ],
      ),
    );
  }

  /// v1.12.0 (D6): acciones del dueño en tarjeta SEPARADA (patrón
  /// del Panel del dueño): ajustar acceso y eliminar no se mezclan
  /// con las acciones generales.
  Widget _tarjetaAccionesDueno(InvitadoDetalle d) {
    final esAdmin = AuthService().isAdmin;
    // G4: con una conversión sin resolver, Eliminar queda
    // deshabilitado (la op podría crear el cliente después y la
    // conversión quedaría imposible de confirmar).
    final eliminarBloqueado = eliminarInvitadoBloqueado(
        local: _local, enServidor: d.conversionPreparada);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Acciones del dueño', style: AppTexto.subtitulo),
          const SizedBox(height: AppEspacio.md),
          if (esAdmin && !d.convertido) ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.key_rounded),
              label: const Text('Ajustar acceso (clave)'),
              onPressed: _actuando ? null : _ajustarClave,
            ),
            const SizedBox(height: AppEspacio.sm),
          ],
          // J1 (v1.8.0): eliminar invitado es SOLO del dueño; el
          // servidor lo refuerza con el error limpio 42501 (G2).
          if (AuthService().isOwner && !d.convertido) ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline_rounded,
                  color: AppColores.error),
              label: const Text('Eliminar invitado',
                  style: TextStyle(color: AppColores.error)),
              onPressed:
                  (_actuando || eliminarBloqueado) ? null : _eliminar,
            ),
            if (eliminarBloqueado) ...[
              const SizedBox(height: AppEspacio.sm),
              const Text(
                'No se puede eliminar mientras haya una '
                'conversión en curso: termínala o cancélala '
                'primero.',
                style: AppTexto.secundario,
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// Regla anti-fuga (§12.3): el ajuste de clave SOLO procede si
  /// la persona confirma el nombre registrado y la fecha de
  /// creación. Si el nombre no coincide con quien reclama, NO se
  /// resetea: se elimina (libera el número) o se inscribe directo.
  Future<void> _ajustarClave() async {
    // Ronda 3-9 #10: ajustar acceso es de dueño o admin (la UI ya
    // lo oculta; esto frena un cambio de sesión a mitad).
    if (!AuthService().isOwner && !AuthService().isAdmin) return;
    // Lote 1.35 (SL-1 · A-22): la MISMA guarda offline que sus
    // hermanas (_atender, _accionUnica, _eliminar). Era la
    // única acción destructiva del detalle sin ella: con la
    // ficha en caché (datos sin verificar) se podía revocar el
    // acceso del invitado y dejarlo fuera con una clave nueva
    // asentada sobre datos viejos.
    if (_offlineCache) {
      _snack('Sin conexión: el detalle está en solo lectura.');
      return;
    }
    final d = _d!;
    // 1.29 (Oleada 4, barrido): el diálogo vive en un
    // StatefulWidget dueño de su controlador
    // (_DialogoAjustarClaveInvitado); antes se disponía al
    // resolver el showDialog con el campo aún
    // reconstruyéndose en la animación de salida (defecto
    // D-B1-08). Devuelve la clave nueva ya recortada.
    final claveNueva = await showDialog<String>(
      context: context,
      builder: (_) => _DialogoAjustarClaveInvitado(
        nombre: d.nombre,
        registradoEl: fechaAbsoluta(d.creadoEn),
      ),
    );
    if (claveNueva == null || !mounted) return;
    setState(() => _actuando = true);
    try {
      await _svc.ajustarClave(widget.invitadoId, claveNueva);
      _snack('Clave ajustada. Las sesiones del invitado se '
          'revocaron: debe entrar con la clave nueva y cambiarla.');
      await _cargar();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  Future<void> _eliminar() async {
    final d = _d!;
    // Ronda 3-9 #10: eliminar invitado es SOLO del dueño (J1).
    if (!AuthService().isOwner) return;
    // v1.12.0 (D5): en caché de solo lectura no hay acciones.
    if (_offlineCache) {
      _snack('Sin conexión: el detalle está en solo lectura.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Eliminar invitado',
        iconoTitulo: Icons.delete_outline_rounded,
        contenido: Text(
            'Se elimina a «${d.nombre}» con sus medidas y '
            'sesiones de invitado, y el número ${d.telefono} '
            'queda libre al instante (también se resetea su '
            'límite de registro). Esta acción no se puede '
            'deshacer.'),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColores.error,
                foregroundColor: Colors.white,
              ),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _actuando = true);
    try {
      await _svc.eliminar(widget.invitadoId);
      if (!mounted) return;
      Navigator.of(context).pop();
    } on InvitadoError catch (e) {
      _snack(e.mensaje);
      if (mounted) setState(() => _actuando = false);
    }
  }
}

// ---------------------------------------------------------------------------
// Información pública (panel del dueño): lo que la app de
// clientes muestra al invitado. Cambiar un enlace o un número
// aquí NO exige actualizar la app (diseño §10.2). Vacío = la
// clave se borra y el dato/botón no se muestra.
// ---------------------------------------------------------------------------

class InfoPublicaScreen extends StatefulWidget {
  const InfoPublicaScreen({super.key});
  @override
  State<InfoPublicaScreen> createState() => _InfoPublicaScreenState();
}

class _InfoPublicaScreenState extends State<InfoPublicaScreen> {
  final _svc = InvitadosService();
  final Map<String, TextEditingController> _ctrls = {};
  Map<String, String> _originales = {};
  bool _cargando = true;
  bool _guardando = false;
  String? _error;
  // Lote 1.35 (SL-1 · A-20): claves del último guardado en
  // bloque que NO se aplicaron (pendientes de publicar, con
  // reintento durable): se enseñan en la pantalla, no solo en
  // un aviso pasajero.
  Map<String, String> _pendientesInfo = {};
  // v1.6.0 (Jc): el horario ya NO se edita en esta pantalla: la
  // fuente única es el horario del sistema («Horario del Gym»).
  // Aquí se muestra en solo lectura y al guardar se republica como
  // «horario_texto» para que el invitado vea el horario real.
  List<DiaHorario> _horarioSistema = [];

  @override
  void initState() {
    super.initState();
    for (final c in clavesInfoPublica) {
      _ctrls[c.clave] = TextEditingController();
    }
    _cargar();
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final info = await _svc.infoPublica();
      // v1.6.0: el horario canónico del sistema (caché local o la
      // misma RPC que usa «Horario del Gym»); [] si no se pudo.
      final horario = await cargarHorarioCanonico();
      // F02-PB (z03_invitados-2): los pendientes DURABLES se
      // cargan también al entrar: el banner no puede depender
      // solo del último _guardar de esta misma visita.
      Map<String, String> pendientesDurables = {};
      try {
        pendientesDurables =
            await LocalDb.instance.infoPublicaPendientes();
      } catch (_) {
        pendientesDurables = {};
      }
      if (!mounted) return;
      setState(() {
        _originales = info;
        for (final c in clavesInfoPublica) {
          _ctrls[c.clave]!.text = info[c.clave] ?? '';
        }
        _horarioSistema = horario;
        _pendientesInfo = pendientesDurables;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is InvitadoError
            ? e.mensaje
            : 'Sin conexión o error del servidor.';
        _cargando = false;
      });
    }
  }

  Future<void> _guardar() async {
    // Ronda 3-9 #10: la información pública la edita un admin
    // (la entrada a esta pantalla ya exige isAdmin).
    if (!AuthService().isAdmin) return;
    final cambios = <String, String>{};
    for (final c in clavesInfoPublica) {
      // v1.6.0: «horario_texto» no sale de un campo editable (ver
      // el bloque siguiente); el resto, como siempre.
      if (c.clave == 'horario_texto') continue;
      // G6: las claves de teléfono se comparan y guardan
      // NORMALIZADAS (8 dígitos); el resto, como texto libre.
      final v =
          valorAGuardarInfoPublica(c.clave, _ctrls[c.clave]!.text);
      if (v != (_originales[c.clave] ?? '')) cambios[c.clave] = v;
    }
    // v1.6.0 (Jc, fuente única): el horario que ve el invitado se
    // REPUBLICA desde el horario del sistema al guardar esta
    // pantalla, para que nunca quede un horario viejo tecleado a
    // mano. Si el canónico no cargó, no se toca el valor guardado.
    final textoHorario = textoHorarioCanonico(_horarioSistema);
    if (textoHorario.isNotEmpty &&
        textoHorario != (_originales['horario_texto'] ?? '')) {
      cambios['horario_texto'] = textoHorario;
    }
    if (cambios.isEmpty) {
      mostrarSnack(context, 'Sin cambios que guardar');
      return;
    }
    // G6: un teléfono que no cumple (8 dígitos) frena TODO el
    // guardado con aviso claro: nada llega a info_publica_guardar
    // a medias.
    for (final c in clavesInfoPublica) {
      if (!cambios.containsKey(c.clave)) continue;
      // El horario republicado no es texto tecleado: no se valida.
      if (c.clave == 'horario_texto') continue;
      final error = validarValorInfoPublica(
          c.clave, _ctrls[c.clave]!.text);
      if (error != null) {
        mostrarSnack(context, '«${c.etiqueta}» $error', significado: SignificadoChip.error);
        return;
      }
    }
    setState(() => _guardando = true);
    try {
      // Lote 1.35 (SL-1 · A-20): guardado EN BLOQUE con
      // reintento durable (antes: una RPC inmediata por clave
      // y un corte a mitad dejaba claves mezcladas en
      // silencio). Lo no aplicado queda pendiente, visible
      // aquí y en el aviso, y la sync lo reintenta sola.
      final quedan = await _svc.guardarInfoPublicaEnBloque(cambios);
      if (!mounted) return;
      // 1.36 H-B2 (136-702): las claves APLICADAS se
      // fusionan en _originales en el acto — sin esto, el
      // estado «sin guardar» (y el aviso al salir) seguía
      // contando como pendientes las que SÍ se guardaron.
      for (final c in cambios.keys) {
        if (!quedan.containsKey(c)) _originales[c] = cambios[c]!;
      }
      setState(() => _pendientesInfo = quedan);
      if (quedan.isEmpty) {
        mostrarSnack(context, 'Información pública actualizada: la app de '
                'clientes la verá en su próxima sincronización', significado: SignificadoChip.exito);
        await _cargar();
      } else {
        mostrarSnack(context,
            'Se guardó una parte y ${quedan.length} '
            '${quedan.length == 1 ? 'clave quedó' : 'claves quedaron'} '
            'pendiente(s) de publicar: se reintentan solas con '
            'la próxima sincronización. Nada quedó a medias en '
            'silencio.',
            significado: SignificadoChip.alerta);
      }
    } on InvitadoError catch (e) {
      if (!mounted) return;
      mostrarSnack(context, e.mensaje, significado: SignificadoChip.error);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  /// 1.25 T89: ¿hay texto tecleado sin guardar? Mismo
  /// cálculo que _guardar (con su normalización de
  /// teléfonos), para que salir no lo pierda en
  /// silencio — el tercer editor con el mismo aviso
  /// (patrón semanal F3-11 y Horario del Gym T89).
  bool get _hayCambiosInfo {
    for (final c in clavesInfoPublica) {
      if (c.clave == 'horario_texto') continue;
      final v =
          valorAGuardarInfoPublica(c.clave, _ctrls[c.clave]!.text);
      if (v != (_originales[c.clave] ?? '')) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_hayCambiosInfo || _guardando,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final salir = await DialogoApp.confirmar(
          context,
          titulo: 'Cambios sin guardar',
          mensaje:
              'Tienes cambios en la información pública que aún no se han guardado.',
          aceptar: 'Salir sin guardar',
          cancelar: 'Seguir editando',
          icono: Icons.warning_amber_rounded,
          peligro: true,
        );
        if (salir && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: appBarIron(context, 'Información pública'),
        body: Column(
          children: [
            const SyncBanner(compact: true),
            Expanded(child: _cuerpo()),
          ],
        ),
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppEspacio.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 40, color: AppColores.alerta),
              const SizedBox(height: AppEspacio.md),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: AppEspacio.md),
              BotonPrimario(
                  texto: 'Reintentar',
                  icono: Icons.refresh_rounded,
                  onPressed: _cargar),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        const Text(
          'Esto es lo que ve el invitado en su portada: redes, '
          'contactos, precios estándar, horario y ubicación. '
          'Deja un campo vacío para que no se muestre.',
          style: AppTexto.secundario,
        ),
        // A-20: el pendiente de publicación se VE aquí hasta
        // que se aplique (la sync lo reintenta sola); no es un
        // aviso que pasa y se olvida.
        if (_pendientesInfo.isNotEmpty) ...[
          const SizedBox(height: AppEspacio.md),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppEspacio.md),
            decoration: BoxDecoration(
              color: AppColores.alerta.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadio.md),
            ),
            child: Text(
              '⏳ ${_pendientesInfo.length} '
              '${_pendientesInfo.length == 1 ? 'clave pendiente' : 'claves pendientes'} '
              'de publicar: el resto sí se aplicó. Se reintentan '
              'solas con la próxima sincronización.',
              style: AppTexto.cuerpo.copyWith(
                  fontWeight: FontWeight.w600),
            ),
          ),
        ],
        const SizedBox(height: AppEspacio.md),
        for (final c in clavesInfoPublica) ...[
          // v1.6.0 (Jc): el horario ya no es un campo editable
          // aquí; se muestra el del sistema en solo lectura.
          if (c.clave == 'horario_texto')
            _tarjetaHorarioSistema()
          else
            CampoTexto(
              controller: _ctrls[c.clave],
              etiqueta: c.etiqueta,
              hint: c.ayuda,
            ),
          const SizedBox(height: AppEspacio.md),
        ],
        const SizedBox(height: AppEspacio.sm),
        // 1.36 H-B3 (136-706): botón ↔ spinner con transición
        // (antes el botón de Info Pública cambiaba en seco).
        AnimatedSwitcher(
          duration: AppMovimiento.media,
          child: _guardando
              ? const Center(
                  key: ValueKey('guardando-info'),
                  child:
                      CircularProgressIndicator(color: AppColores.naranja))
              : BotonPrimario(
                  key: const ValueKey('guardar-info'),
                  texto: 'Guardar información pública',
                  icono: Icons.save_rounded,
                  onPressed: _guardar,
                ),
        ),
        const SizedBox(height: AppEspacio.lg),
      ],
    );
  }

  /// v1.6.0 (Jc): el horario del gym en SOLO LECTURA dentro de la
  /// Información pública. La fuente única es el horario del
  /// sistema; aquí no se teclea nada.
  Widget _tarjetaHorarioSistema() {
    final texto = textoHorarioCanonico(_horarioSistema);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.schedule_rounded,
                  size: 18, color: AppColores.textoSecundario(context)),
              SizedBox(width: AppEspacio.sm),
              Text('Horario del gym', style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(
            texto.isEmpty
                ? 'No se pudo cargar el horario del sistema.'
                : texto,
            style: AppTexto.cuerpo,
          ),
          const SizedBox(height: AppEspacio.xs),
          const Text(
            'Este es el horario del sistema; se edita en su '
            'sección («Horario del Gym»). Al guardar esta pantalla '
            'se republica tal cual para los invitados.',
            style: AppTexto.secundario,
          ),
        ],
      ),
    );
  }
}

/// 1.29 (Oleada 4, barrido de diálogos): «Rechazar
/// solicitud» de invitado como StatefulWidget DUEÑO de su
/// controlador, dispuesto en dispose() — el patrón de la
/// casa. Devuelve el motivo recortado; null al cancelar.
class _DialogoRechazarInvitado extends StatefulWidget {
  const _DialogoRechazarInvitado();

  @override
  State<_DialogoRechazarInvitado> createState() =>
      _DialogoRechazarInvitadoState();
}

class _DialogoRechazarInvitadoState
    extends State<_DialogoRechazarInvitado> {
  final _motivoCtrl = TextEditingController();

  @override
  void dispose() {
    _motivoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rechazar solicitud'),
      content: TextField(
        controller: _motivoCtrl,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          labelText: 'Motivo del rechazo',
          hintText: 'Ej.: cupo lleno este mes',
          border: OutlineInputBorder(),
        ),
        maxLength: 120,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          // 1.36 H-B2 (136-703): Rechazar queda
          // deshabilitado hasta escribir el motivo.
          onPressed: _motivoCtrl.text.trim().isEmpty
              ? null
              : () => Navigator.of(context)
                  .pop(_motivoCtrl.text.trim()),
          child: const Text('Rechazar'),
        ),
      ],
    );
  }
}

/// 1.29 (Oleada 4, barrido de diálogos): «Ajustar acceso del
/// invitado» como StatefulWidget DUEÑO de su controlador,
/// dispuesto en dispose() — el patrón de la casa. La regla
/// anti-fuga no cambia: el botón solo se habilita con la
/// confirmación marcada y una clave de 6–32 sin espacios.
/// Devuelve la clave nueva recortada; null al cancelar.
class _DialogoAjustarClaveInvitado extends StatefulWidget {
  const _DialogoAjustarClaveInvitado({
    required this.nombre,
    required this.registradoEl,
  });

  final String nombre;
  final String registradoEl;

  @override
  State<_DialogoAjustarClaveInvitado> createState() =>
      _DialogoAjustarClaveInvitadoState();
}

class _DialogoAjustarClaveInvitadoState
    extends State<_DialogoAjustarClaveInvitado> {
  final _ctrl = TextEditingController();
  bool _confirmado = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  bool get _claveValida =>
      RegExp(r'^\S{6,32}$').hasMatch(_ctrl.text.trim());

  Widget _linea(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 130,
              child: Text(etiqueta, style: AppTexto.secundario)),
          Expanded(child: Text(valor, style: AppTexto.cuerpo)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Ajustar acceso del invitado',
      iconoTitulo: Icons.key_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'El teléfono del invitado NO está verificado. '
              'Solo ajusta la clave si la persona confirma '
              'estos datos:',
              style: AppTexto.cuerpo,
            ),
            const SizedBox(height: AppEspacio.md),
            _linea('Nombre registrado', widget.nombre),
            _linea('Registrado el', widget.registradoEl),
            const SizedBox(height: AppEspacio.sm),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _confirmado,
              onChanged: (v) =>
                  setState(() => _confirmado = v ?? false),
              title: const Text(
                  'La persona confirmó su nombre y su fecha '
                  'de registro',
                  style: AppTexto.cuerpo),
            ),
            const SizedBox(height: AppEspacio.sm),
            CampoTexto(
              controller: _ctrl,
              etiqueta: 'Clave nueva (6–32, sin espacios)',
              icono: Icons.lock_rounded,
              obscure: true,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppEspacio.sm),
            const Text(
              'Si quien reclama dice que el teléfono es suyo '
              'pero el nombre NO coincide, no ajustes la '
              'clave: elimina el invitado (libera el número '
              'al instante) o inscribe a la persona '
              'directamente como cliente.',
              style: AppTexto.secundario,
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: _confirmado && _claveValida
              ? () => Navigator.pop(context, _ctrl.text.trim())
              : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColores.naranja,
            foregroundColor: Colors.white,
          ),
          child: const Text('Ajustar clave'),
        ),
      ],
    );
  }
}
