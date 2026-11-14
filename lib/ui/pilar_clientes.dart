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

import 'package:flutter/material.dart';

import '../permisos_entrenador.dart';
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

class _PilarClientesState extends State<PilarClientes> {
  String _segmento = 'directorio';
  int _tabListas = 0;
  int _epochListas = 0;
  String? _filtroBuscar;
  int _epochBuscar = 0;
  final Set<String> _visitados = {'directorio'};

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
    return Column(
      key: const ValueKey('pilar-clientes'),
      children: [
        // Acciones del pilar (G-73): inscribir y pase diario /
        // control de acceso a 1 toque; papelera del dueño.
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppEspacio.lg, AppEspacio.md, AppEspacio.lg, 0),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('clientes-inscribir'),
                  onPressed: () async {
                    if (await permisoOperativoOkConRefresco(
                        context,
                        () => PermisosEntrenador().canInscribirClientes,
                        'inscribir clientes')) {
                      _ir(const InscribirScreen());
                    }
                  },
                  icon: const Icon(Icons.person_add_rounded, size: 19),
                  label: const Text('Inscribir'),
                ),
              ),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('clientes-acceso'),
                  onPressed: () => _ir(const ControlAccesoScreen()),
                  icon: const Icon(Icons.badge_rounded, size: 19),
                  label: const Text('Control de Acceso'),
                ),
              ),
              if (widget.esDueno)
                IconButton(
                  key: const ValueKey('clientes-papelera'),
                  tooltip: 'Papelera',
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => _ir(const PapeleraScreen()),
                ),
            ],
          ),
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
                const ButtonSegment(
                    value: 'vencimientos',
                    icon: Icon(Icons.event_busy_rounded),
                    label: Text('Vencimientos')),
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
              onSelectionChanged: (s) => setState(() {
                _segmento = s.first;
                _visitados.add(s.first);
              }),
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
    );
  }
}
