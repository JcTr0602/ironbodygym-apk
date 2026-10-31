/// Listas: vencen hoy, atrasados, por vencer. Con mini foto y pago rápido.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import '../sync.dart';
import '../cliente_protegido.dart';
import 'buscar.dart';
import 'componentes.dart';
import 'dialogo_pago.dart';
import 'preview_cobro.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

/// Buscador de Listas (16/25, PURO): coincide por nombre (sin
/// mayúsculas) o por dígitos del teléfono.
bool coincideBusquedaListas(Map<String, dynamic> c, String texto) {
  final q = texto.trim().toLowerCase();
  if (q.isEmpty) return true;
  if ('${c['nombre'] ?? ''}'.toLowerCase().contains(q)) return true;
  final digQ = q.replaceAll(RegExp(r'[^0-9]'), '');
  if (digQ.isNotEmpty) {
    final tel =
        '${c['telefono'] ?? ''}'.replaceAll(RegExp(r'[^0-9]'), '');
    if (tel.contains(digQ)) return true;
  }
  return false;
}

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
  // 16/25: buscador dentro de Listas (nombre o teléfono).
  String _busqueda = '';
  final _busquedaCtrl = TextEditingController();

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    _tab.dispose();
    super.dispose();
  }

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
    // Cliente protegido (2026-10-26, Protegido 2 H6): estas listas
    // muestran teléfono y botón de WhatsApp; un no-dueño no ve
    // protegidos en ninguna.
    List<Map<String, dynamic>> sinProtegidos(
        List<Map<String, dynamic>> l) =>
        l.where((c) => !esVistaProtegida(c)).toList();
    if (mounted) {
      setState(() {
        _hoy = sinProtegidos(h);
        _menos30 = sinProtegidos(m30);
        _mas30 = sinProtegidos(p30);
        _porVencer = sinProtegidos(pv);
        _alDia = sinProtegidos(ad);
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

  /// 16/25: lista ordenada y filtrada por la búsqueda (aplica a
  /// las 5 pestañas por igual).
  List<Map<String, dynamic>> _visibles(
      List<Map<String, dynamic>> rows) {
    return _ordenar(rows)
        .where((c) => coincideBusquedaListas(c, _busqueda))
        .toList();
  }

  Future<void> _pagoRapido(Map<String, dynamic> c) async {
    // Bloque 1 (Argón AMARILLO): Casa no paga mensualidad, y el
    // «cobro en 2 toques» ya no existe: todo cobro pasa por el
    // Preview obligatorio + Recibo con Deshacer, sin excepciones.
    if (await mostrarBloqueoCasa(context, c)) return;
    if (!mounted) return;
    final payload = await pagoDialogo(context, c);
    if (payload == null || !mounted) return;
    final deshecho = await cobrarConPreviewYRecibo(
      context: context,
      nombreCliente: '${c['nombre'] ?? ''}',
      payload: payload,
    );
    if (!mounted) return;
    if (deshecho) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cobro deshecho')));
    }
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
            // L1 (estéticas 1.19): cada pestaña lleva su color
            // semántico — ámbar para Hoy/Por vencer, rojo para
            // los dos Atrasados, verde para Al día — para ver la
            // urgencia sin leer el número.
            Tab(
              child: Text('Hoy (${_hoy.length})',
                  style: const TextStyle(
                      color: AppColores.alerta,
                      fontWeight: FontWeight.w600)),
            ),
            Tab(
              child: Text('Por vencer (${_porVencer.length})',
                  style: const TextStyle(
                      color: AppColores.alerta,
                      fontWeight: FontWeight.w600)),
            ),
            Tab(
              child: Text('Atrasados -30d (${_menos30.length})',
                  style: const TextStyle(
                      color: AppColores.error,
                      fontWeight: FontWeight.w600)),
            ),
            Tab(
              child: Text('Atrasados +30d (${_mas30.length})',
                  style: const TextStyle(
                      color: AppColores.error,
                      fontWeight: FontWeight.w600)),
            ),
            Tab(
              child: Text('Al día (${_alDia.length})',
                  style: const TextStyle(
                      color: AppColores.exito,
                      fontWeight: FontWeight.w600)),
            ), // v1.2.1
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
          // 16/25: buscador (nombre o teléfono, en las 5 pestañas).
          Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: CampoTexto(
                    controller: _busquedaCtrl,
                    hint: 'Buscar cliente…',
                    icono: Icons.search,
                    onChanged: (v) =>
                        setState(() => _busqueda = v.trim()),
                  ),
                ),
                if (_busqueda.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Limpiar búsqueda',
                    onPressed: () {
                      _busquedaCtrl.clear();
                      setState(() => _busqueda = '');
                    },
                  ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _lista(_visibles(_hoy), Icons.celebration,
                    'Nadie vence hoy', 'Todo al día.'),
                _lista(_visibles(_porVencer),
                    Icons.celebration, 'Nadie por vencer',
                    'Nada en los próximos 3 días.'),
                _lista(_visibles(_menos30),
                    Icons.celebration, 'Sin atrasados',
                    'Nada de menos de un mes.'),
                _lista(_visibles(_mas30),
                    Icons.celebration, 'Sin atrasados',
                    'Nada de más de un mes.'),
                _lista(_visibles(_alDia), // v1.2.1
                    Icons.check_circle, 'Nadie al día',
                    'Todos los activos están vencidos.'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v1.2.4 (C7): móvil cubano del cliente para wa.me (con prefijo
  /// 53) o null. Argón P3#5: normalizarTelefonoWaMe acepta 5 y 6.
  String? _movilCliente(Map<String, dynamic> c) {
    final normalizado =
        normalizarTelefonoWaMe('${c['telefono'] ?? ''}');
    return normalizado.isEmpty ? null : normalizado;
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
                    hoyHabanaIso()) <
                0
            ? 'tu mensualidad venció el $f'
            : 'tu mensualidad vence el $f');
    final msg = 'Hola $nombre 👋, te recordamos de Iron Body Gym que '
        '$venceTxt. ¡Te esperamos para seguir entrenando! 💪';
    final ok = await launchUrl(
        Uri.parse('https://wa.me/$movil?text=${Uri.encodeComponent(msg)}'),
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
      // 16/25: con búsqueda activa, el vacío es por la búsqueda
      // (no porque nadie venza) y ofrece limpiarla.
      if (_busqueda.isNotEmpty) {
        return EstadoVacio(
          icono: Icons.search_off,
          titulo: 'Sin coincidencias',
          subtitulo: 'Ningún cliente de esta lista coincide '
              'con «$_busqueda».',
          textoAccion: 'Limpiar búsqueda',
          onAccion: () {
            _busquedaCtrl.clear();
            setState(() => _busqueda = '');
          },
        );
      }
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
          // L2 (estéticas 1.19): la fila avisada lleva acento
          // verde en el borde izquierdo.
          return FutureBuilder<String?>(
            future: LocalDb.instance.getAvisado(id),
            builder: (ctx, snap) {
              final avisado = snap.data != null;
              return Container(
                decoration: avisado
                    ? const BoxDecoration(
                        border: Border(
                          left: BorderSide(
                              color: AppColores.exito, width: 4),
                        ),
                      )
                    : null,
                child: FilaCliente(
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
                    IconButton(
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
              ),
            );
          },
        );
      },
      ),
    );
  }
}
