/// 1.32 «Mostrador Táctico» — Pilar 2 · CLIENTES.
///
/// El directorio y sus vistas de trabajo como UN solo pilar:
/// - Directorio: BuscarScreen embebida (sus chips de estado —
///   Todos, Al día, Vencidos, Por vencer, Sin foto — son los
///   chips del plano; el salto con contexto del Pulso del Día
///   llega por [MarcoNav] con el filtro ya puesto).
/// - Vencimientos: ListasScreen embebida con sus 5 pestañas
///   (Hoy · Por vencer · Atrasados −30d · +30d · Al día).
/// - Invitados/Plus: InvitadosScreen embebida (ya traía su
///   modo embebido desde la v1.6.0), sobre la caché local
///   endurecida del saneamiento.
/// - Avisos WhatsApp (solo dueño): BandejaWhatsappScreen
///   embebida, con su foco secuencial volátil y SIN marcado
///   automático al volver (descartado por Jc en 2026-11-03 y
///   otra vez en el veredicto g132).
///
/// Arriba: Inscribir y Control de Acceso a 1 toque (G-73) y,
/// para el dueño, la Papelera. Las vistas visitadas quedan
/// montadas (IndexedStack perezoso): cambiar de segmento no
/// pierde el scroll ni la búsqueda en curso.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../permisos_entrenador.dart';
import '../sync.dart';
import 'bandeja_whatsapp.dart';
import 'buscar.dart';
import 'control_acceso.dart';
import 'diseno.dart';
import 'inscribir.dart';
import 'invitados.dart';
import 'listas.dart';
import 'marco.dart';
import 'primitivas.dart';
import 'papelera.dart';
import 'permisos_ui.dart';

class PilarClientes extends StatefulWidget {
  final bool esDueno;

  const PilarClientes({super.key, required this.esDueno});

  @override
  State<PilarClientes> createState() => _PilarClientesState();
}

/// 1.35 (UI-08): la cifra de la insignia del segmento
/// Vencimientos — los que vencen HOY más los atrasados
/// que aún no tienen aviso vigente. Se calcula con las
/// MISMAS funciones que alimentan Listas (vencenHoy /
/// atrasados / avisadosVigentesConFecha) y con su mismo
/// filtro de protegidos: la insignia nunca promete un
/// número distinto del que la pestaña enseña.
Future<int> conteoInsigniaVencimientos() async {
  final activos = await clientesActivos();
  final hoy = await vencenHoy(activosPre: activos);
  final m30 = await atrasados(masDe30: false, activosPre: activos);
  final p30 = await atrasados(masDe30: true, activosPre: activos);
  final avisados = await LocalDb.instance.avisadosVigentesConFecha();
  int idDe(Map<String, dynamic> c) => (c['id'] as num?)?.toInt() ?? -1;
  bool visible(Map<String, dynamic> c) => !esVistaProtegida(c);
  final atrasadosSinAvisar = [...m30, ...p30]
      .where((c) => visible(c) && !avisados.containsKey(idDe(c)))
      .length;
  return hoy.where(visible).length + atrasadosSinAvisar;
}

/// 1.35 (campo nº 13): la fila de acciones del pilar
/// (Inscribir · Control de Acceso · Papelera) como bloque
/// plegable: al bajar por la vista, colapsa a cero con el
/// mismo gesto que la identidad de la cabecera (UI-22) y
/// la lista gana su alto entero; al volver arriba,
/// regresa. Los segmentos NO se pliegan: son la navegación
/// del pilar y quedarse sin ellos a mitad de lista
/// dejaría al usuario sin cambio de vista.
class AccionesPilarClientes extends StatelessWidget {
  final bool esDueno;
  final bool plegadas;
  final VoidCallback onInscribir;
  final VoidCallback onAcceso;
  final VoidCallback onPapelera;

  const AccionesPilarClientes({
    super.key,
    required this.esDueno,
    required this.plegadas,
    required this.onInscribir,
    required this.onAcceso,
    required this.onPapelera,
  });

  @override
  Widget build(BuildContext context) {
    final reducido = MediaQuery.disableAnimationsOf(context);
    return AnimatedSize(
      duration: reducido ? Duration.zero : AppMovimiento.media,
      curve: AppMovimiento.curvaSuave,
      alignment: Alignment.topCenter,
      child: plegadas
          ? const SizedBox.shrink(
              key: ValueKey('clientes-acciones-plegadas'))
          : Padding(
              key: const ValueKey('clientes-acciones-plenas'),
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('clientes-inscribir'),
                      onPressed: onInscribir,
                      icon: const Icon(Icons.person_add_rounded,
                          size: 19),
                      label: const Text('Inscribir'),
                    ),
                  ),
                  const SizedBox(width: AppEspacio.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('clientes-acceso'),
                      onPressed: onAcceso,
                      icon: const Icon(Icons.badge_rounded, size: 19),
                      label: const Text('Control de Acceso'),
                    ),
                  ),
                  if (esDueno)
                    IconButton(
                      key: const ValueKey('clientes-papelera'),
                      tooltip: 'Papelera',
                      icon: const Icon(Icons.delete_outline_rounded),
                      onPressed: onPapelera,
                    ),
                ],
              ),
            ),
    );
  }
}

class _PilarClientesState extends State<PilarClientes> {
  String _segmento = 'directorio';
  int _tabListas = 0;
  int _epochListas = 0;
  String? _filtroBuscar;
  int _epochBuscar = 0;
  final Set<String> _visitados = {'directorio'};

  /// 1.35 (campo nº 13): las acciones del pilar se
  /// pliegan al bajar (histéresis 140/60, la de UI-22) —
  /// la cabecera del Directorio dejaba de comerse media
  /// pantalla solo en Vencimientos; ahora el pilar entero
  /// respira igual.
  bool _accionesPlegadas = false;

  bool _alDesplazar(ScrollNotification n) {
    if (n is ScrollUpdateNotification &&
        n.metrics.axis == Axis.vertical) {
      final p = n.metrics.pixels;
      if (p > 140 && !_accionesPlegadas) {
        setState(() => _accionesPlegadas = true);
      } else if (p < 60 && _accionesPlegadas) {
        setState(() => _accionesPlegadas = false);
      }
    }
    return false;
  }

  /// 1.35 (UI-08): cifra de la insignia de Vencimientos.
  /// Null = aún sin leer (o lectura fallida): no se pinta
  /// insignia — nunca un cero falso (doctrina SYNC-12).
  int? _urgenciaVenc;
  StreamSubscription<SyncStatus>? _subSync;

  Future<void> _contarUrgencia() async {
    try {
      final n = await conteoInsigniaVencimientos();
      if (mounted) setState(() => _urgenciaVenc = n);
    } catch (_) {
      // Sin lectura, sin insignia: el segmento no afirma
      // una cifra que no pudo comprobar.
    }
  }

  List<String> get _segmentos => [
        'directorio',
        'vencimientos',
        'invitados',
        if (widget.esDueno) 'avisos',
      ];

  @override
  void initState() {
    super.initState();
    MarcoNav.destinoClientes.addListener(_aplicarDestino);
    // 1.35 (UI-08): la insignia se cuenta al nacer y se
    // recuenta cada vez que la sync queda en reposo (la
    // foto del espejo pudo cambiar).
    _contarUrgencia();
    _subSync = SyncEngine.instance.statusStream.listen((s) {
      if (s.phase == SyncPhase.idle) _contarUrgencia();
    });
    // Un destino pedido ANTES de montar el pilar (arranque
    // directo con salto) se aplica al nacer.
    if (MarcoNav.destinoClientes.value != null) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _aplicarDestino());
    }
  }

  @override
  void dispose() {
    MarcoNav.destinoClientes.removeListener(_aplicarDestino);
    _subSync?.cancel();
    super.dispose();
  }

  void _aplicarDestino() {
    final d = MarcoNav.destinoClientes.value;
    if (d == null || !mounted) return;
    MarcoNav.destinoClientes.value = null; // consumir
    if (!_segmentos.contains(d.segmento)) return;
    setState(() {
      _segmento = d.segmento;
      _visitados.add(d.segmento);
      if (d.tabListas != null) {
        _tabListas = d.tabListas!;
        _epochListas++; // ListasScreen lee «inicial» al nacer
      }
      if (d.filtro != null) {
        _filtroBuscar = d.filtro;
        _epochBuscar++; // BuscarScreen lee «filtroInicial» al nacer
      }
    });
    // E3 (C5-02): un salto de destino también es un cambio
    // de contexto: la insignia se recuenta al aplicarlo.
    _contarUrgencia();
  }

  void _ir(Widget pantalla) {
    Navigator.of(context).push(RutaIron(builder: (_) => pantalla));
  }

  Widget _vistaDe(String segmento) {
    switch (segmento) {
      case 'vencimientos':
        return ListasScreen(
          key: ValueKey('pilar-listas-$_epochListas'),
          embebida: true,
          inicial: _tabListas,
          // E3 (C5-02): marcar avisado, cobrar o volver de
          // la ficha recuentan la insignia al momento.
          alCambiarDatos: () {
            _contarUrgencia();
          },
        );
      case 'invitados':
        return const InvitadosScreen(embebido: true);
      case 'avisos':
        return const BandejaWhatsappScreen(embebida: true);
      case 'directorio':
      default:
        return BuscarScreen(
          key: ValueKey('pilar-buscar-$_epochBuscar'),
          embebida: true,
          filtroInicial: _filtroBuscar,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final segmentos = _segmentos;
    return NotificationListener<ScrollNotification>(
      onNotification: _alDesplazar,
      child: Column(
      key: const ValueKey('pilar-clientes'),
      children: [
        // Acciones del pilar (G-73): inscribir y pase diario /
        // control de acceso a 1 toque; papelera del dueño.
        // 1.35 (campo nº 13): se pliegan al bajar.
        AccionesPilarClientes(
          esDueno: widget.esDueno,
          plegadas: _accionesPlegadas,
          onInscribir: () async {
            if (await permisoOperativoOkConRefresco(
                context,
                () => PermisosEntrenador().canInscribirClientes,
                'inscribir clientes')) {
              _ir(const InscribirScreen());
            }
          },
          onAcceso: () => _ir(const ControlAccesoScreen()),
          onPapelera: () => _ir(const PapeleraScreen()),
        ),
        // Segmentos del pilar.
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppEspacio.lg, AppEspacio.md, AppEspacio.lg, AppEspacio.sm),
          // 1.32 (integración, RD-8): con pista — al crecer
          // la fuente, «Avisos WhatsApp» quedaba fuera sin
          // señal de que hubiera más segmentos.
          child: ScrollHorizontalConPista(
            colorFondo: Theme.of(context).scaffoldBackgroundColor,
            child: SegmentedButton<String>(
              segments: [
                const ButtonSegment(
                    value: 'directorio',
                    icon: Icon(Icons.people_rounded),
                    label: Text('Directorio')),
                ButtonSegment(
                    value: 'vencimientos',
                    icon: const Icon(Icons.event_busy_rounded),
                    // 1.35 (UI-08): la urgencia se ve antes
                    // de entrar — solo si es mayor que cero
                    // (la regla del cero de Jc) y solo si la
                    // cifra se pudo leer.
                    label: Badge(
                      isLabelVisible:
                          _urgenciaVenc != null && _urgenciaVenc! > 0,
                      label: Text('${_urgenciaVenc ?? ''}'),
                      child: const Text('Vencimientos'),
                    )),
                const ButtonSegment(
                    value: 'invitados',
                    icon: Icon(Icons.card_membership_rounded),
                    label: Text('Invitados/Plus')),
                if (widget.esDueno)
                  const ButtonSegment(
                      value: 'avisos',
                      icon: Icon(Icons.forum_rounded),
                      label: Text('Avisos WhatsApp')),
              ],
              selected: {_segmento},
              onSelectionChanged: (s) {
                // 1.35 (UI-02): cambiar de segmento se siente.
                Tacto.seleccion();
                setState(() {
                  _segmento = s.first;
                  _visitados.add(s.first);
                });
                // E3 (C5-02): al volver a un segmento la
                // insignia se recuenta: marcar avisado es
                // local y cobrar desde la ficha no pasa por
                // la sync — sin este recuento la insignia
                // prometía trabajo ya hecho.
                _contarUrgencia();
              },
            ),
          ),
        ),
        Expanded(
          // 1.35 (UI-01): mismo fundido al cambiar de
          // segmento, sin remontar las vistas visitadas.
          child: FundidoAlCambiar(
            indice: segmentos.indexOf(_segmento),
            child: IndexedStack(
            index: segmentos.indexOf(_segmento),
            children: [
              for (final s in segmentos)
                if (_visitados.contains(s))
                  KeyedSubtree(
                      key: ValueKey('pilar-clientes-$s'), child: _vistaDe(s))
                else
                  const SizedBox.shrink(),
            ],
            ),
          ),
        ),
      ],
      ),
    );
  }
}
