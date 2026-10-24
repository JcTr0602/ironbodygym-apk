import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../etiqueta_producto.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtMonto;
import '../servicios.dart';
import '../sync.dart';
import 'componentes.dart';
import 'diseno.dart';

/// v1.8.0: Administración de Servicios por dosis (SOLO DUEÑO):
/// precios y comisión, stock común de agua (CPP), botes y lotes.
/// Todas las acciones encolan su op; el servidor re-impone los
/// permisos (estas ops son solo-admin en el candado).
class ServiciosAdminScreen extends StatefulWidget {
  const ServiciosAdminScreen({super.key});

  @override
  State<ServiciosAdminScreen> createState() =>
      _ServiciosAdminScreenState();
}

class _ServiciosAdminScreenState extends State<ServiciosAdminScreen> {
  bool _cargando = true;
  ({double sinAgua, double conAgua, double agua, double comision})?
      _precios;
  ({int saldo, double cpp}) _agua = (saldo: 0, cpp: 0);
  List<Map<String, dynamic>> _botes = [];
  List<Map<String, dynamic>> _lotes = [];
  List<Map<String, dynamic>> _suplementos = [];
  Map<int, String> _categorias = {};
  Map<int, String> _personas = {}; // telegram_id → nombre
  // Ítem 7: un controlador por clave precio_<producto>_<método> y el
  // estado de cada interruptor activo_<producto>_<método>.
  static const _stemsPrecio = ['racion', 'combo', 'agua'];
  final _precioCtrl = <String, TextEditingController>{
    for (final s in _stemsPrecio)
      for (final m in const ['efectivo', 'transferencia'])
        '${s}_$m': TextEditingController(),
  };
  final _activoMet = <String, bool>{
    for (final s in _stemsPrecio)
      for (final m in const ['efectivo', 'transferencia'])
        '${s}_$m': true,
  };
  final _comisionCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    for (final c in _precioCtrl.values) {
      c.dispose();
    }
    _comisionCtrl.dispose();
    super.dispose();
  }

  /// Ítem 13: «Nombre · Categoría» en toda identificación de producto
  /// de esta pantalla (selector de Abrir bote, botes y lotes).
  String _nombreSup(int? id) {
    for (final s in _suplementos) {
      if ((s['id'] as num?)?.toInt() == id) {
        return etiquetaDeSuplemento(s, _categorias);
      }
    }
    return 'Suplemento #$id';
  }

  String _nombrePersona(int? id) =>
      _personas[id] ?? 'Persona #$id';

  Future<void> _cargar() async {
    final precios = await preciosServicios();
    final ajustes = await LocalDb.instance.getAjustes();
    final agua = await stockAguaLocal();
    final botes = await LocalDb.instance.allMirror('servicio_botes');
    final lotes = await LocalDb.instance.allMirror('servicio_lotes');
    final suplementos =
        await LocalDb.instance.allMirror('suplementos');
    final categorias =
        await LocalDb.instance.allMirror('categorias_suplemento');
    // Personas conocidas (para responsables y nombres): el dueño +
    // quien haya registrado pagos o ventas de suplementos.
    final personas = <int, String>{};
    final miTid = AuthService().telegramId;
    if (miTid != null) personas[miTid] = 'Yo (dueño)';
    for (final p in await LocalDb.instance.allMirror('pagos')) {
      final tid = LocalDb.normalizarTelegramId(p['telegram_user_id']);
      final nombre = '${p['registrado_por'] ?? ''}';
      if (tid != null && nombre.isNotEmpty) {
        personas.putIfAbsent(tid, () => nombre);
      }
    }
    for (final v
        in await LocalDb.instance.allMirror('ventas_suplementos')) {
      final tid = LocalDb.normalizarTelegramId(v['registrado_por']);
      if (tid != null) personas.putIfAbsent(tid, () => 'Entrenador');
    }
    for (final l in lotes) {
      final saldo = await saldoLoteLocal((l['id'] as num).toInt());
      l['saldo_local'] = saldo;
    }
    if (!mounted) return;
    setState(() {
      _precios = precios;
      _agua = agua;
      _botes = botes;
      _lotes = lotes;
      _suplementos = suplementos;
      _categorias = mapaCategoriasSuplemento(categorias);
      _personas = personas;
      // Ítem 7: los campos nacen con los valores RESUELTOS vigentes
      // (lo que publica el servidor), no con claves sueltas.
      for (final s in _stemsPrecio) {
        final tipo = s == 'racion'
            ? 'dosis_sin_agua'
            : s == 'combo'
                ? 'dosis_con_agua'
                : 'agua_suelta';
        for (final m in const ['efectivo', 'transferencia']) {
          _precioCtrl['${s}_$m']!.text =
              precioServicioMetodo(ajustes, tipo, m).toStringAsFixed(0);
          _activoMet['${s}_$m'] = metodoServicioActivo(ajustes, tipo, m);
        }
      }
      _comisionCtrl.text = precios.comision.toStringAsFixed(0);
      _cargando = false;
    });
  }

  void _aviso(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppColores.error : null,
    ));
  }

  String _limpio(Object e) =>
      e.toString().replaceFirst('Exception: ', '');

  // ---------------------------------------------------------------
  // Precios
  // ---------------------------------------------------------------

  String _tipoDeStem(String stem) => stem == 'racion'
      ? 'dosis_sin_agua'
      : stem == 'combo'
          ? 'dosis_con_agua'
          : 'agua_suelta';

  Future<void> _guardarPrecios() async {
    // Ítem 7: se guardan las claves por (producto, método) que hayan
    // cambiado contra lo VIGENTE resuelto, más la comisión.
    final ajustes = await LocalDb.instance.getAjustes();
    final cambios = <String, num>{};
    for (final s in _stemsPrecio) {
      final tipo = _tipoDeStem(s);
      for (final m in const ['efectivo', 'transferencia']) {
        final valor = double.tryParse(
                _precioCtrl['${s}_$m']!.text.trim().replaceAll(',', '.')) ??
            -1;
        // Las dosis deben costar más de 0; el agua admite 0 (sin
        // fijar) y la comisión también.
        if (s == 'agua' ? valor < 0 : valor <= 0) {
          _aviso('Revisa los valores: las dosis deben costar más de 0',
              error: true);
          return;
        }
        if (valor != precioServicioMetodo(ajustes, tipo, m)) {
          cambios['servicio_precio_${s}_$m'] = valor;
        }
        final activo = _activoMet['${s}_$m']! ? 1 : 0;
        if (activo != (metodoServicioActivo(ajustes, tipo, m) ? 1 : 0)) {
          cambios['servicio_activo_${s}_$m'] = activo;
        }
      }
    }
    final comision = double.tryParse(
            _comisionCtrl.text.trim().replaceAll(',', '.')) ??
        -1;
    if (comision < 0) {
      _aviso('Revisa la comisión', error: true);
      return;
    }
    final pr = _precios;
    if (pr != null && comision != pr.comision) {
      cambios['servicio_comision_dosis'] = comision;
    }
    // Compatibilidad: el precio único legacy de cada producto sigue
    // al de EFECTIVO, para las versiones viejas aún instaladas.
    const legacyDe = {
      'racion': 'servicio_precio_sin_agua',
      'combo': 'servicio_precio_con_agua',
      'agua': 'servicio_precio_agua',
    };
    for (final s in _stemsPrecio) {
      final ef = cambios['servicio_precio_${s}_efectivo'];
      if (ef != null &&
          ef.toDouble() !=
              (ajustes[legacyDe[s]] as num?)?.toDouble()) {
        cambios[legacyDe[s]!] = ef;
      }
    }
    if (cambios.isEmpty) {
      _aviso('Sin cambios');
      return;
    }
    for (final e in cambios.entries) {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': e.key, 'valor': e.value},
      );
    }
    // Actualización optimista del espejo local de ajustes (patrón
    // de AdminScreen): claves sueltas Y la estructura resuelta que
    // leen los formularios, para que el cambio se vea sin esperar
    // al próximo pull.
    final aj = await LocalDb.instance.getAjustes();
    for (final e in cambios.entries) {
      aj[e.key] = e.value;
    }
    final pub = aj['servicio_precios_metodo'];
    if (pub is Map) {
      for (final e in cambios.entries) {
        final partes = e.key.split('_');
        if (partes.length == 4 && partes[0] == 'servicio') {
          final prod = pub[partes[2]];
          if (prod is Map) {
            prod[partes[1] == 'precio'
                ? partes[3]
                : 'activo_${partes[3]}'] = e.value;
          }
        }
      }
    }
    await LocalDb.instance.setAjustes(aj);
    SyncEngine.instance.push();
    _aviso('Precios guardados (se sincronizarán)');
    await _cargar();
  }

  // ---------------------------------------------------------------
  // Agua
  // ---------------------------------------------------------------

  Future<void> _reponerAgua() async {
    final cantCtrl = TextEditingController();
    final costoCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Reponer agua',
        iconoTitulo: Icons.water_drop,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: cantCtrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Pomos que entraron'),
            ),
            TextField(
              controller: costoCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                  labelText: 'Costo por pomo (CUP)'),
            ),
            const SizedBox(height: 8),
            const Text(
              'El costo alimenta el costo promedio (CPP) con el que '
              'se valoriza cada venta con agua.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Registrar entrada'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await reponerAguaServicio(
        cantidad: int.tryParse(cantCtrl.text.trim()) ?? 0,
        costoUnitario:
            double.tryParse(costoCtrl.text.trim().replaceAll(',', '.')) ??
                0,
      );
      _aviso('Entrada de agua registrada');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  /// Ítem 11: salida sin venta del stock común de agua (solo el
  /// dueño la ve; el servidor la exige). Para pomos rotos, regalados
  /// o consumidos sin pasar por una venta.
  Future<void> _salidaAgua() async {
    var motivo = 'merma';
    final cantCtrl = TextEditingController(text: '1');
    final notaCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => DialogoApp(
          titulo: 'Salida de agua sin venta',
          iconoTitulo: Icons.water_drop_outlined,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Stock actual: ${_agua.saldo} pomos. La salida queda '
                'registrada con su motivo y descuenta del inventario.',
                style: AppTexto.secundario,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: motivo,
                decoration:
                    const InputDecoration(labelText: 'Motivo'),
                items: const [
                  DropdownMenuItem(
                      value: 'merma', child: Text('Merma / rotura')),
                  DropdownMenuItem(
                      value: 'cortesia', child: Text('Cortesía')),
                  DropdownMenuItem(
                      value: 'consumo_staff',
                      child: Text('Consumo del staff')),
                  DropdownMenuItem(
                      value: 'ajuste', child: Text('Ajuste')),
                ],
                onChanged: (v) => setD(() => motivo = v ?? 'merma'),
              ),
              TextField(
                controller: cantCtrl,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Pomos'),
              ),
              TextField(
                controller: notaCtrl,
                decoration: const InputDecoration(
                    labelText: 'Nota (opcional)'),
              ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Registrar salida'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await registrarSalidaAguaServicio(
        cantidad: int.tryParse(cantCtrl.text.trim()) ?? 0,
        motivo: motivo,
        nota: notaCtrl.text.trim().isEmpty ? null : notaCtrl.text.trim(),
      );
      _aviso('Salida de agua registrada');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  // ---------------------------------------------------------------
  // Botes y lotes
  // ---------------------------------------------------------------

  Future<void> _abrirBote() async {
    if (_suplementos.isEmpty) {
      _aviso('No hay suplementos en el catálogo', error: true);
      return;
    }
    var supId = (_suplementos.first['id'] as num).toInt();
    final rendCtrl = TextEditingController(text: '30');
    final costoCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => DialogoApp(
          titulo: 'Abrir bote de servicio',
          iconoTitulo: Icons.science,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<int>(
                value: supId,
                decoration:
                    const InputDecoration(labelText: 'Producto'),
                items: [
                  for (final s in _suplementos)
                    DropdownMenuItem(
                      value: (s['id'] as num).toInt(),
                      child: Text(etiquetaDeSuplemento(s, _categorias)),
                    ),
                ],
                onChanged: (v) => setD(() => supId = v ?? supId),
              ),
              TextField(
                controller: rendCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Rendimiento (dosis del bote)'),
              ),
              TextField(
                controller: costoCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: const InputDecoration(
                    labelText:
                        'Costo del bote (CUP, opcional si el producto ya tiene costo)'),
              ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Abrir bote'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      final costo =
          double.tryParse(costoCtrl.text.trim().replaceAll(',', '.'));
      await abrirBoteServicio(
        suplementoId: supId,
        dosisRendimiento: int.tryParse(rendCtrl.text.trim()) ?? 0,
        costoBote: (costo != null && costo > 0) ? costo : null,
      );
      _aviso('Bote abierto (se sincronizará)');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  Future<void> _crearLote(Map<String, dynamic> bote) async {
    final boteId = (bote['id'] as num).toInt();
    final sinRepartir = await sinRepartirLocal(boteId);
    if (!mounted) return;
    if (sinRepartir <= 0) {
      _aviso('Este bote ya está repartido completo', error: true);
      return;
    }
    var responsable = _personas.keys.first;
    final dosisCtrl =
        TextEditingController(text: '$sinRepartir');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => DialogoApp(
          titulo: 'Crear lote · ${_nombreSup((bote['suplemento_id'] as num?)?.toInt())}',
          iconoTitulo: Icons.local_drink,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Sin repartir: $sinRepartir dosis',
                  style: AppTexto.cuerpo),
              DropdownButtonFormField<int>(
                value: responsable,
                decoration:
                    const InputDecoration(labelText: 'Responsable'),
                items: [
                  for (final e in _personas.entries)
                    DropdownMenuItem(
                        value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) =>
                    setD(() => responsable = v ?? responsable),
              ),
              TextField(
                controller: dosisCtrl,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Dosis del lote'),
              ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Crear lote'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      final miTid = AuthService().telegramId;
      await crearLoteServicio(
        boteId: boteId,
        dosis: int.tryParse(dosisCtrl.text.trim()) ?? 0,
        responsableTipo:
            responsable == miTid ? 'dueno' : 'entrenador',
        responsableId: responsable,
      );
      _aviso('Lote creado (se sincronizará)');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  Future<void> _cerrarLote(Map<String, dynamic> lote) async {
    final conteoCtrl = TextEditingController(
        text: '${lote['saldo_local'] ?? 0}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Cerrar lote',
        iconoTitulo: Icons.lock,
        contenido: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Saldo según el sistema: ${lote['saldo_local']} dosis. '
              'Cuenta el pomo físico y escribe lo que hay de verdad: '
              'la diferencia queda registrada y lo que sobre vuelve '
              'a «sin repartir» del bote.',
              style: AppTexto.cuerpo,
            ),
            TextField(
              controller: conteoCtrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                  labelText: 'Conteo físico (dosis que quedan)'),
            ),
          ],
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cerrar lote'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await cerrarLoteServicio(
        loteId: (lote['id'] as num).toInt(),
        conteoFisico: int.tryParse(conteoCtrl.text.trim()) ?? -1,
      );
      _aviso('Cierre registrado (se sincronizará)');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  Future<void> _cerrarBote(Map<String, dynamic> bote) async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cerrar bote',
      mensaje:
          'Se sella el bote y se registra su diferencia de '
          'rendimiento. Los lotes activos de este bote deben estar '
          'cerrados.',
      aceptar: 'Cerrar bote',
      icono: Icons.lock,
    );
    if (ok != true) return;
    try {
      await cerrarBoteServicio(boteId: (bote['id'] as num).toInt());
      _aviso('Cierre de bote registrado (se sincronizará)');
      await _cargar();
    } catch (e) {
      _aviso(_limpio(e), error: true);
    }
  }

  // ---------------------------------------------------------------
  // Vista
  // ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: AppBar(title: const Text('Servicios · Admin')),
        body: const Center(
            child: Text('Solo el dueño administra los servicios.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Servicios · Admin'),
        actions: [
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                _seccionPrecios(),
                const SizedBox(height: AppEspacio.md),
                _seccionAgua(),
                const SizedBox(height: AppEspacio.md),
                _seccionBotes(),
                const SizedBox(height: AppEspacio.md),
                _seccionLotes(),
              ],
            ),
    );
  }

  Widget _seccionPrecios() {
    Widget campo(String etiqueta, TextEditingController ctrl) =>
        Expanded(
          child: TextField(
            controller: ctrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: etiqueta),
          ),
        );
    Widget interruptor(String stem, String metodo, String etiqueta) =>
        Expanded(
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(etiqueta, style: AppTexto.cuerpo),
            value: _activoMet['${stem}_$metodo']!,
            onChanged: (v) =>
                setState(() => _activoMet['${stem}_$metodo'] = v),
          ),
        );
    Widget bloque(String titulo, String stem) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titulo,
                style:
                    AppTexto.cuerpo.copyWith(fontWeight: FontWeight.w600)),
            Row(children: [
              campo('Efectivo (CUP)', _precioCtrl['${stem}_efectivo']!),
              const SizedBox(width: AppEspacio.sm),
              campo('Transferencia (CUP)',
                  _precioCtrl['${stem}_transferencia']!),
            ]),
            Row(children: [
              interruptor(stem, 'efectivo', 'Cobrar en efectivo'),
              interruptor(
                  stem, 'transferencia', 'Cobrar por transferencia'),
            ]),
            const SizedBox(height: 4),
          ],
        );
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Precios y comisión',
              style: AppTexto.titulo.copyWith(fontSize: 16)),
          const SizedBox(height: 8),
          // Ítem 7: precio y métodos habilitados POR PRODUCTO.
          bloque('Ración (dosis sin agua)', 'racion'),
          bloque('Combo (dosis con agua)', 'combo'),
          bloque('Pomo de agua suelto', 'agua'),
          Row(children: [
            campo('Comisión por dosis (CUP)', _comisionCtrl),
            const Expanded(child: SizedBox()),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Agua en 0 = precio sin fijar (no se puede vender suelta). '
            'Comisión en 0 = sin comisión. La comisión se paga con la '
            'nómina del mes. Apagar ambos métodos de un producto lo '
            'deja invendible (la Cuenta a la Casa no se afecta).',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              onPressed: _guardarPrecios,
              child: const Text('Guardar precios'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _seccionAgua() {
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Row(
        children: [
          const IconoModuloBadge(
            icono: Icons.water_drop,
            tinte: Colors.blue,
            iconoOscuro: Color(0xFF60A5FA),
            iconoClaro: Color(0xFF2563EB),
          ),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Agua común',
                    style: AppTexto.titulo.copyWith(fontSize: 16)),
                Text(
                  'Stock: ${_agua.saldo} pomos · Costo promedio: '
                  '${fmtMonto(_agua.cpp)} CUP/pomo',
                  style: AppTexto.cuerpo,
                ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton(
                onPressed: _reponerAgua,
                child: const Text('Reponer'),
              ),
              const SizedBox(height: 6),
              OutlinedButton(
                onPressed: _salidaAgua,
                child: const Text('Salida sin venta'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _seccionBotes() {
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Botes',
                    style: AppTexto.titulo.copyWith(fontSize: 16)),
              ),
              FilledButton.icon(
                onPressed: _abrirBote,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Abrir bote'),
              ),
            ],
          ),
          if (_botes.isEmpty)
            Text('Sin botes abiertos todavía.',
                style: AppTexto.cuerpo.copyWith(
                    color: AppColores.textoSecundario(context)))
          else
            for (final b in _botes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_nombreSup(
                    (b['suplemento_id'] as num?)?.toInt())),
                subtitle: Text(
                  'Rendimiento: ${b['dosis_rendimiento']} dosis · '
                  'Costo: ${fmtMonto(b['costo_bote'])} CUP · '
                  'Estado: ${b['estado']}'
                  '${b['diferencia_rendimiento_bote'] != null ? ' · Diferencia: ${b['diferencia_rendimiento_bote']}' : ''}',
                ),
                trailing: '${b['estado']}' == 'abierto'
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => _crearLote(b),
                            child: const Text('Crear lote'),
                          ),
                          IconButton(
                            tooltip: 'Cerrar bote',
                            icon: const Icon(Icons.lock, size: 20),
                            onPressed: () => _cerrarBote(b),
                          ),
                        ],
                      )
                    : null,
              ),
        ],
      ),
    );
  }

  Widget _seccionLotes() {
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Lotes',
              style: AppTexto.titulo.copyWith(fontSize: 16)),
          if (_lotes.isEmpty)
            Text('Sin lotes creados.',
                style: AppTexto.cuerpo.copyWith(
                    color: AppColores.textoSecundario(context)))
          else
            for (final l in _lotes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  '${l['estado']}' == 'activo'
                      ? Icons.local_drink
                      : Icons.lock,
                  color: '${l['estado']}' == 'activo'
                      ? AppColores.naranja
                      : Colors.grey,
                ),
                title: Text(
                    '${_nombreSup(_supDeBote((l['bote_id'] as num?)?.toInt()))} '
                    '· ${_nombrePersona((l['responsable_id'] as num?)?.toInt())}'),
                subtitle: Text(
                  '${l['estado']} · Saldo: ${l['saldo_local'] ?? '—'} '
                  'de ${l['dosis_iniciales']} dosis'
                  '${l['conteo_cierre'] != null ? ' · Conteo cierre: ${l['conteo_cierre']}' : ''}',
                ),
                trailing: '${l['estado']}' == 'activo'
                    ? TextButton(
                        onPressed: () => _cerrarLote(l),
                        child: const Text('Cerrar'),
                      )
                    : null,
              ),
        ],
      ),
    );
  }

  int? _supDeBote(int? boteId) {
    for (final b in _botes) {
      if ((b['id'] as num?)?.toInt() == boteId) {
        return (b['suplemento_id'] as num?)?.toInt();
      }
    }
    return null;
  }
}
