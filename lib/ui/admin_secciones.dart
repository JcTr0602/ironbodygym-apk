/// Subpantallas del hub de Administración (A–G).
///
/// Cada sección agrupa contenido relacionado de la antigua pantalla
/// de scroll. El interior de cada sección conserva el diseño original;
/// solo se movió de lugar.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth.dart';
import '../config.dart';

import '../negocio.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tipos_pago.dart';
import 'auditoria.dart';
import 'categorias_suplemento.dart';
import 'componentes.dart';
import 'cuentas_cobrar.dart';
import 'detalle_pendiente.dart';
import 'diseno.dart';
import 'historial_entrenador.dart';
import 'incidencias_sync.dart';
import 'arqueo.dart';
import 'nomina.dart';
import 'historial_ventas.dart';
import 'suplementos.dart';
import 'usuarios.dart';

/// Tarjeta de sección (mismo diseño que la antigua administración).
/// v1.3.6 (Argón, diseño): el icono del encabezado usa el badge squircle
/// del sistema (igual que Home) para no dejar dos estilos conviviendo.
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
              IconoModuloBadge.naranja(icono, tamanoIcono: 20),
              const SizedBox(width: AppEspacio.sm),
              Expanded(child: Text(titulo, style: AppTexto.subtitulo)),
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
          // v1.3.6 (ítem 1B): arqueo de caja con liquidaciones.
          seccionAdmin(context, Icons.point_of_sale, 'Arqueo de caja', [
            Text(
              'Liquida el pendiente de cada entrenador con monto esperado '
              'vs entregado. Las parciales dejan saldo de arrastre.',
              style: TextStyle(
                  color: AppColores.textoSecundario(context),
                  fontSize: 12),
            ),
            const SizedBox(height: 8),
            BotonPrimario(
              texto: 'Abrir arqueo de caja',
              icono: Icons.account_balance_wallet_rounded,
              onPressed: () => _irYActualizar(const ArqueoScreen()),
            ),
          ]),
          // v1.3.7 (Fase A, 6.1): pre-cálculo de nómina.
          seccionAdmin(context, Icons.payments_rounded, 'Nómina del mes', [
            Text(
              'Proyección del pago por entrenador: clientes pagados '
              '× 150 CUP. Solo lectura.',
              style: TextStyle(
                  color: AppColores.textoSecundario(context),
                  fontSize: 12),
            ),
            const SizedBox(height: 8),
            BotonPrimario(
              texto: 'Ver nómina',
              icono: Icons.payments_rounded,
              onPressed: () => _irYActualizar(const NominaScreen()),
            ),
          ]),
          seccionAdmin(
              context, Icons.account_balance_wallet_rounded, 'Cuentas por cobrar', [            Text(
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
                  // v1.3.8: lenguaje común, no tecnicismos.
                  errorSyncLegible(syncDet.error ?? ''),
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
  // v1.2.4: datos bancarios
  final Map<String, TextEditingController> bancarios;
  final Future<void> Function() onGuardarBancarios;
  final bool gestionarUsuarios;
  final Future<void> Function(Widget) onIr;
  final bool Function(String) esTipoFijo;
  // v1.3.9: filtrar por sección ('tipos', 'precios', 'bancarios', null=todas)
  final String? seccion;

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
    required this.bancarios,
    required this.onGuardarBancarios,
    required this.gestionarUsuarios,
    required this.onIr,
    required this.esTipoFijo,
    this.seccion,
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
      appBar: AppBar(
          title: Text(widget.seccion == 'bancarios'
              ? 'Datos bancarios'
              : widget.seccion == 'precios'
                  ? 'Otros precios'
                  : widget.seccion == 'tipos'
                      ? 'Tipos de pago'
                      : 'Ajustes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.seccion == null || widget.seccion == 'tipos')
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
          if (widget.seccion == null || widget.seccion == 'precios')
            seccionAdmin(context, Icons.price_change, 'Otros precios', [
            for (final (clave, etiqueta) in widget.clavesMonto)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: CampoTexto(
                  controller: widget.montos[clave],
                  etiqueta: etiqueta.contains('CUP') ? etiqueta : '$etiqueta (CUP)',
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
          // v1.2.4: datos bancarios para transferencias
          if (widget.seccion == null || widget.seccion == 'bancarios')
            seccionAdmin(context, Icons.account_balance, 'Datos bancarios', [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: CampoTexto(
                controller: widget.bancarios['tarjeta_bandec'],
                etiqueta: 'Tarjeta BANDEC',
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: CampoTexto(
                controller: widget.bancarios['tarjeta_bpa'],
                etiqueta: 'Tarjeta BPA',
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: CampoTexto(
                controller: widget.bancarios['movil_confirmacion'],
                etiqueta: 'Móvil confirmación',
                teclado: TextInputType.phone,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: CampoTexto(
                controller: widget.bancarios['titular'],
                etiqueta: 'Titular de la cuenta',
              ),
            ),
            BotonPrimario(
              texto: 'Guardar datos bancarios',
              icono: Icons.save,
              onPressed: widget.onGuardarBancarios,
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
            // v1.2.1: CRUD de categorías.
            BotonSecundario(
              texto: 'Categorías',
              icono: Icons.category_outlined,
              onPressed: () =>
                  onIr(const CategoriasSuplementoScreen()),
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

// -- H · Diagnóstico (v1.2.4) --------------------------------------------------
/// Centro de diagnóstico: estado de sincronización, operaciones y entidades.
/// v1.2.4 (Hark): conteos con COUNT(*) (no carga tablas completas),
/// watermark vs server_seq, versión y botón "Copiar informe".
class SeccionDiagnosticoScreen extends StatefulWidget {
  const SeccionDiagnosticoScreen({super.key});

  @override
  State<SeccionDiagnosticoScreen> createState() =>
      _SeccionDiagnosticoScreenState();
}

class _SeccionDiagnosticoScreenState extends State<SeccionDiagnosticoScreen> {
  Map<String, String> _datos = {};
  String? _ultimoError;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final db = LocalDb.instance;
      final lastOk = await db.getMeta('last_sync_ok');
      final lastErr = await db.getMeta('last_sync_error');
      final wm = await db.getWatermarkMinimo();
      final ss = await db.getMeta('server_seq') ?? '?';
      final datos = <String, String>{
        'Versión': '${AppConfig.appVersion} (${AuthService().username})',
        'Última sync correcta': _fmt(lastOk),
        'Watermark / servidor': '$wm / $ss',
        'Ops pendientes':
            '${await db.contar('ops_queue', where: "estado IN ('pendiente','error')")}',
        'Ops rechazadas':
            '${await db.contar('ops_queue', where: "estado = 'rechazada'")}',
        'Fotos pendientes': '${await db.contar('fotos_cola', where: "estado = 'pendiente'")}',
        'Fotos con error': '${await db.contar('fotos_cola', where: "estado = 'error'")}',
        'Clientes': '${await db.contar('clientes')}',
        'Pagos': '${await db.contar('pagos')}',
        'Ventas suplementos': '${await db.contar('ventas_suplementos')}',
        'Suplementos': '${await db.contar('suplementos')}',
      };
      // v1.3.1 (Argón): valores de precios en ajustes para auditar
      // discrepancias (menores 1500 vs 2000).
      final aj = await db.getAjustes();
      datos['Precio mensual'] = '${aj['mensualidad'] ?? 2000}';
      datos['Precio menores'] = '${aj['mensualidad_menores'] ?? 1500}';
      datos['Precio transferencia'] = '${aj['transferencia'] ?? 2500}';
      // v1.3.1 (Argón): detalle de fotos atascadas en la cola.
      // Nota: sin lista columns (SELECT *) y con fallbacks por si el
      // esquema varía entre versiones.
      try {
        final fotosAtascadas = await db.db.then((d) => d.query(
              'fotos_cola',
              where: "estado IN ('pendiente','error','subiendo')",
              orderBy: 'id ASC',
              limit: 20,
            ));
        if (fotosAtascadas.isEmpty) {
          datos['Fotos en cola'] = 'ninguna atascada';
        } else {
          var i = 0;
          for (final f in fotosAtascadas) {
            i++;
            datos['Foto cola #$i'] =
                'id=${f['id']} cliente=${f['cliente_id'] ?? f['suplemento_id'] ?? '-'} '
                'estado=${f['estado']} intentos=${f['intentos']} '
                'error=${f['ultimo_error'] ?? f['error'] ?? '-'}';
          }
        }
      } catch (_) {
        datos['Fotos en cola'] = 'no se pudo leer';
      }
      // v1.3.1 (Argón pull): desglose por tabla — watermark, filas
      // locales y estado. Es lo que permite identificar qué tabla deja
      // el mínimo en 0.
      const tablasDiag = [
        'clientes',
        'pagos',
        'pagos_diarios',
        'gastos',
        'suplementos',
        'ventas_suplementos',
        'categorias_suplemento',
        'turnos_cierre',
        'borrados',
        'incidencias',
        'incidencias_tipos',
        'incidencias_comentarios',
        'liquidaciones_caja', // v1.3.6 (v28, ítem 1B)
        'incidencias_sync', // v1.3.6 (v28, ítem 1C)
      ];
      for (final t in tablasDiag) {
        final wmt = await db.getWatermarkTabla(t);
        var estado = 'OK';
        final err = await db.getMeta('wm_err_$t');
        if (err != null && err.isNotEmpty) {
          estado = 'ERROR: $err';
        } else if (await db.getMeta('wm_${t}_sin_permiso') == '1') {
          estado = 'sin_permiso';
        } else if (await db.getMeta('wm_${t}_ausente') == '1') {
          estado = 'ausente';
        }
        String filas;
        // v1.3.1 (Argón pull r2): 'borrados' no es tabla local;
        // 'incidencias' en SQLite se llama incidencias_local.
        if (t == 'borrados') {
          filas = '-';
        } else {
          final tablaSql = t == 'incidencias' ? 'incidencias_local' : t;
          try {
            filas = '${await db.contar(tablaSql)}';
          } catch (_) {
            filas = '?';
          }
        }
        datos['wm_$t'] = '$wmt · filas=$filas · $estado';
      }
      if (!mounted) return;
      setState(() {
        _datos = datos;
        _ultimoError = (lastErr?.isNotEmpty ?? false) ? lastErr : null;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ultimoError = 'No se pudo leer el diagnóstico: $e';
        _cargando = false;
      });
    }
  }

  String _fmt(String? iso) {
    final d = iso == null ? null : DateTime.tryParse(iso);
    if (d == null) return 'Nunca';
    final m = DateTime.now().difference(d).inMinutes;
    final hace = m < 1
        ? 'ahora'
        : m < 60
            ? 'hace $m min'
            : m < 1440
                ? 'hace ${m ~/ 60} h'
                : 'hace ${m ~/ 1440} d';
    return '${iso!.substring(0, 16).replaceFirst('T', ' ')} ($hace)';
  }

  Future<void> _copiar() async {
    final txt = StringBuffer('Iron Body Gym · diagnóstico\n');
    _datos.forEach((k, v) => txt.writeln('$k: $v'));
    if (_ultimoError != null) txt.writeln('Último error: $_ultimoError');
    await Clipboard.setData(ClipboardData(text: txt.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Informe copiado. Pégalo en Telegram o WhatsApp.')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('H · Diagnóstico'),
        actions: [
          IconButton(
            tooltip: 'Copiar informe',
            icon: const Icon(Icons.copy_all),
            onPressed: _cargando ? null : _copiar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Leyendo diagnóstico…')
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  seccionAdmin(context, Icons.monitor_heart, 'Estado', [
                    for (final e in _datos.entries)
                      filaAdmin(context, null, e.key, e.value),
                  ]),
                  if (_ultimoError != null)
                    seccionAdmin(context, Icons.error_outline, 'Último error', [
                      Text(_ultimoError!,
                          style: const TextStyle(
                              color: AppColores.error, fontSize: 13)),
                    ]),
                  // v1.3.6 (ítem 1C): cola de incidencias de sync del dueño.
                  seccionAdmin(
                      context, Icons.sync_problem_rounded, 'Incidencias de sync', [
                    Text(
                      'Operaciones rechazadas por el servidor, con '
                      'Aprobar/Descartar.',
                      style: TextStyle(
                          color: AppColores.textoSecundario(context),
                          fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    BotonPrimario(
                      texto: 'Revisar incidencias de sync',
                      icono: Icons.sync_problem,
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) =>
                                const IncidenciasSyncScreen()),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
    );
  }
}

