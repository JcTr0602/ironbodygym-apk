import 'package:flutter/material.dart';

import '../localdb.dart';
import '../negocio.dart' show fmtMonto, fmtFecha;
import '../servicios.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'hoja_accion.dart';

/// 1.31 (Oleada de Mejoras · Día): el detalle de una venta de
/// Servicios y su reversión viven UNA sola vez aquí y los usan
/// «Ventas de hoy» y el Historial. Antes el Historial era solo
/// lectura (ni abría el detalle) y revertir una venta de otro
/// día no tenía camino en toda la app (G-1); el detalle, además,
/// pintaba al comprador como una fila más entre Hora y Pomo
/// (G-2): ahora el monto manda arriba y el cliente es el
/// protagonista, como pidió Jc.

/// Hoja de «Revertir venta» (nació en Servicios en la 1.30 D3):
/// HojaAccion con estado propio, dueña de su controlador.
/// Devuelve (motivo, polvoPerdido) ya validado; null si se
/// cancela. Los guardarraíles se comprueban ANTES, en
/// [revertirVentaServicioUI].
class HojaRevertirVenta extends StatefulWidget {
  final Map<String, dynamic> venta;
  final bool esDueno;
  const HojaRevertirVenta(
      {super.key, required this.venta, required this.esDueno});

  @override
  State<HojaRevertirVenta> createState() => _HojaRevertirVentaState();
}

class _HojaRevertirVentaState extends State<HojaRevertirVenta> {
  final _motivoCtrl = TextEditingController();
  var _polvoPerdido = false;
  String? _errorMotivo;

  @override
  void dispose() {
    _motivoCtrl.dispose();
    super.dispose();
  }

  void _revertir() {
    if (_motivoCtrl.text.trim().isEmpty) {
      setState(() =>
          _errorMotivo = 'Escribe el motivo de la reversión');
      return;
    }
    Navigator.pop(context, (
      motivo: _motivoCtrl.text.trim(),
      polvoPerdido: _polvoPerdido,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.venta;
    // La comisión de la hoja es la real de la fila (la
    // configurable; puede ser 0 para el dueño, el agua o la
    // Casa), no un texto fijo.
    final com = (v['comision_monto'] as num?)?.toDouble() ??
        ((v['comision_unitaria'] as num?)?.toDouble() ?? 0) *
            ((v['cantidad'] as num?)?.toInt() ?? 0);
    return HojaAccion(
      titulo: 'Revertir venta',
      icono: Icons.undo_rounded,
      cuerpo: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              'Se registrará un reverso auditable de esta venta '
              '(${fmtMonto(((v['precio_unitario'] as num?)?.toDouble() ?? 0) * ((v['cantidad'] as num?)?.toDouble() ?? 0))} CUP). '
              'La dosis vuelve al pomo, el pomo al agua común'
              '${com > 0 ? ' y se restan los ${fmtMonto(com)} CUP de comisión' : ''}.'),
          const SizedBox(height: AppEspacio.md),
          CampoTexto(
            controller: _motivoCtrl,
            etiqueta: 'Motivo (obligatorio)',
            errorText: _errorMotivo,
            onChanged: (_) {
              if (_errorMotivo != null) {
                setState(() => _errorMotivo = null);
              }
            },
          ),
          // «Polvo perdido» solo lo marca el dueño. Ventas
          // viejas sin pomo no lo ofrecen: su merma no se
          // puede atribuir a un pomo.
          if (mostrarCheckboxPolvoPerdido(widget.esDueno) &&
              (v['pomo_id'] as num?) != null)
            CheckboxListTile(
              value: _polvoPerdido,
              contentPadding: EdgeInsets.zero,
              title: const Text('El polvo se perdió físicamente'),
              subtitle: const Text(
                  'La reversión anula cobro y comisión y la '
                  'pérdida queda como salida no vendida.'),
              onChanged: (x) =>
                  setState(() => _polvoPerdido = x ?? false),
            ),
        ],
      ),
      pie: Row(
        children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar'),
            ),
          ),
          const SizedBox(width: AppEspacio.sm),
          Expanded(
            child: BotonPrimario(
              texto: 'Revertir',
              icono: Icons.undo_rounded,
              onPressed: _revertir,
            ),
          ),
        ],
      ),
    );
  }
}

/// Flujo completo de reversión de una venta de Servicios:
/// guardarraíles (pomo desactivado / lote cerrado), hoja con
/// motivo, op encolada y avisos. Devuelve true si el reverso
/// quedó registrado. Es EL MISMO flujo para la venta de hoy y
/// para la de cualquier día del historial: la op de reversión
/// existente no distingue días.
Future<bool> revertirVentaServicioUI(
  BuildContext context,
  Map<String, dynamic> v, {
  required bool esDueno,
  required void Function(String mensaje, {bool error}) aviso,
}) async {
  String limpio(Object e) =>
      e.toString().replaceFirst('Exception: ', '');
  final pomoId = (v['pomo_id'] as num?)?.toInt();
  // Guardarraíl: si el pomo ya fue desactivado por el dueño, la
  // reversión está BLOQUEADA con motivo visible (la dosis no
  // puede volver a un pomo desactivado). Ventas viejas de la
  // época de lotes (pomo_id NULL) conservan su guardarraíl.
  if (pomoId != null) {
    final pomos = await LocalDb.instance.allMirror('servicio_pomos');
    final pomo = pomos
        .where((l) => (l['id'] as num?)?.toInt() == pomoId)
        .toList();
    if (pomo.isNotEmpty &&
        (pomo.first['activo'] as num?)?.toInt() != 1) {
      aviso('El pomo de esta venta ya fue desactivado por el dueño',
          error: true);
      return false;
    }
  } else {
    final loteId = (v['lote_id'] as num?)?.toInt();
    if (loteId != null) {
      final lotes = await LocalDb.instance.allMirror('servicio_lotes');
      final lote = lotes
          .where((l) => (l['id'] as num?)?.toInt() == loteId)
          .toList();
      if (lote.isNotEmpty &&
          '${lote.first['estado'] ?? ''}' != 'activo') {
        aviso('El lote de esta venta ya fue cerrado por el dueño',
            error: true);
        return false;
      }
    }
  }
  if (!context.mounted) return false;
  final res = await showModalBottomSheet<
      ({String motivo, bool polvoPerdido})>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => HojaRevertirVenta(venta: v, esDueno: esDueno),
  );
  if (res == null) return false;
  try {
    await revertirVentaServicio(
      ventaId: (v['id'] as num).toInt(),
      motivo: res.motivo,
      polvoPerdido: res.polvoPerdido,
      pomoId: pomoId,
      cantidad: (v['cantidad'] as num?)?.toInt(),
    );
    aviso('Reverso registrado');
    return true;
  } catch (e) {
    aviso(limpio(e), error: true);
    return false;
  }
}

/// La venta original de un reverso, por PK (sin escanear el
/// espejo completo).
Future<Map<String, dynamic>?> ventaOriginalServicio(
    Map<String, dynamic> v) async {
  final origId = (v['reverso_de'] as num?)?.toInt();
  if (origId == null) return null;
  final filas =
      await LocalDb.instance.mirrorPorIds('servicio_ventas', [origId]);
  return filas.isEmpty ? null : filas.first;
}

/// Detalle ÚNICO de una venta de Servicios (Hoy e Historial):
/// monto grande y tipo arriba, el CLIENTE como protagonista
/// (G-2), el resto en filas y Revertir al pie cuando aplica
/// (misma condición que el botón de la fila: ni reverso, ni ya
/// reversada, ni aún en cola).
Future<void> mostrarDetalleVentaServicio(
  BuildContext context, {
  required Map<String, dynamic> venta,
  required List<Map<String, dynamic>> pomos,
  required bool yaReversada,
  required void Function(Map<String, dynamic> venta) onRevertir,
}) async {
  final v = venta;
  final esReverso = (v['reverso_de'] as num?) != null;
  final esCasa = (v['casa'] as num?)?.toInt() == 1;
  final enCola = v['en_cola'] == true;
  final precio = (v['precio_unitario'] as num?)?.toDouble() ?? 0;
  final cant = (v['cantidad'] as num?)?.toInt() ?? 0;
  final monto = precio * cant;
  final tipoTxt = etiquetaTipoServicio('${v['tipo']}');
  final com = (v['comision_monto'] as num?)?.toDouble() ??
      ((v['comision_unitaria'] as num?)?.toDouble() ?? 0) * cant;
  final original = await ventaOriginalServicio(v);
  final fecha = '${v['fecha'] ?? ''}';
  final fecha10 = fecha.length >= 10 ? fecha.substring(0, 10) : fecha;
  final motivo = '${v['motivo'] ?? ''}'.trim();
  if (!context.mounted) return;

  Widget fila(String e, String valor) => Padding(
        padding: const EdgeInsets.only(bottom: AppEspacio.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 92, child: Text(e, style: AppTexto.secundario)),
            Expanded(child: Text(valor, style: AppTexto.cuerpo)),
          ],
        ),
      );

  await showDialog<void>(
    context: context,
    builder: (ctx) => DialogoApp(
      titulo: esReverso ? 'Reverso · $tipoTxt' : tipoTxt,
      iconoTitulo: esReverso ? Icons.undo_rounded : Icons.bolt_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // G-2: el monto manda — es lo primero que se lee.
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${fmtMonto(monto)} CUP',
                    style: AppTexto.metrica.copyWith(
                        color: esReverso ? AppColores.error : null)),
                const SizedBox(width: AppEspacio.sm),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                      cant > 1
                          ? '$cant × ${fmtMonto(precio)} CUP'
                          : '${fmtMonto(precio)} CUP',
                      style: AppTexto.secundario),
                ),
              ],
            ),
            if (enCola || yaReversada || esCasa) ...[
              const SizedBox(height: AppEspacio.xs),
              Wrap(
                spacing: AppEspacio.sm,
                children: [
                  if (enCola)
                    const ChipEstado.semantico(
                      texto: 'Por sincronizar',
                      significado: SignificadoChip.info,
                      icono: Icons.sync_rounded,
                    ),
                  if (yaReversada && !esReverso)
                    const ChipEstado.semantico(
                      texto: 'Revertida',
                      significado: SignificadoChip.error,
                      icono: Icons.undo_rounded,
                    ),
                  if (esCasa)
                    const ChipEstado.semantico(
                      texto: 'Cuenta a la Casa',
                      significado: SignificadoChip.alerta,
                      icono: Icons.star_rounded,
                    ),
                ],
              ),
            ],
            const SizedBox(height: AppEspacio.md),
            // G-2: el comprador es el dato más importante de
            // la venta — nombre grande, no una fila más.
            Text('CLIENTE', style: AppTexto.metadato),
            Text(nombreClienteVentaServicio(v),
                style: AppTexto.titulo),
            const Divider(height: 24),
            fila('Fecha',
                '${fecha10.isEmpty ? '—' : fmtFecha(fecha10)} · ${horaVentaServicio(v)}'),
            fila('Pomo', nombrePomoVenta(v, pomos)),
            fila('Cantidad', '$cant'),
            fila('Método', '${v['metodo'] ?? '—'}'),
            fila('Registrado por',
                '${v['registrado_por_nombre'] ?? '—'}'),
            if (com > 0) fila('Comisión', '${fmtMonto(com)} CUP'),
            if (motivo.isNotEmpty) fila('Motivo', motivo),
            if (original != null) ...[
              const EncabezadoSeccion(titulo: 'Venta original'),
              fila('Tipo',
                  etiquetaTipoServicio('${original['tipo']}')),
              fila('Cliente', nombreClienteVentaServicio(original)),
              fila('Monto',
                  '${fmtMonto(((original['precio_unitario'] as num?)?.toDouble() ?? 0) * ((original['cantidad'] as num?)?.toDouble() ?? 0))} CUP'),
              fila('Fecha', (() {
                final f = '${original['fecha'] ?? ''}';
                return f.length >= 10 ? fmtFecha(f.substring(0, 10)) : f;
              })()),
            ],
          ],
        ),
      ),
      acciones: [
        // Una venta aún en cola no se revierte (no tiene id de
        // espejo): se deshace al vender, en sus 15 s.
        if (!esReverso && !yaReversada && !enCola)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onRevertir(v);
            },
            child: const Text('Revertir',
                style: TextStyle(color: AppColores.error)),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cerrar'),
        ),
      ],
    ),
  );
}
