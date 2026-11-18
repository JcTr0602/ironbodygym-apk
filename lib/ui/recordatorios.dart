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

import '../app_log.dart';
import '../errores_sync.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart'
    show
        fmtFecha,
        mensajeWaRecordatorio,
        telefonoEfectivoWa,
        urlWaRecordatorio;
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
  bool _falloCarga = false;
  bool _empujePendiente = false;
  List<RecordatorioDebido> _debidos = [];
  List<Map<String, dynamic>> _configs = [];

  /// 1.29 (Oleada 4, FB-10): fila del espejo de cada cliente
  /// con debido hoy (para su teléfono efectivo y el mensaje
  /// según su estado). Se carga con la pantalla: pintar no
  /// espera ninguna red.
  Map<int, Map<String, dynamic>> _clientesDebidos = {};

  /// 1.29 (Oleada 4, FB-13): hora vigente de los avisos
  /// automáticos (la lee el servicio de su meta).
  int _horaAvisos = 8;

  String get _horaAvisosTxt =>
      '${_horaAvisos.toString().padLeft(2, '0')}:00';

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
      // Yunque B (YB-TRA-06): la tarjeta sale si el permiso
      // está denegado AHORA (triestado: el canal roto ya no
      // se funde con «hay permiso») o si quedó la señal
      // persistente de denegación de la última sincronización.
      final permiso = await AvisosRecordatorios.estadoPermiso();
      final denegadoPersistente =
          await AvisosRecordatorios.permisoDenegadoPersistente();
      // 1.29 (FB-10): filas de los clientes debidos, del
      // espejo local (sin red): su teléfono efectivo decide
      // si la tarjeta ofrece «WhatsApp».
      final clientesDebidos = <int, Map<String, dynamic>>{};
      final idsDebidos = <int>{
        for (final d in debidos)
          if (d.clienteId != null) d.clienteId!,
      };
      if (idsDebidos.isNotEmpty) {
        final todos = await LocalDb.instance.allMirror('clientes');
        for (final c in todos) {
          final id = (c['id'] as num?)?.toInt();
          if (id != null && idsDebidos.contains(id)) {
            clientesDebidos[id] = c;
          }
        }
      }
      final hora = await AvisosRecordatorios.horaAvisos();
      // (1.36 H-B4 136-984) señal del último empuje tras
      // mutar: si falló, la pantalla lo dice.
      final empujeFallo = await LocalDb.instance
              .getMeta(kMetaRecordatoriosPushFallo) ==
          '1';
      if (mounted) {
        setState(() {
          _debidos = debidos;
          _configs = visibles;
          _clientesDebidos = clientesDebidos;
          _horaAvisos = hora;
          _sinPermisoNotif =
              permiso == 'denegado' || denegadoPersistente;
          _empujePendiente = empujeFallo;
          _cargando = false;
          _falloCarga = false;
        });
      }
    } catch (e) {
      // (1.36 H-B4 136-977) el fallo se VE con reintento;
      // la lista vieja/vacía no se presenta como normal.
      AppLog.error('ui', 'recordatorios_carga_fallo', d: '$e');
      if (mounted) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
    }
  }

  /// 1.28 (M5-A6/R1M5-H1): ¿puede ESTA sesión pausar o
  /// eliminar esta configuración? Espejo de los guardas
  /// del servicio (que siguen siendo el cinturón): el
  /// dueño, todo; el entrenador, solo sus «solo para
  /// mí». Sin permiso, la tarjeta enseña «Solo el dueño»
  /// en vez de botones que al tocarlos no hacían nada
  /// visible (el servicio lanzaba y nadie lo contaba).
  bool _puedoGestionar(Map<String, dynamic> c) {
    if (_soyDueno) return true;
    if ('${c['alcance']}' != 'solo_mio') return false;
    return c['creado_por'] == _yo;
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

  /// 1.29 (Oleada 4, FB-10): avisar por WhatsApp desde la
  /// tarjeta del debido. Abre wa.me con el teléfono efectivo
  /// del cliente (FB-01) y el mensaje de la casa según su
  /// estado o su cumpleaños. NO marca el recordatorio como
  /// atendido: abrir el chat no prueba que el mensaje se
  /// enviara — el debido sigue pendiente al volver, y
  /// «Disparar» sigue siendo el gesto que lo asienta.
  Future<void> _avisarWhatsApp(RecordatorioDebido d) async {
    final cliente =
        d.clienteId != null ? _clientesDebidos[d.clienteId] : null;
    if (cliente == null) return;
    final tel = telefonoEfectivoWa(cliente);
    if (tel.isEmpty) return;
    final mensaje = mensajeWaRecordatorio(
      tipo: d.tipo,
      cliente: cliente,
      nombre: d.clienteNombre ?? '${cliente['nombre'] ?? ''}',
    );
    final uri = Uri.parse(urlWaRecordatorio(tel, mensaje));
    var abierto = false;
    try {
      abierto = await launchUrl(uri,
          mode: LaunchMode.externalApplication);
    } catch (_) {
      abierto = false;
    }
    if (!abierto && mounted) {
      mostrarSnack(context, 'No se pudo abrir WhatsApp',
          significado: SignificadoChip.error);
    }
  }

  /// 1.29 (Oleada 4, FB-13): el dueño elige la hora de los
  /// avisos automáticos; el servicio la persiste y
  /// reprograma las alarmas vigentes con la hora nueva.
  Future<void> _cambiarHoraAvisos() async {
    final elegida = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _horaAvisos, minute: 0),
      helpText: 'Hora de los avisos automáticos',
    );
    if (elegida == null || !mounted) return;
    await AvisosRecordatorios.fijarHoraAvisos(elegida.hour);
    if (!mounted) return;
    setState(() => _horaAvisos = elegida.hour);
    mostrarSnack(
        context, 'Avisos automáticos a las $_horaAvisosTxt');
  }

  /// Tarjeta de un debido de hoy. 1.29 (Oleada 4, FB-10):
  /// junto a la acción de siempre («Disparar» o «Ver
  /// ficha»), la tarjeta ofrece «WhatsApp» cuando el cliente
  /// tiene teléfono válido — avisar NO asienta el debido.
  Widget _tarjetaDebido(RecordatorioDebido d) {
    final cliente =
        d.clienteId != null ? _clientesDebidos[d.clienteId] : null;
    final telWa = cliente != null ? telefonoEfectivoWa(cliente) : '';
    return Tarjeta(
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
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (telWa.isNotEmpty)
              TextButton(
                onPressed: () => _avisarWhatsApp(d),
                child: const Text('WhatsApp'),
              ),
            if (d.puedoDisparar)
              TextButton(
                  onPressed: () => _disparar(d),
                  child: const Text('Disparar'))
            else if (d.clienteId != null)
              TextButton(
                  onPressed: () => Navigator.push(
                      context,
                      RutaIron(
                          builder: (_) =>
                              FichaScreen(clienteId: d.clienteId!))),
                  child: const Text('Ver ficha')),
          ],
        ),
      ),
    );
  }

  /// 1.28 (M5-B3): el estado legible de la config: la
  /// pausa CON FECHA se nombra con su último día («en
  /// pausa hasta el…»); vencida la fecha, vuelve a
  /// «activo» sin tocar nada (la reactivación es por
  /// lectura, no por escritura).
  String _estadoLegible(Map<String, dynamic> c) {
    if ((c['activa'] as num?)?.toInt() != 1) return 'pausado';
    if (recordatorioEnPausaConFecha(c, hoyHabanaIso())) {
      final hasta = '${c['pausada_hasta']}';
      return 'en pausa hasta el '
          '${fmtFecha(hasta.length >= 10 ? hasta.substring(0, 10) : hasta)}';
    }
    return 'activo';
  }

  /// 1.28 (M5-B3): conmutar la pausa. Activo sin pausa →
  /// elegir el alcance (con fecha o sin fecha); en pausa
  /// con fecha → reanudar ahora; pausado sin fecha →
  /// reactivar. Los rechazos del servicio se avisan, como
  /// en el resto de la pantalla (M5-A6).
  Future<void> _conmutarPausa(Map<String, dynamic> c) async {
    final id = '${c['id']}';
    final activa = (c['activa'] as num?)?.toInt() == 1;
    try {
      if (!activa) {
        await RecordatoriosService.instance.cambiarActiva(id, true);
      } else if (recordatorioEnPausaConFecha(c, hoyHabanaIso())) {
        await RecordatoriosService.instance.pausarHasta(id, null);
        if (mounted) mostrarSnack(context, 'Recordatorio reanudado');
      } else {
        final hasta = await _elegirPausa();
        if (hasta == null) return; // canceló el diálogo
        if (hasta.isEmpty) {
          await RecordatoriosService.instance.cambiarActiva(id, false);
        } else {
          await RecordatoriosService.instance.pausarHasta(id, hasta);
          if (mounted) {
            mostrarSnack(context,
                'En pausa hasta el ${fmtFecha(hasta)}; se reactiva solo');
          }
        }
      }
    } catch (e) {
      if (mounted) {
        mostrarSnack(
            context, e.toString().replaceFirst('Exception: ', ''),
            significado: SignificadoChip.error);
      }
      return;
    }
    await _cargar();
  }

  /// Diálogo de alcance de la pausa: devuelve la fecha ISO
  /// del ÚLTIMO día de pausa, '' para la pausa sin fecha
  /// de siempre, o null si se cancela. La aritmética de
  /// calendario va en UTC (regla de la casa).
  Future<String?> _elegirPausa() {
    String sumar(int dias) {
      final hoy = hoyHabanaIso();
      final p = hoy.split('-');
      final d = DateTime.utc(
              int.parse(p[0]), int.parse(p[1]), int.parse(p[2]))
          .add(Duration(days: dias));
      String dos(int n) => n.toString().padLeft(2, '0');
      return '${d.year}-${dos(d.month)}-${dos(d.day)}';
    }

    return showDialog<String>(
      context: context,
      builder: (ctx) {
        Widget opcion(String titulo, String detalle, String valor) {
          return ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(titulo, style: AppTexto.cuerpo),
            subtitle: Text(detalle, style: AppTexto.secundario),
            onTap: () => Navigator.of(ctx).pop(valor),
          );
        }

        return DialogoApp(
          titulo: 'Pausar recordatorio',
          iconoTitulo: Icons.pause_circle_outline_rounded,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // La fecha elegida es el ÚLTIMO día de
              // pausa: la opción y el subtítulo de la
              // lista («en pausa hasta el…») dicen lo
              // mismo.
              opcion('Hasta mañana',
                  'Hoy y mañana no dispara; vuelve solo '
                      'pasado mañana.',
                  sumar(1)),
              opcion('7 días',
                  'Vuelve solo el ${fmtFecha(sumar(8))}.',
                  sumar(7)),
              opcion('Sin fecha',
                  'Pausado hasta que lo reactives a mano.', ''),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
          ],
        );
      },
    );
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
    // 1.29 (Oleada 4, barrido): el formulario vive en un
    // StatefulWidget dueño de su controlador (antes se
    // creaba en este método y se disponía al resolver el
    // showDialog, con la animación de salida aún
    // reconstruyendo el campo: el defecto D-B1-08).
    final r =
        await showDialog<({String titulo, String tipo, String alcance, int dias, String? fechaFija, String frecuencia})>(
      context: context,
      builder: (_) => _DialogoCrearRecordatorio(esDueno: _soyDueno),
    );
    if (r == null || r.titulo.isEmpty) return;
    try {
      await RecordatoriosService.instance.crear(
        titulo: r.titulo,
        tipo: r.tipo,
        alcance: _soyDueno ? r.alcance : 'solo_mio',
        diasAnticipacion: r.dias,
        fechaFija: r.fechaFija,
        frecuencia: r.frecuencia,
      );
      await _cargar();
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, mensajeErrorAmable(e), significado: SignificadoChip.error);
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
          : _falloCarga
              ? EstadoError(
                  titulo: 'No se pudieron cargar los recordatorios',
                  detalle: 'La lectura falló en este teléfono. '
                      'Reinténtalo.',
                  onReintentar: _cargar,
                )
              : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                if (_empujePendiente) ...[
                  Tarjeta(
                    child: Row(
                      children: [
                        const Icon(Icons.cloud_upload_rounded,
                            color: AppColores.alerta),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Hay cambios de recordatorios '
                            'pendientes de subir: se enviarán '
                            'al sincronizar.',
                            style: AppTexto.secundario,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
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
                      subtitle: Text(
                          'Los avisos automáticos ($_horaAvisosTxt) '
                          'no se verán en este teléfono hasta '
                          'activarlo.',
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
                  for (final d in _debidos) _tarjetaDebido(d),
                const SizedBox(height: 20),
                // 1.29 (Oleada 4, FB-13): la hora de los avisos
                // automáticos, elegible por el dueño.
                if (_soyDueno) ...[
                  Tarjeta(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.schedule_rounded,
                          color: AppColores.naranja),
                      title: const Text('Hora de los avisos',
                          style: AppTexto.cuerpo),
                      subtitle: Text(
                          'Los avisos automáticos suenan a las '
                          '$_horaAvisosTxt (hora de Cuba)',
                          style: AppTexto.secundario),
                      trailing: TextButton(
                        onPressed: _cambiarHoraAvisos,
                        child: const Text('Cambiar'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
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
                            '${_estadoLegible(c)}'
                            '${'${c['frecuencia'] ?? 'ninguna'}' == 'semanal' ? ' · cada semana' : '${c['frecuencia'] ?? 'ninguna'}' == 'mensual' ? ' · cada mes' : ''}',
                            style: AppTexto.secundario),
                        // 1.28 (M5-A6/R1M5-H1): sin permiso
                        // de gestión, etiqueta en vez de
                        // botones mudos; con permiso, los
                        // handlers avisan si el servicio
                        // rechaza (defensa en profundidad).
                        trailing: !_puedoGestionar(c)
                            ? const Text('Solo el dueño',
                                style: AppTexto.metadato)
                            : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                  (c['activa'] as num?)?.toInt() == 1 &&
                                          !recordatorioEnPausaConFecha(
                                              c, hoyHabanaIso())
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 20),
                              onPressed: () => _conmutarPausa(c),
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
                                try {
                                  await RecordatoriosService.instance
                                      .eliminar('${c['id']}');
                                } catch (e) {
                                  if (mounted) {
                                    mostrarSnack(
                                        context,
                                        e
                                            .toString()
                                            .replaceFirst(
                                                'Exception: ', ''),
                                        significado:
                                            SignificadoChip.error);
                                  }
                                  return;
                                }
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

/// 1.29 (Oleada 4, barrido de diálogos): formulario de
/// «Nuevo recordatorio» como StatefulWidget DUEÑO de su
/// TextEditingController, dispuesto en dispose() — el
/// patrón de la casa. Antes el controlador se creaba en el
/// método `_crear` y se disponía nada más resolver el
/// showDialog, mientras la animación de salida seguía
/// reconstruyendo el campo (defecto D-B1-08 de la Oleada 3).
/// Devuelve los datos del formulario por Navigator.pop.
class _DialogoCrearRecordatorio extends StatefulWidget {
  const _DialogoCrearRecordatorio({required this.esDueno});

  final bool esDueno;

  @override
  State<_DialogoCrearRecordatorio> createState() =>
      _DialogoCrearRecordatorioState();
}

class _DialogoCrearRecordatorioState
    extends State<_DialogoCrearRecordatorio> {
  final _tituloCtrl = TextEditingController();
  String _tipo = 'vencimiento';
  String _alcance = 'solo_mio';
  int _dias = 3;
  String _frecuencia = 'ninguna';
  // 1.25 T122 (F6-18): la fecha personalizada se ELIGE con
  // el selector del sistema, no se teclea como texto
  // YYYY-MM-DD (que fallaba por formato).
  String _fechaSel = hoyHabanaIso();

  @override
  void dispose() {
    _tituloCtrl.dispose();
    super.dispose();
  }

  void _crear() {
    Navigator.pop(
        context,
        (
          titulo: _tituloCtrl.text.trim(),
          tipo: _tipo,
          alcance: _alcance,
          dias: _dias,
          fechaFija: _tipo == 'personalizado' ? _fechaSel : null,
          frecuencia:
              _tipo == 'personalizado' ? _frecuencia : 'ninguna',
        ));
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Nuevo recordatorio',
      iconoTitulo: Icons.notifications_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
                controller: _tituloCtrl,
                decoration: const InputDecoration(
                    labelText: 'Título (p. ej. «Vence esta semana»')),
            const SizedBox(height: 8),
            SelectorIron<String>(
              valor: _tipo,
              tituloPanel: 'Tipo de recordatorio',
              opciones: const [
                OpcionSelector('vencimiento', 'Vencimiento'),
                OpcionSelector('cumpleanos', 'Cumpleaños'),
                OpcionSelector('personalizado', 'Personalizado'),
              ],
              alCambiar: (v) =>
                  setState(() => _tipo = v ?? 'vencimiento'),
            ),
            if (widget.esDueno) ...[
              const SizedBox(height: 8),
              SelectorIron<String>(
                valor: _alcance,
                tituloPanel: 'Alcance',
                opciones: const [
                  OpcionSelector('solo_mio', 'Solo para mí'),
                  OpcionSelector('todos', 'Para todos (masivo)'),
                ],
                alCambiar: (v) =>
                    setState(() => _alcance = v ?? 'solo_mio'),
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
            if (_tipo != 'personalizado') ...[
              Text('Días de anticipación (vencimiento): $_dias'),
              Slider(
                  value: _dias.toDouble(),
                  min: 0,
                  max: 14,
                  divisions: 14,
                  onChanged: (v) =>
                      setState(() => _dias = v.round())),
            ],
            if (_tipo == 'personalizado') ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fecha', style: AppTexto.cuerpo),
                subtitle: Text(fmtFecha(_fechaSel),
                    style: AppTexto.secundario),
                trailing: TextButton(
                  onPressed: () async {
                    final ini = DateTime.tryParse(_fechaSel) ??
                        ahoraHabana();
                    final f = await showDatePicker(
                      context: context,
                      initialDate: ini,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (f != null && mounted) {
                      setState(() => _fechaSel =
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
              SelectorIron<String>(
                valor: _frecuencia,
                tituloPanel: 'Repetición',
                opciones: const [
                  OpcionSelector('ninguna', 'Solo esa fecha'),
                  OpcionSelector('semanal', 'Cada semana (ese día)'),
                  OpcionSelector('mensual', 'Cada mes (ese día)'),
                ],
                alCambiar: (v) =>
                    setState(() => _frecuencia = v ?? 'ninguna'),
              ),
            ],
          ],
        ),
      ),
      acciones: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        TextButton(
            onPressed: _crear, child: const Text('Crear')),
      ],
    );
  }
}
