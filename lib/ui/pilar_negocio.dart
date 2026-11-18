/// 1.32 «Mostrador Táctico» — Pilar 4 · NEGOCIO (dueño) /
/// MI CAJA (entrenador).
///
/// Dueño: Caja · Nómina y Mes · Equipo · App y Reglas.
/// Entrenador: A Entregar · Mi Nómina · Mis Turnos.
///
/// - Caja: el botón ÚNICO «Liquidar Arqueo» por entrenador
///   con pendiente (hoja de conteo con pad empotrado y
///   confirmación por deslizamiento sobre la liquidación
///   canónica) — la dualidad ArqueoScreen/ArqueoEntregaScreen
///   queda retirada del marco (S-5); el Arqueo queda enlazado
///   como detalle, historial y expedientes, que es su papel
///   desde la 1.22 (ver hoja_liquidar.dart). Debajo, los
///   enlaces de caja de siempre.
/// - Nómina y Mes / Mi Nómina: las pantallas de siempre
///   embebidas, leyendo la foto sellada — el cálculo NO se
///   retoca en esta oleada.
/// - Equipo: turnos y el Horario G-48 (visible para dueño y
///   entrenador; editable SOLO dueño — la guarda vive dentro
///   de HorarioGym, que ignora la edición si no es dueño).
/// - Mis Turnos (entrenador): su turno y el horario en solo
///   lectura efectiva (la misma guarda).
/// - App y Reglas: el índice de destinos del Admin vigente.
///   Desde la Fase 3 de la Oleada 2, Anuncios y Avisos son
///   UNA sola entrada «Comunicados» (el Publicador
///   Unificado G-63+G-64: una pantalla, un selector). Las
///   exportaciones y los montos que aún viven atados al
///   estado del Panel quedan en la entrada «Panel clásico»
///   al final (enlace hondo honesto, no una copia).
library;

import 'package:flutter/material.dart';

import '../config.dart';
import '../negocio.dart';
import '../novedades.dart';
import 'admin.dart';
import 'ajustes.dart';
import 'arqueo.dart';
import 'avisos_entrenador.dart';
import 'bandeja.dart';
import 'cierre_mes.dart';
import 'comparativa_entrenadores.dart';
import 'componentes.dart';
import 'congelaciones.dart';
import 'conciliacion.dart';
import 'dashboard.dart';
import 'diferencias_caja.dart';
import 'diseno.dart';
import 'estadisticas_adopcion.dart';
import 'gastos.dart';
import 'historial_caja.dart';
import 'hoja_liquidar.dart';
import 'hoja_liquidar_arqueo.dart';
import 'horario_gym.dart';
import 'invitados.dart';
import 'marco.dart';
import 'primitivas.dart';
import 'mi_nomina.dart';
import 'publicador.dart';
import 'mi_turno.dart';
import 'nomina.dart';
import 'panel_candado.dart';
import 'panel_comunidad.dart';
import 'panel_permisos.dart';
import 'panel_premios_hub.dart';
import 'panel_resto_caja.dart';
import 'pendiente.dart';
import 'tarifas_especiales.dart';
import 'turnos_hub.dart';
import 'usuarios.dart';

class PilarNegocio extends StatefulWidget {
  final bool esDueno;

  const PilarNegocio({super.key, required this.esDueno});

  @override
  State<PilarNegocio> createState() => _PilarNegocioState();
}

class _PilarNegocioState extends State<PilarNegocio> {
  late String _tab = widget.esDueno ? 'caja' : 'entregar';
  final Set<String> _visitados = {};

  List<({String id, String titulo, IconData icono})> get _tabs =>
      widget.esDueno
          ? const [
              (id: 'caja', titulo: 'Caja', icono: Icons.point_of_sale_rounded),
              (id: 'nomina', titulo: 'Nómina y Mes', icono: Icons.payments_rounded),
              (id: 'equipo', titulo: 'Equipo', icono: Icons.groups_rounded),
              (id: 'reglas', titulo: 'App y Reglas', icono: Icons.tune_rounded),
            ]
          : const [
              (id: 'entregar', titulo: 'A Entregar', icono: Icons.payments_rounded),
              (id: 'minomina', titulo: 'Mi Nómina', icono: Icons.receipt_long_rounded),
              (id: 'misturnos', titulo: 'Mis Turnos', icono: Icons.schedule_rounded),
            ];

  @override
  void initState() {
    super.initState();
    _visitados.add(_tab);
    MarcoNav.destinoNegocio.addListener(_aplicarDestino);
    if (MarcoNav.destinoNegocio.value != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _aplicarDestino());
    }
  }

  @override
  void dispose() {
    MarcoNav.destinoNegocio.removeListener(_aplicarDestino);
    super.dispose();
  }

  void _aplicarDestino() {
    final d = MarcoNav.destinoNegocio.value;
    if (d == null || !mounted) return;
    MarcoNav.destinoNegocio.value = null; // consumir
    // La lupa del dueño pide «nomina»: en Mi Caja esa
    // pestaña se llama «minomina».
    var destino = d;
    if (!widget.esDueno && d == 'nomina') destino = 'minomina';
    if (!_tabs.any((t) => t.id == destino)) return;
    setState(() {
      _tab = destino;
      _visitados.add(destino);
    });
  }

  void _ir(Widget pantalla) {
    Navigator.of(context).push(RutaIron(builder: (_) => pantalla));
  }

  Widget _vistaDe(String tab) {
    switch (tab) {
      case 'caja':
        return _TabCaja(onIr: _ir);
      case 'nomina':
        return Column(
          children: [
            _filaEnlaces([
              ('Cierre de mes', Icons.lock_rounded,
                  () => _ir(const CierreMesScreen())),
              ('Precalculada', Icons.calculate_rounded,
                  () => _ir(const NominaPrecalculadaScreen())),
              ('Panel del negocio', Icons.dashboard_rounded,
                  () => _ir(const DashboardScreen())),
            ]),
            const Expanded(child: NominaScreen(embebida: true)),
          ],
        );
      case 'equipo':
        return _listaDestinos([
          ('Turnos del equipo', 'Programación y cierres de turno',
              Icons.schedule_rounded, () => _ir(const TurnosHubScreen())),
          ('Horario del gym', 'Visible para todos; lo edita solo el dueño',
              Icons.access_time_rounded, () => _ir(const HorarioGym())),
          ('Usuarios y accesos', 'Cuentas del equipo y de la app',
              Icons.manage_accounts_rounded,
              () => _ir(const UsuariosScreen())),
          ('Comparativa de entrenadores', 'Su trabajo, lado a lado',
              Icons.compare_arrows_rounded,
              () => _ir(const ComparativaEntrenadoresScreen())),
          ('Permisos del equipo', 'Qué puede hacer cada entrenador',
              Icons.admin_panel_settings_rounded,
              () => _ir(const PanelPermisos())),
          ('Candado de acceso', 'PIN y bloqueo de la app',
              Icons.lock_rounded, () => _ir(const PanelCandadoScreen())),
        ]);
      case 'reglas':
        return _listaDestinos([
          ('Comunicados', 'Publicar a Clientes: anuncio de portada y avisos',
              Icons.campaign_rounded,
              () => _ir(const PublicadorScreen())),
          ('Avisos a entrenadores', 'Mensajes al equipo',
              Icons.forum_rounded,
              () => _ir(const AvisosEntrenadorScreen())),
          ('Contenido y GymPedia', 'Artículos y la bandeja de contenido',
              Icons.menu_book_rounded, () => _ir(const BandejaScreen())),
          ('Premios y vales', 'El panel de premios por logros',
              Icons.emoji_events_rounded,
              () => _ir(const PremiosHubScreen())),
          ('Comunidad', 'Reportes y actividad de la comunidad',
              Icons.groups_rounded,
              () => _ir(const ComunidadPanelScreen())),
          ('Congelaciones', 'Solicitudes y pausas aprobadas',
              Icons.ac_unit_rounded,
              () => _ir(const CongelacionesScreen())),
          ('Adopción de la app', 'Quién usa la app de Clientes',
              Icons.insights_rounded,
              () => _ir(const EstadisticasAdopcionScreen())),
          ('Tarifas especiales', 'Precios pactados por cliente',
              Icons.price_change_rounded,
              () => _ir(const TarifasScreen())),
          ('Info pública', 'Lo que la app publica del gym',
              Icons.public_rounded, () => _ir(const InfoPublicaScreen())),
          ('Ajustes', 'La configuración de la app',
              Icons.settings_rounded, () => _ir(const AjustesScreen())),
          ('Panel clásico', 'Exportar datos y montos (la vista anterior)',
              Icons.dashboard_customize_rounded,
              () => _ir(const AdminScreen())),
        ]);
      case 'entregar':
        return Column(
          children: [
            _filaEnlaces([
              ('Registrar gasto', Icons.money_off_rounded,
                  () => _ir(const GastosScreen())),
            ]),
            const Expanded(child: PendienteScreen(embebida: true)),
          ],
        );
      case 'minomina':
        return const MiNominaScreen(embebida: true);
      case 'misturnos':
        return _listaDestinos([
          ('Mi turno', 'Abrir, cerrar y ver mi turno de hoy',
              Icons.schedule_rounded, () => _ir(const MiTurnoScreen())),
          ('Horario del gym', 'Solo lectura: lo edita el dueño',
              Icons.access_time_rounded, () => _ir(const HorarioGym())),
        ]);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _filaEnlaces(
      List<(String, IconData, VoidCallback)> enlaces) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
      child: Wrap(
        spacing: AppEspacio.sm,
        runSpacing: AppEspacio.sm,
        children: [
          for (final (titulo, icono, accion) in enlaces)
            ActionChip(
              avatar: Icon(icono, size: 18),
              label: Text(titulo),
              // 1.32 (integración, RD-5): enlaces de uso
              // diario del Pilar 4 («Cierre de mes»,
              // «Registrar gasto»…): objetivo táctil
              // acolchado de 48 en vez de los ≈36 visuales.
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onPressed: accion,
            ),
        ],
      ),
    );
  }

  Widget _listaDestinos(
      List<(String, String, IconData, VoidCallback)> destinos) {
    return ListView(
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        for (final (titulo, detalle, icono, accion) in destinos)
          Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.sm),
            child: Tarjeta(
              onTap: accion,
              child: Row(
                children: [
                  // 1.33 (diseño): fila-destino del pilar en
                  // chip de marca — este constructor compartido
                  // pinta Equipo, App y Reglas y Mis Turnos:
                  // la corrección cascada a sus 19 destinos.
                  IconoModuloBadge.naranja(icono),
                  const SizedBox(width: AppEspacio.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(titulo, style: AppTexto.cuerpo),
                        Text(detalle,
                            style: AppTexto.metadato.copyWith(
                                color:
                                    AppColores.textoSecundario(context))),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        // Pie de cierre del Pilar 4 (1.32, Oleada 2 F1 —
        // desviación 8 de Argón; decisión de Jc: SÍ al
        // copyright): versión de compilación, acceso a
        // Novedades y la firma, al final del scroll de las
        // listas de destinos del pilar. NO va en el Mostrador
        // (zona operativa, cero ruido). La versión sale de la
        // misma fuente que usa Ajustes (AppConfig.appVersion).
        const SizedBox(height: AppEspacio.lg),
        Center(
          child: Text(
            'Versión ${AppConfig.appVersion}',
            style: AppTexto.metadato.copyWith(
                color: AppColores.textoSecundario(context)),
          ),
        ),
        const SizedBox(height: AppEspacio.xs),
        Center(
          child: TextButton.icon(
            icon: const Icon(Icons.auto_awesome_rounded, size: 18),
            label: const Text('Lo nuevo'),
            onPressed: () => mostrarVitrinaNovedades(
              context,
              novedadesDeMiVersion(),
              titulo: 'Novedades de mi versión',
            ),
          ),
        ),
        Center(
          child: Text(
            '© Creado por JcTr0602',
            key: const ValueKey('pie-autoria-pilar4'),
            style: AppTexto.minuscula.copyWith(
                color: AppColores.textoSecundario(context)),
          ),
        ),
        const SizedBox(height: AppEspacio.md),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    return Column(
      key: const ValueKey('pilar-negocio'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppEspacio.lg, AppEspacio.md, AppEspacio.lg, AppEspacio.sm),
          // 1.32 (integración, RD-8): con pista — al crecer
          // la fuente, «App y Reglas» quedaba fuera sin
          // señal de que hubiera más segmentos.
          child: ScrollHorizontalConPista(
            colorFondo: Theme.of(context).scaffoldBackgroundColor,
            child: SegmentedButton<String>(
              segments: [
                for (final t in tabs)
                  ButtonSegment(
                      value: t.id,
                      icon: Icon(t.icono),
                      label: Text(t.titulo)),
              ],
              selected: {_tab},
              // 1.36 H-B1 (136-324): mismo lenguaje que el
              // pilar Clientes — tacto al elegir y fundido
              // al cambiar de segmento.
              onSelectionChanged: (s) {
                Tacto.seleccion();
                setState(() {
                  _tab = s.first;
                  _visitados.add(s.first);
                });
              },
            ),
          ),
        ),
        Expanded(
          child: FundidoAlCambiar(
            indice: tabs.indexWhere((t) => t.id == _tab),
            child: IndexedStack(
              index: tabs.indexWhere((t) => t.id == _tab),
              children: [
                for (final t in tabs)
                  if (_visitados.contains(t.id))
                    KeyedSubtree(
                        key: ValueKey('pilar-negocio-${t.id}'),
                        child: _vistaDe(t.id))
                  else
                    const SizedBox.shrink(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// La pestaña Caja del dueño: pendientes por entrenador con
/// el botón ÚNICO «Liquidar Arqueo» y los enlaces de caja.
class _TabCaja extends StatefulWidget {
  final void Function(Widget pantalla) onIr;

  const _TabCaja({required this.onIr});

  @override
  State<_TabCaja> createState() => _TabCajaState();
}

class _TabCajaState extends State<_TabCaja> {
  List<Map<String, dynamic>> _pendientes = const [];
  bool _cargando = true;
  bool _fallo = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // 1.36 H-B1 (136-338): cada recarga se anuncia — el
    // «Reintentar» no gira en silencio sobre la foto vieja.
    if (mounted && !_cargando) setState(() => _cargando = true);
    try {
      final lista = await entrenadoresConPendiente();
      if (!mounted) return;
      setState(() {
        _pendientes = lista;
        _cargando = false;
        _fallo = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _fallo = true;
      });
    }
  }

  Future<void> _liquidar(Map<String, dynamic> e) async {
    final tid = (e['telegram_id'] as num?)?.toInt();
    // 1.36 H-B1 (136-339): sin telegram_id no hay silencio —
    // se dice por qué no se puede liquidar.
    if (tid == null) {
      mostrarSnackEnMessenger(
        ScaffoldMessenger.of(context),
        'Este entrenador no tiene cuenta de Telegram vinculada: '
        'no se le puede liquidar desde aquí.',
        significado: SignificadoChip.alerta,
      );
      return;
    }
    final nombre = '${e['nombre'] ?? ''}';
    final messenger = ScaffoldMessenger.of(context);
    final r = await mostrarHojaLiquidarArqueo(context,
        telegramId: tid, nombre: nombre);
    if (r == null) return;
    if (r.modo == ModoHojaArqueo.entregaC1) {
      // Modo C1: no hay Deshacer (la entrega queda en el
      // libro; igual que la pantalla C1 original).
      mostrarSnackEnMessenger(
        messenger,
        'Entrega anticipada registrada para $nombre '
        '(${r.entregado.toStringAsFixed(0)} CUP).',
        significado: SignificadoChip.exito,
      );
    } else {
      mostrarAvisoLiquidacionConDeshacer(
        messenger,
        mensaje: 'Liquidación registrada para $nombre.',
        liqId: r.liquidacion!.liqId,
        alDeshacer: () async {
          await _cargar();
        },
      );
    }
    await _cargar();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('negocio-caja'),
      padding: const EdgeInsets.all(AppEspacio.lg),
      children: [
        const EncabezadoSeccion(titulo: 'PENDIENTE POR RECOGER'),
        if (_cargando)
          const Padding(
            padding: EdgeInsets.all(AppEspacio.lg),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_fallo)
          // Error ≠ vacío: una caída de lectura jamás se
          // pinta como «nadie debe nada».
          Tarjeta(
            child: Row(
              children: [
                const Icon(Icons.cloud_off_rounded,
                    color: AppColores.error),
                const SizedBox(width: AppEspacio.sm),
                const Expanded(
                  child: Text(
                    'No se pudo leer el pendiente en este '
                    'teléfono. No significa que nadie deba '
                    'nada: reintenta.',
                    style: AppTexto.secundario,
                  ),
                ),
                TextButton(
                    onPressed: _cargar, child: const Text('Reintentar')),
              ],
            ),
          )
        else if (_pendientes.isEmpty)
          const Tarjeta(
            child: Text(
              'Nadie tiene efectivo pendiente de entregar.',
              style: AppTexto.secundario,
            ),
          )
        else
          for (final e in _pendientes)
            Padding(
              padding: const EdgeInsets.only(bottom: AppEspacio.sm),
              child: Tarjeta(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${e['nombre'] ?? ''}',
                        style: AppTexto.subtitulo),
                    const SizedBox(height: AppEspacio.xs),
                    Text(
                      [
                        if (((e['cup'] as num?)?.toDouble() ?? 0) > 0)
                          '${fmtMonto((e['cup'] as num).toDouble())} CUP',
                        if (((e['usd'] as num?)?.toDouble() ?? 0) > 0)
                          '${fmtMonto((e['usd'] as num).toDouble())} USD',
                      ].join(' · '),
                      style: AppTexto.conTabulares(AppTexto.metrica),
                    ),
                    const SizedBox(height: AppEspacio.sm),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: ValueKey(
                            'liquidar-arqueo-${e['telegram_id']}'),
                        // 1.36 H-B1 (136-339): sin telegram_id
                        // el botón nace deshabilitado.
                        onPressed: e['telegram_id'] == null
                            ? null
                            : () => _liquidar(e),
                        icon: const Icon(
                            Icons.account_balance_wallet_rounded,
                            size: 19),
                        label: const Text('Liquidar Arqueo'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        const SizedBox(height: AppEspacio.md),
        const EncabezadoSeccion(titulo: 'CAJA Y ARQUEO'),
        _enlace('Arqueo: detalle e historial',
            'Expedientes de diferencia y liquidaciones pasadas',
            Icons.fact_check_rounded, () => widget.onIr(const ArqueoScreen())),
        _enlace('Historial de caja', 'Cierres y arqueos por fecha',
            Icons.history_rounded,
            () => widget.onIr(const HistorialCajaScreen())),
        _enlace('Diferencias de caja', 'Expedientes abiertos por diferencia',
            Icons.report_problem_rounded,
            () => widget.onIr(const DiferenciasCajaScreen())),
        _enlace('Conciliación de transferencias',
            'Transferencias por comprobar', Icons.compare_arrows_rounded,
            () => widget.onIr(const ConciliacionScreen())),
        _enlace('Gastos', 'Registrar y ver los gastos del gym',
            Icons.money_off_rounded,
            () => widget.onIr(const GastosScreen())),
      ],
    );
  }

  Widget _enlace(
      String titulo, String detalle, IconData icono, VoidCallback accion) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        onTap: accion,
        child: Row(
          children: [
            // 1.33 (diseño): los enlaces de «Caja y Arqueo»
            // (Arqueo, Historial, Diferencias, Conciliación,
            // Gastos) en el mismo chip de marca que el resto
            // de filas-destino del pilar.
            IconoModuloBadge.naranja(icono),
            const SizedBox(width: AppEspacio.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(titulo, style: AppTexto.cuerpo),
                  Text(detalle,
                      style: AppTexto.metadato.copyWith(
                          color: AppColores.textoSecundario(context))),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}
