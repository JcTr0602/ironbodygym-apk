import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth.dart';
import '../comunidad_panel.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'diseno.dart' show AppEspacio, AppRadio, AppTexto, RutaIron;
import 'componentes.dart';
import 'ficha.dart';

/// 1.27 (Comunidad MVP, Pieza G): «Comunidad» del
/// Panel — los perfiles que los clientes han hecho
/// visibles y el botón de ocultarlos.
///
/// 1.29 (Comunidad C3, DF-18): la pantalla pasa a
/// tres pestañas — Perfiles · Reportes · Historial —
/// para resolver un reporte en menos de un minuto
/// sin salir de su tarjeta: la cola trae la
/// proyección pública compacta del reportado, su
/// Nick anterior si lo hubo y quién reporta. Perfiles
/// gana el denominador «de N clientes» (COM-24), el
/// chip de nuevos de la semana (COM-25), «Ver como
/// lo ven los clientes» (COM-26) y «Borrar Nick»;
/// Historial lee el registro de moderación (COM-27);
/// y el bloqueo al resolver es POR TARJETA, no
/// global. Al abrir la pantalla, los reportes
/// pendientes quedan marcados como vistos por su id
/// mayor (DF-27; A1-M5-01: antes era el conteo y las
/// resoluciones lo movían): la tarjeta del Panel
/// solo volverá a enseñar la cifra cuando entren
/// reportes con ids nuevos.
///
/// El cliente manda sobre sus datos: esta pantalla
/// NO puede encender la vitrina de nadie ni ver lo
/// que el cliente apagó (eso ni siquiera sale del
/// servidor); solo puede OCULTAR un perfil del
/// directorio (p. ej. un nombre inadecuado), borrar
/// un Nick inadecuado y deshacer la ocultación. Las
/// RPC admin_comunidad_* validan es_admin en el
/// servidor. Cargadores inyectables para los tests.
class ComunidadPanelScreen extends StatefulWidget {
  final Future<Map<String, dynamic>> Function()? cargarPerfiles;
  final Future<Map<String, dynamic>> Function(
      int clienteId, bool ocultar)? ocultarPerfil;
  final Future<Map<String, dynamic>> Function()? cargarReportes;
  final Future<Map<String, dynamic>> Function(
      int reporteId, String accion)? resolverReporte;
  final Future<Map<String, dynamic>> Function()? cargarHistorial;
  final Future<Map<String, dynamic>> Function(int clienteId)?
      verPerfil;
  final Future<Map<String, dynamic>> Function(int clienteId)?
      borrarNick;

  /// 1.29 (Oleada 6, FB-20): abrir la ficha del cliente
  /// al tocar su tarjeta de perfil (costura para los
  /// tests; por defecto navega a FichaScreen).
  final void Function(int clienteId)? abrirFicha;

  /// 1.29 (Oleada 8, FB-20 reverso): texto inicial del
  /// buscador al abrir el panel ya filtrado (la ficha del
  /// cliente salta aquí con su nombre).
  final String? busquedaInicial;

  const ComunidadPanelScreen({
    super.key,
    this.cargarPerfiles,
    this.ocultarPerfil,
    this.cargarReportes,
    this.resolverReporte,
    this.cargarHistorial,
    this.verPerfil,
    this.borrarNick,
    this.abrirFicha,
    this.busquedaInicial,
  });

  @override
  State<ComunidadPanelScreen> createState() =>
      _ComunidadPanelScreenState();
}

class _ComunidadPanelScreenState extends State<ComunidadPanelScreen> {
  bool _cargando = true;
  bool _falloCarga = false;
  List<PerfilComunidadAdmin> _perfiles = const [];
  int _totalClientes = 0;
  int _reportesPendientes = 0;

  /// A1-M5-01: los ids de los reportes pendientes
  /// (la marca de vistos se ancla al id mayor).
  List<int> _idsReportesPendientes = const [];

  List<ReporteComunidadAdmin> _reportes = const [];
  bool _reportesCargados = false;
  bool _falloReportes = false;

  List<EventoModeracionComunidad> _historial = const [];
  bool _historialCargado = false;
  bool _falloHistorial = false;

  /// Bloqueo POR TARJETA (DF-18): ids en curso
  /// ('p<clienteId>' perfiles, 'r<reporteId>'
  /// reportes, 'n<clienteId>' nick).
  final Set<String> _ocupados = {};

  // 1.28 (M5-B4): el buscador de la lista (con dispose,
  // regla de la casa para controladores en diálogos y
  // pantallas).
  final _busquedaCtrl = TextEditingController();
  String _consulta = '';

  @override
  void initState() {
    super.initState();
    // FB-20 (reverso): el panel puede nacer ya filtrado
    // por un nombre (salto desde la ficha del cliente).
    final inicial = widget.busquedaInicial?.trim() ?? '';
    if (inicial.isNotEmpty) {
      _busquedaCtrl.text = inicial;
      _consulta = inicial;
    }
    // Sin sesión de dueño ni siquiera se disparan las
    // RPC de administración (ver la guarda en build).
    if (AuthService().isOwner) {
      _cargar();
      _cargarReportes();
      _cargarHistorial();
    }
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  // ── Cargadores reales (Supabase, timeout 12 s) ──

  Future<Map<String, dynamic>> _rpcReal(
      String nombre, [Map<String, dynamic>? params]) async {
    final res = await Supabase.instance.client
        .rpc(nombre, params: params)
        .timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    // 1.28 (M5-A2 ★): una respuesta que no es un mapa
    // es un FALLO, no un vacío legítimo.
    throw StateError('$nombre: respuesta no es un mapa');
  }

  Future<Map<String, dynamic>> _cargarReal() =>
      _rpcReal('admin_comunidad_perfiles');

  Future<Map<String, dynamic>> _ocultarReal(
          int clienteId, bool ocultar) =>
      _rpcReal('admin_comunidad_ocultar', {
        'p_cliente_id': clienteId,
        'p_ocultar': ocultar,
      });

  Future<Map<String, dynamic>> _reportesReal() =>
      _rpcReal('admin_comunidad_reportes');

  Future<Map<String, dynamic>> _resolverReal(
          int reporteId, String accion) =>
      _rpcReal('admin_comunidad_resolver_reporte', {
        'p_reporte_id': reporteId,
        'p_accion': accion,
      });

  Future<Map<String, dynamic>> _historialReal() =>
      _rpcReal('admin_comunidad_historial');

  Future<Map<String, dynamic>> _verReal(int clienteId) =>
      _rpcReal('admin_comunidad_ver_perfil', {
        'p_cliente_id': clienteId,
      });

  Future<Map<String, dynamic>> _borrarNickReal(int clienteId) =>
      _rpcReal('admin_comunidad_borrar_nick', {
        'p_cliente_id': clienteId,
      });

  // ── Cargas ──

  /// 1.34 Campo 2 (P-7): el Panel gana el gesto de
  /// bajar-para-actualizar en sus tres pestañas. Sus
  /// datos no son espejo: el cargador ES una consulta
  /// viva al servidor, así que el gesto re-consulta
  /// (perfiles, reportes e historial) sin pasar por la
  /// regla de frescura de los espejos.
  Future<void> _refrescarPanel() async {
    await _cargar();
    await _cargarReportes();
    await _cargarHistorial();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _falloCarga = false;
    });
    try {
      final json = await (widget.cargarPerfiles ?? _cargarReal)();
      if (!mounted) return;
      final raiz = parseRaizComunidad(json);
      setState(() {
        _perfiles = parsePerfilesComunidad(json);
        _totalClientes = raiz.totalClientes;
        _reportesPendientes = raiz.reportesPendientes;
        _idsReportesPendientes = parseIdsReportesPendientes(json);
        _cargando = false;
        // 1.28 (M5-A2 ★): un {ok:false} ES un fallo de
        // carga aunque el mapa venga vacío.
        _falloCarga = json['ok'] != true;
      });
      if (json['ok'] == true) _marcarReportesVistos();
    } catch (_) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
    }
  }

  /// DF-27: al abrir la lista, los reportes pendientes
  /// actuales quedan como «vistos» en este teléfono;
  /// la tarjeta del Panel enseña solo los que entren
  /// después. A1-M5-01: la marca es el ID MAYOR
  /// pendiente (no el conteo: las resoluciones movían
  /// el conteo y fabricaban «nuevos» ya vistos).
  Future<void> _marcarReportesVistos() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var maxId = 0;
      for (final id in _idsReportesPendientes) {
        if (id > maxId) maxId = id;
      }
      await prefs.setInt(
        claveReportesComunidadVistos(
            AuthService().telegramId ?? 0),
        maxId,
      );
    } catch (_) {}
  }

  Future<void> _cargarReportes() async {
    try {
      final json =
          await (widget.cargarReportes ?? _reportesReal)();
      if (!mounted) return;
      setState(() {
        _reportes = parseReportesComunidad(json);
        _reportesCargados = true;
        _falloReportes = json['ok'] != true;
        if (json['ok'] == true) {
          _reportesPendientes = _reportes.length;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _reportesCargados = true;
          _falloReportes = true;
        });
      }
    }
  }

  Future<void> _cargarHistorial() async {
    try {
      final json =
          await (widget.cargarHistorial ?? _historialReal)();
      if (!mounted) return;
      setState(() {
        _historial = parseHistorialComunidad(json);
        _historialCargado = true;
        _falloHistorial = json['ok'] != true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _historialCargado = true;
          _falloHistorial = true;
        });
      }
    }
  }

  // ── Acciones ──

  Future<void> _alternarOculto(PerfilComunidadAdmin p) async {
    final nuevo = !p.ocultoAdmin;
    final clave = 'p${p.clienteId}';
    setState(() => _ocupados.add(clave));
    try {
      final res = await (widget.ocultarPerfil ?? _ocultarReal)(
          p.clienteId, nuevo);
      if (!mounted) return;
      if (res['ok'] == true) {
        setState(() {
          _perfiles = [
            for (final x in _perfiles)
              if (x.clienteId == p.clienteId)
                x.conOculto(nuevo)
              else
                x,
          ];
        });
        _cargarHistorial();
      } else {
        _avisar('El servidor no aplicó el cambio. '
            'Inténtalo de nuevo.');
      }
    } catch (_) {
      if (mounted) {
        _avisar('Sin conexión no se pudo cambiar. '
            'Inténtalo de nuevo.');
      }
    } finally {
      if (mounted) setState(() => _ocupados.remove(clave));
    }
  }

  Future<void> _borrarNick(PerfilComunidadAdmin p) async {
    final confirma = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Borrar el Nick?'),
        content: Text(
          '«${p.nick}» dejará de verse y ${p.nombre} '
          'pasará a verse con su nombre en la '
          'Comunidad. Podrá elegir otro Nick cuando '
          'quiera. Su antigüedad y su vitrina no se '
          'tocan.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Borrar Nick'),
          ),
        ],
      ),
    );
    if (confirma != true || !mounted) return;
    final clave = 'n${p.clienteId}';
    setState(() => _ocupados.add(clave));
    try {
      final res =
          await (widget.borrarNick ?? _borrarNickReal)(p.clienteId);
      if (!mounted) return;
      if (res['ok'] == true) {
        setState(() {
          _perfiles = [
            for (final x in _perfiles)
              if (x.clienteId == p.clienteId) x.sinNick() else x,
          ];
        });
        _avisar('Nick retirado. El cliente verá el '
            'aviso en su vitrina.');
        _cargarHistorial();
      } else {
        _avisar('El servidor no retiró el Nick. '
            'Inténtalo de nuevo.');
      }
    } catch (_) {
      if (mounted) {
        _avisar('Sin conexión no se pudo retirar. '
            'Inténtalo de nuevo.');
      }
    } finally {
      if (mounted) setState(() => _ocupados.remove(clave));
    }
  }

  Future<void> _resolver(ReporteComunidadAdmin r,
      String accion) async {
    final clave = 'r${r.id}';
    setState(() => _ocupados.add(clave));
    try {
      final res = await (widget.resolverReporte ?? _resolverReal)(
          r.id, accion);
      if (!mounted) return;
      if (res['ok'] == true) {
        setState(() {
          _reportes = [
            for (final x in _reportes)
              if (x.id != r.id) x,
          ];
          _reportesPendientes = _reportes.length;
          if (accion == 'ocultar') {
            _perfiles = [
              for (final x in _perfiles)
                if (x.clienteId == r.reportadoId)
                  x.conOculto(true)
                else
                  x,
            ];
          }
        });
        _avisar(accion == 'ocultar'
            ? 'Perfil ocultado por el reporte.'
            : 'Reporte descartado.');
        _cargarHistorial();
      } else {
        _avisar('El servidor no resolvió el reporte. '
            'Inténtalo de nuevo.');
      }
    } catch (_) {
      if (mounted) {
        _avisar('Sin conexión no se pudo resolver. '
            'Inténtalo de nuevo.');
      }
    } finally {
      if (mounted) setState(() => _ocupados.remove(clave));
    }
  }

  Future<void> _verComoCliente(PerfilComunidadAdmin p) async {
    await Navigator.of(context).push(RutaIron(
      builder: (_) => _VerPerfilComunidadScreen(
        perfil: p,
        cargar: widget.verPerfil ?? _verReal,
        ocultar: (ocultar) async {
          final res =
              await (widget.ocultarPerfil ?? _ocultarReal)(
                  p.clienteId, ocultar);
          return res['ok'] == true;
        },
      ),
    ));
    // Al volver, la ocultación pudo cambiar dentro.
    if (mounted) _cargar();
  }

  // SL-10 G13-7: el aviso de la casa, no SnackBar crudo.
  void _avisar(String texto) {
    mostrarSnack(context, texto);
  }

  @override
  Widget build(BuildContext context) {
    // Delta Argón 1.27 (#5): guarda defensiva de
    // dueño, el mismo patrón de PremiosHubScreen.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Comunidad'),
        body: const Center(
            child: Text('Solo el dueño administra la comunidad.')),
      );
    }
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: appBarIron(context, 'Comunidad'),
        body: Column(
          children: [
            TabBar(
              tabs: [
                const Tab(text: 'Perfiles'),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Reportes'),
                      if (_reportesPendientes > 0) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .error,
                            borderRadius: BorderRadius.circular(
                                AppRadio.circular),
                          ),
                          child: Text(
                            '$_reportesPendientes',
                            style: AppTexto.minuscula.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Tab(text: 'Historial'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _cuerpoPerfiles(),
                  _cuerpoReportes(),
                  _cuerpoHistorial(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cuerpoPerfiles() {
    if (_cargando) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_falloCarga) {
      return _mensaje(
          'No se pudieron cargar los perfiles. '
          'Revisa la conexión e inténtalo de nuevo.',
          reintento: _cargar);
    }
    if (_perfiles.isEmpty) {
      return _mensaje('Ningún cliente ha creado su '
          'vitrina todavía. Cuando alguien la '
          'encienda en su app, aparecerá aquí.');
    }
    return _listaConBuscador();
  }

  /// Cabecera con los CONTEOS de la comunidad (con
  /// su denominador, COM-24) y el buscador por
  /// nombre; debajo, la lista filtrada. Los conteos
  /// son de la lista COMPLETA (no del filtro).
  Widget _listaConBuscador() {
    final conteos = conteosComunidad(_perfiles);
    final visibles =
        filtrarPerfilesComunidad(_perfiles, _consulta);
    // Yunque B (YB-FLU-05): esNuevo compara instantes: el
    // instante real UTC, no la hora de pared habanera.
    final nuevos = _perfiles
        .where((p) => p.esNuevo(ahoraUtcReal()))
        .length;
    // SL-10 G13-5: la cabecera va INTEGRADA en el scroll
    // (antes quedaba fija sobre la lista y empujaba la
    // primera tarjeta muy abajo en pantallas de 360 dp):
    // al bajar, la cabecera se va con la lista.
    final cabecera = Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'El cliente manda sobre sus datos: '
            'desde aquí solo puedes ocultar un '
            'perfil del directorio (y deshacerlo) '
            'y retirar un Nick inadecuado. '
            'Lo que cada cliente apagó no se ve '
            'ni aquí.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 10),
          Text(
            '${conteos.conVitrina} con vitrina '
            'de $_totalClientes clientes · '
            '${conteos.visibles} visibles en el directorio · '
            '${conteos.ocultosPorTi} ocultos por ti',
            style: AppTexto.secundario
                .copyWith(fontWeight: FontWeight.w700),
          ),
          if (nuevos > 0) ...[
            const SizedBox(height: AppEspacio.sm),
            Chip(
              avatar: const Icon(
                  Icons.fiber_new_rounded, size: 18),
              label: Text(nuevos == 1
                  ? '1 perfil nuevo esta semana'
                  : '$nuevos perfiles nuevos esta semana'),
              visualDensity: VisualDensity.compact,
            ),
          ],
          const SizedBox(height: 10),
          TextField(
            controller: _busquedaCtrl,
            decoration: InputDecoration(
              hintText: 'Buscar por nombre…',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: _consulta.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _busquedaCtrl.clear();
                        setState(() => _consulta = '');
                      },
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _consulta = v),
          ),
          const SizedBox(height: AppEspacio.xs),
        ],
      ),
    );
    if (visibles.isEmpty) {
      return Column(
        children: [
          cabecera,
          Expanded(
            child: _mensaje('Ningún perfil coincide con '
                '«$_consulta».'),
          ),
        ],
      );
    }
    return RefrescoIron(
      onRefresh: _refrescarPanel,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          cabecera,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              children: [
                for (final p in visibles) _tarjeta(p),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fechaCorta(String? iso) => fechaCortaHabana(iso);

  /// FB-20: el destino al tocar una tarjeta de perfil —
  /// la ficha del cliente en Gestión.
  void _abrirFichaDe(PerfilComunidadAdmin p) {
    final abrir = widget.abrirFicha;
    if (abrir != null) {
      abrir(p.clienteId);
      return;
    }
    Navigator.of(context).push(RutaIron(
      builder: (_) => FichaScreen(clienteId: p.clienteId),
    ));
  }

  Widget _tarjeta(PerfilComunidadAdmin p) {
    final estado = p.ocultoAdmin
        ? 'Oculto por administración'
        : p.visible
            ? 'Visible en el directorio'
            : 'Vitrina apagada (no aparece)';
    final ocupada = _ocupados.contains('p${p.clienteId}') ||
        _ocupados.contains('n${p.clienteId}');
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      // FB-20: tocar la tarjeta abre la ficha del cliente;
      // los botones de la tarjeta (Ver perfil, Borrar
      // Nick, Ocultar/Mostrar) siguen siendo suyos y no
      // disparan la navegación.
      child: InkWell(
        onTap: () => _abrirFichaDe(p),
        child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              p.nick == null
                  ? p.nombre
                  : '${p.nombre} · «${p.nick}»',
              style: AppTexto.subtitulo
                  .copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              '$estado'
              '${p.bloquesActivos.isEmpty ? '' : '\nComparte: ${p.bloquesActivos.join(', ')}'}'
              '${p.altaEn == null ? '' : '\nEn la Comunidad desde el ${_fechaCorta(p.altaEn)}'}',
              style: const TextStyle(height: 1.35),
            ),
            Row(
              children: [
                TextButton(
                  onPressed:
                      ocupada ? null : () => _verComoCliente(p),
                  child: const Text('Ver perfil'),
                ),
                const Spacer(),
                if (p.nick != null)
                  TextButton(
                    onPressed:
                        ocupada ? null : () => _borrarNick(p),
                    child: const Text('Borrar Nick'),
                  ),
                TextButton(
                  onPressed:
                      ocupada ? null : () => _alternarOculto(p),
                  child: Text(p.ocultoAdmin ? 'Mostrar' : 'Ocultar'),
                ),
              ],
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _cuerpoReportes() {
    if (!_reportesCargados) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_falloReportes) {
      return _mensaje(
          'No se pudo cargar la cola de reportes. '
          'Revisa la conexión e inténtalo de nuevo.',
          reintento: _cargarReportes);
    }
    if (_reportes.isEmpty) {
      return _mensaje('Sin reportes pendientes. '
          'Cuando un cliente reporte un perfil, '
          'aparecerá aquí para resolverlo.');
    }
    return RefrescoIron(
      onRefresh: _refrescarPanel,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        itemCount: _reportes.length,
        itemBuilder: (context, i) => _tarjetaReporte(_reportes[i]),
      ),
    );
  }

  /// La tarjeta autocontenida del reporte (DF-18):
  /// quién, por qué, qué comparte y quién reporta —
  /// y las dos resoluciones sin salir de ella.
  Widget _tarjetaReporte(ReporteComunidadAdmin r) {
    final ocupado = _ocupados.contains('r${r.id}');
    final nombreReportado = r.reportadoNick ??
        r.reportadoNombreReal;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$nombreReportado'
              '${r.reportadoNick == null ? '' : ' (${r.reportadoNombreReal})'}',
              style: AppTexto.subtitulo
                  .copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              '${motivoReporteTexto(r.motivo)}'
              '${r.creadoEn == null ? '' : ' · ${_fechaCorta(r.creadoEn)}'}'
              '\nReporta: ${r.reportanteNick ?? r.reportanteNombreReal}'
              '${r.bloquesProyeccion.isEmpty ? '' : '\nComparte: ${r.bloquesProyeccion.join(', ')}'}'
              '${r.reportadoNickAnterior == null ? '' : '\nNick anterior retirado: «${r.reportadoNickAnterior}»'}',
              style: const TextStyle(height: 1.35),
            ),
            Row(
              children: [
                const Spacer(),
                TextButton(
                  onPressed: ocupado
                      ? null
                      : () => _resolver(r, 'descartar'),
                  child: const Text('Descartar'),
                ),
                const SizedBox(width: AppEspacio.xs),
                FilledButton(
                  onPressed: ocupado
                      ? null
                      : () => _resolver(r, 'ocultar'),
                  child: const Text('Ocultar perfil'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _cuerpoHistorial() {
    if (!_historialCargado) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_falloHistorial) {
      return _mensaje(
          'No se pudo cargar el historial. '
          'Revisa la conexión e inténtalo de nuevo.',
          reintento: _cargarHistorial);
    }
    if (_historial.isEmpty) {
      return _mensaje('Todavía no hay movimientos '
          'de moderación. Las ocultaciones, los '
          'Nicks retirados y los reportes '
          'resueltos quedarán registrados aquí.');
    }
    return RefrescoIron(
      onRefresh: _refrescarPanel,
      child: ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _historial.length,
      itemBuilder: (context, i) {
        final e = _historial[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(e.accionTexto),
          subtitle: Text(
            '${e.nombreReal ?? 'Cliente'}'
            '${e.nick == null ? '' : ' · «${e.nick}»'}'
            '${e.creadoEn == null ? '' : ' · ${_fechaCorta(e.creadoEn)}'}',
          ),
        );
      },
      ),
    );
  }

  Widget _mensaje(String texto, {VoidCallback? reintento}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(texto,
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.4)),
            if (reintento != null) ...[
              const SizedBox(height: 14),
              FilledButton(
                  onPressed: reintento,
                  child: const Text('Reintentar')),
            ],
          ],
        ),
      ),
    );
  }
}

/// 1.32 (H-B7-2/B567): la fecha corta (d/m/aaaa) de un
/// instante del servidor, compuesta en hora de La Habana:
/// antes se componía del día/mes/año del instante UTC
/// crudo y un alta de las 21:30 habaneras se pintaba con
/// el día siguiente. Función pura.
String fechaCortaHabana(String? iso) {
  final d = DateTime.tryParse(iso ?? '');
  if (d == null) return '';
  final h = d.isUtc ? aHabana(d) : d;
  return '${h.day}/${h.month}/${h.year}';
}

/// 1.29 (Comunidad C3, COM-25 + DF-27): cuántos
/// reportes de la Comunidad son NUEVOS para el
/// dueño — los pendientes por encima de la marca de
/// vistos que la pantalla de Comunidad guarda al
/// abrirse — para el distintivo de su tarjeta en el
/// Panel sin obligar a entrar. null = no se pudo
/// saber (sin conexión o respuesta degradada):
/// quien llama NO enseña un 0 mentiroso.
Future<int?> contarReportesComunidadNuevos() async {
  try {
    final res = await Supabase.instance.client
        .rpc('admin_comunidad_perfiles')
        .timeout(const Duration(seconds: 12));
    final prefs = await SharedPreferences.getInstance();
    final vistos = prefs.getInt(claveReportesComunidadVistos(
            AuthService().telegramId ?? 0)) ??
        0;
    // 1.32 (H-RPC-5/B1-H5): el {ok:false} devuelve null
    // vía la función pura (antes degradaba a un 0 falso).
    return reportesNuevosDesdeRespuesta(res, vistos);
  } catch (_) {
    return null;
  }
}

/// COM-26: el perfil TAL COMO lo ven los clientes —
/// la proyección pública del servidor, no una
/// reconstrucción local. Si está ocultado, la
/// franja lo dice y la proyección sigue disponible
/// para juzgar antes de «Mostrar». Una sola acción
/// de moderación: Ocultar/Mostrar.
class _VerPerfilComunidadScreen extends StatefulWidget {
  final PerfilComunidadAdmin perfil;
  final Future<Map<String, dynamic>> Function(int clienteId)
      cargar;
  final Future<bool> Function(bool ocultar) ocultar;

  const _VerPerfilComunidadScreen({
    required this.perfil,
    required this.cargar,
    required this.ocultar,
  });

  @override
  State<_VerPerfilComunidadScreen> createState() =>
      _VerPerfilComunidadScreenState();
}

class _VerPerfilComunidadScreenState
    extends State<_VerPerfilComunidadScreen> {
  bool _cargando = true;
  bool _fallo = false;
  bool _aplicando = false;
  Map<String, dynamic> _proyeccion = const {};
  List<String> _apagados = const [];
  late bool _oculto;

  @override
  void initState() {
    super.initState();
    _oculto = widget.perfil.ocultoAdmin;
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final json = await widget.cargar(widget.perfil.clienteId);
      if (!mounted) return;
      final v = parseVerPerfilComunidad(json);
      setState(() {
        _proyeccion = v.proyeccion;
        _apagados = v.apagados;
        _oculto = v.ocultoAdmin;
        _fallo = !v.ok;
        _cargando = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _fallo = true;
          _cargando = false;
        });
      }
    }
  }

  Future<void> _alternar() async {
    setState(() => _aplicando = true);
    final ok = await widget.ocultar(!_oculto);
    if (!mounted) return;
    setState(() {
      _aplicando = false;
      if (ok) _oculto = !_oculto;
    });
    // SL-10 G13-7: el aviso de la casa, no SnackBar crudo.
    mostrarSnack(
      context,
      ok
          ? (_oculto
              ? 'Perfil ocultado del directorio.'
              : 'Perfil visible de nuevo.')
          : 'El servidor no aplicó el cambio. '
              'Inténtalo de nuevo.',
      significado:
          ok ? SignificadoChip.exito : SignificadoChip.error,
    );
  }

  String _resumenBloque(String clave, dynamic v) {
    if (v is Map) {
      switch (clave) {
        case 'marcas':
          final lista = v['lista'];
          return lista is List
              ? '${lista.length} marcas publicadas'
              : 'Marcas publicadas';
        case 'actividad':
          return v['ultima'] != null
              ? 'Última sesión: ${v['ultima']}'
              : 'Actividad reciente';
        case 'rutina':
          return 'Rutina: ${v['nombre'] ?? 'sin nombre'}';
        case 'constancia':
          return 'Constancia verificada'
              '${v['dias'] != null ? ' · ${v['dias']} días' : ''}';
        case 'nivel':
          return 'Nivel: ${v['etiqueta'] ?? v['nivel'] ?? ''}';
        case 'logros':
          final s = v['sello'];
          final n = s is List ? s.length : 0;
          final vales = v['vales'];
          final nv = vales is List ? vales.length : 0;
          return '$n insignias · $nv vales';
      }
    }
    return 'Compartido';
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.perfil;
    return Scaffold(
      appBar: appBarIron(context, 'Así lo ven los clientes'),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _fallo
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'No se pudo cargar la vista '
                          'pública de este perfil.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 14),
                        FilledButton(
                          onPressed: () {
                            setState(() => _cargando = true);
                            _cargar();
                          },
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView(
                  padding:
                      const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    if (_oculto)
                      Container(
                        padding:
                            const EdgeInsets.all(AppEspacio.md),
                        margin: const EdgeInsets.only(
                            bottom: AppEspacio.md),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .errorContainer,
                          borderRadius: BorderRadius.circular(
                              AppRadio.md),
                        ),
                        child: const Text(
                          'Oculto por administración: '
                          'los clientes NO ven este '
                          'perfil. Esto es lo que se '
                          'vería si lo muestras.',
                        ),
                      ),
                    Text(
                      '${_proyeccion['identidad'] ?? p.nombre}',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 18),
                    ),
                    Text(
                      'Nombre real: ${p.nombre}'
                      '${p.nick == null ? '' : ' · Nick: «${p.nick}»'}',
                      style: const TextStyle(height: 1.4),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'LO QUE COMPARTE',
                      style: AppTexto.etiqueta.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6),
                    ),
                    const SizedBox(height: 6),
                    for (final e in _proyeccion.entries)
                      if (!const {
                        'cliente_id',
                        'color_idx',
                        'identidad',
                        'foto',
                        'es_nuevo',
                        'reducido',
                        'ok',
                      }.contains(e.key))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          // SL-10 G13-1: etiqueta humana
                          // por clave, no la clave cruda.
                          title: Text(
                              etiquetaBloqueComunidad(e.key)),
                          subtitle:
                              Text(_resumenBloque(e.key, e.value)),
                        ),
                    if (_apagados.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'APAGADO POR EL CLIENTE (NO VIAJA)',
                        style: AppTexto.etiqueta.copyWith(
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6),
                      ),
                      const SizedBox(height: 6),
                      // SL-10 G13-1: también en humano.
                      Text(_apagados
                          .map(etiquetaBloqueComunidad)
                          .join(', ')),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _aplicando ? null : _alternar,
                      child: Text(
                          _oculto ? 'Mostrar' : 'Ocultar'),
                    ),
                  ],
                ),
    );
  }
}
