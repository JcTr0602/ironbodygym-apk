/// Pantalla D1 (todas las tarifas) y modal D6 (tarifas especiales).
///
/// Bloque 2 NÚCLEO, 1.10.0, Argón AMARILLO ajustes 1 y 3.
///
/// - D1: precios estándar + especiales activas, en un solo sitio.
/// - D6: otorgar / editar / revocar. El formulario pre-carga el valor
///   que ya tenía el otro método (ajuste 1): lo que se ve es lo que
///   queda; vaciar un método lo deja en null para ese método.
/// - Multi-cliente (Administración): el selector es solo visual; al
///   guardar se crea UNA fila por cliente (ajuste 1). Si algún método
///   pasaría de tener valor a null para algún cliente, se pide
///   confirmación listando los afectados.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tarifa_especial.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import '../app_log.dart';

/// D1: todas las tarifas en una pantalla (estándar + especiales).
class TarifasScreen extends StatefulWidget {
  const TarifasScreen({super.key});
  @override
  State<TarifasScreen> createState() => _TarifasScreenState();
}

class _TarifasScreenState extends State<TarifasScreen> {
  var _cargando = true;
  Map<String, double> _precios = {};
  List<Map<String, dynamic>> _especiales = [];
  Map<int, String> _nombres = {};

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
    final precios = await preciosVigentes();
    final especiales = await tarifasActivas();
    final clientes = await LocalDb.instance.allMirror('clientes');
    final nombres = <int, String>{};
    for (final c in clientes) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null) nombres[id] = '${c['nombre'] ?? 'Cliente $id'}';
    }
    if (!mounted) return;
    setState(() {
      _precios = precios;
      _especiales = especiales;
      _nombres = nombres;
      _cargando = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Tarifas'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando tarifas…')
          : RefrescoIron(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  const Text('Precios estándar', style: AppTexto.titulo),
                  const SizedBox(height: 8),
                  _filaPrecio('Mensualidad en efectivo',
                      _precios['mensual'] ?? 2000),
                  _filaPrecio('Mensualidad por transferencia',
                      _precios['transfer'] ?? 2500),
                  _filaPrecio('Mensualidad menores',
                      _precios['menores'] ?? 1500),
                  _filaPrecio(
                      'Semana', _precios['semanal'] ?? 600),
                  _filaPrecio(
                      'Quincena', _precios['quincenal'] ?? 1200),
                  _filaPrecio(
                      'Pago diario', _precios['diario'] ?? 200),
                  const SizedBox(height: 8),
                  const Text(
                    'La Cuenta a la Casa es precio 0 y va por encima '
                    'de todo. Una tarifa especial vigente gana a '
                    'menores y a la Oferta; un método en vacío cae al '
                    'siguiente escalón, nunca directo al estándar.',
                    style: AppTexto.secundario,
                  ),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      const Expanded(
                          child: Text('Tarifas especiales activas',
                              style: AppTexto.titulo)),
                      if (AuthService().isOwner)
                        FilledButton.icon(
                          onPressed: () async {
                            await mostrarModalTarifaEspecial(context);
                            _cargar();
                          },
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: const Text('Nueva'),
                        ),
                    ],
                  ),
                  // T14 (1.20): aviso de tarifas por revisar.
                  // 1.29 (FB-06 · D-B1-06): el texto distingue la
                  // VERDAD de cada estado — la VENCIDA ya no se
                  // aplica (el motor cobra la tarifa normal,
                  // T14-A); la que está por vencer sí sigue
                  // aplicando. Antes un solo texto decía «sigue
                  // aplicando» de ambas y era falso para las
                  // vencidas.
                  Builder(builder: (_) {
                    final hoy = hoyHabanaIso();
                    final vencidas = _especiales
                        .where((e) =>
                            estadoRevisionTarifa(e, hoy) == 'vencida')
                        .length;
                    final porVencer = _especiales
                        .where((e) =>
                            estadoRevisionTarifa(e, hoy) ==
                            'por_vencer')
                        .length;
                    if (vencidas == 0 && porVencer == 0) {
                      return const SizedBox.shrink();
                    }
                    final frases = <String>[
                      if (vencidas > 0)
                        vencidas == 1
                            ? '1 tarifa vencida: ya no se aplica; se cobra la tarifa normal hasta renovarla.'
                            : '$vencidas tarifas vencidas: ya no se aplican; se cobra la tarifa normal hasta renovarlas.',
                      if (porVencer > 0)
                        porVencer == 1
                            ? '1 vence pronto: sigue aplicando; revísala antes de que caduque.'
                            : '$porVencer vencen pronto: siguen aplicando; revísalas antes de que caduquen.',
                    ];
                    return Padding(
                      padding:
                          const EdgeInsets.only(bottom: AppEspacio.sm),
                      child: Tarjeta(
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded,
                                color: AppColores.alerta),
                            const SizedBox(width: AppEspacio.sm),
                            Expanded(
                              child: Text(
                                frases.join(' '),
                                style: AppTexto.cuerpo,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  if (_especiales.isEmpty)
                    const Text('Ninguna tarifa especial activa.',
                        style: AppTexto.secundario),
                  for (final e in _especiales)
                    Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      ListTile(
                        leading: Icon(Icons.local_offer_rounded,
                            color: AppColores.textoSecundario(context)),
                        title: Text(_nombres[
                                (e['cliente_id'] as num?)?.toInt()] ??
                            'Cliente ${e['cliente_id']}'),
                        subtitle: Text(
                            '${e['nombre'] ?? ''} · ${e['periodo'] ?? 'mensual'}\n'
                            'Efectivo: ${_montoTexto((e['monto_efectivo'] as num?)?.toDouble())} · '
                            'Transferencia: ${_montoTexto((e['monto_transferencia'] as num?)?.toDouble())}'
                            '${(e['vigente_hasta'] as String?) != null ? '\nHasta: ${e['vigente_hasta']}' : ''}'),
                        isThreeLine: true,
                        onTap: AuthService().isOwner
                            ? () async {
                                await mostrarModalTarifaEspecial(
                                  context,
                                  clienteId:
                                      (e['cliente_id'] as num?)?.toInt(),
                                  clienteNombre: _nombres[
                                      (e['cliente_id'] as num?)?.toInt()],
                                );
                                _cargar();
                              }
                            : null,
                      ),
                      Builder(builder: (_) {
                        final est = estadoRevisionTarifa(
                            e, hoyHabanaIso());
                        if (est != 'vencida' && est != 'por_vencer') {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(
                              16, 0, 16, 12),
                          child: ChipEstado.semantico(
                            // 1.29 (FB-06): la vencida dice la
                            // verdad operativa — ya no se aplica.
                            texto: est == 'vencida'
                                ? 'Vencida — ya no se aplica'
                                : 'Vence pronto — por revisar',
                            significado: est == 'vencida'
                                ? SignificadoChip.error
                                : SignificadoChip.alerta,
                          ),
                        );
                      }),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _filaPrecio(String etiqueta, double monto) => Padding(
        padding: const EdgeInsets.only(bottom: AppEspacio.xs),
        child: Row(
          children: [
            Expanded(child: Text(etiqueta, style: AppTexto.cuerpo)),
            Text('${fmtMonto(monto)} CUP', style: AppTexto.cuerpo),
          ],
        ),
      );

  String _montoTexto(double? m) =>
      m == null ? 'sin especial' : '${fmtMonto(m)} CUP';
}

/// Modal D6: otorgar / editar / revocar una tarifa especial.
///
/// - Con [clienteId]: modo un cliente (desde la ficha). Pre-carga la
///   fila activa del periodo elegido (ambos métodos).
/// - Sin [clienteId]: modo multi (desde TarifasScreen). Primero se
///   eligen los clientes; al guardar, una fila por cliente.
Future<void> mostrarModalTarifaEspecial(
  BuildContext context, {
  int? clienteId,
  String? clienteNombre,
}) async {
  if (!AuthService().isOwner) return;
  if (clienteId == null) {
    final ids = await _elegirClientes(context);
    if (ids == null || ids.isEmpty || !context.mounted) return;
    await _formularioTarifa(context, clienteIds: ids);
    return;
  }
  await _formularioTarifa(context,
      clienteIds: [clienteId], clienteNombre: clienteNombre);
}

Future<List<int>?> _elegirClientes(BuildContext context) async {
  final todos = await listaClientes('');
  return showDialog<List<int>>(
    context: context,
    builder: (ctx) => _DialogoElegirClientesTarifa(todos: todos),
  );
}

/// 1.30 (Oleada 7, clase B): selector de clientes de la
/// tarifa como StatefulWidget propio: posee y dispone el
/// controlador del filtro (antes se creaba en la función y
/// nunca se liberaba). Devuelve los ids elegidos o null.
class _DialogoElegirClientesTarifa extends StatefulWidget {
  final List<Map<String, dynamic>> todos;
  const _DialogoElegirClientesTarifa({required this.todos});

  @override
  State<_DialogoElegirClientesTarifa> createState() =>
      _DialogoElegirClientesTarifaState();
}

class _DialogoElegirClientesTarifaState
    extends State<_DialogoElegirClientesTarifa> {
  final _filtro = TextEditingController();
  final _elegidos = <int>{};

  @override
  void dispose() {
    _filtro.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _filtro.text.trim().toLowerCase();
    final visibles = q.isEmpty
        ? widget.todos
        : widget.todos
            .where((c) =>
                '${c['nombre'] ?? ''}'.toLowerCase().contains(q))
            .toList();
    return DialogoApp(
      titulo: 'Elegir clientes',
      iconoTitulo: Icons.group_rounded,
      contenido: SizedBox(
        width: double.maxFinite,
        height: 420,
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
                    CheckboxListTile(
                      dense: true,
                      title: Text('${c['nombre'] ?? ''}'),
                      value: _elegidos
                          .contains((c['id'] as num?)?.toInt()),
                      onChanged: (v) => setState(() {
                        final id = (c['id'] as num?)?.toInt();
                        if (id == null) return;
                        if (v == true) {
                          _elegidos.add(id);
                        } else {
                          _elegidos.remove(id);
                        }
                      }),
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
        FilledButton(
            onPressed: _elegidos.isEmpty
                ? null
                : () => Navigator.pop(context, _elegidos.toList()),
            child: Text('Continuar (${_elegidos.length})')),
      ],
    );
  }
}

/// Datos que devuelve el formulario de tarifa al guardar.
typedef _DatosTarifa = ({
  String nombre,
  String efectivo,
  String transfer,
  String desde,
  String hasta,
  String motivo,
  String periodo,
});

Future<void> _formularioTarifa(
  BuildContext context, {
  required List<int> clienteIds,
  String? clienteNombre,
}) async {
  final esMulti = clienteIds.length > 1;
  // Pre-carga inicial del periodo por defecto ('mensual'),
  // ANTES de abrir, como siempre: el diálogo nace ya con los
  // valores de la fila activa (o vacío si no hay).
  Map<String, dynamic>? activaPrevia;
  if (!esMulti) {
    activaPrevia =
        await tarifaActivaPara(clienteIds.first, 'mensual');
  }
  if (!context.mounted) return;

  final datos = await showDialog<_DatosTarifa>(
    context: context,
    builder: (ctx) => _DialogoFormularioTarifa(
      clienteIds: clienteIds,
      clienteNombre: clienteNombre,
      previaInicial: activaPrevia,
    ),
  );
  if (datos == null || !context.mounted) return;
  final periodo = datos.periodo;

  // Validación (no bloquea con diálogos crípticos: un aviso claro).
  String? error;
  final ef = _parseMonto(datos.efectivo);
  final tr = _parseMonto(datos.transfer);
  if (datos.nombre.trim().isEmpty) {
    error = 'Falta el nombre de la tarifa.';
  } else if (ef == null && tr == null) {
    error = 'Pon al menos un monto (efectivo o transferencia).';
  } else if ((ef != null && ef <= 0) || (tr != null && tr <= 0)) {
    error = 'Los montos deben ser mayores que 0.';
  } else if (datos.motivo.trim().isEmpty) {
    error = 'Falta el motivo (es obligatorio y queda en el historial).';
  } else if (DateTime.tryParse(datos.desde.trim()) == null) {
    error = 'Vigente desde no es una fecha válida (AAAA-MM-DD).';
  } else if (datos.hasta.trim().isNotEmpty &&
      DateTime.tryParse(datos.hasta.trim()) == null) {
    error = 'Vigente hasta no es una fecha válida (AAAA-MM-DD).';
  } else if (datos.hasta.trim().isNotEmpty &&
      datos.hasta.trim().compareTo(datos.desde.trim()) < 0) {
    error = 'Vigente hasta no puede ser antes que vigente desde.';
  }
  if (error != null) {
    if (!context.mounted) return;
    mostrarSnack(context, error, significado: SignificadoChip.error);
    return;
  }

  // Multi: si algún método pasaría de tener valor a null para algún
  // cliente, confirmar listando los afectados (ajuste 1).
  if (esMulti) {
    final afectados = <String>[];
    for (final cid in clienteIds) {
      final prev = await tarifaActivaPara(cid, periodo);
      if (prev == null) continue;
      if (ef == null && prev['monto_efectivo'] != null) {
        afectados.add('Cliente $cid: efectivo quedará sin especial');
      }
      if (tr == null && prev['monto_transferencia'] != null) {
        afectados
            .add('Cliente $cid: transferencia quedará sin especial');
      }
    }
    if (afectados.isNotEmpty && context.mounted) {
      final conf = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('¿Quitar esas especiales?'),
          content: Text(afectados.join('\n')),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Sí, guardar así')),
          ],
        ),
      );
      if (conf != true) return;
    }
  }

  await otorgarTarifaEspecialMulti(
    clienteIds: clienteIds,
    nombre: datos.nombre.trim(),
    montoEfectivo: ef,
    montoTransferencia: tr,
    periodo: periodo,
    vigenteDesde: datos.desde.trim(),
    vigenteHasta:
        datos.hasta.trim().isEmpty ? null : datos.hasta.trim(),
    motivo: datos.motivo.trim(),
    otorgadoPor: AuthService().telegramId,
  );
  // Como tras revocar: subir en cuanto se guarda.
  SyncEngine.instance.push();
  if (!context.mounted) return;
  mostrarSnack(context, 'Tarifa especial guardada', significado: SignificadoChip.exito);
}

Future<String?> _pedirMotivo(BuildContext context) async {
  return showDialog<String>(
    context: context,
    builder: (ctx) => const _DialogoPedirMotivo(),
  );
}

/// 1.30 (Oleada 7, clase B): diálogo «Motivo de la
/// revocación» como StatefulWidget propio: posee y dispone
/// su controlador (antes se creaba en la función y nunca se
/// liberaba). Devuelve el motivo (vacío = null) o null.
class _DialogoPedirMotivo extends StatefulWidget {
  const _DialogoPedirMotivo();

  @override
  State<_DialogoPedirMotivo> createState() =>
      _DialogoPedirMotivoState();
}

class _DialogoPedirMotivoState extends State<_DialogoPedirMotivo> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Motivo de la revocación',
      iconoTitulo: Icons.cancel_rounded,
      contenido: TextField(
          controller: _ctrl,
          decoration: const InputDecoration(
              hintText: 'Ej: terminó el pacto',
              border: OutlineInputBorder())),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(context,
                _ctrl.text.trim().isEmpty ? null : _ctrl.text.trim()),
            child: const Text('Revocar')),
      ],
    );
  }
}

/// 1.30 (Oleada 7, clase B): el formulario de tarifa especial
/// como StatefulWidget propio: posee y dispone sus seis
/// controladores (antes se creaban en la función y nunca se
/// liberaban). La pre-carga inicial llega por [previaInicial]
/// (el llamador la espera ANTES de abrir, como siempre); al
/// cambiar el periodo, el propio estado recarga la previa de
/// ese periodo. Devuelve los datos al guardar o null si se
/// cancela o se revoca.
class _DialogoFormularioTarifa extends StatefulWidget {
  final List<int> clienteIds;
  final String? clienteNombre;
  final Map<String, dynamic>? previaInicial;
  const _DialogoFormularioTarifa({
    required this.clienteIds,
    required this.clienteNombre,
    required this.previaInicial,
  });

  @override
  State<_DialogoFormularioTarifa> createState() =>
      _DialogoFormularioTarifaState();
}

class _DialogoFormularioTarifaState
    extends State<_DialogoFormularioTarifa> {
  final _nombreCtrl = TextEditingController();
  final _efectivoCtrl = TextEditingController();
  final _transferCtrl = TextEditingController();
  late final TextEditingController _desdeCtrl;
  final _hastaCtrl = TextEditingController();
  final _motivoCtrl = TextEditingController();
  var _periodo = 'mensual';
  Map<String, dynamic>? _activaPrevia;

  bool get _esMulti => widget.clienteIds.length > 1;

  @override
  void initState() {
    super.initState();
    _desdeCtrl = TextEditingController(text: hoyHabanaIso());
    _aplicarPrevia(widget.previaInicial);
  }

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _efectivoCtrl.dispose();
    _transferCtrl.dispose();
    _desdeCtrl.dispose();
    _hastaCtrl.dispose();
    _motivoCtrl.dispose();
    super.dispose();
  }

  void _aplicarPrevia(Map<String, dynamic>? previa) {
    _activaPrevia = previa;
    if (previa != null) {
      _nombreCtrl.text = '${previa['nombre'] ?? ''}';
      final ef = (previa['monto_efectivo'] as num?)?.toDouble();
      final tr = (previa['monto_transferencia'] as num?)?.toDouble();
      _efectivoCtrl.text = ef == null ? '' : _num(ef);
      _transferCtrl.text = tr == null ? '' : _num(tr);
      _desdeCtrl.text = '${previa['vigente_desde'] ?? hoyHabanaIso()}';
      _hastaCtrl.text = '${previa['vigente_hasta'] ?? ''}';
      _motivoCtrl.text = '${previa['motivo'] ?? ''}';
    } else {
      // Corrección panel 1.10 (BAJO): sin previa, el formulario
      // es «Nueva tarifa» y NO debe conservar los valores del
      // periodo anterior (antes se guardaban como si fueran de
      // este periodo).
      _nombreCtrl.clear();
      _efectivoCtrl.clear();
      _transferCtrl.clear();
      _desdeCtrl.text = hoyHabanaIso();
      _hastaCtrl.clear();
      _motivoCtrl.clear();
    }
  }

  Future<void> _cargarPrevia() async {
    // Solo en modo un cliente: pre-carga AMBOS métodos de la fila
    // activa de ese periodo (ajuste 1).
    if (_esMulti) return;
    final previa =
        await tarifaActivaPara(widget.clienteIds.first, _periodo);
    if (!mounted) return;
    setState(() => _aplicarPrevia(previa));
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: _activaPrevia != null
          ? 'Editar tarifa especial'
          : 'Nueva tarifa especial',
      iconoTitulo: Icons.local_offer_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_esMulti)
              const Text(
                'Se creará UNA fila por cliente. Lo que dejes vacío '
                'quedará sin especial para ese método en todos los '
                'clientes elegidos.',
                style: AppTexto.secundario,
              ),
            if (!_esMulti && widget.clienteNombre != null)
              Text('Cliente: ${widget.clienteNombre}',
                  style: AppTexto.cuerpo),
            const SizedBox(height: 8),
            // N1 (estéticas 1.19): campos del sistema.
            CampoTexto(
                controller: _nombreCtrl,
                etiqueta: 'Nombre (ej: Kevin 1000)'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: _efectivoCtrl,
                teclado: TextInputType.number,
                etiqueta:
                    'Monto en efectivo (vacío = sin especial)'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: _transferCtrl,
                teclado: TextInputType.number,
                etiqueta:
                    'Monto por transferencia (vacío = sin especial)'),
            const SizedBox(height: 8),
            SelectorIronForm<String>(
              valorInicial: _periodo,
              etiqueta: 'Periodo',
              opciones: const [
                OpcionSelector('mensual', 'Mensual'),
                OpcionSelector('semanal', 'Semanal'),
                OpcionSelector('quincenal', 'Quincenal'),
              ],
              alCambiar: (v) async {
                if (v == null) return;
                setState(() => _periodo = v);
                await _cargarPrevia();
              },
            ),
            const SizedBox(height: 8),
            CampoTexto(
                controller: _desdeCtrl,
                etiqueta: 'Vigente desde (AAAA-MM-DD)'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: _hastaCtrl,
                etiqueta: 'Vigente hasta (vacío = sin fin)'),
            const SizedBox(height: 8),
            CampoTexto(
                controller: _motivoCtrl,
                etiqueta: 'Motivo (obligatorio, interno: '
                    'nunca sale en mensajes)'),
          ],
        ),
      ),
      acciones: [
        if (_activaPrevia != null && !_esMulti)
          TextButton(
              onPressed: () async {
                final motivo = await _pedirMotivo(context);
                if (motivo == null || !mounted) return;
                await revocarTarifaEspecial(
                    id: '${_activaPrevia!['id']}', motivo: motivo);
                // Corrección panel 1.10: subir la revocación en
                // cuanto se confirma, no esperar al próximo push
                // (antes la ventana en que el espejo viejo
                // volvía a mostrarla activa duraba un turno).
                SyncEngine.instance.push();
                // Cerrar SIN guardar: null hace que el código de
                // arriba retorne sin otorgar nada nuevo.
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('Revocar',
                  style: TextStyle(color: AppColores.error))),
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(
            onPressed: () => Navigator.pop(context, (
                  nombre: _nombreCtrl.text,
                  efectivo: _efectivoCtrl.text,
                  transfer: _transferCtrl.text,
                  desde: _desdeCtrl.text,
                  hasta: _hastaCtrl.text,
                  motivo: _motivoCtrl.text,
                  periodo: _periodo,
                )),
            child: const Text('Guardar')),
      ],
    );
  }
}

double? _parseMonto(String raw) {
  final t = raw.trim().replaceAll(',', '.');
  if (t.isEmpty) return null;
  // Autoauditoría 1.22 #2 (clase N-2): un monto no finito no es
  // un monto (NaN pasaba la validación <= 0 de la tarifa y
  // viajaba en su payload).
  final v = double.tryParse(t);
  return (v != null && v.isFinite) ? v : null;
}

String _num(double v) =>
    v == v.roundToDouble() ? '${v.toInt()}' : '$v';
