/// Pantalla G2 (1.11.0): recordatorios automáticos.
///
/// - Arriba: los vencidos HOY, con su estado (ya disparado / puedo
///   disparar / lo dispara el dueño). Disparar escribe el log
///   anti-duplicado; un masivo solo se dispara en el teléfono del
///   dueño (los demás lo ven como «lo dispara el dueño»).
/// - Abajo: las configuraciones, con crear / activar / eliminar.
///   Un entrenador solo puede crear «solo para mí» (el selector de
///   alcance no le ofrece «todos»); solo el dueño toca los de otros.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart' show fmtFecha;
import '../notificaciones_recordatorios.dart';
import '../recordatorios.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';

class RecordatoriosScreen extends StatefulWidget {
  const RecordatoriosScreen({super.key});
  @override
  State<RecordatoriosScreen> createState() => _RecordatoriosScreenState();
}

class _RecordatoriosScreenState extends State<RecordatoriosScreen> {
  bool _cargando = true;
  List<RecordatorioDebido> _debidos = [];
  List<Map<String, dynamic>> _configs = [];

  /// 1.22 R-9: permiso de notificaciones denegado (las
  /// alarmas se programan pero Android no las muestra).
  bool _sinPermisoNotif = false;

  bool get _soyDueno => AuthService().isOwner;
  int? get _yo => AuthService().telegramId;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final debidos =
          await RecordatoriosService.instance.debidosHoy();
      final configs = await LocalDb.instance.listarRecordatorios();
      // Corrección panel 1.11 (MEDIO): los «solo_mio» de otros
      // creadores NO se listan aquí (debidosHoy ya los filtraba;
      // esta lista no). Sin filtro, un entrenador veía títulos,
      // tipos y estado privados ajenos con botones pausar/eliminar.
      final visibles = configs
          .where((c) =>
              '${c['alcance']}' != 'solo_mio' ||
              _soyDueno ||
              c['creado_por'] == _yo)
          .toList();
      final permiso = await AvisosRecordatorios.tienePermiso();
      if (mounted) {
        setState(() {
          _debidos = debidos;
          _configs = visibles;
          _sinPermisoNotif = !permiso;
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _disparar(RecordatorioDebido d) async {
    final ok = await RecordatoriosService.instance.disparar(d);
    if (ok) {
      // 23/25: ya se atendió hoy: cancelar su aviso programado.
      unawaited(AvisosRecordatorios.cancelarAviso(d));
    }
    if (!mounted) return;
    mostrarSnack(context, ok
            ? 'Recordatorio marcado como disparado hoy'
            : 'Ya estaba disparado hoy');
    await _cargar();
  }

  // 1.25 T122 (F6-05/F6-18): los subtítulos enseñaban el
  // enum crudo («personalizado · solo_mio · …»).
  String _tipoLegible(String tipo) =>
      const {
        'vencimiento': 'Vencimiento',
        'cumpleanos': 'Cumpleaños',
        'personalizado': 'Personalizado',
      }[tipo] ??
      tipo;

  String _alcanceLegible(String alcance) =>
      const {
        'solo_mio': 'solo para mí',
        'todos': 'para todos',
      }[alcance] ??
      alcance;

  Future<void> _crear() async {
    final tituloCtrl = TextEditingController();
    var tipo = 'vencimiento';
    var alcance = 'solo_mio';
    var dias = 3;
    var frecuencia = 'ninguna';
    // 1.25 T122 (F6-18): la fecha personalizada se ELIGE
    // con el selector del sistema, no se teclea como texto
    // YYYY-MM-DD (que fallaba por formato). El selector
    // siempre devuelve una fecha válida: la validación de
    // formato de Argón P2#15 ya no hace falta.
    var fechaSel = hoyHabanaIso();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => DialogoApp(
        titulo: 'Nuevo recordatorio',
        iconoTitulo: Icons.notifications_rounded,
        contenido: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                  controller: tituloCtrl,
                  decoration: const InputDecoration(
                      labelText: 'Título (p. ej. «Vence esta semana»')),
              const SizedBox(height: 8),
              DropdownButton<String>(
                value: tipo,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(
                      value: 'vencimiento', child: Text('Vencimiento')),
                  DropdownMenuItem(
                      value: 'cumpleanos', child: Text('Cumpleaños')),
                  DropdownMenuItem(
                      value: 'personalizado', child: Text('Personalizado')),
                ],
                onChanged: (v) =>
                    setDialogState(() => tipo = v ?? 'vencimiento'),
              ),
              if (_soyDueno) ...[
                const SizedBox(height: 8),
                DropdownButton<String>(
                  value: alcance,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                        value: 'solo_mio', child: Text('Solo para mí')),
                    DropdownMenuItem(
                        value: 'todos', child: Text('Para todos (masivo)')),
                  ],
                  onChanged: (v) =>
                      setDialogState(() => alcance = v ?? 'solo_mio'),
                ),
                const Text(
                  'Masivo: solo se dispara en tu teléfono; los demás '
                  'lo ven como ya disparado ese día.',
                  style: AppTexto.secundario,
                ),
              ] else
                const Text(
                  'Como entrenador, tus recordatorios son solo para ti.',
                  style: AppTexto.secundario,
                ),
              const SizedBox(height: 8),
              // Argón P2#15: el slider de días solo tiene sentido
              // para vencimiento/cumpleaños; el personalizado usa
              // fecha fija.
              if (tipo != 'personalizado') ...[
                Text('Días de anticipación (vencimiento): $dias'),
                Slider(
                    value: dias.toDouble(),
                    min: 0,
                    max: 14,
                    divisions: 14,
                    onChanged: (v) =>
                        setDialogState(() => dias = v.round())),
              ],
              if (tipo == 'personalizado') ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fecha', style: AppTexto.cuerpo),
                  subtitle: Text(fmtFecha(fechaSel),
                      style: AppTexto.secundario),
                  trailing: TextButton(
                    onPressed: () async {
                      final ini = DateTime.tryParse(fechaSel) ??
                          ahoraHabana();
                      final f = await showDatePicker(
                        context: ctx,
                        initialDate: ini,
                        firstDate: DateTime(2020),
                        lastDate: DateTime(2100),
                      );
                      if (f != null) {
                        setDialogState(() => fechaSel =
                            '${f.year.toString().padLeft(4, '0')}-'
                            '${f.month.toString().padLeft(2, '0')}-'
                            '${f.day.toString().padLeft(2, '0')}');
                      }
                    },
                    child: const Text('Elegir'),
                  ),
                ),
                const SizedBox(height: 8),
                // F4 (1.20): repetición del personalizado.
                DropdownButton<String>(
                  value: frecuencia,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                        value: 'ninguna', child: Text('Solo esa fecha')),
                    DropdownMenuItem(
                        value: 'semanal',
                        child: Text('Cada semana (ese día)')),
                    DropdownMenuItem(
                        value: 'mensual',
                        child: Text('Cada mes (ese día)')),
                  ],
                  onChanged: (v) => setDialogState(
                      () => frecuencia = v ?? 'ninguna'),
                ),
              ],
            ],
          ),
        ),
        acciones: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Crear')),
        ],
        ),
      ),
    );
    final titulo = tituloCtrl.text.trim();
    tituloCtrl.dispose();
    if (ok != true) return;
    if (titulo.isEmpty) return;
    try {
      await RecordatoriosService.instance.crear(
        titulo: titulo,
        tipo: tipo,
        alcance: _soyDueno ? alcance : 'solo_mio',
        diasAnticipacion: dias,
        fechaFija: tipo == 'personalizado' ? fechaSel : null,
        frecuencia: tipo == 'personalizado' ? frecuencia : 'ninguna',
      );
      await _cargar();
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, '$e', significado: SignificadoChip.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Recordatorios automáticos'),
      floatingActionButton: FloatingActionButton(
        onPressed: _crear,
        child: const Icon(Icons.add_rounded),
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando recordatorios…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                // 1.22 R-9: sin permiso, los avisos de las
                // 08:00 nunca se ven: avisar aquí, donde se
                // gestionan, con salto directo a Ajustes.
                if (_sinPermisoNotif) ...[
                  Tarjeta(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                          Icons.notifications_off_rounded,
                          color: AppColores.alerta),
                      title: const Text(
                          'Sin permiso de notificaciones',
                          style: AppTexto.cuerpo),
                      subtitle: const Text(
                          'Los avisos automáticos (08:00) no se '
                          'verán en este teléfono hasta activarlo.',
                          style: AppTexto.secundario),
                      trailing: TextButton(
                        onPressed: () => unawaited(AvisosRecordatorios
                            .abrirAjustesNotificaciones()),
                        child: const Text('Ajustes'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                // 1.25 T122 (F6-18): sin nada hoy NI
                // configurado, un solo EstadoVacio de
                // pantalla en vez de dos textos planos.
                if (_debidos.isEmpty && _configs.isEmpty)
                  const EstadoVacio(
                    icono: Icons.notifications_rounded,
                    titulo: 'Sin recordatorios',
                    subtitulo: 'Nada vence hoy y aún no hay '
                        'recordatorios configurados. Crea el '
                        'primero con el botón +.',
                  )
                else ...[
                const Text('Hoy', style: AppTexto.titulo),
                const SizedBox(height: 4),
                if (_debidos.isEmpty)
                  const Text('Nada vence hoy.',
                      style: AppTexto.secundario)
                else
                  for (final d in _debidos)
                    Tarjeta(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                            d.yaDisparado
                                ? Icons.check_circle_rounded
                                : Icons.notifications_rounded,
                            color: d.yaDisparado
                                ? AppColores.exito
                                : AppColores.naranja),
                        title: Text(d.titulo, style: AppTexto.cuerpo),
                        subtitle: Text(
                            '${_tipoLegible(d.tipo)} · ${d.clienteNombre ?? d.targetKey}'
                            '${d.yaDisparado ? ' · ya disparado hoy' : ''}'
                            '${!d.yaDisparado && !d.puedoDisparar ? ' · lo dispara el dueño' : ''}',
                            style: AppTexto.secundario),
                        trailing: d.puedoDisparar
                            ? TextButton(
                                onPressed: () => _disparar(d),
                                child: const Text('Disparar'))
                            : d.clienteId != null
                                ? TextButton(
                                    onPressed: () => Navigator.push(
                                        context,
                                        RutaIron(
                                            builder: (_) => FichaScreen(
                                                clienteId: d.clienteId!))),
                                    child: const Text('Ver ficha'))
                                : null,
                      ),
                    ),
                const SizedBox(height: 20),
                const Text('Mis recordatorios', style: AppTexto.titulo),
                const SizedBox(height: 4),
                if (_configs.isEmpty)
                  const Text('Aún no hay recordatorios configurados.',
                      style: AppTexto.secundario)
                else
                  for (final c in _configs)
                    Tarjeta(
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('${c['titulo']}',
                            style: AppTexto.cuerpo),
                        subtitle: Text(
                            '${_tipoLegible('${c['tipo']}')} · '
                            '${_alcanceLegible('${c['alcance']}')} · '
                            '${(c['activa'] as num?)?.toInt() == 1 ? 'activo' : 'pausado'}'
                            '${'${c['frecuencia'] ?? 'ninguna'}' == 'semanal' ? ' · cada semana' : '${c['frecuencia'] ?? 'ninguna'}' == 'mensual' ? ' · cada mes' : ''}',
                            style: AppTexto.secundario),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                  (c['activa'] as num?)?.toInt() == 1
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 20),
                              onPressed: () async {
                                await RecordatoriosService.instance
                                    .cambiarActiva('${c['id']}',
                                        (c['activa'] as num?)?.toInt() != 1);
                                await _cargar();
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline_rounded,
                                  size: 20),
                              onPressed: () async {
                                // F6-18: borrar pedía cero
                                // confirmación; ahora sí.
                                final seguro =
                                    await DialogoApp.confirmar(
                                  context,
                                  titulo: 'Eliminar recordatorio',
                                  mensaje: 'Se elimina '
                                      '«${c['titulo']}» y deja de '
                                      'dispararse. No se puede '
                                      'deshacer.',
                                  aceptar: 'Eliminar',
                                  peligro: true,
                                );
                                if (!seguro) return;
                                await RecordatoriosService.instance
                                    .eliminar('${c['id']}');
                                await _cargar();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ],
            ),
    );
  }
}
