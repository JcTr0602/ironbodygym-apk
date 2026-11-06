/// 1.25 T100: el buscador del Panel — «¿Qué quieres
/// hacer?». Con la Expansión del Panel, cada función
/// nueva encarece encontrar todas las demás: este es
/// el índice buscable de los destinos del Panel, por
/// nombre y por sinónimo («quitar acceso», «cobrar
/// Plus», «arreglar sync»), con la fila de usados
/// recientemente. La navegación la resuelve admin.dart
/// por id (esta pantalla solo devuelve el id elegido):
/// los destinos que necesitan callbacks del Panel no
/// se duplican aquí.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../localdb.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

/// Una función del Panel en el buscador.
class FuncionPanel {
  final String id;
  final String titulo;
  final List<String> sinonimos;
  final IconData icono;

  const FuncionPanel({
    required this.id,
    required this.titulo,
    required this.sinonimos,
    required this.icono,
  });
}

/// El catálogo: los títulos son los de las tarjetas
/// del Panel (la misma palabra en los dos sitios).
const catalogoFuncionesPanel = <FuncionPanel>[
  // Caja y dinero.
  FuncionPanel(
      id: 'arqueo',
      titulo: 'Arqueo del día',
      sinonimos: ['cuadre', 'contar efectivo', 'caja del día'],
      icono: Icons.fact_check_rounded),
  FuncionPanel(
      id: 'cierre_caja',
      titulo: 'Cierre de caja',
      sinonimos: ['cerrar caja', 'reporte de caja', 'turno sin reporte'],
      icono: Icons.lock_rounded),
  FuncionPanel(
      id: 'liquidar',
      titulo: 'Liquidar efectivo de entrenadores',
      sinonimos: ['pendiente a entregar', 'entrega', 'recoger efectivo'],
      icono: Icons.payments_rounded),
  FuncionPanel(
      id: 'extracto',
      titulo: 'Centro de Compras y Extracto',
      sinonimos: ['extracto', 'compras', 'historial de compras'],
      icono: Icons.receipt_long_rounded),
  FuncionPanel(
      id: 'gastos',
      titulo: 'Últimos gastos',
      sinonimos: ['registrar gasto', 'gastos del día', 'egresos'],
      icono: Icons.money_off_rounded),
  FuncionPanel(
      id: 'historial_caja',
      titulo: 'Historial de caja',
      sinonimos: ['cierres por fecha', 'arqueos viejos'],
      icono: Icons.history_rounded),
  FuncionPanel(
      id: 'pagos_metodo',
      titulo: 'Pagos por método',
      sinonimos: ['efectivo o transferencia', 'métodos de pago'],
      icono: Icons.account_balance_wallet_rounded),
  FuncionPanel(
      id: 'comparativa',
      titulo: 'Comparativa mensual',
      sinonimos: ['mes contra mes', 'ingresos por mes'],
      icono: Icons.bar_chart_rounded),
  FuncionPanel(
      id: 'ingresos_periodo',
      titulo: 'Ingresos por período',
      sinonimos: ['ingresos', 'cuánto entró', 'ventas del período'],
      icono: Icons.trending_up_rounded),
  FuncionPanel(
      id: 'nomina',
      titulo: 'Nómina del mes',
      sinonimos: ['pagar a entrenadores', 'salario', 'nómina'],
      icono: Icons.badge_rounded),
  FuncionPanel(
      id: 'nomina_precalculada',
      titulo: 'Nómina pre-calculada',
      sinonimos: ['previsión de nómina', 'cuánto pagaré'],
      icono: Icons.calculate_rounded),
  FuncionPanel(
      id: 'adelantos',
      titulo: 'Adelantos',
      sinonimos: ['adelanto de salario', 'dar un adelanto'],
      icono: Icons.forward_rounded),
  FuncionPanel(
      id: 'solicitudes_adelanto',
      titulo: 'Solicitudes de adelanto',
      sinonimos: ['aprobar adelanto', 'peticiones de adelanto'],
      icono: Icons.request_quote_rounded),
  // Clientes e invitados.
  FuncionPanel(
      id: 'usuarios',
      titulo: 'Usuarios',
      sinonimos: ['clientes', 'entrenadores e invitados', 'padrón'],
      icono: Icons.manage_accounts_rounded),
  FuncionPanel(
      id: 'candado',
      titulo: 'Candado de acceso',
      sinonimos: ['quitar acceso', 'bloquear app', 'pausar acceso', 'suspender'],
      icono: Icons.block_rounded),
  FuncionPanel(
      id: 'recuperar',
      titulo: 'Clientes por recuperar',
      sinonimos: ['en riesgo', 'no vienen', 'ausentes', 'recuperación'],
      icono: Icons.person_search_rounded),
  FuncionPanel(
      id: 'congeladas',
      titulo: 'Membresías congeladas',
      sinonimos: ['congelar', 'pausadas', 'congelados'],
      icono: Icons.ac_unit_rounded),
  FuncionPanel(
      id: 'papelera',
      titulo: 'Papelera',
      sinonimos: ['eliminados', 'restaurar cliente', 'borrados'],
      icono: Icons.delete_rounded),
  FuncionPanel(
      id: 'cuentas_casa',
      titulo: 'Cuentas a la Casa',
      sinonimos: ['casa', 'no pagan', 'cortesía permanente'],
      icono: Icons.house_rounded),
  FuncionPanel(
      id: 'vencimientos',
      titulo: 'Vencimientos próximos',
      sinonimos: ['a punto de vencer', 'vencen pronto'],
      icono: Icons.event_rounded),
  FuncionPanel(
      id: 'comunicacion',
      titulo: 'Comunicación',
      sinonimos: ['mensajes', 'avisos', 'whatsapp', 'campañas', 'plantillas'],
      icono: Icons.forum_rounded),
  FuncionPanel(
      id: 'cumpleanos',
      titulo: 'Cumpleaños',
      sinonimos: ['cumple', 'felicitar', 'regalo de cumpleaños'],
      icono: Icons.cake_rounded),
  FuncionPanel(
      id: 'solicitudes_invitados',
      titulo: 'Solicitudes de invitados',
      sinonimos: ['quiero inscribirme', 'solicitudes de inscripción'],
      icono: Icons.group_rounded),
  FuncionPanel(
      id: 'invitados_frecuentes',
      titulo: 'Invitados frecuentes',
      sinonimos: ['candidatos a cliente', 'visitas de invitados'],
      icono: Icons.how_to_reg_rounded),
  // Comunicación.
  FuncionPanel(
      id: 'plantillas',
      titulo: 'Plantillas de mensajes',
      sinonimos: ['mensajes guardados', 'textos para whatsapp'],
      icono: Icons.message_rounded),
  FuncionPanel(
      id: 'avisos_entrenadores',
      titulo: 'Avisos para entrenadores',
      sinonimos: ['avisar al staff', 'mensaje a entrenadores'],
      icono: Icons.campaign_rounded),
  FuncionPanel(
      id: 'avisos_clientes',
      titulo: 'Avisos a clientes',
      sinonimos: ['mensaje masivo', 'avisar a clientes'],
      icono: Icons.send_rounded),
  FuncionPanel(
      id: 'recordatorios',
      titulo: 'Recordatorios automáticos',
      sinonimos: ['avisos automáticos', 'recordatorio de vencimiento'],
      icono: Icons.alarm_rounded),
  FuncionPanel(
      id: 'info_publica',
      titulo: 'Información pública',
      sinonimos: ['datos del gym', 'horarios y precios públicos'],
      icono: Icons.info_rounded),
  // Equipo y turnos.
  FuncionPanel(
      id: 'entrenadores_apk',
      titulo: 'Entrenadores y usuarios APK',
      sinonimos: ['crear entrenador', 'cuentas de la app', 'credenciales'],
      icono: Icons.manage_accounts_rounded),
  FuncionPanel(
      id: 'plan_turnos',
      titulo: 'Plan y ajustes de turnos',
      sinonimos: ['patrón semanal', 'horario de turnos', 'excepciones'],
      icono: Icons.calendar_month_rounded),
  FuncionPanel(
      id: 'horario_apertura',
      titulo: 'Horario de apertura',
      sinonimos: ['horario del gym', 'a qué hora abre'],
      icono: Icons.schedule_rounded),
  FuncionPanel(
      id: 'permisos',
      titulo: 'Permisos por entrenador',
      sinonimos: ['qué puede hacer', 'autorizaciones', 'permisos'],
      icono: Icons.admin_panel_settings_rounded),
  FuncionPanel(
      id: 'permisos_explicados',
      titulo: 'Permisos explicados',
      sinonimos: ['qué significa cada permiso', 'ayuda de permisos'],
      icono: Icons.help_rounded),
  // Tienda.
  FuncionPanel(
      id: 'suplementos',
      titulo: 'Catálogo de suplementos',
      sinonimos: ['productos', 'suplementos', 'inventario'],
      icono: Icons.medication_rounded),
  FuncionPanel(
      id: 'categorias',
      titulo: 'Categorías',
      sinonimos: ['categorías de suplementos'],
      icono: Icons.category_rounded),
  FuncionPanel(
      id: 'historial_ventas',
      titulo: 'Historial de ventas',
      sinonimos: ['ventas de suplementos', 'qué se vendió'],
      icono: Icons.point_of_sale_rounded),
  FuncionPanel(
      id: 'fiados',
      titulo: 'Fiados por cobrar',
      sinonimos: ['fiado', 'deudas de clientes', 'por cobrar'],
      icono: Icons.handshake_rounded),
  FuncionPanel(
      id: 'sin_foto',
      titulo: 'Productos sin foto o sin precio',
      sinonimos: ['incompletos', 'sin foto', 'sin precio'],
      icono: Icons.image_not_supported_rounded),
  FuncionPanel(
      id: 'botes',
      titulo: 'Botes y lotes',
      sinonimos: ['pomos', 'servicios', 'dosis', 'abrir bote'],
      icono: Icons.science_rounded),
  FuncionPanel(
      id: 'reportes_plus',
      titulo: 'Reportes App Plus',
      sinonimos: ['cobrar plus', 'confirmar plus', 'pagos del plus'],
      icono: Icons.star_rounded),
  FuncionPanel(
      id: 'reservas',
      titulo: 'Reservas',
      sinonimos: ['reservar suplemento', 'apartados'],
      icono: Icons.inventory_2_rounded),
  // Contenido.
  FuncionPanel(
      id: 'biblioteca',
      titulo: 'Biblioteca',
      sinonimos: ['gympedia', 'artículos', 'guía de clientes'],
      icono: Icons.menu_book_rounded),
  FuncionPanel(
      id: 'rutinas_gym',
      titulo: 'Rutinas del gym',
      sinonimos: ['banco de rutinas', 'rutinas para clientes'],
      icono: Icons.fitness_center_rounded),
  FuncionPanel(
      id: 'bandeja_gympedia',
      titulo: 'Bandeja GymPedia',
      sinonimos: ['solicitudes de artículos', 'borradores gympedia'],
      icono: Icons.inbox_rounded),
  // Precios (el centro de T99).
  FuncionPanel(
      id: 'precios_metodo',
      titulo: 'Precios por método',
      sinonimos: ['precios', 'mensualidad', 'cuánto cuesta', 'tarifas'],
      icono: Icons.tune_rounded),
  FuncionPanel(
      id: 'tipos_pago',
      titulo: 'Tipos de pago',
      sinonimos: ['períodos', 'semanal quincenal', 'ofertas'],
      icono: Icons.payments_rounded),
  FuncionPanel(
      id: 'tarifas',
      titulo: 'Tarifas especiales',
      sinonimos: ['precio especial', 'descuento de un cliente'],
      icono: Icons.local_offer_rounded),
  FuncionPanel(
      id: 'bancarios',
      titulo: 'Datos bancarios',
      sinonimos: ['tarjetas', 'bandec', 'bpa', 'móvil de confirmación'],
      icono: Icons.account_balance_rounded),
  FuncionPanel(
      id: 'pago_base',
      titulo: 'Pago base a entrenadores',
      sinonimos: ['cuánto por cliente', 'pago por cliente pagado'],
      icono: Icons.payments_rounded),
  // Configuración y sistema.
  FuncionPanel(
      id: 'ajustes_gym',
      titulo: 'Ajustes del gym',
      sinonimos: ['configuración', 'métodos y textos'],
      icono: Icons.settings_rounded),
  FuncionPanel(
      id: 'registro_mensual',
      titulo: 'Registro mensual',
      sinonimos: ['resumen del mes', 'copiar registro'],
      icono: Icons.book_rounded),
  FuncionPanel(
      id: 'estado_sync',
      titulo: 'Estado de sync',
      sinonimos: ['arreglar sync', 'sincronización', 'diagnóstico'],
      icono: Icons.sync_rounded),
  FuncionPanel(
      id: 'cola_sync',
      titulo: 'Cola de sincronización',
      sinonimos: ['operaciones pendientes', 'reintentar subida'],
      icono: Icons.queue_rounded),
  FuncionPanel(
      id: 'historial_sync',
      titulo: 'Historial de sync',
      sinonimos: ['eventos de sincronización'],
      icono: Icons.history_rounded),
  FuncionPanel(
      id: 'verificacion_espejo',
      titulo: 'Verificación del espejo',
      sinonimos: ['espejo desfasado', 'comprobar datos'],
      icono: Icons.fact_check_rounded),
  FuncionPanel(
      id: 'incidencias',
      titulo: 'Incidencias',
      sinonimos: ['operaciones rechazadas', 'revisar sync', 'errores por aprobar'],
      icono: Icons.sync_problem_rounded),
  FuncionPanel(
      id: 'errores_sync',
      titulo: 'Errores de sync',
      sinonimos: ['fallos de sincronización'],
      icono: Icons.error_outline_rounded),
  FuncionPanel(
      id: 'centro_control',
      titulo: 'Centro de control',
      sinonimos: ['auditoría', 'qué pasó', 'registro', 'anomalías', 'por persona'],
      icono: Icons.fact_check_rounded),
  FuncionPanel(
      id: 'auditoria',
      titulo: 'Auditoría',
      sinonimos: ['quién hizo qué', 'historial de cambios'],
      icono: Icons.manage_search_rounded),
  FuncionPanel(
      id: 'auditoria_persona',
      titulo: 'Auditoría por persona',
      sinonimos: ['actividad de una persona', 'qué hizo'],
      icono: Icons.person_search_rounded),
  FuncionPanel(
      id: 'anomalias',
      titulo: 'Anomalías',
      sinonimos: ['detección silenciosa', 'cosas raras'],
      icono: Icons.radar_rounded),
  FuncionPanel(
      id: 'mantenimiento',
      titulo: 'Mantenimiento',
      sinonimos: ['limpieza', 'herramientas del sistema'],
      icono: Icons.build_rounded),
  FuncionPanel(
      id: 'copia',
      titulo: 'Copia de seguridad',
      sinonimos: ['respaldo', 'exportar la base', 'backup'],
      icono: Icons.backup_rounded),
  FuncionPanel(
      id: 'exportar_csv',
      titulo: 'Exportar CSV',
      sinonimos: ['exportar clientes', 'csv del mes'],
      icono: Icons.table_chart_rounded),
  FuncionPanel(
      id: 'exportar_excel',
      titulo: 'Exportar Excel',
      sinonimos: ['exportar a excel', 'hoja de cálculo'],
      icono: Icons.grid_on_rounded),
  FuncionPanel(
      id: 'bitacora',
      titulo: 'Bitácora',
      sinonimos: ['registro de diagnóstico', 'log'],
      icono: Icons.bug_report_rounded),
  FuncionPanel(
      id: 'bajada',
      titulo: 'Bajada completa',
      sinonimos: ['redescargar todo', 'resincronizar espejos'],
      icono: Icons.download_for_offline_rounded),
];

/// PURO: normaliza para buscar — minúsculas, sin
/// acentos ni eñe, espacios colapsados.
String normalizarTextoPanel(String s) {
  const mapa = {
    'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u',
    'ñ': 'n',
  };
  final buf = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    buf.write(mapa[ch] ?? ch);
  }
  return buf.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// PURO: las funciones cuya título+sinónimos contienen
/// TODOS los tokens de la consulta (busca por palabras
/// sueltas, en cualquier orden). Consulta vacía → nada
/// (la pantalla enseña los recientes en ese caso).
List<FuncionPanel> buscarFuncionesPanel(String consulta,
    {List<FuncionPanel> catalogo = catalogoFuncionesPanel}) {
  final q = normalizarTextoPanel(consulta);
  if (q.isEmpty) return const [];
  final tokens = q.split(' ');
  return [
    for (final f in catalogo)
      if (tokens.every((t) => normalizarTextoPanel(
              '${f.titulo} ${f.sinonimos.join(' ')}')
          .contains(t)))
        f,
  ];
}

/// PURO (1.25 Panel 11): clientes del espejo que casan
/// con la consulta — TODOS los tokens dentro de
/// nombre+teléfono, con la misma normalización de las
/// funciones. Una consulta de un solo carácter no busca
/// personas (sería ruido). Fuera eliminados y filas
/// optimistas (id <= 0); tope [limite].
List<Map<String, dynamic>> buscarClientesPanel(
  String consulta,
  List<Map<String, dynamic>> clientes, {
  int limite = 8,
}) {
  final q = normalizarTextoPanel(consulta);
  if (q.length < 2) return const [];
  final tokens = q.split(' ');
  final out = <Map<String, dynamic>>[];
  for (final c in clientes) {
    final id = (c['id'] as num?)?.toInt() ?? 0;
    if (id <= 0 || LocalDb.esEliminadoDe(c)) continue;
    final texto = normalizarTextoPanel(
        '${c['nombre'] ?? ''} ${c['telefono'] ?? ''}');
    if (tokens.every((t) => texto.contains(t))) {
      out.add(c);
      if (out.length >= limite) break;
    }
  }
  return out;
}

/// PURO: los recientes como funciones del catálogo, en
/// el orden guardado (más reciente primero), sin ids
/// que ya no existan.
List<FuncionPanel> recientesPanel(List<String> ids,
    {List<FuncionPanel> catalogo = catalogoFuncionesPanel}) {
  final porId = {for (final f in catalogo) f.id: f};
  return [
    for (final id in ids)
      if (porId[id] != null) porId[id]!,
  ];
}

const _kRecientesPanel = 'panel_buscador_recientes_v1';
const _kMaxRecientesPanel = 5;

/// La pantalla del buscador: devuelve el id elegido
/// con Navigator.pop (o null al salir sin elegir).
class BuscadorPanelScreen extends StatefulWidget {
  const BuscadorPanelScreen({super.key});

  @override
  State<BuscadorPanelScreen> createState() =>
      _BuscadorPanelScreenState();
}

class _BuscadorPanelScreenState extends State<BuscadorPanelScreen> {
  final _ctrl = TextEditingController();
  final _foco = FocusNode();
  var _consulta = '';
  List<String> _recientesIds = [];
  // 1.25 Panel 11: el espejo de clientes para la mitad
  // «clientes» del buscador global. Se pinta sin él y se
  // rellena al llegar (es local: no hay red de por medio).
  List<Map<String, dynamic>> _clientes = const [];

  @override
  void initState() {
    super.initState();
    _cargarRecientes();
    _cargarClientes();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _foco.requestFocus());
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _foco.dispose();
    super.dispose();
  }

  Future<void> _cargarRecientes() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() =>
        _recientesIds = prefs.getStringList(_kRecientesPanel) ?? []);
  }

  Future<void> _cargarClientes() async {
    try {
      final filas = await LocalDb.instance.allMirror('clientes');
      if (!mounted) return;
      setState(() => _clientes = filas);
    } catch (_) {
      // Sin espejo legible, el buscador de funciones sigue.
    }
  }

  void _elegirCliente(Map<String, dynamic> c) =>
      Navigator.pop(context, 'cliente:${c['id']}');

  Widget _filaCliente(Map<String, dynamic> c) {
    final tel = '${c['telefono'] ?? ''}'.trim();
    return ListTile(
      leading: AvatarCliente(
          nombre: '${c['nombre'] ?? ''}', tamano: TamanoAvatar.s),
      title: Text('${c['nombre'] ?? 'Sin nombre'}'),
      subtitle: tel.isEmpty ? null : Text(tel),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => _elegirCliente(c),
    );
  }

  Future<void> _elegir(FuncionPanel f) async {
    final prefs = await SharedPreferences.getInstance();
    final nuevos = [
      f.id,
      ..._recientesIds.where((id) => id != f.id),
    ].take(_kMaxRecientesPanel).toList();
    await prefs.setStringList(_kRecientesPanel, nuevos);
    if (!mounted) return;
    Navigator.pop(context, f.id);
  }

  Widget _fila(FuncionPanel f) => ListTile(
        leading: Icon(f.icono, color: AppColores.naranja),
        title: Text(f.titulo),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => _elegir(f),
      );

  @override
  Widget build(BuildContext context) {
    final resultados = buscarFuncionesPanel(_consulta);
    final clientesRes = buscarClientesPanel(_consulta, _clientes);
    final recientes = recientesPanel(_recientesIds);
    return Scaffold(
      appBar: appBarIron(context, 'Buscar en el Panel'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppEspacio.lg),
            child: CampoTexto(
              controller: _ctrl,
              hint: '¿Qué quieres hacer?',
              icono: Icons.search_rounded,
              focusNode: _foco,
              onChanged: (v) => setState(() => _consulta = v),
            ),
          ),
          Expanded(
            child: _consulta.trim().isEmpty
                ? ListView(
                    children: [
                      if (recientes.isNotEmpty) ...[
                        const Padding(
                          padding: EdgeInsets.symmetric(
                              horizontal: AppEspacio.lg),
                          child: Text('Usados recientemente',
                              style: AppTexto.secundario),
                        ),
                        for (final f in recientes) _fila(f),
                        const Divider(),
                      ],
                      const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: AppEspacio.lg),
                        child: Text('Todas las funciones',
                            style: AppTexto.secundario),
                      ),
                      for (final f in catalogoFuncionesPanel)
                        _fila(f),
                    ],
                  )
                : (resultados.isEmpty && clientesRes.isEmpty)
                    ? const Center(
                        child: Text(
                            'Nada con ese nombre. Prueba con '
                            '«sync», «precios» o «acceso».',
                            style: AppTexto.secundario))
                    : ListView(
                        children: [
                          if (resultados.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: AppEspacio.lg),
                              child: Text('Funciones',
                                  style: AppTexto.secundario),
                            ),
                            for (final f in resultados) _fila(f),
                          ],
                          if (clientesRes.isNotEmpty) ...[
                            if (resultados.isNotEmpty) const Divider(),
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                  horizontal: AppEspacio.lg),
                              child: Text('Clientes',
                                  style: AppTexto.secundario),
                            ),
                            for (final c in clientesRes)
                              _filaCliente(c),
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}
