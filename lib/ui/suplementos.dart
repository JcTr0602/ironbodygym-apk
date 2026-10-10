// Catálogo de suplementos ("Inventario en Gimnasio").
//
// - Entrenador: catálogo de solo lectura + botón Vender por producto.
// - Dueño: además gestiona el catálogo (nuevo/editar/activar),
//   el interruptor de la promo "mes gratis" y el historial de ventas.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'historial_ventas.dart';
import 'venta_suplemento.dart';
import 'widgets.dart';

class SuplementosScreen extends StatefulWidget {
  const SuplementosScreen({super.key});

  @override
  State<SuplementosScreen> createState() => _SuplementosScreenState();
}

class _SuplementosScreenState extends State<SuplementosScreen> {
  final _auth = AuthService();
  List<Map<String, dynamic>> _items = [];
  bool _cargando = true;
  String _busqueda = '';
  bool _promoActiva = true;

  bool get _esDueno => _auth.isOwner;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final items = await LocalDb.instance.allMirror('suplementos');
    final aj = await LocalDb.instance.getAjustes();
    if (!mounted) return;
    setState(() {
      _items = items
          .where((s) => _esDueno || (s['activo'] as int?) == 1)
          .toList();
      _promoActiva = (aj['promo_suplementos'] as num?)?.toInt() != 0;
      _cargando = false;
    });
  }

  List<Map<String, dynamic>> get _filtrados {
    if (_busqueda.isEmpty) return _items;
    final q = _busqueda.toLowerCase();
    return _items
        .where((s) => '${s['nombre'] ?? ''}'.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _togglePromo(bool v) async {
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'ajuste',
      payload: {'clave': 'promo_suplementos', 'valor': v ? 1 : 0},
    );
    // Optimista: reflejar de inmediato en ajustes locales.
    final aj = await LocalDb.instance.getAjustes();
    aj['promo_suplementos'] = v ? 1 : 0;
    await LocalDb.instance.setAjustes(aj);
    unawaited(SyncEngine.instance.push());
    if (mounted) setState(() => _promoActiva = v);
  }

  void _irVender(Map<String, dynamic> s) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VentaSuplementoScreen(suplemento: s),
      ),
    ).then((_) => _cargar());
  }

  void _irEditar(Map<String, dynamic>? s) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditarSuplementoScreen(suplemento: s),
      ),
    ).then((_) => _cargar());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Suplementos'),
        actions: [
          if (_esDueno)
            IconButton(
              icon: const Icon(Icons.receipt_long),
              tooltip: 'Historial de ventas',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const HistorialVentasScreen()),
              ),
            ),
        ],
      ),
      floatingActionButton: _esDueno
          ? FloatingActionButton.extended(
              onPressed: () => _irEditar(null),
              icon: const Icon(Icons.add),
              label: const Text('Nuevo'),
            )
          : null,
      body: Column(
        children: [
          const SyncBanner(compact: true),
          if (_esDueno) _tarjetaPromo(),
          Padding(
            padding: const EdgeInsets.all(AppEspacio.md),
            child: CampoTexto(
              hint: 'Buscar suplemento…',
              icono: Icons.search,
              onChanged: (v) =>
                  setState(() => _busqueda = v.trim()),
            ),
          ),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _tarjetaPromo() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppEspacio.md, AppEspacio.sm, AppEspacio.md, 0),
      child: Tarjeta(
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.lg, vertical: AppEspacio.sm),
        child: Row(
          children: [
            const Icon(Icons.card_giftcard,
                color: AppColores.naranja),
            const SizedBox(width: AppEspacio.sm),
            const Expanded(
              child: Text('Promo: 1 mes gratis por compra',
                  style: AppTexto.cuerpo),
            ),
            Switch(
              value: _promoActiva,
              activeThumbColor: AppColores.naranja,
              onChanged: _togglePromo,
            ),
          ],
        ),
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _filtrados;
    if (items.isEmpty) {
      return EstadoVacio(
        icono: Icons.medication_outlined,
        titulo: 'Sin suplementos',
        subtitulo: _esDueno
            ? 'Agrega el primero con el botón Nuevo.'
            : 'Aún no hay productos en el inventario.',
      );
    }
    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(
            AppEspacio.md, AppEspacio.sm, AppEspacio.md, 96),
        itemCount: items.length,
        itemBuilder: (ctx, i) => _tarjetaProducto(items[i]),
      ),
    );
  }

  Widget _tarjetaProducto(Map<String, dynamic> s) {
    final stock = (s['stock'] as num?)?.toInt() ?? 0;
    final precio = (s['precio_oficial'] as num?)?.toDouble() ?? 0;
    final foto = s['foto_storage'] as String?;
    final inactivo = (s['activo'] as int?) != 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.md),
        child: Row(
          children: [
            _fotoProducto(foto),
            const SizedBox(width: AppEspacio.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${s['nombre'] ?? 'Sin nombre'}',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 2),
                  Text(
                    '${precio.toStringAsFixed(2)} USD · $stock disp.',
                    style: AppTexto.secundario,
                  ),
                  if (inactivo)
                    ChipEstado(
                        texto: 'Inactivo',
                        color:
                            AppColores.textoSecundario(context)),
                ],
              ),
            ),
            if (_esDueno)
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Editar',
                onPressed: () => _irEditar(s),
              )
            else
              BotonPrimario(
                texto: 'Vender',
                onPressed: stock > 0 ? () => _irVender(s) : null,
              ),
          ],
        ),
      ),
    );
  }

  Widget _fotoProducto(String? storagePath) {
    const tam = 56.0;
    Widget placeholder() => Container(
          width: tam,
          height: tam,
          decoration: BoxDecoration(
            color: AppColores.fondo(context),
            borderRadius:
                BorderRadius.circular(AppRadio.md),
          ),
          child: const Icon(Icons.medication_outlined,
              color: AppColores.naranja),
        );
    if (storagePath == null || storagePath.isEmpty) {
      return placeholder();
    }
    return FutureBuilder(
      future: FotoCache.instance.obtener(storagePath),
      builder: (ctx, snap) {
        final f = snap.data;
        if (f == null) return placeholder();
        return ClipRRect(
          borderRadius:
              BorderRadius.circular(AppRadio.md),
          child: Image.file(f,
              width: tam, height: tam, fit: BoxFit.cover),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Crear / editar suplemento (solo dueño)
// ---------------------------------------------------------------------------

class EditarSuplementoScreen extends StatefulWidget {
  final Map<String, dynamic>? suplemento;
  const EditarSuplementoScreen({super.key, this.suplemento});

  @override
  State<EditarSuplementoScreen> createState() =>
      _EditarSuplementoScreenState();
}

class _EditarSuplementoScreenState
    extends State<EditarSuplementoScreen> {
  final _nombre = TextEditingController();
  final _desc = TextEditingController();
  final _precio = TextEditingController();
  final _stock = TextEditingController();
  bool _activo = true;
  bool _guardando = false;
  Uint8List? _fotoNueva;
  bool _subiendoFoto = false;

  bool get _editando => widget.suplemento != null;

  @override
  void initState() {
    super.initState();
    final s = widget.suplemento;
    if (s != null) {
      _nombre.text = '${s['nombre'] ?? ''}';
      _desc.text = '${s['descripcion'] ?? ''}';
      _precio.text = '${s['precio_oficial'] ?? ''}';
      _stock.text = '${s['stock'] ?? 0}';
      _activo = (s['activo'] as int?) == 1;
    }
  }

  @override
  void dispose() {
    _nombre.dispose();
    _desc.dispose();
    _precio.dispose();
    _stock.dispose();
    super.dispose();
  }

  Future<void> _elegirFoto() async {
    final img = await ImagePicker().pickImage(
        source: ImageSource.gallery, maxWidth: 1024, imageQuality: 80);
    if (img == null || !mounted) return;
    final bytes = await img.readAsBytes();
    if (mounted) setState(() => _fotoNueva = bytes);
  }

  Future<void> _guardar() async {
    final nombre = _nombre.text.trim();
    final precio = double.tryParse(
        _precio.text.trim().replaceAll(',', '.'));
    final stock =
        int.tryParse(_stock.text.trim()) ?? 0;
    if (nombre.isEmpty || precio == null || precio <= 0) {
      await DialogoApp.confirmar(context,
          titulo: 'Revisa los datos',
          mensaje:
              'El nombre y un precio oficial mayor que 0 son obligatorios.',
          aceptar: 'Entendido',
          cancelar: '');
      return;
    }
    setState(() => _guardando = true);
    try {
      final payload = {
        'nombre': nombre,
        'descripcion': _desc.text.trim(),
        'precio_oficial': precio,
        'stock': stock,
        'activo': _activo ? 1 : 0,
        if (_editando) 'suplemento_id': widget.suplemento!['id'],
      };
      if (_editando) {
        await LocalDb.instance.queueOp(
          opUuid: const Uuid().v4(),
          tipo: 'editar_suplemento',
          payload: payload,
        );
      } else {
        await LocalDb.instance.queueOp(
          opUuid: const Uuid().v4(),
          tipo: 'crear_suplemento',
          payload: payload,
        );
      }
      // Foto (solo al editar: el id lo asigna el servidor al crear).
      if (_editando && _fotoNueva != null) {
        setState(() => _subiendoFoto = true);
        final opUuid = const Uuid().v4();
        final path = await SyncEngine.instance
            .subirFotoSuplemento(opUuid, _fotoNueva!);
        if (path != null) {
          await LocalDb.instance.queueOp(
            opUuid: const Uuid().v4(),
            tipo: 'foto_suplemento',
            payload: {
              'suplemento_id': widget.suplemento!['id'],
              'storage_path': path,
            },
          );
        }
        if (mounted) setState(() => _subiendoFoto = false);
      }
      unawaited(SyncEngine.instance.push());
      if (mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(
              _editando ? 'Editar suplemento' : 'Nuevo suplemento')),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          const SyncBanner(compact: true),
          const SizedBox(height: AppEspacio.md),
          Center(
            child: GestureDetector(
              onTap: _editando && !_subiendoFoto ? _elegirFoto : null,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: AppColores.fondo(context),
                  borderRadius:
                      BorderRadius.circular(AppRadio.lg),
                  border: Border.all(
                      color: AppColores.borde(context)),
                ),
                child: _subiendoFoto
                    ? const Center(
                        child: CircularProgressIndicator())
                    : _fotoNueva != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(
                                AppRadio.lg),
                            child: Image.memory(_fotoNueva!,
                                fit: BoxFit.cover),
                          )
                        : Column(
                            mainAxisAlignment:
                                MainAxisAlignment.center,
                            children: [
                              const Icon(
                                  Icons.add_a_photo_outlined,
                                  color: AppColores.naranja),
                              if (!_editando)
                                const Text('Foto al editar',
                                    style:
                                        AppTexto.minuscula),
                            ],
                          ),
              ),
            ),
          ),
          const SizedBox(height: AppEspacio.md),
          CampoTexto(
              controller: _nombre,
              etiqueta: 'Nombre',
              hint: 'Ej. Creatina Monohidrato 500g'),
          const SizedBox(height: AppEspacio.md),
          CampoTexto(
              controller: _desc,
              etiqueta: 'Descripción (opcional)',
              maxLineas: 2),
          const SizedBox(height: AppEspacio.md),
          Row(
            children: [
              Expanded(
                child: CampoTexto(
                    controller: _precio,
                    etiqueta: 'Precio oficial (USD)',
                    teclado:
                        const TextInputType.numberWithOptions(
                            decimal: true)),
              ),
              const SizedBox(width: AppEspacio.md),
              Expanded(
                child: CampoTexto(
                    controller: _stock,
                    etiqueta: 'Stock',
                    teclado: TextInputType.number),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          SwitchListTile(
            value: _activo,
            activeThumbColor: AppColores.naranja,
            title:
                const Text('Activo en catálogo', style: AppTexto.cuerpo),
            onChanged: (v) => setState(() => _activo = v),
          ),
          const SizedBox(height: AppEspacio.lg),
          BotonPrimario(
            texto: _guardando
                ? 'Guardando…'
                : (_editando ? 'Guardar cambios' : 'Crear suplemento'),
            onPressed: _guardando ? null : _guardar,
          ),
        ],
      ),
    );
  }
}
