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
/// Recientes: los últimos 3 destinos usados (clientes o
/// funciones), en SharedPreferences. Nada de esto toca la red:
/// el espejo local es la fuente (Compuerta: pintar local).
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth.dart';
import '../localdb.dart';
import 'ajustes.dart';
import 'auditoria.dart';
import 'auditoria_persona.dart';
import 'auditoria_silenciosa.dart';
import 'avisos_entrenador.dart';
import 'bandeja.dart';
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
import 'editor_avisos_clientes.dart';
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

const _kRecientesLupa = 'lupa_recientes_v1';
const _kMaxRecientesLupa = 3;

/// Resolvedor de la lupa: el MISMO destino que abriría la
/// tarjeta del Panel (admin.dart) para cada id del catálogo.
/// Los destinos atados a estado del Panel viejo (cierre de
/// caja, liquidar, nómina, exportaciones) saltan a su pestaña
/// del Pilar 4 por [MarcoNav]: el marco es su casa nueva.
void abrirFuncionLupa(BuildContext context, String id) {
  void ir(Widget pantalla) {
    Navigator.of(context).pop();
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
      ir(const EditorAvisosClientesScreen());
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
  final _auth = AuthService();
  List<Map<String, dynamic>> _clientes = const [];
  List<String> _recientes = const [];
  String _consulta = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    try {
      final filas = await LocalDb.instance.allMirror('clientes');
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _clientes = filas;
        _recientes =
            prefs.getStringList(_kRecientesLupa) ?? const [];
      });
    } catch (_) {
      // Sin espejo legible, la lupa enseña el campo y el aviso
      // de vacío honesto; jamás resultados inventados.
    }
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
    _registrarReciente(f.id);
    abrirFuncionLupa(context, f.id);
  }

  Widget _filaCliente(Map<String, dynamic> c) {
    final id = (c['id'] as num?)?.toInt() ?? 0;
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
      title: Text('${c['nombre'] ?? ''}'),
      subtitle: Text('${c['telefono'] ?? ''}'),
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
      appBar: AppBar(title: const Text('Buscar en el gym')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.md, AppEspacio.lg, AppEspacio.sm),
            child: CampoTexto(
              controller: _ctrl,
              hint: 'Nombre, teléfono o herramienta…',
              icono: Icons.search_rounded,
              onChanged: (v) => setState(() => _consulta = v),
            ),
          ),
          Expanded(
            child: !buscando
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
                        const Padding(
                          padding: EdgeInsets.all(AppEspacio.lg),
                          child: Text(
                            'Sin resultados en este teléfono. '
                            'Si el cliente aún no sincronizó, '
                            'no aparece aquí.',
                            style: AppTexto.secundario,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _recientesVista() {
    if (_recientes.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(AppEspacio.lg),
        child: Text(
          'Escribe un nombre (en cualquier orden, sin tildes), '
          'los últimos 4 dígitos de un teléfono o el nombre de '
          'una herramienta.',
          style: AppTexto.secundario,
        ),
      );
    }
    final funciones = recientesPanel(
        _recientes.where((r) => !r.startsWith('cliente:')).toList());
    final porId = {for (final c in _clientes) '${c['id']}': c};
    return ListView(
      key: const ValueKey('lupa-recientes'),
      children: [
        const EncabezadoSeccion(titulo: 'RECIENTES'),
        for (final r in _recientes) ...[
          if (r.startsWith('cliente:') &&
              porId[r.substring(8)] != null)
            _filaCliente(porId[r.substring(8)]!),
          if (!r.startsWith('cliente:'))
            for (final f in funciones)
              if (f.id == r)
                ListTile(
                  leading: Icon(f.icono),
                  title: Text(f.titulo),
                  onTap: () => _abrirFuncion(f),
                ),
        ],
      ],
    );
  }
}
