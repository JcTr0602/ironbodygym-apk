/// Pantallas H del Panel (1.11.0): H1, H2, H4, H5.
///
/// - H1: ajustes del gym en un sitio. ENLAZA lo que ya tiene pantalla
///   (C6 precios, D6 especiales) y solo edita métodos aceptados y
///   textos base. Los cambios rigen hacia adelante, nunca reescriben
///   pagos pasados (los cobros guardan su monto congelado).
/// - H2: registro mensual, VISOR de solo lectura + «Copiar resumen en
///   Markdown». La app JAMÁS escribe el archivo maestro.
/// - H4: turnos desde el panel: enlaza al editor único de Turnos de
///   1.8.0 (HorarioTurnosScreen), no lo duplica.
/// - H5: copia de seguridad, EXPORTAR solo (sin restauración).
///   Antes de copiar: PRAGMA wal_checkpoint(TRUNCATE). NUNCA VACUUM.
///   Solo el .db, sin fotos personales. Aviso fijo de copia en frío
///   con el contador de ops pendientes visible ANTES de exportar.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../auth.dart';
import '../bloque2_resto.dart';
import '../localdb.dart';
import '../nomina_calc.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'horario_turnos.dart';
import 'panel_resto_caja.dart';
import 'tarifas_especiales.dart';

void _ir(BuildContext context, Widget pantalla) {
  Navigator.push(context, MaterialPageRoute(builder: (_) => pantalla));
}

// ---------------------------------------------------------------------------
// H1
// ---------------------------------------------------------------------------

class AjustesGymScreen extends StatefulWidget {
  const AjustesGymScreen({super.key});
  @override
  State<AjustesGymScreen> createState() => _AjustesGymScreenState();
}

class _AjustesGymScreenState extends State<AjustesGymScreen> {
  bool _cargando = true;
  final _metodosCtrl = TextEditingController();
  final _textosCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final aj = await LocalDb.instance.getAjustes();
    _metodosCtrl.text = '${aj['metodos_aceptados'] ?? 'efectivo, transferencia'}';
    _textosCtrl.text = '${aj['textos_base'] ?? ''}';
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _guardar() async {
    try {
      await guardarConfigGym({
        'metodos_aceptados': _metodosCtrl.text.trim(),
        'textos_base': _textosCtrl.text.trim(),
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Ajustes guardados y sincronizados')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(title: const Text('Ajustes del gym (H1)')),
          body: const Center(
              child: Text('Solo el dueño cambia ajustes.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes del gym (H1)')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Los precios y períodos NO se editan aquí: viven en '
                  'una sola pantalla (C6). Esto enlaza, no duplica.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 12),
                Tarjeta(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.tune,
                        color: AppColores.naranja),
                    title: const Text('Precios por método (C6)',
                        style: AppTexto.cuerpo),
                    trailing:
                        const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _ir(context, const PreciosMetodoScreen()),
                  ),
                ),
                Tarjeta(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.local_offer,
                        color: AppColores.naranja),
                    title: const Text('Tarifas especiales (D6)',
                        style: AppTexto.cuerpo),
                    trailing:
                        const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _ir(context, const TarifasScreen()),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _metodosCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Métodos aceptados',
                      helperText: 'Separados por coma, p. ej. efectivo, transferencia'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _textosCtrl,
                  maxLines: 4,
                  decoration: const InputDecoration(
                      labelText: 'Textos base',
                      helperText: 'Textos base de mensajes del gym'),
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                    onPressed: _guardar,
                    child: const Text('Guardar y sincronizar')),
                const SizedBox(height: 8),
                const Text(
                  'Los cambios rigen hacia adelante: ningún cobro ya '
                  'hecho cambia su monto.',
                  style: AppTexto.secundario,
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// H2
// ---------------------------------------------------------------------------

class RegistroMensualScreen extends StatefulWidget {
  const RegistroMensualScreen({super.key});
  @override
  State<RegistroMensualScreen> createState() =>
      _RegistroMensualScreenState();
}

class _RegistroMensualScreenState extends State<RegistroMensualScreen> {
  bool _cargando = true;
  ResumenIngresos? _resumen;
  int _pagaron = 0;
  String _mes = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final mes = mesHabanaActual();
    try {
      final filas = <FilaIngreso>[];
      for (final p in await LocalDb.instance.allMirror('pagos')) {
        final f = filaIngresoDesdeEspejo('pagos', p);
        if (f != null) filas.add(f);
      }
      for (final d in await LocalDb.instance.allMirror('pagos_diarios')) {
        final f = filaIngresoDesdeEspejo('pagos_diarios', d);
        if (f != null) filas.add(f);
      }
      for (final v in await LocalDb.instance.allMirror('ventas_suplementos')) {
        final f = filaIngresoDesdeEspejo('ventas_suplementos', v);
        if (f != null) filas.add(f);
      }
      for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
        final f = filaIngresoDesdeEspejo('servicio_ventas', v);
        if (f != null) filas.add(f);
      }
      final desde = '$mes-01';
      final hasta = hoyHabanaIso();
      final resumen = resumenIngresos(filas, desde, hasta);
      final pagaron = await NominaCalc.clientesQuePagaronElMes(mes);
      if (mounted) {
        setState(() {
          _mes = mes;
          _resumen = resumen;
          _pagaron = pagaron;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _resumen;
    final md = r == null
        ? ''
        : resumenMensualMarkdown(mes: _mes, ingresos: r, pagaron: _pagaron);
    return Scaffold(
      appBar: AppBar(title: const Text('Registro mensual (H2)')),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Visor de solo lectura. La copia maestra sigue siendo '
                  'el archivo Markdown que el dueño dicta: la app no '
                  'lo escribe ni lo modifica.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 12),
                if (r != null) ...[
                  Text('Mes: $_mes', style: AppTexto.titulo),
                  const SizedBox(height: 8),
                  Text('Efectivo: ${r.efectivo.toStringAsFixed(0)} CUP',
                      style: AppTexto.cuerpo),
                  Text(
                      'Transferencia: ${r.transferencia.toStringAsFixed(0)} CUP',
                      style: AppTexto.cuerpo),
                  Text('Total: ${r.total.toStringAsFixed(0)} CUP',
                      style: AppTexto.titulo),
                  const SizedBox(height: 8),
                  for (final c in kConceptosC5)
                    Text(
                        '${c[0].toUpperCase()}${c.substring(1)}: '
                        '${(r.porConcepto[c] ?? 0).toStringAsFixed(0)} CUP',
                        style: AppTexto.cuerpo),
                  const SizedBox(height: 8),
                  Text('Pagaron el mes: $_pagaron',
                      style: AppTexto.cuerpo),
                  const Text(
                    'Altas/bajas: se dictan en el archivo maestro (la '
                    'app no guarda fecha de alta en el espejo y no '
                    'inventa el número).',
                    style: AppTexto.secundario,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: md));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Resumen copiado. Pégalo en tu archivo.')));
                      }
                    },
                    child: const Text('Copiar resumen en Markdown'),
                  ),
                ] else
                  const Text('Sin datos.', style: AppTexto.secundario),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// H4
// ---------------------------------------------------------------------------

class TurnosPanelScreen extends StatelessWidget {
  const TurnosPanelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Turnos y horarios (H4)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'El editor de turnos es ÚNICO (1.8.0): esta pantalla lo '
            'enlaza, no lo duplica. Solo el dueño crea o edita turnos; '
            'el entrenador ve los suyos.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: 12),
          Tarjeta(
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule,
                  color: AppColores.naranja),
              title: const Text('Editor de turnos',
                  style: AppTexto.cuerpo),
              subtitle: const Text('Horarios y excepciones',
                  style: AppTexto.secundario),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => _ir(context, const HorarioTurnosScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// H5
// ---------------------------------------------------------------------------

class CopiaSeguridadScreen extends StatefulWidget {
  const CopiaSeguridadScreen({super.key});
  @override
  State<CopiaSeguridadScreen> createState() => _CopiaSeguridadScreenState();
}

class _CopiaSeguridadScreenState extends State<CopiaSeguridadScreen> {
  int _pendientes = -1;
  bool _exportando = false;

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

  Future<void> _exportar() async {
    setState(() => _exportando = true);
    try {
      final d = await LocalDb.instance.db;
      // Copia en frío: volcar el WAL a la BD antes de copiar, para
      // que el archivo no salga incompleto ni corrupto. NUNCA VACUUM
      // sobre la BD activa.
      await d.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      final dir = await getDatabasesPath();
      final origen = File(p.join(dir, 'ironbody.db'));
      final tmp = await Directory.systemTemp.createTemp('ironbody_backup');
      final destino = File(p.join(tmp.path, 'ironbody_backup.db'));
      await origen.copy(destino.path);
      await registrarAccionMantenimiento(
          'f5_exportar_copia', {'pendientes_al_exportar': _pendientes});
      await Share.shareXFiles([XFile(destino.path)],
          text: 'Copia de seguridad Iron Body Gym (solo BD, sin fotos).');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('No se pudo exportar: $e')));
      }
    } finally {
      if (mounted) setState(() => _exportando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: AppBar(title: const Text('Copia de seguridad (H5)')),
          body: const Center(
              child: Text('Exportar la BD es solo el dueño.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Copia de seguridad (H5)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(kAvisoCopiaFria, style: AppTexto.cuerpo),
                const SizedBox(height: 8),
                Text(
                  'Operaciones pendientes de subir ahora: '
                  '${_pendientes < 0 ? '—' : _pendientes}',
                  style: AppTexto.cuerpo,
                ),
                const SizedBox(height: 4),
                const Text(
                  'La copia incluye solo la base de datos, sin fotos '
                  'personales (las fotos ya viven en el servidor). No '
                  'hay botón de restaurar en esta versión.',
                  style: AppTexto.secundario,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _exportando ? null : _exportar,
            child: Text(_exportando ? 'Exportando…' : 'Exportar copia'),
          ),
        ],
      ),
    );
  }
}
