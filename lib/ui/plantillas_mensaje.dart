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
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../plantilla_mensaje.dart';
import '../precio_cobro.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import '../app_log.dart';

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
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
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
      appBar: appBarIron(context, 'Plantillas de mensajes'),
      floatingActionButton: AuthService().isOwner
          ? FloatingActionButton.extended(
              onPressed: () async {
                await _editarPlantilla(context, null);
                _cargar();
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('Nueva plantilla'),
            )
          : null,
      // 1.23 B7+T7: cruce por tipo de estado y vacío compartido.
      body: CruceEstados(
        estado: _cargando
            ? 'cargando'
            : _plantillas.isEmpty
                ? 'vacio'
                : 'contenido',
        child: _cargando
            ? const EstadoCargando(texto: 'Cargando plantillas…')
            : _plantillas.isEmpty
                ? const EstadoVacio(
                    icono: Icons.message_rounded,
                    titulo: 'Sin plantillas.',
                    subtitulo: 'Crea la primera con el botón +.')
                : RefrescoIron(
                  onRefresh: _cargar,
                  child: ListView(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    children: [
                      const Text(
                        // 1.25 T42: también vale la sintaxis
                        // simple de Campañas ({nombre}).
                        'Variables permitidas: {{nombre}}, '
                        '{{fecha_vencimiento}}, {{monto_a_pagar_vigente}}, '
                        '{{dias_restantes}}, {{folio_recibo}} '
                        '(también vale {nombre}, como en Campañas). '
                        'Cualquier otra variable queda sin sustituir.',
                        style: AppTexto.secundario,
                      ),
                      const SizedBox(height: 12),
                      for (final p in _plantillas)
                        Card(
                          child: ListTile(
                            leading: Icon(Icons.message_rounded,
                                color: AppColores.textoSecundario(context)),
                            title: Text('${p['nombre']}'),
                            subtitle: Text('${p['cuerpo']}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis),
                            onTap: () => _vistaPrevia(p),
                            trailing: AuthService().isOwner
                                ? PopupMenuButton<String>(
                                    popUpAnimationStyle: estiloAparicionMenu,
                                    onSelected: (v) async {
                                      if (v == 'editar') {
                                        await _editarPlantilla(
                                            context, p);
                                        _cargar();
                                      } else if (v == 'eliminar') {
                                        // SL-10 G04-7: una
                                        // plantilla compartida
                                        // no se borra de un
                                        // toque: confirmación
                                        // estándar de la casa.
                                        final ok =
                                            await DialogoApp.confirmar(
                                          context,
                                          titulo:
                                              '¿Eliminar la plantilla?',
                                          mensaje:
                                              '«${p['nombre']}» dejará de estar disponible en todos los dispositivos del negocio.',
                                          aceptar: 'Eliminar',
                                          peligro: true,
                                        );
                                        if (!ok || !mounted) return;
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
        ),
    );
  }

  Future<void> _editarPlantilla(
      BuildContext context, Map<String, dynamic>? p) async {
    final datos = await showDialog<({String nombre, String cuerpo})>(
      context: context,
      builder: (ctx) => _DialogoEditarPlantilla(plantilla: p),
    );
    if (datos == null || !context.mounted) return;
    if (datos.nombre.trim().isEmpty || datos.cuerpo.trim().isEmpty) {
      mostrarSnack(context, 'Nombre y texto son obligatorios.', significado: SignificadoChip.alerta);
      return;
    }
    if (p == null) {
      await crearPlantilla(datos.nombre.trim(), datos.cuerpo.trim());
    } else {
      await editarPlantilla(
          '${p['id']}', datos.nombre.trim(), datos.cuerpo.trim());
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
        iconoTitulo: Icons.preview_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(render.texto),
            if (render.bloqueadas.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.sm),
                child: Text(
                  'Variables NO permitidas (quedaron sin sustituir): '
                  '${render.bloqueadas.map((b) => '{{$b}}').join(', ')}',
                  style: TextStyle(color: AppColores.errorTexto(context)),
                ),
              ),
            if (aviso != null)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.sm),
                child: Text(aviso,
                    style: TextStyle(color: AppColores.alertaTexto(context))),
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
    final cliente = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _DialogoElegirClientePlantilla(todos: todos),
    );
    if (cliente == null || !mounted) return;
    final precio = await precioCobroParaCliente(
        cliente: cliente, periodo: 'mensual', metodo: 'efectivo');
    final ph = '${cliente['pagado_hasta'] ?? ''}';
    var dias = '—';
    // Yunque B (YB-CLI-08): días contados en UTC vía
    // fechaIsoEstricta — con medianoches locales, la variable
    // {dias} del mensaje salía con un día de desfase al
    // cruzar el cambio de hora.
    final hastaD = fechaIsoEstricta(ph);
    final hoyD = fechaIsoEstricta(hoyHabanaIso());
    if (hastaD != null && hoyD != null) {
      dias = '${hastaD.difference(hoyD).inDays}';
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
        iconoTitulo: Icons.send_rounded,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(render.texto),
            if (aviso != null)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.sm),
                child: Text(aviso,
                    style: TextStyle(color: AppColores.alertaTexto(context))),
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
    // 1.32 (D-5, familia teléfono efectivo): la plantilla va
    // al teléfono EFECTIVO (movil primero), no al crudo.
    final tel = telefonoEfectivoWa(cliente);
    if (tel.isEmpty) {
      mostrarSnack(context, 'El cliente no tiene un teléfono válido.', significado: SignificadoChip.alerta);
      return;
    }
    final url = Uri.parse(
        'https://wa.me/$tel?text=${Uri.encodeComponent(render.texto)}');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      mostrarSnack(context, 'No se pudo abrir WhatsApp.', significado: SignificadoChip.error);
    }
  }
}

/// 1.30 (Oleada 7, clase B): editor de plantilla como
/// StatefulWidget propio: posee y dispone los controladores
/// de nombre y cuerpo (antes se creaban en el llamador y
/// nunca se liberaban). Devuelve los textos al guardar o
/// null si se cancela.
class _DialogoEditarPlantilla extends StatefulWidget {
  final Map<String, dynamic>? plantilla;
  const _DialogoEditarPlantilla({required this.plantilla});

  @override
  State<_DialogoEditarPlantilla> createState() =>
      _DialogoEditarPlantillaState();
}

class _DialogoEditarPlantillaState
    extends State<_DialogoEditarPlantilla> {
  late final TextEditingController _nombreCtrl;
  late final TextEditingController _cuerpoCtrl;

  @override
  void initState() {
    super.initState();
    final p = widget.plantilla;
    _nombreCtrl = TextEditingController(text: '${p?['nombre'] ?? ''}');
    _cuerpoCtrl = TextEditingController(text: '${p?['cuerpo'] ?? ''}');
  }

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _cuerpoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.plantilla;
    return DialogoApp(
      titulo: p == null ? 'Nueva plantilla' : 'Editar plantilla',
      iconoTitulo: Icons.message_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: _nombreCtrl,
                decoration: const InputDecoration(
                    labelText: 'Nombre',
                    border: OutlineInputBorder())),
            const SizedBox(height: 8),
            TextField(
                controller: _cuerpoCtrl,
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
                      final t = _cuerpoCtrl.text;
                      _cuerpoCtrl.text = '$t {{$v}}';
                      setState(() {});
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(context,
                (nombre: _nombreCtrl.text, cuerpo: _cuerpoCtrl.text)),
            child: const Text('Guardar')),
      ],
    );
  }
}

/// 1.30 (Oleada 7, clase B): selector de cliente para enviar
/// la plantilla, como StatefulWidget propio: posee y dispone
/// el controlador del filtro (antes se creaba en el llamador
/// y nunca se liberaba). Devuelve el cliente elegido o null.
class _DialogoElegirClientePlantilla extends StatefulWidget {
  final List<Map<String, dynamic>> todos;
  const _DialogoElegirClientePlantilla({required this.todos});

  @override
  State<_DialogoElegirClientePlantilla> createState() =>
      _DialogoElegirClientePlantillaState();
}

class _DialogoElegirClientePlantillaState
    extends State<_DialogoElegirClientePlantilla> {
  final _filtro = TextEditingController();

  @override
  void dispose() {
    _filtro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _filtro.text.trim().toLowerCase();
    // P2#8-parte: el filtro de protegidos va AQUÍ, en el
    // diálogo de envío, no dentro de buscarClientes (que es
    // compartida). El diálogo muestra además el teléfono, así
    // que un protegido no debe llegar a esta lista.
    final sinProtegidos =
        widget.todos.where((c) => !esVistaProtegida(c)).toList();
    final visibles = q.isEmpty
        ? sinProtegidos
        : sinProtegidos
            .where((c) =>
                '${c['nombre'] ?? ''}'.toLowerCase().contains(q))
            .toList();
    return DialogoApp(
      titulo: 'Elegir cliente',
      iconoTitulo: Icons.person_rounded,
      contenido: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: Column(
          children: [
            TextField(
              controller: _filtro,
              decoration: const InputDecoration(
                  hintText: 'Filtrar por nombre',
                  border: OutlineInputBorder()),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  for (final c in visibles)
                    ListTile(
                      dense: true,
                      title: Text('${c['nombre'] ?? ''}'),
                      // 1.32 (Yunque, Y-2): el subtítulo enseña
                      // el teléfono EFECTIVO (al que saldrá el
                      // mensaje), no el campo crudo — en los
                      // migrados el crudo trae el carnet
                      // (regla FB-01) y el selector mentía.
                      subtitle: Text(telefonoEfectivoLocal(c)),
                      onTap: () => Navigator.pop(context, c),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancelar')),
      ],
    );
  }
}
