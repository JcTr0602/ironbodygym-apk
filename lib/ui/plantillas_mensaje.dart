/// Plantillas de mensajes G1 (Bloque 2 NÚCLEO, 1.10.0, Argón
/// AMARILLO ajuste 6).
///
/// Lista, creación, edición, vista previa y envío por WhatsApp.
/// El render usa SOLO la lista blanca (ver plantilla_mensaje.dart):
/// motivo, otorgado_por, notas y comparativas jamás salen.
/// Antes de enviar, si la sync lleva > 2 h o hay ops en cola, se
/// muestra el aviso no bloqueante (no impide enviar).
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../plantilla_mensaje.dart';
import '../precio_cobro.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

class PlantillasScreen extends StatefulWidget {
  const PlantillasScreen({super.key});
  @override
  State<PlantillasScreen> createState() => _PlantillasScreenState();
}

class _PlantillasScreenState extends State<PlantillasScreen> {
  var _cargando = true;
  List<Map<String, dynamic>> _plantillas = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final lista = await listarPlantillas();
    if (!mounted) return;
    setState(() {
      _plantillas = lista;
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Plantillas de mensajes')),
      floatingActionButton: AuthService().isOwner
          ? FloatingActionButton.extended(
              onPressed: () async {
                await _editarPlantilla(context, null);
                _cargar();
              },
              icon: const Icon(Icons.add),
              label: const Text('Nueva plantilla'),
            )
          : null,
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _plantillas.isEmpty
              ? const Center(
                  child: Text(
                      'Sin plantillas. Crea la primera con el botón +.',
                      style: AppTexto.secundario))
              : RefreshIndicator(
                  onRefresh: _cargar,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      const Text(
                        'Variables permitidas: {{nombre}}, '
                        '{{fecha_vencimiento}}, {{monto_a_pagar_vigente}}, '
                        '{{dias_restantes}}, {{folio_recibo}}. Cualquier '
                        'otra variable queda sin sustituir.',
                        style: AppTexto.secundario,
                      ),
                      const SizedBox(height: 12),
                      for (final p in _plantillas)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.message,
                                color: AppColores.naranja),
                            title: Text('${p['nombre']}'),
                            subtitle: Text('${p['cuerpo']}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            onTap: () => _vistaPrevia(p),
                            trailing: AuthService().isOwner
                                ? PopupMenuButton<String>(
                                    onSelected: (v) async {
                                      if (v == 'editar') {
                                        await _editarPlantilla(
                                            context, p);
                                        _cargar();
                                      } else if (v == 'eliminar') {
                                        await eliminarPlantilla(
                                            '${p['id']}');
                                        _cargar();
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                          value: 'editar',
                                          child: Text('Editar')),
                                      PopupMenuItem(
                                          value: 'eliminar',
                                          child: Text('Eliminar')),
                                    ],
                                  )
                                : null,
                          ),
                        ),
                    ],
                  ),
                ),
    );
  }

  Future<void> _editarPlantilla(
      BuildContext context, Map<String, dynamic>? p) async {
    final nombreCtrl = TextEditingController(text: '${p?['nombre'] ?? ''}');
    final cuerpoCtrl = TextEditingController(text: '${p?['cuerpo'] ?? ''}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => DialogoApp(
          titulo: p == null ? 'Nueva plantilla' : 'Editar plantilla',
          iconoTitulo: Icons.message,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: nombreCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Nombre',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                TextField(
                    controller: cuerpoCtrl,
                    maxLines: 6,
                    decoration: const InputDecoration(
                        labelText: 'Texto (usa {{variable}})',
                        border: OutlineInputBorder())),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final v in kVariablesPlantilla)
                      ActionChip(
                        label: Text('{{$v}}'),
                        onPressed: () {
                          final t = cuerpoCtrl.text;
                          cuerpoCtrl.text = '$t {{$v}}';
                          setS(() {});
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
          acciones: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Guardar')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    if (nombreCtrl.text.trim().isEmpty ||
        cuerpoCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nombre y texto son obligatorios.')));
      return;
    }
    if (p == null) {
      await crearPlantilla(
          nombreCtrl.text.trim(), cuerpoCtrl.text.trim());
    } else {
      await editarPlantilla(
          '${p['id']}', nombreCtrl.text.trim(), cuerpoCtrl.text.trim());
    }
  }

  /// Vista previa con datos de ejemplo + aviso de frescura real.
  Future<void> _vistaPrevia(Map<String, dynamic> p) async {
    final ejemplo = {
      'nombre': 'Ejemplo Pérez',
      'fecha_vencimiento': '20/11/2026',
      'monto_a_pagar_vigente': '2000 CUP',
      'dias_restantes': '5',
      'folio_recibo': '—',
    };
    final render = renderPlantilla('${p['cuerpo']}', ejemplo);
    final aviso = await _avisoReal();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Vista previa: ${p['nombre']}',
        iconoTitulo: Icons.preview,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(render.texto),
            if (render.bloqueadas.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Variables NO permitidas (quedaron sin sustituir): '
                  '${render.bloqueadas.map((b) => '{{$b}}').join(', ')}',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (aviso != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(aviso,
                    style: const TextStyle(color: Colors.orange)),
              ),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar')),
          FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await _enviarACliente(p);
              },
              child: const Text('Enviar a un cliente')),
        ],
      ),
    );
  }

  Future<String?> _avisoReal() async {
    try {
      final ts = await LocalDb.instance.getMeta('ultimo_pull_ts');
      final pendientes = await LocalDb.instance.countPendingOps();
      return avisoFrescura(
          ultimoPullIso: ts,
          opsPendientes: pendientes,
          ahora: ahoraHabana());
    } catch (_) {
      return null;
    }
  }

  /// Enviar: elige cliente, renderiza con SUS datos y abre wa.me.
  /// No registra nada (como el teléfono tocable de la ficha).
  Future<void> _enviarACliente(Map<String, dynamic> p) async {
    final todos = await listaClientes('');
    final filtro = TextEditingController();
    final cliente = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final q = filtro.text.trim().toLowerCase();
          final visibles = q.isEmpty
              ? todos
              : todos
                  .where((c) => '${c['nombre'] ?? ''}'
                      .toLowerCase()
                      .contains(q))
                  .toList();
          return DialogoApp(
            titulo: 'Elegir cliente',
            iconoTitulo: Icons.person,
            contenido: SizedBox(
              width: double.maxFinite,
              height: 380,
              child: Column(
                children: [
                  TextField(
                    controller: filtro,
                    decoration: const InputDecoration(
                        hintText: 'Filtrar por nombre',
                        border: OutlineInputBorder()),
                    onChanged: (_) => setS(() {}),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final c in visibles)
                          ListTile(
                            dense: true,
                            title: Text('${c['nombre'] ?? ''}'),
                            subtitle: Text('${c['telefono'] ?? ''}'),
                            onTap: () => Navigator.pop(ctx, c),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            acciones: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, null),
                  child: const Text('Cancelar')),
            ],
          );
        },
      ),
    );
    if (cliente == null || !mounted) return;
    final precio = await precioCobroParaCliente(
        cliente: cliente, periodo: 'mensual', metodo: 'efectivo');
    final ph = '${cliente['pagado_hasta'] ?? ''}';
    var dias = '—';
    if (ph.length >= 10) {
      try {
        final hasta = DateTime.parse(ph.substring(0, 10));
        final hoy = DateTime.parse(hoyHabanaIso());
        dias = '${hasta.difference(hoy).inDays}';
      } catch (_) {}
    }
    final datos = {
      'nombre': '${cliente['nombre'] ?? ''}',
      'fecha_vencimiento':
          ph.length >= 10 ? fmtFecha(ph.substring(0, 10)) : '—',
      'monto_a_pagar_vigente': '${fmtMonto(precio.monto)} CUP',
      'dias_restantes': dias,
      'folio_recibo': '—',
    };
    final render = renderPlantilla('${p['cuerpo']}', datos);
    final aviso = await _avisoReal();
    if (!mounted) return;
    final enviar = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Enviar a ${cliente['nombre']}',
        iconoTitulo: Icons.send,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(render.texto),
            if (aviso != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(aviso,
                    style: const TextStyle(color: Colors.orange)),
              ),
          ],
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Abrir WhatsApp')),
        ],
      ),
    );
    if (enviar != true || !mounted) return;
    final tel = normalizarTelefonoWaMe('${cliente['telefono'] ?? ''}');
    if (tel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('El cliente no tiene un teléfono válido.')));
      return;
    }
    final url = Uri.parse(
        'https://wa.me/$tel?text=${Uri.encodeComponent(render.texto)}');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No se pudo abrir WhatsApp.')));
    }
  }
}
