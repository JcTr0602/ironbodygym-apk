import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
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
  Map<int, String> _personas = {}; // telegram_id → nombre
  final _sinAguaCtrl = TextEditingController();
  final _conAguaCtrl = TextEditingController();
  final _aguaCtrl = TextEditingController();
  final _comisionCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _sinAguaCtrl.dispose();
    _conAguaCtrl.dispose();
    _aguaCtrl.dispose();
    _comisionCtrl.dispose();
    super.dispose();
  }

  String _nombreSup(int? id) {
    for (final s in _suplementos) {
      if ((s['id'] as num?)?.toInt() == id) return '${s['nombre'] ?? ''}';
    }
    return 'Suplemento #$id';
  }

  String _nombrePersona(int? id) =>
      _personas[id] ?? 'Persona #$id';

  Future<void> _cargar() async {
    final precios = await preciosServicios();
    final agua = await stockAguaLocal();
    final botes = await LocalDb.instance.allMirror('servicio_botes');
    final lotes = await LocalDb.instance.allMirror('servicio_lotes');
    final suplementos =
        await LocalDb.instance.allMirror('suplementos');
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
      _personas = personas;
      _sinAguaCtrl.text = precios.sinAgua.toStringAsFixed(0);
      _conAguaCtrl.text = precios.conAgua.toStringAsFixed(0);
      _aguaCtrl.text = precios.agua.toStringAsFixed(0);
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

  Future<void> _guardarPrecios() async {
    final pr = _precios;
    if (pr == null) return;
    final nuevos = <String, double>{
      'servicio_precio_sin_agua':
          double.tryParse(_sinAguaCtrl.text.trim()) ?? -1,
      'servicio_precio_con_agua':
          double.tryParse(_conAguaCtrl.text.trim()) ?? -1,
      'servicio_precio_agua':
          double.tryParse(_aguaCtrl.text.trim()) ?? -1,
      'servicio_comision_dosis':
          double.tryParse(_comisionCtrl.text.trim()) ?? -1,
    };
    final actuales = <String, double>{
      'servicio_precio_sin_agua': pr.sinAgua,
      'servicio_precio_con_agua': pr.conAgua,
      'servicio_precio_agua': pr.agua,
      'servicio_comision_dosis': pr.comision,
    };
    // Precios de dosis: > 0. Agua y comisión admiten 0.
    if (nuevos['servicio_precio_sin_agua']! <= 0 ||
        nuevos['servicio_precio_con_agua']! <= 0 ||
        nuevos['servicio_precio_agua']! < 0 ||
        nuevos['servicio_comision_dosis']! < 0) {
      _aviso('Revisa los valores: las dosis deben costar más de 0',
          error: true);
      return;
    }
    final cambios = <String, double>{
      for (final e in nuevos.entries)
        if (e.value != actuales[e.key]) e.key: e.value,
    };
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
    // de AdminScreen).
    final aj = await LocalDb.instance.getAjustes();
    for (final e in cambios.entries) {
      aj[e.key] = e.value;
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
                      child: Text('${s['nombre']}'),
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
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Precios y comisión',
              style: AppTexto.titulo.copyWith(fontSize: 16)),
          const SizedBox(height: 8),
          Row(children: [
            campo('Dosis sin agua (CUP)', _sinAguaCtrl),
            const SizedBox(width: AppEspacio.sm),
            campo('Dosis con agua (CUP)', _conAguaCtrl),
          ]),
          Row(children: [
            campo('Pomo de agua (CUP)', _aguaCtrl),
            const SizedBox(width: AppEspacio.sm),
            campo('Comisión por dosis (CUP)', _comisionCtrl),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Agua en 0 = precio sin fijar (no se puede vender suelta). '
            'Comisión en 0 = sin comisión. La comisión se paga con la '
            'nómina del mes.',
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
          FilledButton(
            onPressed: _reponerAgua,
            child: const Text('Reponer'),
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
