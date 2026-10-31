/// Subpantallas de los módulos de Administración (1.14: sin letras A–G).
///
/// Cada sección agrupa contenido relacionado de la antigua pantalla
/// de scroll. El interior de cada sección conserva el diseño original;
/// solo se movió de lugar.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth.dart';
import '../app_log.dart';
import '../bloque2_resto.dart';
import '../config.dart';
import '../copia_seguridad.dart';
import '../errores_sync.dart';

import '../negocio.dart';
import '../localdb.dart';
import '../sync.dart';
import '../tipos_pago.dart';
import '../tiempo.dart';
import '../ultimo_sync.dart';
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
      appBar: AppBar(title: const Text('Resumen')),
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
  // 1.15 (H4): registrar una recogida (total o parcial) desde el
  // pendiente, sin pasar por Arqueo.
  final Future<void> Function(
      {int? trainerId, required String nombre, required double pendiente})
      onRegistrarRecogida;
  final Future<void> Function(Widget) onIr;

  const SeccionCobrosScreen({
    super.key,
    required this.getCaja,
    required this.getGastosHoy,
    required this.getPend,
    required this.onConfirmarEntrega,
    required this.onRegistrarRecogida,
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

  Future<void> _registrarYActualizar(
      {int? trainerId,
      required String nombre,
      required double pendiente}) async {
    await widget.onRegistrarRecogida(
        trainerId: trainerId, nombre: nombre, pendiente: pendiente);
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
      appBar: AppBar(title: const Text('Cobros')),
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
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          child: const Text('Recogida'),
                          onPressed: () => _registrarYActualizar(
                              trainerId: t['id'] as int?,
                              nombre: '${t['nombre']}',
                              pendiente:
                                  (t['total'] as num?)?.toDouble() ?? 0),
                        ),
                        TextButton(
                          child: const Text('Confirmar'),
                          onPressed: () => _confirmarYActualizar(
                              trainerId: t['id'] as int?,
                              nombre: '${t['nombre']}'),
                        ),
                      ],
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
              context, Icons.account_balance_wallet_rounded, 'Vencidos por cobrar', [            Text(
              'Clientes vencidos ordenados por monto adeudado. El dinero dormido, visible.',
              style: TextStyle(
                  color: AppColores.textoSecundario(context),
                  fontSize: 12),
            ),
            const SizedBox(height: 8),
            BotonPrimario(
              texto: 'Ver vencidos por cobrar',
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
          // v1.8.0 (decisión de Jc): la tarjeta «Usuarios APK /
          // Gestionar usuarios» salió de esta sección — aquí ya no
          // tenía sentido. La pantalla sigue viva desde Control de
          // Acceso (control_acceso.dart).
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
      appBar: AppBar(title: const Text('Gastos')),
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
      appBar: AppBar(title: const Text('Suplementos')),
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
  // Módulo 6 (estado único): filas de sync por teléfono, antes en
  // EstadoSyncScreen (F4). Solo se muestran al dueño.
  List<Map<String, dynamic>> _ultimoSync = [];
  // Módulo 6 (datos visibles): últimos eventos de carga/purga.
  List<Map<String, dynamic>> _eventosCarga = [];
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
            // v1.8.0: misma traducción que el estado por tabla.
            final errFoto =
                (f['ultimo_error'] ?? f['error'])?.toString() ?? '';
            datos['Foto cola #$i'] =
                'id=${f['id']} cliente=${f['cliente_id'] ?? f['suplemento_id'] ?? '-'} '
                'estado=${f['estado']} intentos=${f['intentos']} '
                'error=${errFoto.isEmpty ? '-' : resumenErrorDiagnostico(errFoto)}';
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
          // v1.8.0: el error crudo (ClientException truncada, etc.)
          // no se entiende; se pinta la frase corta traducida. El
          // texto técnico sigue guardado en wm_err_ para soporte.
          estado = 'ERROR: ${resumenErrorDiagnostico(err)}';
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
      // Módulo 6 (estado único): sync por teléfono. Si falla, la
      // sección queda vacía pero el resto del diagnóstico se muestra.
      List<Map<String, dynamic>> ultimoSync = [];
      try {
        ultimoSync = await ultimoSyncPorTelefono();
      } catch (_) {
        ultimoSync = [];
      }
      // Módulo 6 (datos visibles): últimos eventos de carga/purga.
      // Si falla la lectura, la sección queda vacía.
      List<Map<String, dynamic>> eventosCarga = [];
      try {
        final recientes = await AppLog.eventosRecientes(limite: 200);
        const claves = {
          'purga_reconciliacion',
          'purga_omitida',
          'cargar_fallo',
        };
        eventosCarga = recientes
            .where((f) => claves.contains('${f['evento']}'))
            .take(10)
            .toList();
      } catch (_) {
        eventosCarga = [];
      }
      setState(() {
        _datos = datos;
        _ultimoError = (lastErr?.isNotEmpty ?? false) ? lastErr : null;
        _ultimoSync = ultimoSync;
        _eventosCarga = eventosCarga;
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

  /// v1.13.0 (G4): «Reparar lista de clientes» — re-descarga
  /// completa del espejo clientes (bandera forzar_redescarga +
  /// scope 'clientes'). Con ops pendientes, se NIEGA (primero hay
  /// que subir la cola: purgar con una op en vuelo podría borrar
  /// un cliente recién creado que aún no subió) y se ofrece subir.
  /// La bandera la consume el pull DESPUÉS de validar la purga
  /// (G4: si la purga se omite, la bandera sobrevive).
  Future<void> _repararClientes() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Reparar lista de clientes',
        iconoTitulo: Icons.build,
        contenido: const Text(
          'Vuelve a descargar la lista completa de clientes desde '
          'el servidor (para cuando la lista local quedó desfasada '
          'o con clientes que ya no existen). No borra tus '
          'operaciones pendientes.',
        ),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Reparar'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final pendientes = await LocalDb.instance.countPendingOps();
    if (pendientes > 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
              'Primero sube la cola: hay operaciones pendientes.'),
          action: SnackBarAction(
            label: 'Subir cola',
            onPressed: () async {
              await SyncEngine.instance.push();
              await _cargar();
            },
          ),
        ),
      );
      return;
    }
    try {
      await LocalDb.instance
          .setMeta('forzar_redescarga_clientes', '1');
      AppLog.info('sync', 'reparar_clientes_ini');
      await SyncEngine.instance.sincronizarScope('clientes');
      AppLog.info('sync', 'reparar_clientes_fin');
      await _cargar();
      // 1.14 (Fix 3): sincronizarScope traga los errores y la purga
      // puede omitirse (una op apareció tras el push, o el pull
      // falló), dejando la bandera viva. No anunciar éxito si no
      // purgó: la bandera sobrevive y el próximo ciclo con la cola
      // limpia reintenta la purga solo.
      final banderaViva =
          await LocalDb.instance.getMeta('forzar_redescarga_clientes') ==
              '1';
      final colaSucia = await LocalDb.instance.countPendingOps() > 0;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(banderaViva || colaSucia
                ? 'No se completó la purga (la cola no quedó limpia). '
                    'Quedó pendiente y se reintentará sola en la '
                    'próxima sincronización.'
                : 'Lista de clientes reparada.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('No se pudo reparar: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnóstico'),
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
                  // Módulo 6 (estado único): sync por teléfono, antes
                  // en EstadoSyncScreen (F4). Solo el dueño ve otros
                  // teléfonos; es dato de todos los usuarios.
                  if (AuthService().isOwner)
                    seccionAdmin(
                        context, Icons.phone_android, 'Teléfonos con sync vieja', [
                      const Text(
                        'Espejo sync_ultimo_sync: última sync '
                        'efectiva por usuario (solo cuentan las '
                        'operaciones aplicadas).',
                        style: AppTexto.secundario,
                      ),
                      const SizedBox(height: 8),
                      if (_ultimoSync.isEmpty)
                        const Text(
                          'Sin registro de sync todavía: ningún '
                          'usuario sincronizó con éxito aún.',
                          style: AppTexto.secundario,
                        )
                      else
                        ..._ultimoSync.map((f) => Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text('${f['nombre']}',
                                        style: AppTexto.cuerpo),
                                  ),
                                  Text(
                                    etiquetaUltimoSync(
                                        f, ahoraHabana()),
                                    style: AppTexto.secundario,
                                  ),
                                ],
                              ),
                            )),
                    ]),
                  if (_ultimoError != null)
                    seccionAdmin(context, Icons.error_outline, 'Último error', [
                      Text(_ultimoError!,
                          style: const TextStyle(
                              color: AppColores.error, fontSize: 13)),
                    ]),
                  // Módulo 6 (datos visibles): si una pantalla
                  // muestra cero pero los conteos de arriba traen
                  // datos, el problema es de carga, no de sync.
                  // Es dato de este teléfono: sin guarda de dueño.
                  seccionAdmin(
                      context, Icons.visibility, 'Datos visibles', [
                    const Text(
                      'Conteos de arriba = datos en la base de este '
                      'teléfono. Si una pantalla muestra cero con '
                      'conteos mayores que cero, falló la carga, '
                      'no la sincronización. Últimos eventos:',
                      style: AppTexto.secundario,
                    ),
                    const SizedBox(height: 8),
                    if (_eventosCarga.isEmpty)
                      const Text(
                        'Sin eventos de carga o purga recientes.',
                        style: AppTexto.secundario,
                      )
                    else
                      ..._eventosCarga.map((f) => Padding(
                            padding:
                                const EdgeInsets.only(bottom: 6),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                      '${f['modulo']}.${f['evento']}',
                                      style: AppTexto.cuerpo),
                                ),
                                Text(
                                  _fmt('${f['ts']}'),
                                  style: AppTexto.secundario,
                                ),
                              ],
                            ),
                          )),
                  ]),
                  // v1.13.0 (G4): reparar la lista de clientes.
                  seccionAdmin(
                      context, Icons.build_circle_outlined, 'Reparar lista', [
                    Text(
                      'Si la lista de clientes quedó desfasada, '
                      're-descárgala completa desde el servidor.',
                      style: TextStyle(
                          color: AppColores.textoSecundario(context),
                          fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    BotonPrimario(
                      texto: 'Reparar lista de clientes',
                      icono: Icons.build,
                      onPressed: _repararClientes,
                    ),
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

// ---------------------------------------------------------------------------
// Módulo 6 (historial de sync): últimos eventos del módulo 'sync'
// de la bitácora (subidas, bajadas, purgas, fallos). Es la vista
// completa; el resumen de fallos vive en Diagnóstico y en la
// tarjeta de Último error del módulo.
// ---------------------------------------------------------------------------

class HistorialSyncScreen extends StatefulWidget {
  const HistorialSyncScreen({super.key});
  @override
  State<HistorialSyncScreen> createState() => _HistorialSyncScreenState();
}

class _HistorialSyncScreenState extends State<HistorialSyncScreen> {
  List<Map<String, dynamic>> _eventos = [];
  bool _cargando = true;
  // G1: si la lectura falla, no mostrar «sin eventos» (mentira):
  // error honesto con Reintentar.
  bool _fallo = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _fallo = false);
    try {
      final eventos =
          await AppLog.eventosRecientes(limite: 100, modulo: 'sync');
      if (!mounted) return;
      setState(() {
        _eventos = eventos;
        _cargando = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _fallo = true;
        _cargando = false;
      });
    }
  }

  String _ts(String ts) =>
      ts.length > 16 ? ts.substring(0, 16).replaceFirst('T', ' ') : ts;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Historial de sync'),
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Leyendo historial…')
          : _fallo
              ? EstadoError(
                  titulo: 'No se pudo leer el historial',
                  detalle: 'La lectura falló; no significa que no haya '
                      'eventos. Inténtalo de nuevo.',
                  onReintentar: _cargar,
                )
              : _eventos.isEmpty
              ? const Center(
                  child: Text('Sin eventos de sync recientes.'))
              : RefreshIndicator(
                  onRefresh: _cargar,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _eventos.length,
                    itemBuilder: (context, i) {
                      final f = _eventos[i];
                      final nivel = '${f['nivel']}';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text('${f['evento']}',
                                      style: AppTexto.cuerpo),
                                ),
                                Text(
                                  _ts('${f['ts']}'),
                                  style: AppTexto.secundario,
                                ),
                              ],
                            ),
                            Text(nivel, style: AppTexto.secundario),
                            if (f['detalle'] != null)
                              Text('${f['detalle']}',
                                  style: AppTexto.secundario,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis),
                          ],
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}

/// Módulo 6 (1.19): verificación del espejo, con alcance declarado.
///
/// Compara la CANTIDAD de filas locales por tabla antes y después de
/// un ciclo forzado de sync. Si una tabla cambia, el espejo estaba
/// desfasado y ya bajó lo nuevo; si no cambia, no hay desfase de
/// cantidad. Alcance honesto (ajuste Terra): conteos iguales NO
/// certifican integridad — dos espejos con el mismo número de filas
/// pueden diferir en contenido. Esta pantalla detecta desfases de
/// cantidad, no de contenido, y no es una reparación.
/// AU1 (estéticas 1.19): delta de filas entre dos conteos del
/// espejo — null si no hay antes o si no cambió (puro).
String? textoDeltaEspejo(int? antes, int? despues) {
  if (antes == null || despues == null) return null;
  final d = despues - antes;
  if (d == 0) return null;
  return d > 0 ? '+$d' : '$d';
}

class VerificacionEspejoScreen extends StatefulWidget {
  const VerificacionEspejoScreen({super.key});
  @override
  State<VerificacionEspejoScreen> createState() =>
      _VerificacionEspejoScreenState();
}

class _VerificacionEspejoScreenState
    extends State<VerificacionEspejoScreen> {
  static const _tablas = [
    'clientes',
    'pagos',
    'pagos_diarios',
    'ventas_suplementos',
    'servicio_ventas',
    'reservas',
    'gympedia_solicitudes',
    'permisos_bandeja',
    'espejo_gympedia_borradores',
    'avisos_entrenadores',
  ];

  bool _cargando = true;
  bool _verificando = false;
  // G1: si la lectura inicial falla, no pintar la tabla vacía
  // (parece «todo en cero»): error honesto con Reintentar.
  bool _fallo = false;
  Map<String, int?> _conteos = {};
  Map<String, int?> _antes = {};
  String? _ultimaPull;
  String? _errorSync;
  int _pendientes = 0;
  String? _resultado;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<Map<String, int?>> _contar() async {
    final mapa = <String, int?>{};
    for (final t in _tablas) {
      try {
        mapa[t] = (await LocalDb.instance.allMirror(t)).length;
      } catch (_) {
        mapa[t] = null;
      }
    }
    return mapa;
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _fallo = false;
    });
    try {
      final conteos = await _contar();
      final det = await SyncEngine.instance.detalle();
      final pend = await LocalDb.instance.countPendingOps();
      if (!mounted) return;
      setState(() {
        _conteos = conteos;
        _ultimaPull = det.ultimaPull?.toIso8601String();
        _errorSync = det.error;
        _pendientes = pend;
        _cargando = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _fallo = true;
          _cargando = false;
        });
      }
    }
  }

  Future<void> _verificar() async {
    setState(() {
      _verificando = true;
      _resultado = null;
    });
    try {
      final antes = await _contar();
      await SyncEngine.instance.run(forzar: true);
      final despues = await _contar();
      // Argón Gmail_1-14 #2 + Q7: run() captura los errores
      // internamente, así que sin refrescar la cabecera seguía
      // mostrando contadores y errores viejos, y un ciclo fallido
      // por red se leía como «sin cambios». Se refresca detalle
      // y pendientes, y el resultado avisa si hubo error.
      final det = await SyncEngine.instance.detalle();
      final pend = await LocalDb.instance.countPendingOps();
      var cambiadas = 0;
      var desconocidas = 0;
      for (final t in _tablas) {
        if (antes[t] == null || despues[t] == null) {
          desconocidas++;
        } else if (antes[t] != despues[t]) {
          cambiadas++;
        }
      }
      if (!mounted) return;
      // Panel Terra (alta): null == null NO es «sin cambios», y un
      // cambio local NO prueba que el espejo previo estuviera
      // desfasado contra el servidor (el servidor pudo cambiar
      // entre lecturas, o el ciclo no completarse). El resultado
      // describe solo cambios locales observados + lo desconocido.
      setState(() {
        _antes = antes;
        _conteos = despues;
        _ultimaPull = det.ultimaPull?.toIso8601String();
        _errorSync = det.error;
        _pendientes = pend;
        _resultado = [
          if (det.error != null && det.error!.isNotEmpty)
            'El ciclo registró un error: ${det.error}. Los conteos '
                'pueden no reflejar un ciclo completo.',
          if (desconocidas > 0)
            'Verificación parcial: $desconocidas tabla(s) no se '
                'pudieron contar y no entran en el resultado.',
          if (cambiadas == 0 && desconocidas == 0)
            'Sin cambios locales de cantidad tras el ciclo. Esto '
                'no certifica contenido: dos espejos con el mismo '
                'número de filas pueden diferir dentro.',
          if (cambiadas > 0)
            'Cambios locales observados en $cambiadas tabla(s) '
                'tras el ciclo (cada fila muestra su delta). El '
                'espejo local ya trae lo nuevo.',
        ].join('\n');
      });
    } catch (e) {
      if (mounted) {
        setState(() => _resultado = 'No se pudo verificar: $e');
      }
    } finally {
      if (mounted) setState(() => _verificando = false);
    }
  }

  String _ts(String? iso) {
    if (iso == null || iso.length < 16) return '—';
    return iso.substring(0, 16).replaceFirst('T', ' ');
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(title: const Text('Verificación del espejo')),
          body: const Center(
              child: Text('Verificar el espejo es solo el dueño.')));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verificación del espejo'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _cargar,
              tooltip: 'Actualizar'),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Contando espejos…')
          : _fallo
              ? EstadoError(
                  titulo: 'No se pudo contar el espejo',
                  detalle: 'La lectura falló; los conteos en cero no '
                      'son reales. Inténtalo de nuevo.',
                  onReintentar: _cargar,
                )
              : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Tarjeta(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Última bajada: ${_ts(_ultimaPull)}',
                          style: AppTexto.cuerpo),
                      Text('Ops pendientes de subir: $_pendientes',
                          style: AppTexto.cuerpo),
                      if (_errorSync != null &&
                          _errorSync!.isNotEmpty)
                        Text('Último error: $_errorSync',
                            style: AppTexto.cuerpo),
                      const SizedBox(height: 6),
                      const Text(
                        'Alcance: conteos iguales no certifican '
                        'integridad. Esta pantalla detecta desfases '
                        'de cantidad, no de contenido.',
                        style: AppTexto.secundario,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (_resultado != null) ...[
                  Tarjeta(
                    child: Text(_resultado!, style: AppTexto.cuerpo),
                  ),
                  const SizedBox(height: 12),
                ],
                for (final t in _tablas)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Tarjeta(
                      child: Builder(builder: (_) {
                        // AU1: delta explícito con color (verde
                        // llegaron, ámbar se fueron).
                        final delta = textoDeltaEspejo(
                            _antes[t], _conteos[t]);
                        return Row(
                          children: [
                            Expanded(
                              child:
                                  Text(t, style: AppTexto.subtitulo),
                            ),
                            if (_conteos[t] == null)
                              const Text('sin espejo',
                                  style: AppTexto.cuerpo)
                            else ...[
                              Text('${_conteos[t]} filas',
                                  style: AppTexto.cuerpo),
                              if (delta != null) ...[
                                const SizedBox(width: 8),
                                Text(
                                  delta,
                                  style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: delta.startsWith('+')
                                          ? AppColores.exito
                                          : AppColores.alerta),
                                ),
                              ],
                            ],
                          ],
                        );
                      }),
                    ),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _verificando ? null : _verificar,
                  child: Text(_verificando
                      ? 'Verificando…'
                      : 'Verificar ahora (sube y baja)'),
                ),
              ],
            ),
    );
  }
}

/// Módulo 6 (1.19): bajada completa SEGURA (21/25).
///
/// La primitiva `SyncEngine.bajadaCompleta` re-descarga todos los
/// espejos desde 0 SIN borrar nada antes: si la bajada falla a
/// mitad, los datos viejos quedan intactos y las banderas
/// reintentan solas en el próximo ciclo. La purga de filas que ya
/// no están en el servidor solo corre con las guardas H-03 (cola
/// limpia + serverSeq estable); con pendientes, el pull trae lo
/// nuevo pero no purga, y el resultado lo dice. Las ops pendientes,
/// los borradores y los datos locales nunca se tocan. Si el espejo
/// se ve vacío, primero Diagnóstico de datos visibles: en el
/// incidente del 30/10 era un fallo de carga, no de sync.
class BajadaCompletaScreen extends StatefulWidget {
  const BajadaCompletaScreen({super.key});
  @override
  State<BajadaCompletaScreen> createState() =>
      _BajadaCompletaScreenState();
}

class _BajadaCompletaScreenState extends State<BajadaCompletaScreen> {
  int _pendientes = -1;
  bool _copiaEnSesion = false;
  bool _ocupado = false;
  String? _resultadoBajada;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final p = await LocalDb.instance.countPendingOps();
      if (mounted) setState(() => _pendientes = p);
    } catch (_) {}
  }

  void _snack(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(texto)));
  }

  Future<void> _subir() async {
    setState(() => _ocupado = true);
    try {
      await SyncEngine.instance.run(forzar: true);
      await _cargar();
      _snack('Ciclo forzado terminado. Revisa los pendientes.');
    } catch (e) {
      _snack('No se pudo subir: $e');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  Future<void> _copiar() async {
    setState(() => _ocupado = true);
    try {
      await exportarCopiaFria();
      await registrarAccionMantenimiento(
          'f6_copia_pre_bajada', {'pendientes': _pendientes});
      if (mounted) setState(() => _copiaEnSesion = true);
      _snack('Copia local creada y registrada.');
    } catch (e) {
      _snack('No se pudo crear la copia: $e');
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  /// 21/25: baja todo de nuevo con la primitiva segura.
  Future<void> _bajar() async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Bajar todo de nuevo',
      mensaje: 'Vuelve a descargar todos los espejos desde el '
          'servidor. No borra tus operaciones pendientes, tus '
          'borradores ni ningún dato local: si la bajada falla a '
          'mitad, lo viejo queda intacto y se reintenta solo. Si '
          'hay operaciones sin subir, la limpieza de filas viejas '
          'queda para el próximo ciclo.',
      aceptar: 'Bajar todo',
      icono: Icons.download_rounded,
    );
    if (!ok) return;
    setState(() {
      _ocupado = true;
      _resultadoBajada = null;
    });
    try {
      final r = await SyncEngine.instance.bajadaCompleta();
      await _cargar();
      if (mounted) {
        setState(
            () => _resultadoBajada = resumenBajadaCompleta(r).join('\n'));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _resultadoBajada =
            'No se pudo bajar: $e. Las banderas quedaron marcadas y '
            'el próximo ciclo reintenta solo.');
      }
    } finally {
      if (mounted) setState(() => _ocupado = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(title: const Text('Bajada completa')),
          body: const Center(
              child: Text('La bajada completa es solo el dueño.')));
    }
    final sinPendientes = _pendientes == 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Bajada completa')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Antes de una bajada completa',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 6),
                Text(
                  '${sinPendientes ? '✓' : '○'} Sin pendientes de subir '
                  '(${_pendientes < 0 ? '—' : _pendientes})',
                  style: AppTexto.cuerpo,
                ),
                Text(
                  '${_copiaEnSesion ? '✓' : '○'} Copia local creada '
                  'en esta sesión',
                  style: AppTexto.cuerpo,
                ),
                const Text(
                  '✓ Primitiva segura del motor: re-descarga sin '
                  'borrar pendientes ni datos locales (21/25).',
                  style: AppTexto.cuerpo,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: (_ocupado || sinPendientes) ? null : _subir,
            child: Text(_ocupado
                ? 'Trabajando…'
                : 'Subir pendientes ahora'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _ocupado ? null : _copiar,
            child: const Text('Crear copia local'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _ocupado ? null : _bajar,
            child: Text(_ocupado
                ? 'Trabajando…'
                : 'Bajar todo de nuevo'),
          ),
          if (_resultadoBajada != null) ...[
            const SizedBox(height: 12),
            Tarjeta(
              child: Text(_resultadoBajada!, style: AppTexto.cuerpo),
            ),
          ],
          const SizedBox(height: 16),
          const Tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Cómo es segura esta bajada',
                    style: AppTexto.subtitulo),
                SizedBox(height: 6),
                Text(
                  'No borra los espejos antes de bajar: re-descarga '
                  'cada tabla desde 0 y aplica por encima de lo '
                  'viejo. Solo al final, con la pasada completa y '
                  'la cola limpia, se purgan las filas que ya no '
                  'están en el servidor. Si algo falla, lo viejo '
                  'queda y el próximo ciclo reintenta solo. Subir '
                  'los pendientes primero es recomendable (así la '
                  'limpieza no queda diferida), pero no obligatorio.',
                  style: AppTexto.cuerpo,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
