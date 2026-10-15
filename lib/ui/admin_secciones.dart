/// Subpantallas del hub de Administración (A–G).
///
/// Cada sección agrupa contenido relacionado de la antigua pantalla
/// de scroll. El interior de cada sección conserva el diseño original;
/// solo se movió de lugar.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth.dart';
import '../config.dart';

import '../negocio.dart';
import '../localdb.dart';
import '../permisos.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../tipos_pago.dart';
import 'auditoria.dart';
import 'categorias_suplemento.dart';
import 'componentes.dart';
import 'congelados.dart';
import 'cuentas_cobrar.dart';
import 'detalle_pendiente.dart';
import 'diseno.dart';
import 'historial_entrenador.dart';
import 'historial_ventas.dart';
import 'papelera.dart';
import 'riesgo.dart';
import 'skeleton.dart';
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
  // v1.2.4: datos bancarios
  final Map<String, TextEditingController> bancarios;
  final Future<void> Function() onGuardarBancarios;
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
    required this.bancarios,
    required this.onGuardarBancarios,
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
                ],
              ),
            ),
    );
  }
}

// -- I · Incidencias (v1.2.4, diseño ChatGPT) --------------------------------
/// Bandeja unificada: incidencias locales (offline, pendientes de subir)
/// + espejo de la tabla central de Supabase. Crear, filtrar por estado,
/// cambiar estado con validación del servidor.
/// v1.2.5: [modoEntrenador] muestra solo compartidas + reportar (sin
/// resolver/reabrir ni privadas). El admin ve todo.
class SeccionIncidenciasScreen extends StatefulWidget {
  final bool modoEntrenador;
  const SeccionIncidenciasScreen({super.key, this.modoEntrenador = false});

  @override
  State<SeccionIncidenciasScreen> createState() =>
      _SeccionIncidenciasScreenState();
}

class _SeccionIncidenciasScreenState
    extends State<SeccionIncidenciasScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _cargando = true;
  String? _error;
  String _filtro = 'todas'; // todas, pendiente, en_revision, resuelta

  static const _tipos = {
    'stock': ('Stock', Icons.inventory_2),
    'rechazo': ('Rechazo', Icons.block),
    'sync': ('Sincronización', Icons.sync_problem),
    'foto': ('Foto', Icons.photo),
  };
  static const _estados = {
    'pendiente': ('Pendiente', 0xFFF57C00),
    'en_revision': ('En revisión', 0xFF1E88E5),
    'resuelta': ('Resuelta', 0xFF43A047),
  };

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    if (mounted) setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final db = LocalDb.instance;
      final items = <Map<String, dynamic>>[];
      // Locales aún no sincronizadas: origen 'local'
      final locales = await db.incidenciasLocales(sincronizada: false);
      for (final l in locales) {
        items.add({...l, '_origen': 'local'});
      }
      // Espejo central: origen 'central'
      final mirror = await db.incidenciasMirror();
      final idsLocales = locales.map((l) => l['id']).toSet();
      for (final m in mirror) {
        if (idsLocales.contains(m['id'])) continue; // evita duplicados
        // v1.2.5: en modo entrenador, defensa en profundidad (RLS ya
        // filtra en la descarga): nunca mostrar privadas.
        if (widget.modoEntrenador && m['visibilidad'] == 'privada') continue;
        items.add({...m, '_origen': 'central'});
      }
      // Orden: pendientes primero, luego por fecha desc
      const ordenEstado = {'pendiente': 0, 'en_revision': 1, 'resuelta': 2};
      items.sort((a, b) {
        final ea = ordenEstado[a['estado']] ?? 9;
        final eb = ordenEstado[b['estado']] ?? 9;
        if (ea != eb) return ea.compareTo(eb);
        return (b['creada_en'] ?? '').compareTo(a['creada_en'] ?? '');
      });
      if (!mounted) return;
      setState(() {
        _items = items;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _reportar() async {
    String tipo = 'sync';
    String visibilidad = 'compartida';
    final esAdmin = !widget.modoEntrenador && Permisos().esAdmin;
    final descCtrl = TextEditingController();
    // v1.2.5 (#8): restaura borrador si existe.
    const borradorKey = 'borrador_incidencia_nueva';
    try {
      final p = await SharedPreferences.getInstance();
      final b = p.getString(borradorKey);
      if (b != null && b.isNotEmpty) descCtrl.text = b;
    } catch (_) {}
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reportar incidencia'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: tipo,
                items: [
                  for (final e in _tipos.entries)
                    DropdownMenuItem(
                        value: e.key, child: Text(e.value.$1)),
                ],
                onChanged: (v) => tipo = v ?? 'sync',
                decoration: const InputDecoration(labelText: 'Tipo'),
              ),
              // v1.2.5: visibilidad solo para el dueño.
              if (esAdmin) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: visibilidad,
                  items: const [
                    DropdownMenuItem(
                        value: 'compartida',
                        child: Text('Compartida (la ven entrenadores)')),
                    DropdownMenuItem(
                        value: 'privada',
                        child: Text('Privada (solo yo)')),
                  ],
                  onChanged: (v) => visibilidad = v ?? 'compartida',
                  decoration:
                      const InputDecoration(labelText: 'Visibilidad'),
                ),
              ],
              const SizedBox(height: 12),
              // v1.2.5 (#7): plantillas de notas.
              FutureBuilder<List<String>>(
                future: _plantillas(),
                builder: (ctx, snap) {
                  final pls = snap.data ?? const <String>[];
                  if (pls.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Wrap(
                      spacing: 6,
                      children: [
                        for (final pl in pls)
                          ActionChip(
                            label: Text(pl,
                                style: const TextStyle(fontSize: 11)),
                            onPressed: () {
                              final cur = descCtrl.text;
                              descCtrl.text = cur.isEmpty
                                  ? pl
                                  : '$cur\n$pl';
                            },
                          ),
                      ],
                    ),
                  );
                },
              ),
              TextField(
                controller: descCtrl,
                maxLines: 4,
                maxLength: 2000,
                decoration: const InputDecoration(
                  labelText: 'Descripción',
                  hintText: '¿Qué pasó?',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Se guarda en este dispositivo y se sincroniza '
                'cuando haya conexión.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar')),
        ],
      ),
    );
    final desc = descCtrl.text.trim();
    descCtrl.dispose();
    // v1.2.5 (#8): guarda borrador si se canceló con texto, limpia si se envió.
    try {
      final p = await SharedPreferences.getInstance();
      if (ok == true) {
        await p.remove(borradorKey);
      } else if (desc.isNotEmpty) {
        await p.setString(borradorKey, desc);
      }
    } catch (_) {}
    if (ok != true) {
      return;
    }
    if (desc.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('La descripción no puede estar vacía')));
      }
      return;
    }
    try {
      await SyncEngine.instance.reportarIncidencia(
          tipo: tipo, descripcion: desc, visibilidad: visibilidad);
      await _cargar();
      // v1.2.6 (Gemini): confirmación háptica en acción crítica.
      await vibrarConfirmacion();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Incidencia guardada ⏳ (se sincronizará)')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  /// v1.2.5 (#7): plantillas personales de notas.
  Future<List<String>> _plantillas() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getStringList('plantilla_nota_incidencia') ?? const [];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _verDetalle(Map<String, dynamic> inc) async {
    // v1.2.5: en modo entrenador no hay acciones de admin aunque el
    // Permisos() diga otra cosa (defensa en profundidad).
    final esAdmin = !widget.modoEntrenador && Permisos().esAdmin;
    final estado = inc['estado'] as String? ?? 'pendiente';
    final tipoInfo = _tipos[inc['tipo']] ?? ('Otro', Icons.help_outline);
    final notaField = TextEditingController();
    final motivoField = TextEditingController();
    // v1.2.5 (#9): motivo obligatorio al reabrir.
    bool mostrarMotivo = false;
    final accion = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) => AlertDialog(
          title: Row(
            children: [
              Icon(tipoInfo.$2, color: AppColores.naranja),
              const SizedBox(width: 8),
              Expanded(child: Text(tipoInfo.$1)),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(inc['descripcion'] ?? '',
                    style: const TextStyle(fontSize: 15)),
                const SizedBox(height: 12),
                _filaDetalle('Estado', _estados[estado]?.$1 ?? estado),
                _filaDetalle('Reportada por', inc['creada_por'] ?? '—'),
                _filaDetalle('Fecha', (inc['creada_en'] ?? '').toString().substring(0, 16)),
                if (inc['_origen'] == 'local')
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('⏳ En este dispositivo, pendiente de subir',
                        style: TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                if ((inc['resuelta_por'] ?? '').toString().isNotEmpty) ...[
                  _filaDetalle('Resuelta por', inc['resuelta_por']),
                  _filaDetalle('Nota', inc['nota_resolucion'] ?? '—'),
                ],
                // v1.2.5 (#6): historial de cambios (eventos autoritativos).
                const SizedBox(height: 12),
                const Text('Historial',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                FutureBuilder<List<Map<String, dynamic>>>(
                  future: LocalDb.instance
                      .eventosMirror(inc['id'] as String),
                  builder: (ctx, snap) {
                    if (!snap.hasData) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                      );
                    }
                    final evs = snap.data!;
                    if (evs.isEmpty) {
                      return const Text(
                          'Sin eventos registrados aún.',
                          style: TextStyle(fontSize: 12, color: Colors.grey));
                    }
                    return Column(
                      children: [
                        for (final ev in evs)
                          _filaEvento(ev),
                      ],
                    );
                  },
                ),
                if (estado == 'en_revision' && esAdmin) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: notaField,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Nota de resolución (obligatoria)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
                // v1.2.5 (#9): motivo obligatorio al reabrir.
                if (mostrarMotivo) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: motivoField,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Motivo de reapertura (obligatorio)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, null),
                child: const Text('Cerrar')),
            if (estado == 'pendiente')
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'en_revision'),
                  child: const Text('Tomar (en revisión)')),
            if (estado == 'en_revision' && esAdmin)
              FilledButton(
                  onPressed: () => Navigator.pop(
                      ctx, 'resuelta:${notaField.text}'),
                  child: const Text('Resolver')),
            if (estado == 'resuelta' && esAdmin && !mostrarMotivo)
              FilledButton(
                  onPressed: () => setSt(() => mostrarMotivo = true),
                  child: const Text('Reabrir')),
            // v1.2.5 (#9): confirma la reapertura con el motivo escrito.
            if (estado == 'resuelta' && esAdmin && mostrarMotivo)
              FilledButton(
                  onPressed: () => Navigator.pop(
                      ctx, 'reabrir:${motivoField.text}'),
                  child: const Text('Confirmar reapertura')),
          ],
          ),
        );
      },
    );
    notaField.dispose();
    motivoField.dispose();
    if (accion == null || !mounted) return;
    // v1.2.5 (#9): confirmación explícita antes de resolver.
    if (accion.startsWith('resuelta:')) {
      final confirma = await showDialog<bool>(
        context: context,
        builder: (c2) => AlertDialog(
          title: const Text('¿Resolver incidencia?'),
          content: const Text(
              'Se marcará como resuelta y los entrenadores verán el cambio.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c2, false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.pop(c2, true),
                child: const Text('Sí, resolver')),
          ],
        ),
      );
      if (confirma != true || !mounted) return;
    }
    try {
      if (accion == 'en_revision') {
        await SyncEngine.instance.cambiarEstadoIncidencia(
            id: inc['id'] as String, nuevoEstado: 'en_revision');
      } else if (accion.startsWith('resuelta:')) {
        final nota = accion.substring('resuelta:'.length).trim();
        if (nota.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Resolver exige una nota de resolución')));
          }
          return;
        }
        await SyncEngine.instance.cambiarEstadoIncidencia(
            id: inc['id'] as String,
            nuevoEstado: 'resuelta',
            notaResolucion: nota);
      } else if (accion.startsWith('reabrir:')) {
        // v1.2.5 (#9): motivo obligatorio al reabrir (el servidor lo valida).
        final motivo = accion.substring('reabrir:'.length).trim();
        if (motivo.isEmpty) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Reabrir exige un motivo')));
          }
          return;
        }
        await SyncEngine.instance.cambiarEstadoIncidencia(
            id: inc['id'] as String,
            nuevoEstado: 'en_revision',
            notaResolucion: motivo);
      }
      // Sincroniza para que el servidor valide as soon as possible
      unawaited(SyncEngine.instance.push());
      await _cargar();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Cambio encolado ⏳')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  /// v1.2.5: fila del timeline de eventos autoritativos.
  Widget _filaEvento(Map<String, dynamic> ev) {
    final accion = '${ev['accion'] ?? ''}';
    final actor = '${ev['actor_nombre'] ?? ''}';
    final fecha = '${ev['creada_en'] ?? ''}';
    final fechaCorta = fecha.length >= 16 ? fecha.substring(0, 16) : fecha;
    final nota = '${ev['nota'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.circle, size: 8, color: AppColores.naranja),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$accion · $actor',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
                Text(fechaCorta,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
                if (nota.isNotEmpty)
                  Text(nota, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filaDetalle(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 110,
              child: Text(etiqueta,
                  style:
                      const TextStyle(fontSize: 12, color: Colors.grey))),
          Expanded(child: Text(valor, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtradas = _filtro == 'todas'
        ? _items
        : _items.where((i) => i['estado'] == _filtro).toList();
    final pendientes =
        _items.where((i) => i['estado'] == 'pendiente').length;
    return Scaffold(
      appBar: AppBar(
        title: Text('I · Incidencias${pendientes > 0 ? ' ($pendientes)' : ''}'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Recargar',
              onPressed: _cargar),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _reportar,
        icon: const Icon(Icons.add_alert),
        label: const Text('Reportar'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'todas', label: Text('Todas')),
                ButtonSegment(value: 'pendiente', label: Text('Pendientes')),
                ButtonSegment(value: 'en_revision', label: Text('En rev.')),
                ButtonSegment(value: 'resuelta', label: Text('Resueltas')),
              ],
              selected: {_filtro},
              onSelectionChanged: (s) =>
                  setState(() => _filtro = s.first),
            ),
          ),
          Expanded(
            child: _cargando
                // v1.2.5 (3.1): skeleton en vez de spinner.
                ? const SingleChildScrollView(
                    padding: EdgeInsets.all(16),
                    child: SkeletonLista(items: 4),
                  )
                : _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.error_outline,
                                  size: 48, color: AppColores.error),
                              const SizedBox(height: 12),
                              Text('Error al cargar: $_error',
                                  textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                              BotonPrimario(
                                texto: 'Reintentar',
                                icono: Icons.refresh,
                                onPressed: _cargar,
                              ),
                            ],
                          ),
                        ),
                      )
                    : filtradas.isEmpty
                        ? const Center(
                            child: Text('Sin incidencias 🎉',
                                style: TextStyle(fontSize: 16)))
                        : RefreshIndicator(
                            onRefresh: _cargar,
                            child: ListView.builder(
                              padding: const EdgeInsets.fromLTRB(
                                  16, 8, 16, 80),
                              itemCount: filtradas.length,
                              itemBuilder: (ctx, i) {
                                final inc = filtradas[i];
                                final est = _estados[inc['estado']] ??
                                    ('—', 0xFF9E9E9E);
                                final t =
                                    _tipos[inc['tipo']] ??
                                        ('Otro', Icons.help_outline);
                                final esLocal =
                                    inc['_origen'] == 'local';
                                return Card(
                                  child: ListTile(
                                    leading: Icon(t.$2,
                                        color: AppColores.naranja),
                                    title: Text(
                                      (inc['descripcion'] ?? '').toString(),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 4),
                                        Row(
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8,
                                                      vertical: 2),
                                              decoration: BoxDecoration(
                                                color: Color(est.$2)
                                                    .withValues(alpha: 0.15),
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                              ),
                                              child: Text(
                                                est.$1,
                                                style: TextStyle(
                                                    fontSize: 11,
                                                    color: Color(est.$2),
                                                    fontWeight:
                                                        FontWeight.w600),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                '${inc['creada_por'] ?? '—'}'
                                                '${esLocal ? ' · ⏳ sin subir' : ''}',
                                                style: const TextStyle(
                                                    fontSize: 11,
                                                    color: Colors.grey),
                                                overflow:
                                                    TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                    trailing: const Icon(
                                        Icons.chevron_right),
                                    onTap: () => _verDetalle(inc),
                                  ),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

