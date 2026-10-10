/// Subpantallas del hub de Administración (A–G).
///
/// Cada sección agrupa contenido relacionado de la antigua pantalla
/// de scroll. El interior de cada sección conserva el diseño original;
/// solo se movió de lugar.
library;

import 'package:flutter/material.dart';

import '../negocio.dart';
import '../sync.dart';
import '../tipos_pago.dart';
import 'auditoria.dart';
import 'componentes.dart';
import 'congelados.dart';
import 'cuentas_cobrar.dart';
import 'detalle_pendiente.dart';
import 'diseno.dart';
import 'historial_entrenador.dart';
import 'historial_ventas.dart';
import 'papelera.dart';
import 'riesgo.dart';
import 'suplementos.dart';
import 'usuarios.dart';

/// Tarjeta de sección (mismo diseño que la antigua administración).
Widget seccionAdmin(
    BuildContext context, IconData icono, String titulo, List<Widget> hijos) {
  return Padding(
    padding: const EdgeInsets.only(bottom: AppEspacio.md),
    child: Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: AppColores.naranja, size: 20),
              const SizedBox(width: AppEspacio.sm),
              Text(titulo, style: AppTexto.subtitulo),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          ...hijos,
        ],
      ),
    ),
  );
}

/// Fila etiqueta-valor (mismo diseño que la antigua administración).
Widget filaAdmin(BuildContext context, IconData? icono, String etiqueta,
    String valor, {bool negrita = false}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            if (icono != null) ...[
              Icon(icono,
                  size: 16,
                  color: AppColores.textoSecundario(context)),
              const SizedBox(width: 6),
            ],
            Text(etiqueta),
          ],
        ),
        Text(valor,
            style: TextStyle(
                fontWeight:
                    negrita ? FontWeight.bold : FontWeight.w600)),
      ],
    ),
  );
}

// -- A · Resumen ------------------------------------------------------------
class SeccionResumenScreen extends StatelessWidget {
  final double ingresos;
  final int inscMes;
  final int morosos;
  final List<Map<String, dynamic>> inscPorEntrenador;

  const SeccionResumenScreen({
    super.key,
    required this.ingresos,
    required this.inscMes,
    required this.morosos,
    required this.inscPorEntrenador,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('A · Resumen')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          seccionAdmin(context, Icons.bar_chart, 'Estadísticas del mes', [
            filaAdmin(context, Icons.payments, 'Ingresos',
                '${fmtMonto(ingresos)} CUP'),
            filaAdmin(
                context, Icons.person_add, 'Inscripciones', '$inscMes'),
            filaAdmin(context, Icons.warning, 'Morosos', '$morosos'),
          ]),
          if (inscPorEntrenador.isNotEmpty)
            seccionAdmin(
                context, Icons.group, 'Inscripciones por entrenador', [
              for (final e in inscPorEntrenador)
                filaAdmin(
                    context, null, '${e['nombre']}', '${e['cantidad']}'),
            ]),
        ],
      ),
    );
  }
}

// -- B · Cobros -------------------------------------------------------------
class SeccionCobrosScreen extends StatefulWidget {
  final Map<String, double> Function() getCaja;
  final double Function() getGastosHoy;
  final List<Map<String, dynamic>> Function() getPend;
  final Future<void> Function({int? trainerId, required String nombre})
      onConfirmarEntrega;
  final Future<void> Function(Widget) onIr;

  const SeccionCobrosScreen({
    super.key,
    required this.getCaja,
    required this.getGastosHoy,
    required this.getPend,
    required this.onConfirmarEntrega,
    required this.onIr,
  });

  @override
  State<SeccionCobrosScreen> createState() => _SeccionCobrosScreenState();
}

class _SeccionCobrosScreenState extends State<SeccionCobrosScreen> {
  Future<void> _confirmarYActualizar(
      {int? trainerId, required String nombre}) async {
    await widget.onConfirmarEntrega(
        trainerId: trainerId, nombre: nombre);
    if (mounted) setState(() {});
  }

  Future<void> _irYActualizar(Widget w) async {
    await widget.onIr(w);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final caja = widget.getCaja();
    final gastosHoy = widget.getGastosHoy();
    final pend = widget.getPend();
    final totalPend =
        pend.fold<double>(0, (s, e) => s + (e['total'] as double));
    final cobradoHoy =
        (caja['efectivo'] ?? 0) + (caja['transferencia'] ?? 0);
    final neto = cobradoHoy - gastosHoy;
    return Scaffold(
      appBar: AppBar(title: const Text('B · Cobros')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          seccionAdmin(context, Icons.point_of_sale, 'Cierre de caja (hoy)', [
            filaAdmin(context, Icons.payments, 'Efectivo',
                '${fmtMonto(caja['efectivo'])} CUP'),
            filaAdmin(context, Icons.smartphone, 'Transferencia',
                '${fmtMonto(caja['transferencia'])} CUP'),
            filaAdmin(context, Icons.receipt_long, 'Gastos',
                '${fmtMonto(gastosHoy)} CUP'),
            const Divider(),
            filaAdmin(context, Icons.inventory_2, 'Neto',
                '${fmtMonto(neto)} CUP',
                negrita: true),
          ]),
          seccionAdmin(
              context,
              Icons.outbox,
              'Pendiente a entregar (${fmtMonto(totalPend)} CUP)',
              [
                if (pend.isEmpty)
                  Text('Nada pendiente. Todo cuadrado.',
                      style: TextStyle(
                          color: AppColores.textoSecundario(context))),
                for (final t in pend)
                  ListTile(
                    dense: true,
                    title: Text('${t['nombre']}'),
                    subtitle: Text(
                        '${t['n']} movimiento(s) — ${fmtMonto(t['total'])} CUP'),
                    onTap: () => _irYActualizar(DetallePendienteScreen(
                        trainerId: t['id'] as int,
                        nombre: '${t['nombre']}')),
                    trailing: TextButton(
                      child: const Text('Confirmar'),
                      onPressed: () => _confirmarYActualizar(
                          trainerId: t['id'] as int?,
                          nombre: '${t['nombre']}'),
                    ),
                  ),
                if (pend.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      icon: const Icon(Icons.done_all),
                      label: const Text('Confirmar todo'),
                      onPressed: () =>
                          _confirmarYActualizar(nombre: 'todos'),
                    ),
                  ),
              ]),
          seccionAdmin(
              context, Icons.account_balance_wallet, 'Cuentas por cobrar', [
            Text(
              'Clientes vencidos ordenados por monto adeudado. El dinero dormido, visible.',
              style: TextStyle(
                  color: AppColores.textoSecundario(context),
                  fontSize: 12),
            ),
            const SizedBox(height: 8),
            BotonPrimario(
              texto: 'Ver cuentas por cobrar',
              icono: Icons.money_off,
              onPressed: () =>
                  _irYActualizar(const CuentasCobrarScreen()),
            ),
          ]),
          seccionAdmin(
              context, Icons.history, 'Historial por entrenador', [
            Text(
              'Cobrado, pagos e inscripciones del mes por entrenador.',
              style: TextStyle(
                  color: AppColores.textoSecundario(context),
                  fontSize: 12),
            ),
            const SizedBox(height: 8),
            BotonPrimario(
              texto: 'Ver historial por entrenador',
              icono: Icons.person_search,
              onPressed: () =>
                  _irYActualizar(const HistorialEntrenadorScreen()),
            ),
          ]),
        ],
      ),
    );
  }
}

// -- C · Clientes -----------------------------------------------------------
class SeccionClientesScreen extends StatelessWidget {
  final Future<void> Function(Widget) onIr;

  const SeccionClientesScreen({super.key, required this.onIr});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('C · Clientes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          seccionAdmin(context, Icons.delete_outline, 'Papelera', [
            BotonSecundario(
              texto: 'Abrir papelera',
              icono: Icons.delete_outline,
              onPressed: () => onIr(const PapeleraScreen()),
            ),
          ]),
          seccionAdmin(context, Icons.ac_unit, 'Congelados', [
            BotonSecundario(
              texto: 'Ver congelados',
              icono: Icons.ac_unit,
              onPressed: () => onIr(const CongeladosScreen()),
            ),
          ]),
          seccionAdmin(context, Icons.warning, 'Clientes en riesgo', [
            Text(
              'Inactivos con 3+ pagos cuyo último pago fue hace más de 60 días. Buenos candidatos para recuperar.',
              style: TextStyle(
                  color: AppColores.textoSecundario(context),
                  fontSize: 12),
            ),
            const SizedBox(height: 8),
            BotonPrimario(
              texto: 'Ver clientes en riesgo',
              icono: Icons.warning_amber,
              onPressed: () => onIr(const RiesgoScreen()),
            ),
          ]),
        ],
      ),
    );
  }
}

// -- D · Sistema -------------------------------------------------------------
class SeccionSistemaScreen extends StatelessWidget {
  final SyncDetalle syncDet;
  final int pendientesSubir;
  final String Function(DateTime?) fechaHora;
  final Future<void> Function() onExportar;
  final Future<void> Function() onExportarExcel;
  final Future<void> Function(Widget) onIr;

  const SeccionSistemaScreen({
    super.key,
    required this.syncDet,
    required this.pendientesSubir,
    required this.fechaHora,
    required this.onExportar,
    required this.onExportarExcel,
    required this.onIr,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('D · Sistema')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          seccionAdmin(context, Icons.health_and_safety, 'Salud del sistema', [
            filaAdmin(context, Icons.sync, 'Última sincronización',
                fechaHora(syncDet.ultimaPush)),
            filaAdmin(context, Icons.download, 'Última bajada',
                fechaHora(syncDet.ultimaPull)),
            filaAdmin(context, Icons.upload, 'Pendientes por subir',
                '$pendientesSubir'),
            filaAdmin(context, Icons.download, 'Bajados (última vez)',
                '${syncDet.bajados}'),
            if (syncDet.error != null && syncDet.error!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  syncDet.error ?? '',
                  style: const TextStyle(
                      color: AppColores.error, fontSize: 13),
                ),
              ),
          ]),
          seccionAdmin(context, Icons.fact_check, 'Auditoría', [
            BotonPrimario(
              texto: 'Ver quién hizo qué y cuándo',
              icono: Icons.history,
              onPressed: () => onIr(const AuditoriaScreen()),
            ),
          ]),
          seccionAdmin(context, Icons.file_download, 'Exportar', [
            BotonPrimario(
              texto: 'Compartir CSV (clientes + pagos del mes)',
              icono: Icons.share,
              onPressed: onExportar,
            ),
            const SizedBox(height: 8),
            BotonPrimario(
              texto: 'Exportar Excel',
              icono: Icons.table_chart,
              onPressed: onExportarExcel,
            ),
          ]),
        ],
      ),
    );
  }
}

// -- E · Ajustes -------------------------------------------------------------
class SeccionAjustesScreen extends StatefulWidget {
  final List<TipoPago> Function() getTipos;
  final void Function(TipoPago, bool) onToggleTipo;
  final Future<void> Function(TipoPago) onEditarTipo;
  final Future<void> Function(TipoPago) onEliminarTipo;
  final Future<void> Function() onAgregarTipo;
  final Future<void> Function() onGuardarTipos;
  final Map<String, TextEditingController> montos;
  final List<(String, String)> clavesMonto;
  final Future<void> Function() onGuardarMontos;
  final bool gestionarUsuarios;
  final Future<void> Function(Widget) onIr;
  final bool Function(String) esTipoFijo;

  const SeccionAjustesScreen({
    super.key,
    required this.getTipos,
    required this.onToggleTipo,
    required this.onEditarTipo,
    required this.onEliminarTipo,
    required this.onAgregarTipo,
    required this.onGuardarTipos,
    required this.montos,
    required this.clavesMonto,
    required this.onGuardarMontos,
    required this.gestionarUsuarios,
    required this.onIr,
    required this.esTipoFijo,
  });

  @override
  State<SeccionAjustesScreen> createState() => _SeccionAjustesScreenState();
}

class _SeccionAjustesScreenState extends State<SeccionAjustesScreen> {
  void _toggleYActualizar(TipoPago t, bool v) {
    widget.onToggleTipo(t, v);
    setState(() {});
  }

  Future<void> _editarYActualizar(TipoPago t) async {
    await widget.onEditarTipo(t);
    if (mounted) setState(() {});
  }

  Future<void> _eliminarYActualizar(TipoPago t) async {
    await widget.onEliminarTipo(t);
    if (mounted) setState(() {});
  }

  Future<void> _agregarYActualizar() async {
    await widget.onAgregarTipo();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tipos = widget.getTipos();
    return Scaffold(
      appBar: AppBar(title: const Text('E · Ajustes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          seccionAdmin(context, Icons.payments, 'Tipos de pago', [
            for (final t in tipos)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(t.nombre,
                    style: TextStyle(
                        fontSize: 14,
                        color: t.activo
                            ? null
                            : AppColores.textoSecundario(context))),
                subtitle: Text(
                    '${fmtMonto(t.monto)} CUP · ${t.dias} días'
                    '${t.soloMenores ? ' · solo menores' : ''}',
                    style: const TextStyle(fontSize: 12)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(
                      value: t.activo,
                      onChanged: (v) => _toggleYActualizar(t, v),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      onPressed: () => _editarYActualizar(t),
                    ),
                    if (!widget.esTipoFijo(t.id))
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            size: 20, color: AppColores.error),
                        onPressed: () => _eliminarYActualizar(t),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            BotonSecundario(
              texto: 'Agregar tipo de pago',
              icono: Icons.add,
              onPressed: _agregarYActualizar,
            ),
            const SizedBox(height: 8),
            BotonPrimario(
              texto: 'Guardar tipos de pago',
              icono: Icons.save,
              onPressed: widget.onGuardarTipos,
            ),
          ]),
          seccionAdmin(context, Icons.price_change, 'Otros precios', [
            for (final (clave, etiqueta) in widget.clavesMonto)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: CampoTexto(
                  controller: widget.montos[clave],
                  etiqueta: '$etiqueta (CUP)',
                  teclado: const TextInputType.numberWithOptions(
                      decimal: true),
                ),
              ),
            BotonPrimario(
              texto: 'Guardar otros precios',
              icono: Icons.save,
              onPressed: widget.onGuardarMontos,
            ),
          ]),
          if (widget.gestionarUsuarios)
            seccionAdmin(context, Icons.smartphone, 'Usuarios APK', [
              BotonPrimario(
                texto: 'Gestionar usuarios',
                icono: Icons.manage_accounts,
                onPressed: () => widget.onIr(const UsuariosScreen()),
              ),
              const SizedBox(height: 4),
              Text(
                'Ver lista, bloquear, desbloquear, cambiar contraseña o eliminar.',
                style: TextStyle(
                    fontSize: 12,
                    color: AppColores.textoSecundario(context)),
              ),
            ]),
        ],
      ),
    );
  }
}

// -- F · Gastos --------------------------------------------------------------
class SeccionGastosScreen extends StatefulWidget {
  final List<Map<String, dynamic>> Function() getGastos;
  final Future<void> Function() onAgregarGasto;

  const SeccionGastosScreen({
    super.key,
    required this.getGastos,
    required this.onAgregarGasto,
  });

  @override
  State<SeccionGastosScreen> createState() => _SeccionGastosScreenState();
}

class _SeccionGastosScreenState extends State<SeccionGastosScreen> {
  Future<void> _agregarYActualizar() async {
    await widget.onAgregarGasto();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final gastos = widget.getGastos();
    return Scaffold(
      appBar: AppBar(title: const Text('F · Gastos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          seccionAdmin(context, Icons.receipt_long, 'Últimos gastos', [
            if (gastos.isEmpty)
              Text('Sin gastos registrados.',
                  style: TextStyle(
                      color: AppColores.textoSecundario(context))),
            for (final g in gastos.take(10))
              ListTile(
                dense: true,
                title: Text('${g['concepto'] ?? '—'}'),
                subtitle: Text(fmtFecha(g['fecha'] as String?)),
                trailing: Text('${fmtMonto(g['monto'])} CUP',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold)),
              ),
            const SizedBox(height: 8),
            BotonSecundario(
              texto: 'Agregar gasto',
              icono: Icons.add,
              onPressed: _agregarYActualizar,
            ),
          ]),
        ],
      ),
    );
  }
}

// -- G · Suplementos ----------------------------------------------------------
class SeccionSuplementosScreen extends StatelessWidget {
  final Future<void> Function(Widget) onIr;

  const SeccionSuplementosScreen({super.key, required this.onIr});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('G · Suplementos')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          seccionAdmin(context, Icons.medication, 'Suplementos', [
            BotonPrimario(
              texto: 'Gestionar catálogo',
              icono: Icons.inventory_2,
              onPressed: () => onIr(const SuplementosScreen()),
            ),
            const SizedBox(height: AppEspacio.sm),
            BotonSecundario(
              texto: 'Historial de ventas',
              icono: Icons.receipt_long,
              onPressed: () => onIr(const HistorialVentasScreen()),
            ),
            const SizedBox(height: 4),
            Text(
              'Productos, precios oficiales, stock, promo "mes gratis" y ventas.',
              style: TextStyle(
                  fontSize: 12,
                  color: AppColores.textoSecundario(context)),
            ),
          ]),
        ],
      ),
    );
  }
}
