/// Listas: vencen hoy, atrasados, por vencer. Con mini foto y pago rápido.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import 'buscar.dart';
import 'componentes.dart';
import 'confirmacion_cobro.dart';
import 'dialogo_pago.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

class ListasScreen extends StatefulWidget {
  /// Pestaña inicial: 0=Hoy, 1=Por vencer, 2=Atrasados <30d, 3=Atrasados +30d,
  /// 4=Al día (v1.2.1).
  final int inicial;
  const ListasScreen({super.key, this.inicial = 0});
  @override
  State<ListasScreen> createState() => _ListasScreenState();
}

class _ListasScreenState extends State<ListasScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;
  List<Map<String, dynamic>> _hoy = [];
  List<Map<String, dynamic>> _menos30 = [];
  List<Map<String, dynamic>> _mas30 = [];
  List<Map<String, dynamic>> _porVencer = [];
  List<Map<String, dynamic>> _alDia = []; // v1.2.1
  String _orden = 'nombre'; // nombre | vencimiento | dias

  @override
  void initState() {
    super.initState();
    _tab = TabController(
        length: 5, vsync: this, initialIndex: widget.inicial);
    _cargar();
  }

  Future<void> _cargar() async {
    final h = await vencenHoy();
    final m30 = await atrasados(masDe30: false);
    final p30 = await atrasados(masDe30: true);
    final pv = await porVencer(dias: 3);
    final ad = await clientesAlDia(); // v1.2.1
    if (mounted) {
      setState(() {
        _hoy = h;
        _menos30 = m30;
        _mas30 = p30;
        _porVencer = pv;
        _alDia = ad;
      });
    }
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

  Future<void> _pagoRapido(Map<String, dynamic> c) async {
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'pago_mensual',
      payload: payload,
    );
    if (!mounted) return;
    // Confirmación a pantalla completa (cobro en 2 toques)
    final monto = '${payload['monto'] ?? ''} CUP';
    final venc = '${payload['pagado_hasta'] ?? ''}';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConfirmacionCobroScreen(
          nombreCliente: '${c['nombre'] ?? ''}',
          monto: monto,
          nuevoVencimiento:
              venc.length >= 10 ? venc.substring(0, 10) : venc,
        ),
      ),
    );
    if (!mounted) return;
    _cargar();
    SyncEngine.instance.push();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vencimientos'), // v1.3.6: renombrado (era 'Listas')
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabs: [
            Tab(text: 'Hoy (${_hoy.length})'),
            Tab(text: 'Por vencer (${_porVencer.length})'),
            Tab(text: 'Atrasados -30d (${_menos30.length})'),
            Tab(text: 'Atrasados +30d (${_mas30.length})'),
            Tab(text: 'Al día (${_alDia.length})'), // v1.2.1
          ],
        ),
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                const Text('Ordenar: ',
                    style: TextStyle(fontSize: 13)),
                DropdownButton<String>(
                  value: _orden,
                  items: const [
                    DropdownMenuItem(
                        value: 'nombre',
                        child: Text('Nombre')),
                    DropdownMenuItem(
                        value: 'vencimiento',
                        child: Text('Vencimiento')),
                    DropdownMenuItem(
                        value: 'dias',
                        child: Text('Días restantes')),
                  ],
                  onChanged: (v) =>
                      setState(() => _orden = v ?? 'nombre'),
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _lista(_ordenar(_hoy), Icons.celebration,
                    'Nadie vence hoy', 'Todo al día.'),
                _lista(_ordenar(_porVencer),
                    Icons.celebration, 'Nadie por vencer',
                    'Nada en los próximos 3 días.'),
                _lista(_ordenar(_menos30),
                    Icons.celebration, 'Sin atrasados',
                    'Nada de menos de un mes.'),
                _lista(_ordenar(_mas30),
                    Icons.celebration, 'Sin atrasados',
                    'Nada de más de un mes.'),
                _lista(_ordenar(_alDia), // v1.2.1
                    Icons.check_circle, 'Nadie al día',
                    'Todos los activos están vencidos.'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v1.2.4 (C7): móvil cubano del cliente (8 dígitos) o null.
  String? _movilCliente(Map<String, dynamic> c) {
    var t = '${c['telefono'] ?? ''}'.replaceAll(RegExp(r'\D'), '');
    if (t.startsWith('53') && t.length > 8) t = t.substring(2);
    return (t.length == 8 && t.startsWith('5')) ? t : null;
  }

  Future<String?> _elegirAviso(Map<String, dynamic> c) async {
    if (_movilCliente(c) == null) return 'marcar';
    return showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chat, color: AppColores.exito),
              title: const Text('Avisar por WhatsApp'),
              subtitle: const Text('Abre WhatsApp con el mensaje escrito'),
              onTap: () => Navigator.pop(ctx, 'whatsapp'),
            ),
            ListTile(
              leading: const Icon(Icons.check_circle_outline),
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
    final nombre = '${c['nombre'] ?? ''}'.split(' ').first;
    final hasta = '${c['pagado_hasta'] ?? ''}';
    final f = hasta.length >= 10 ? fmtFecha(hasta) : '';
    final venceTxt = f.isEmpty
        ? 'tu mensualidad está por vencer'
        : (hasta.substring(0, 10).compareTo(
                    DateTime.now().toIso8601String().substring(0, 10)) <
                0
            ? 'tu mensualidad venció el $f'
            : 'tu mensualidad vence el $f');
    final msg = 'Hola $nombre 👋, te recordamos de Iron Body Gym que '
        '$venceTxt. ¡Te esperamos para seguir entrenando! 💪';
    final ok = await launchUrl(
        Uri.parse('https://wa.me/53$movil?text=${Uri.encodeComponent(msg)}'),
        mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir WhatsApp')));
    }
    return ok;
  }

  Widget _lista(List<Map<String, dynamic>> rows, IconData iconoVacio,
      String tituloVacio, String subtituloVacio) {
    if (rows.isEmpty) {
      return EstadoVacio(
          icono: iconoVacio,
          titulo: tituloVacio,
          subtitulo: subtituloVacio);
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.separated(
        itemCount: rows.length,
        separatorBuilder: (_, __) => Divider(
            height: 1,
            indent: 84,
            color: AppColores.borde(context)),
        itemBuilder: (ctx, i) {
          final c = rows[i];
          final id = (c['id'] as int?) ?? 0;
          return FilaCliente(
            cliente: c,
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => FichaScreen(
                        clienteId: id)))
                .then((_) => _cargar()),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Botón avisar (toggle)
                FutureBuilder<String?>(
                  future: LocalDb.instance.getAvisado(id),
                  builder: (ctx, snap) {
                    final avisado = snap.data != null;
                    return IconButton(
                      icon: Icon(
                          avisado
                              ? Icons.check_circle
                              : Icons
                                  .notifications_outlined,
                          color: avisado
                              ? AppColores.exito
                              : Colors.grey),
                      tooltip: avisado
                          ? 'Avisado (toca para quitar)'
                          : 'Marcar como avisado',
                      onPressed: () async {
                        if (avisado) {
                          await LocalDb.instance
                              .desmarcarAvisado(id);
                          if (mounted) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(
                              SnackBar(
                                  content: Text(
                                      'Marca de avisado quitada para ${c['nombre']}')),
                            );
                            setState(() {});
                          }
                        } else {
                          // v1.2.4 (C7): avisar por WhatsApp con el
                          // mensaje ya escrito si tiene teléfono.
                          final via = await _elegirAviso(c);
                          if (via == null) return;
                          if (via == 'whatsapp') {
                            final ok = await _abrirWhatsapp(c);
                            if (!ok) return;
                          }
                          await LocalDb.instance
                              .marcarAvisado(id);
                          if (mounted) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(
                              SnackBar(
                                  content: Text(
                                      '${c['nombre']} marcado como avisado')),
                            );
                            setState(() {});
                          }
                        }
                      },
                    );
                  },
                ),
                // Botón cobro rápido (naranja circular)
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient:
                        AppColores.gradienteNaranja,
                    shape: BoxShape.circle,
                    boxShadow:
                        AppSombra.botonPrimario,
                  ),
                  child: InkWell(
                    customBorder:
                        const CircleBorder(),
                    onTap: () => _pagoRapido(c),
                    child: const Icon(
                        Icons.payments,
                        color: Colors.white,
                        size: 22),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
