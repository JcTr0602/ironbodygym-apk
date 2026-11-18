/// 1.32 «Mostrador Táctico» — Lupa de Comando Universal (G-07).
///
/// La lupa de la cabecera: busca SIN salir del marco sobre el
/// SQLite local — clientes por nombre en cualquier orden y sin
/// tildes, o por los últimos 4 dígitos del teléfono, y (solo
/// dueño) las herramientas del Panel por nombre y sinónimo.
/// Todo con las funciones PURAS del buscador del Panel de la
/// 1.25 ([buscarClientesPanel], [buscarFuncionesPanel],
/// [normalizarTextoPanel]): una sola tolerancia en la casa.
///
/// Recientes: los últimos 5 destinos usados (clientes o
/// funciones), en SharedPreferences. Nada de esto toca la red:
/// el espejo local es la fuente (Compuerta: pintar local).
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import 'ajustes.dart';
import 'app_bar.dart';
import 'auditoria.dart';
import 'auditoria_persona.dart';
import 'auditoria_silenciosa.dart';
import 'avisos_entrenador.dart';
import 'bandeja.dart';
import 'buscar.dart';
import 'categorias_suplemento.dart';
import 'centro_compras.dart';
import 'centro_control.dart';
import 'cola.dart';
import 'comparativa_mensual.dart';
import 'componentes.dart';
import 'congelaciones.dart';
import 'congelados.dart';
import 'control_acceso.dart';
import 'cumpleanos.dart';
import 'diseno.dart';
import 'editor_rutinas_gym.dart';
import 'ficha.dart';
import 'gastos.dart';
import 'historial_caja.dart';
import 'historial_ventas.dart';
import 'horario_gym.dart';
import 'hub_comunicacion.dart';
import 'incidencias/lista_incidencias.dart';
import 'incidencias_sync.dart';
import 'invitados.dart';
import 'marco.dart';
import 'pagos_por_metodo.dart';
import 'panel_buscador.dart';
import 'admin_secciones.dart';
import 'guia.dart';
import 'panel_bloque2.dart';
import 'panel_resto_config.dart';
import 'panel_resto_sistema.dart';
import 'plantillas_mensaje.dart';
import 'publicador.dart';
import 'tarifas_especiales.dart';
import 'panel_candado.dart';
import 'panel_comunidad.dart';
import 'panel_permisos.dart';
import 'panel_premios_hub.dart';
import 'panel_resto_caja.dart';
import 'papelera.dart';
import 'por_cobrar.dart';
import 'recordatorios.dart';
import 'reportes_plus.dart';
import 'reservas.dart';
import 'riesgo.dart';
import 'salud_sync_screen.dart';
import 'servicios_admin.dart';
import 'solicitudes_adelanto.dart';
import 'suplementos.dart';
import 'turnos_hub.dart';
import 'usuarios.dart';

/// Yunque Exhaustivo 1.35 (C-2): destinos del resolvedor que son
/// SOLO del dueño (pantallas que se autoprotegen o cuyo contenido
/// es del dueño: las dos de congelaciones y el Control de
/// Acceso). [abrirFuncionLupa] no navega a ellos con una sesión
/// que no sea la del dueño, aunque el id llegue por un reciente
/// guardado por otra sesión en el mismo aparato.
const destinosSoloDuenoLupa = <String>{
  'congelaciones',
  'congeladas',
  'usuarios',
};

/// ¿El destino [id] de la Lupa es solo del dueño?
bool destinoLupaEsSoloDueno(String id) =>
    destinosSoloDuenoLupa.contains(id);

/// Yunque Exhaustivo 1.35 (C-2): los recientes de FUNCIONES de
/// la Lupa, con la MISMA puerta de rol que la búsqueda de
/// herramientas (en build, las funciones solo se buscan si
/// esDueno): para un no-dueño la lista es vacía, así un reciente
/// guardado por la sesión del dueño (la clave lupa_recientes_v1
/// no se limpia al cerrar sesión) no se ofrece a la sesión del
/// entrenador. PURO: [esDueno] entra como dato para fijarlo en
/// tests sin sesión.
List<FuncionPanel> recientesFuncionesLupa(List<String> recientes,
    {required bool esDueno}) {
  if (!esDueno) return const [];
  return recientesPanel(
      recientes.where((r) => !r.startsWith('cliente:')).toList());
}

const _kRecientesLupa = 'lupa_recientes_v1';
// 1.35 (UI-06): la fila de recientes enseña hasta 5
// destinos (antes 3), como el Directorio.
const _kMaxRecientesLupa = 5;

/// Resolvedor ÚNICO de destinos por id (1.32, Oleada 2 F1 —
/// desviación 3 de Argón): lo usan la Lupa y el buscador del
/// Panel clásico (admin.dart delega aquí todo lo que no está
/// atado al estado del Panel). Los destinos atados a estado
/// del Panel viejo (cierre de caja, liquidar, nómina,
/// exportaciones) saltan a su pestaña del Pilar 4 por
/// [MarcoNav]: el marco es su casa nueva.
///
/// [cerrarActual]: la Lupa es una pantalla pasajera y se
/// cierra antes de empujar el destino (true, el defecto); el
/// Panel queda DEBAJO del destino y no se cierra (false).
/// Los saltos de pilar siempre cierran la pantalla actual:
/// su destino es la cáscara, no una ruta encima.
///
/// Devuelve el futuro de la ruta empujada (completa al
/// volver), para que el llamador pueda recargar al regreso;
/// en los saltos de pilar completa de inmediato.
Future<void> abrirFuncionLupa(BuildContext context, String id,
    {bool cerrarActual = true}) {
  // Yunque Exhaustivo 1.35 (C-2): puerta de rol del resolvedor —
  // a un destino solo-dueño no se navega con otra sesión, venga
  // el id de donde venga (recientes incluidos). Sin sesión
  // resoluble se falla CERRADO, como esVistaProtegida.
  if (destinoLupaEsSoloDueno(id)) {
    var dueno = false;
    try {
      dueno = AuthService().isOwner;
    } catch (_) {
      dueno = false;
    }
    if (!dueno) return Future<void>.value();
  }
  var navegacion = Future<void>.value();
  void ir(Widget pantalla) {
    if (cerrarActual) Navigator.of(context).pop();
    navegacion =
        Navigator.of(context).push(RutaIron(builder: (_) => pantalla));
  }

  void irPilar(VoidCallback salto) {
    Navigator.of(context).pop();
    salto();
  }

  switch (id) {
    case 'centro_control':
      ir(const CentroControlScreen());
    case 'comunicacion':
      ir(const HubComunicacionScreen());
    case 'arqueo':
      irPilar(() => MarcoNav.irANegocio('caja'));
    case 'cierre_caja':
      irPilar(() => MarcoNav.irANegocio('caja'));
    case 'liquidar':
      irPilar(() => MarcoNav.irANegocio('caja'));
    case 'extracto':
      ir(const CentroComprasScreen());
    case 'gastos':
      ir(const GastosScreen());
    case 'historial_caja':
      ir(const HistorialCajaScreen());
    case 'pagos_metodo':
      ir(const PagosPorMetodo());
    case 'comparativa':
      ir(const ComparativaMensual());
    case 'ingresos_periodo':
      ir(const IngresosPeriodoScreen());
    case 'nomina':
      irPilar(() => MarcoNav.irANegocio('nomina'));
    case 'nomina_precalculada':
      ir(const NominaPrecalculadaScreen());
    case 'adelantos':
      ir(const AdelantosListaScreen());
    case 'solicitudes_adelanto':
      ir(const SolicitudesAdelantoScreen());
    case 'congelaciones':
      ir(const CongelacionesScreen());
    case 'usuarios':
      ir(const ControlAccesoScreen());
    case 'candado':
      ir(const PanelCandadoScreen());
    case 'recuperar':
      ir(const RiesgoScreen());
    case 'congeladas':
      ir(const CongeladosScreen());
    case 'papelera':
      ir(const PapeleraScreen());
    case 'cuentas_casa':
      ir(const CuentasCasaScreen());
    case 'vencimientos':
      irPilar(() => MarcoNav.irAClientes(
          const DestinoClientes(segmento: 'vencimientos', tabListas: 0)));
    case 'cumpleanos':
      ir(const CumpleanosScreen());
    case 'solicitudes_invitados':
      irPilar(() => MarcoNav.irAClientes(
          const DestinoClientes(segmento: 'invitados')));
    case 'invitados_frecuentes':
      ir(const InvitadosFrecuentesScreen());
    case 'plantillas':
      ir(const PlantillasScreen());
    case 'avisos_entrenadores':
      ir(const AvisosEntrenadorScreen());
    case 'avisos_clientes':
      // 1.32 (Fase 3): el destino es el Publicador
      // Unificado con el segmento de Avisos abierto.
      ir(const PublicadorScreen(segmentoInicial: 1));
    case 'recordatorios':
      ir(const RecordatoriosScreen());
    case 'info_publica':
      ir(const InfoPublicaScreen());
    case 'entrenadores_apk':
      ir(const UsuariosScreen());
    case 'plan_turnos':
      ir(const TurnosHubScreen());
    case 'horario_apertura':
      ir(const HorarioGym());
    case 'permisos':
      ir(const PanelPermisos());
    case 'permisos_explicados':
      Navigator.of(context).pop();
      mostrarPermisosExplicados(context);
    case 'suplementos':
      ir(const SuplementosScreen());
    case 'categorias':
      ir(const CategoriasSuplementoScreen());
    case 'historial_ventas':
      ir(const HistorialVentasScreen());
    case 'fiados':
      ir(const PorCobrarScreen(pestanaInicial: 1));
    case 'sin_foto':
      ir(const SinFotoPrecioScreen());
    case 'botes':
      ir(const ServiciosAdminScreen());
    case 'reportes_plus':
      ir(const ReportesPlusScreen());
    case 'reservas':
      ir(const ReservasScreen());
    case 'biblioteca':
      ir(const BibliotecaScreen());
    case 'rutinas_gym':
      ir(const EditorRutinasGymScreen());
    case 'bandeja_gympedia':
      ir(const BandejaScreen());
    case 'precios_metodo':
      ir(const PreciosMetodoScreen());
    case 'tipos_pago':
      ir(const AjustesScreen());
    case 'tarifas':
      ir(const TarifasScreen());
    case 'bancarios':
      ir(const AjustesScreen());
    case 'pago_base':
      irPilar(() => MarcoNav.irANegocio('nomina'));
    case 'ajustes_gym':
      ir(const AjustesGymScreen());
    case 'registro_mensual':
      ir(const RegistroMensualScreen());
    case 'estado_sync':
      ir(const SaludSyncScreen());
    case 'cola_sync':
      ir(const ColaScreen());
    case 'historial_sync':
      ir(const HistorialSyncScreen());
    case 'verificacion_espejo':
      ir(const VerificacionEspejoScreen());
    case 'incidencias':
      ir(const ListaIncidenciasScreen());
    case 'incidencias_sync':
      ir(const IncidenciasSyncScreen());
    case 'premios':
      ir(const PremiosHubScreen());
    case 'comunidad':
      ir(const ComunidadPanelScreen());
    case 'errores_sync':
      ir(const ErroresSyncPanelScreen());
    case 'auditoria':
      ir(const AuditoriaScreen());
    case 'auditoria_persona':
      ir(const AuditoriaPersonaScreen());
    case 'anomalias':
      ir(const AuditoriaSilenciosaScreen());
    case 'mantenimiento':
      ir(const MantenimientoScreen());
    case 'copia':
      ir(const CopiaSeguridadScreen());
    case 'exportar_csv':
      irPilar(() => MarcoNav.irANegocio('reglas'));
    case 'exportar_excel':
      irPilar(() => MarcoNav.irANegocio('reglas'));
    case 'bitacora':
      irPilar(() => MarcoNav.irANegocio('reglas'));
    case 'bajada':
      ir(const BajadaCompletaScreen());
  }
  return navegacion;
}

/// La pantalla de la lupa: campo arriba, recientes con el
/// campo vacío y resultados (Clientes · Herramientas) al
/// teclear. Todo local.
class LupaUniversalScreen extends StatefulWidget {
  const LupaUniversalScreen({super.key});

  @override
  State<LupaUniversalScreen> createState() => _LupaUniversalScreenState();
}

class _LupaUniversalScreenState extends State<LupaUniversalScreen> {
  final _ctrl = TextEditingController();
  final _foco = FocusNode();
  final _auth = AuthService();
  List<Map<String, dynamic>> _clientes = const [];
  List<String> _recientes = const [];
  String _consulta = '';
  // 1.36 H-B2 (136-572): la primera carga del espejo se
  // distingue del vacío: hasta que termina, hay indicador.
  bool _cargando = true;
  // 1.36 H-C1 (136-571): el fallo del espejo tiene estado
  // propio (con Reintentar); ya no se funde con el vacío.
  bool _errorCarga = false;

  @override
  void initState() {
    super.initState();
    _cargar();
    // 136-579: foco al entrar, como en el panel buscador.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _foco.requestFocus());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _foco.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    try {
      final filas = await LocalDb.instance.allMirror('clientes');
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      // 1.36 H-C1 (136-573): poda de recientes caducos al
      // cargar — cliente que ya no está en el espejo o
      // función que ya no existe en el catálogo.
      final idsClientes = {for (final c in filas) '${c['id']}'};
      final idsFunciones = {for (final f in catalogoFuncionesPanel) f.id};
      final guardados =
          prefs.getStringList(_kRecientesLupa) ?? const [];
      final vigentes = guardados
          .where((r) => r.startsWith('cliente:')
              ? idsClientes.contains(r.substring(8))
              : idsFunciones.contains(r))
          .toList();
      if (vigentes.length != guardados.length) {
        await prefs.setStringList(_kRecientesLupa, vigentes);
      }
      setState(() {
        _clientes = filas;
        _recientes = vigentes;
        _cargando = false;
        _errorCarga = false;
      });
    } catch (_) {
      // 1.36 H-C1 (136-571): el fallo se DICE (estado de
      // error con Reintentar), no se disfraza de vacío.
      if (mounted) {
        setState(() {
          _cargando = false;
          _errorCarga = true;
        });
      }
    }
  }

  // 1.36 H-B2 (136-581): borrado individual y total de
  // recientes, persistido en la misma clave.
  Future<void> _borrarReciente(String id) async {
    setState(() =>
        _recientes = _recientes.where((r) => r != id).toList());
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kRecientesLupa, _recientes);
    } catch (_) {}
  }

  Future<void> _borrarRecientes() async {
    setState(() => _recientes = const []);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kRecientesLupa);
    } catch (_) {}
  }

  Future<void> _registrarReciente(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lista = [
        id,
        ..._recientes.where((r) => r != id),
      ].take(_kMaxRecientesLupa).toList();
      await prefs.setStringList(_kRecientesLupa, lista);
    } catch (_) {}
  }

  void _abrirCliente(int clienteId) {
    _registrarReciente('cliente:$clienteId');
    Navigator.of(context).pop();
    Navigator.of(context).push(
      RutaIron(builder: (_) => FichaScreen(clienteId: clienteId)),
    );
  }

  void _abrirFuncion(FuncionPanel f) {
    // Yunque Exhaustivo 1.35 (C-2): la misma puerta que la
    // búsqueda de herramientas — las funciones del Panel solo
    // se ofrecen (y solo se abren) con la sesión del dueño; un
    // toque sobre un reciente de otra sesión no navega.
    if (!_auth.isOwner) return;
    _registrarReciente(f.id);
    abrirFuncionLupa(context, f.id);
  }

  Widget _filaCliente(Map<String, dynamic> c, {bool compacta = false}) {
    final id = (c['id'] as num?)?.toInt() ?? 0;
    // 1.35 (UI-05): la fila del directorio (foto, chip de
    // estado) en vez del ListTile pelado: el estado del
    // cliente se decide en el propio resultado. La línea
    // de contacto solo desambigua cuando la vista no es
    // protegida (la regla de FilaCliente: un protegido
    // nunca filtra su contacto a un no-dueño). La acción
    // directa de WhatsApp NO se duplica aquí: su regla
    // entera (pausa, Casa, mensaje) vive en Buscar y la
    // fila abre la ficha, donde la acción existe.
    return FilaCliente(
      cliente: c,
      compacta: compacta,
      desambiguar: !esVistaProtegida(c, esDueno: _auth.isOwner),
      onTap: id > 0 ? () => _abrirCliente(id) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final esDueno = _auth.isOwner;
    final buscando = _consulta.trim().isNotEmpty;
    final clientesRes =
        buscando ? buscarClientesPanel(_consulta, _clientes) : const [];
    final funcionesRes = (buscando && esDueno)
        ? buscarFuncionesPanel(_consulta)
        : const <FuncionPanel>[];
    return Scaffold(
      // 1.35 (UI-05): la cabecera de la casa, no un AppBar
      // crudo.
      appBar: appBarIron(context, 'Buscar en el gym'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, AppEspacio.sm),
            child: CampoTexto(
              controller: _ctrl,
              focusNode: _foco,
              accionTexto: TextInputAction.search,
              onSubmitted: (_) => _foco.unfocus(),
              hint: 'Nombre, teléfono o herramienta…',
              icono: Icons.search_rounded,
              onChanged: (v) => setState(() => _consulta = v),
            ),
          ),
          Expanded(
            // 136-578: cruce por modo (recientes/resultados)
            // con clave, sin sustituir de golpe.
            child: AnimatedSwitcher(
              duration:
                  AppMovimiento.resuelta(context, AppMovimiento.corta),
              child: _cargando && _clientes.isEmpty && _recientes.isEmpty
                  ? const EstadoCargando(
                      key: ValueKey('lupa-cargando'),
                      texto: 'Cargando el espejo…')
                  : _errorCarga && _clientes.isEmpty
                      ? EstadoError(
                          key: const ValueKey('lupa-error'),
                          titulo: 'No se pudo leer el espejo',
                          detalle: 'La búsqueda no tiene datos '
                              'que consultar en este teléfono.',
                          onReintentar: _cargar)
                      : !buscando
                      ? _recientesVista()
                      : ListView(
                    key: const ValueKey('lupa-resultados'),
                    children: [
                      if (clientesRes.isNotEmpty) ...[
                        const EncabezadoSeccion(titulo: 'CLIENTES'),
                        for (final c in clientesRes) _filaCliente(c),
                      ],
                      if (funcionesRes.isNotEmpty) ...[
                        const EncabezadoSeccion(titulo: 'HERRAMIENTAS'),
                        for (final f in funcionesRes)
                          ListTile(
                            leading: Icon(f.icono),
                            title: Text(f.titulo),
                            subtitle:
                                f.detalle == null ? null : Text(f.detalle!),
                            onTap: () => _abrirFuncion(f),
                          ),
                      ],
                      if (clientesRes.isEmpty && funcionesRes.isEmpty)
                        // 1.35 (UI-10): el «sin resultados»
                        // con el vacío de la casa.
                        const EstadoVacio(
                          icono: Icons.search_off_rounded,
                          titulo: 'Sin resultados en este teléfono',
                          subtitulo:
                              'Si el cliente aún no sincronizó, '
                              'no aparece aquí.',
                        ),
                    ],
                  ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _recientesVista() {
    if (_recientes.isEmpty) {
      // 136-577: vacío centrado de la casa (antes un párrafo
      // suelto en la esquina).
      return const EstadoVacio(
        key: ValueKey('lupa-recientes'),
        icono: Icons.history_rounded,
        titulo: 'Sin recientes todavía',
        subtitulo: 'Escribe un nombre (en cualquier orden, sin '
            'tildes), los últimos 4 dígitos de un teléfono o el '
            'nombre de una herramienta.',
      );
    }
    // C-2: los recientes de funciones pasan por la puerta de
    // rol (recientesFuncionesLupa); los de cliente se pintan
    // abajo con la vista protegida del rol vigente, como antes.
    final funciones =
        recientesFuncionesLupa(_recientes, esDueno: _auth.isOwner);
    final porId = {for (final c in _clientes) '${c['id']}': c};
    // 1.36 H-C1 (136-573): la cabecera RECENTES solo se
    // pinta si queda algo VISIBLE tras el filtrado (rol e
    // ids caducos); si todo se filtró, el vacío honesto.
    final hayClientesVisibles = _recientes.any(
        (r) => r.startsWith('cliente:') && porId[r.substring(8)] != null);
    if (!hayClientesVisibles && funciones.isEmpty) {
      return const EstadoVacio(
        key: ValueKey('lupa-recientes'),
        icono: Icons.history_rounded,
        titulo: 'Sin recientes todavía',
        subtitulo: 'Escribe un nombre (en cualquier orden, sin '
            'tildes), los últimos 4 dígitos de un teléfono o el '
            'nombre de una herramienta.',
      );
    }
    return ListView(
      key: const ValueKey('lupa-recientes'),
      children: [
        // 136-581: «Borrar recientes» en el propio encabezado.
        EncabezadoSeccion(
          titulo: 'RECIENTES',
          accionTexto: 'Borrar recientes',
          onAccion: _borrarRecientes,
        ),
        for (final r in _recientes) ...[
          if (r.startsWith('cliente:') &&
              porId[r.substring(8)] != null)
            // 136-581: borrado individual por fila.
            FilaCliente(
              cliente: porId[r.substring(8)]!,
              compacta: true,
              desambiguar:
                  !esVistaProtegida(porId[r.substring(8)]!,
                      esDueno: _auth.isOwner),
              trailing: IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: 'Quitar de recientes',
                onPressed: () => _borrarReciente(r),
              ),
              onTap: () => _abrirCliente(
                  (porId[r.substring(8)]!['id'] as num).toInt()),
            ),
          if (!r.startsWith('cliente:'))
            for (final f in funciones)
              if (f.id == r)
                ListTile(
                  leading: Icon(f.icono),
                  title: Text(f.titulo),
                  trailing: IconButton(
                    icon: const Icon(Icons.close_rounded, size: 18),
                    tooltip: 'Quitar de recientes',
                    onPressed: () => _borrarReciente(r),
                  ),
                  onTap: () => _abrirFuncion(f),
                ),
        ],
      ],
    );
  }
}
