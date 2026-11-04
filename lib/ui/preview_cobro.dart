/// Bloque 1 (Argón AMARILLO, 2026-10-24): flujo de cobro seguro.
///
/// Regla principal: NINGÚN cobro se registra sin un preview previo, y
/// ningún acceso rápido (ficha, pagos del día, listas, fila de Buscar)
/// se salta ese preview. Por eso los tres puntos de cobro de
/// mensualidad pasan por [cobrarConPreviewYRecibo]:
///
///   Paso A (Preview, ANTES de guardar): cliente, monto, método y nuevo
///   vencimiento, con botón explícito «Confirmar cobro».
///   Paso B (Recibo, DESPUÉS de guardar): check grande + «Deshacer»
///   durante 15 segundos exactos (ver [ConfirmacionCobroScreen]).
///
/// La op nace retenida 15 s en cola local ([LocalDb.queueOp] con
/// `retenerHastaIso`): si se cierra la app, el cobro no se pierde;
/// si pasa la ventana, el push la toma normal. Si el usuario deshace,
/// la op se borra porque nunca salió del teléfono.
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../comprobantes.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'aviso_duplicado.dart';
import 'confirmacion_cobro.dart';
import 'diseno.dart';

/// Paso A: preview obligatorio antes de guardar el cobro.
/// Devuelve true solo si el usuario tocó «Confirmar cobro».
/// 1.15 (Cobro 2): Stateful con guard local: tras el primer toque
/// el botón queda deshabilitado, así un doble tap no puede hacer
/// dos pop(true) y cerrar también la ruta anterior.
class PreviewCobroScreen extends StatefulWidget {
  final String nombreCliente;
  final String montoTexto;
  final String metodoTexto;
  final String periodoTexto;
  final String nuevoVencimientoTexto;

  const PreviewCobroScreen({
    super.key,
    required this.nombreCliente,
    required this.montoTexto,
    required this.metodoTexto,
    required this.periodoTexto,
    required this.nuevoVencimientoTexto,
  });

  @override
  State<PreviewCobroScreen> createState() => _PreviewCobroScreenState();
}

class _PreviewCobroScreenState extends State<PreviewCobroScreen> {
  var _confirmado = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Revisar cobro'),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                child: Tarjeta(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _fila(context, 'Cliente', widget.nombreCliente),
                      const Divider(),
                      _filaMonto(context),
                      const Divider(),
                      _filaMetodo(context),
                      const Divider(),
                      _fila(context, 'Período', widget.periodoTexto),
                      const Divider(),
                      _fila(context, 'Nuevo vencimiento',
                          widget.nuevoVencimientoTexto),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                children: [
                  const Text(
                    'Revisa antes de confirmar: al confirmar se guarda '
                    'el cobro en el teléfono.',
                    textAlign: TextAlign.center,
                    style: AppTexto.metadato,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: BotonPrimario(
                      texto: 'Confirmar cobro',
                      cargando: _confirmado,
                      onPressed: _confirmado
                          ? null
                          : () {
                              setState(() => _confirmado = true);
                              Navigator.of(context).pop(true);
                            },
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () =>
                          Navigator.of(context).pop(false),
                      child: const Text('Cancelar'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fila(BuildContext context, String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(etiqueta, style: AppTexto.secundario),
          const SizedBox(width: 16),
          Flexible(
            child: Text(valor,
                textAlign: TextAlign.end,
                style: AppTexto.cuerpo
                    .copyWith(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  /// V21: el monto es el ancla visual del preview — el ojo debe
  /// encontrar el dinero antes que cualquier otro dato.
  Widget _filaMonto(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Monto', style: AppTexto.secundario),
          const SizedBox(width: 16),
          Flexible(
            child: Text(widget.montoTexto,
                textAlign: TextAlign.end,
                style: AppTexto.metrica.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ],
      ),
    );
  }

  /// V22: el método se reconoce por icono y color semántico,
  /// igual que en el historial de la ficha (efectivo = pagos en
  /// verde; transferencia = teléfono en azul).
  Widget _filaMetodo(BuildContext context) {
    final esTransf = widget.metodoTexto == 'Transferencia';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Método', style: AppTexto.secundario),
          const SizedBox(width: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                  esTransf
                      ? Icons.smartphone_rounded
                      : Icons.payments_rounded,
                  size: 18,
                  color: esTransf ? AppColores.info : AppColores.exito),
              const SizedBox(width: 6),
              Text(widget.metodoTexto,
                  style: AppTexto.cuerpo
                      .copyWith(fontWeight: FontWeight.w600)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Bloque 1: una Cuenta a la Casa NO paga mensualidad. Si el cliente
/// es Casa, muestra el bloqueo y devuelve true: el llamador debe
/// retornar sin cobrar. Si no es Casa, devuelve false sin mostrar nada.
Future<bool> mostrarBloqueoCasa(
    BuildContext context, Map<String, dynamic> cliente) async {
  if (!esCuentaCasa(cliente)) return false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Cuenta a la Casa'),
      content: const Text(
          'Esta cuenta no necesita pagar: tiene acceso '
          'permanente sin vencimiento. Cobrarle un mes no cambia '
          'nada, por eso el cobro de mensualidad está bloqueado.\n\n'
          'Si hay que cobrarle, primero quita la Cuenta a la Casa '
          'desde el panel del dueño.'),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Entendido'),
        ),
      ],
    ),
  );
  return true;
}

int _diasPayload(dynamic v) =>
    v is num ? v.toInt() : int.tryParse('$v') ?? 0;

/// Texto del período para el preview (pública y probada).
/// 1.15 (M7): mensual con 'N meses' cuando meses > 1;
/// personalizado con 'N días' usando `dias`, también para
/// ofertas (que viajan como personalizado o `tipo:<id>`).
String periodoTextoPreview(Map<String, dynamic> payload) {
  final periodo = '${payload['periodo'] ?? ''}';
  switch (periodo) {
    case 'mensual':
      final meses = (payload['meses'] as num?)?.toInt() ?? 1;
      if (meses > 1) return '$meses meses';
      return '${payload['tipo_id'] ?? ''}' == 'menores'
          ? 'Menores'
          : 'Mensual';
    case 'semanal':
      return 'Semanal';
    case 'quincenal':
      return 'Quincenal';
    case 'personalizado':
      final dias = _diasPayload(payload['dias']);
      return dias > 0 ? 'Personalizado ($dias días)' : 'Personalizado';
    default:
      if (periodo.startsWith('tipo:')) {
        final dias = _diasPayload(payload['dias']);
        return dias > 0 ? 'Personalizado ($dias días)' : 'Personalizado';
      }
      return periodo;
  }
}

/// Flujo completo de cobro de mensualidad para un [payload] ya
/// dialogado (de [pagoDialogo], en `dialogo_pago.dart`).
///
/// Devuelve true si el cobro se confirmó y luego se deshizo dentro de
/// la ventana de 15 s. Devuelve false si se canceló en el preview, si
/// se confirmó y quedó guardado, o si la pantalla se cerró.
Future<bool> cobrarConPreviewYRecibo({
  required BuildContext context,
  required String nombreCliente,
  required Map<String, dynamic> payload,
}) async {
  final monto = (payload['monto'] as num?) ?? 0;
  final vencRaw = '${payload['pagado_hasta'] ?? ''}';
  final confirmado = await Navigator.of(context).push<bool>(
    RutaIron(
      builder: (_) => PreviewCobroScreen(
        nombreCliente: nombreCliente,
        montoTexto: '${fmtMonto(monto)} CUP',
        metodoTexto:
            '${payload['metodo'] ?? ''}' == 'transferencia'
                ? 'Transferencia'
                : 'Efectivo',
        periodoTexto: periodoTextoPreview(payload),
        nuevoVencimientoTexto:
            vencRaw.length >= 10 ? fmtFecha(vencRaw) : vencRaw,
      ),
    ),
  );
  if (confirmado != true || !context.mounted) return false;

  // T16 (1.20): aviso si ya hay un cobro igual en la cola
  // (doble toque o reintento con mala conexión).
  final clienteIdDup = (payload['cliente_id'] as num?)?.toInt();
  final sigueCobro = await confirmarSiPareceDuplicado(
    context,
    tipo: 'pago_mensual',
    coincide: (p) =>
        (p['cliente_id'] as num?)?.toInt() == clienteIdDup &&
        ((p['monto'] as num?) ?? 0) == monto,
    descripcion:
        'un cobro de ${fmtMonto(monto)} CUP a $nombreCliente',
  );
  if (!sigueCobro || !context.mounted) return false;

  // Argón P1#4 (contrato con PagoScreen._deshacerUltimo): leer el
  // pagado_hasta anterior del espejo ANTES de encolar, aplicar la
  // actualización optimista al encolar y guardar el valor anterior
  // en el payload como 'pagado_hasta_anterior'. Si la confirmación
  // devuelve 'deshecho', se restaura ese valor anterior.
  // NO cubre una op rechazada tras la ventana de 15 s.
  final clienteId = (payload['cliente_id'] as num?)?.toInt();
  String? pagadoHastaAnterior;
  if (clienteId != null) {
    try {
      final filas = await LocalDb.instance
          .mirrorPorIds('clientes', [clienteId]);
      if (filas.isNotEmpty) {
        final anterior = filas.first['pagado_hasta'] as String?;
        pagadoHastaAnterior =
            (anterior == null || anterior.isEmpty) ? null : anterior;
      }
    } catch (_) {}
  }
  // F1 (1.20): la ruta local del comprobante NO viaja en la
  // op; se genera el uuid que sí viaja ('comprobante_uuid') y
  // enlaza el pago con su foto en el bucket.
  final rutaComprobante = payload['_comprobante_ruta'] as String?;
  String? comprobanteUuid;
  final payloadOp = Map<String, dynamic>.from(payload)
    ..remove('_comprobante_ruta')
    ..['pagado_hasta_anterior'] = pagadoHastaAnterior;
  if (rutaComprobante != null &&
      '${payload['metodo'] ?? ''}' == 'transferencia') {
    comprobanteUuid = const Uuid().v4();
    payloadOp['comprobante_uuid'] = comprobanteUuid;
  }

  // Retención Deshacer: la op nace con 15 s de espera en cola local.
  final opUuid = const Uuid().v4();
  final retenerHasta =
      isoHabana(ahoraHabana().add(const Duration(seconds: 15)));
  await LocalDb.instance.queueOp(
    opUuid: opUuid,
    tipo: 'pago_mensual',
    payload: payloadOp,
    retenerHastaIso: retenerHasta,
  );
  // Actualización optimista del espejo con el nuevo vencimiento.
  if (clienteId != null && vencRaw.isNotEmpty) {
    try {
      await LocalDb.instance.updateMirrorPagadoHasta(
          clienteId, vencRaw.substring(0, 10));
    } catch (_) {}
  }
  // F1: guardar la foto del comprobante en su cola local. Si
  // falla, el cobro queda sin comprobante (nunca al revés).
  if (comprobanteUuid != null) {
    try {
      await ComprobantesService.instance.encolar(
          comprobanteUuid: comprobanteUuid,
          rutaOrigen: rutaComprobante!);
    } catch (_) {}
  }
  if (!context.mounted) return false;

  final resultado = await Navigator.of(context).push<String>(
    RutaIron(
      builder: (_) => ConfirmacionCobroScreen(
        nombreCliente: nombreCliente,
        monto: '${fmtMonto(monto)} CUP',
        nuevoVencimiento:
            vencRaw.length >= 10 ? vencRaw.substring(0, 10) : vencRaw,
        opUuid: opUuid,
        // Bloque 4 (T6): el monto del recibo cuenta hasta su
        // valor con MontoAnimado.
        montoValor: monto.toDouble(),
        montoFormato: (v) => '${fmtMonto(v)} CUP',
      ),
    ),
  );
  if (resultado == 'deshecho' && comprobanteUuid != null) {
    // F1: el cobro se deshizo: su comprobante se descarta.
    try {
      await ComprobantesService.instance.descartar(comprobanteUuid);
    } catch (_) {}
  }
  if (resultado == 'deshecho' && clienteId != null) {
    // Restaurar el valor anterior en el espejo (null = quitarlo).
    try {
      if (pagadoHastaAnterior == null) {
        await LocalDb.instance.updateMirrorBasico(
            clienteId, {'pagado_hasta': null});
      } else {
        await LocalDb.instance.updateMirrorPagadoHasta(
            clienteId, pagadoHastaAnterior.substring(0, 10));
      }
    } catch (_) {}
  }
  return resultado == 'deshecho';
}
