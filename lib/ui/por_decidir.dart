/// 1.32 «Mostrador Táctico» — la bandeja «Por Decidir» del
/// Pilar 1 (solo dueño), bajo la COMPUERTA 1 del veredicto
/// g132, que aquí se cumple al pie de la letra:
///
/// - Pinta en el frame 1 con fuentes LOCALES (incidencias,
///   rellenos y adelantos llegan del estado de Home, que ya
///   los contó en local; congelaciones del espejo local con
///   su triestado; arqueos del libro local) MÁS la última
///   FOTO PERSISTIDA de los contadores remotos.
/// - Las remotas (Vales, Plus, Comunidad, Solicitudes de
///   invitados) se refrescan DETRÁS, cada una con su timeout
///   de 12 s y guarda de generación; al verificar, la foto
///   persistida se renueva.
/// - Error ≠ vacío, jamás: si una fuente remota devuelve
///   null (sin conexión o respuesta degradada), su fila dice
///   «sin verificar» (o enseña su foto con la hora) y la
///   bandeja muestra la línea «bandejas remotas sin
///   verificar (sin conexión)». La frase «0 pendientes /
///   Todo al día» SOLO sale si TODAS las fuentes — locales
///   y remotas — verificaron y suman 0.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../congelaciones_gestion.dart';
import '../invitados.dart' as invitados_svc;
import '../localdb.dart';
import '../negocio.dart';
import '../plus_reportes.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'congelaciones.dart';
import 'diseno.dart';
import 'hoja_liquidar.dart';
import 'hoja_liquidar_arqueo.dart';
import 'incidencias/lista_incidencias.dart';
import 'marco.dart';
import 'panel_comunidad.dart';
import 'panel_premios.dart';
import 'panel_premios_hub.dart';
import 'reportes_plus.dart';
import 'solicitudes_adelanto.dart' as ui_adelantos;
import 'suplementos.dart';

/// Conteos remotos de la bandeja: null en un campo = esa
/// fuente NO se pudo verificar (sin conexión o degradada).
class ConteosRemotosPorDecidir {
  final int? vales;
  final int? plus;
  final int? comunidad;
  final int? solicitudes;

  const ConteosRemotosPorDecidir(
      {this.vales, this.plus, this.comunidad, this.solicitudes});

  bool get todasVerificadas =>
      vales != null && plus != null && comunidad != null && solicitudes != null;

  int get sumaVerificada =>
      (vales ?? 0) + (plus ?? 0) + (comunidad ?? 0) + (solicitudes ?? 0);

  Map<String, dynamic> aJson() => {
        if (vales != null) 'v': vales,
        if (plus != null) 'p': plus,
        if (comunidad != null) 'c': comunidad,
        if (solicitudes != null) 's': solicitudes,
      };

  static ConteosRemotosPorDecidir desdeJson(Map<String, dynamic> j) {
    int? n(String k) => (j[k] as num?)?.toInt();
    return ConteosRemotosPorDecidir(
      vales: n('v'),
      plus: n('p'),
      comunidad: n('c'),
      solicitudes: n('s'),
    );
  }
}

/// La foto persistida de las remotas (SharedPreferences):
/// lo último verificado, con su hora habanera.
class FotoRemotaPorDecidir {
  final ConteosRemotosPorDecidir conteos;
  final DateTime hora;

  const FotoRemotaPorDecidir(this.conteos, this.hora);
}

const _kFotoPorDecidir = 'pordecidir_foto_remota_v1';

Future<FotoRemotaPorDecidir?> leerFotoPorDecidir() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kFotoPorDecidir);
    if (raw == null || raw.isEmpty) return null;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    final hora = DateTime.tryParse('${j['ts'] ?? ''}');
    if (hora == null) return null;
    return FotoRemotaPorDecidir(
      ConteosRemotosPorDecidir.desdeJson(j),
      hora,
    );
  } catch (_) {
    return null;
  }
}

Future<void> guardarFotoPorDecidir(ConteosRemotosPorDecidir c) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kFotoPorDecidir,
      jsonEncode({...c.aJson(), 'ts': isoHabana(ahoraHabana())}),
    );
  } catch (_) {}
}

/// Titular de la bandeja (PURO, testeable): la regla de oro
/// de la Compuerta 1 vive aquí — «Todo al día» exige que
/// TODO haya verificado y sume 0.
({String titular, bool todoAlDia}) titularPorDecidir({
  required int locales,
  required ConteosRemotosPorDecidir remotasEfectivas,
  required bool remotasVerificadasAhora,
}) {
  final total = locales + remotasEfectivas.sumaVerificada;
  if (remotasVerificadasAhora && total == 0) {
    return (titular: 'Todo al día · 0 decisiones pendientes', todoAlDia: true);
  }
  if (total == 0) {
    // Hay locales en 0 pero alguna remota no verificó: el
    // titular NO puede afirmar el cero.
    return (titular: 'Por decidir', todoAlDia: false);
  }
  return (
    titular: total == 1 ? '1 decisión pendiente' : '$total decisiones pendientes',
    todoAlDia: false,
  );
}

/// Fusión POR FUENTE de la foto (PURA, testeable) —
/// 1.32 (Oleada 2, Fase 0; refinamiento del Defecto 1 de
/// la Oleada 1 que pide el veredicto de g132dis_): cada
/// fuente conserva SU último valor verificado en la foto
/// persistida hasta que ESA fuente vuelva a verificar: un
/// éxito parcial (1 de 4) actualiza esa 1 y jamás machaca
/// las otras 3 con null/0. [verificadoAhora] dice si la
/// corrida trajo al menos un valor nuevo: SOLO entonces la
/// foto se renueva — con 0 verificadas, ni los valores ni
/// la HORA de la foto se tocan (una hora fresca sobre una
/// foto vieja fingiría una verificación que no ocurrió).
({ConteosRemotosPorDecidir conteos, bool verificadoAhora})
    fusionarFotoPorDecidir(
        ConteosRemotosPorDecidir? previa, ConteosRemotosPorDecidir ahora) {
  final verificadoAhora = ahora.vales != null ||
      ahora.plus != null ||
      ahora.comunidad != null ||
      ahora.solicitudes != null;
  return (
    conteos: ConteosRemotosPorDecidir(
      vales: ahora.vales ?? previa?.vales,
      plus: ahora.plus ?? previa?.plus,
      comunidad: ahora.comunidad ?? previa?.comunidad,
      solicitudes: ahora.solicitudes ?? previa?.solicitudes,
    ),
    verificadoAhora: verificadoAhora,
  );
}

/// Las remotas reales: cualquier fallo o degradación
/// devuelve null en SU campo (las demás no se contaminan).
/// El timeout de 12 s NO se reaplica aquí a propósito:
/// cada servicio ya lo lleva dentro (la unificación del
/// Escalón 2 sobre el propio PostgrestBuilder), y apilar
/// un segundo timeout sobre un builder de postgrest deja
/// su error tardío sin escucha — medido en la costura de
/// la oleada: el error escapaba como no manejado aunque el
/// valor volviera null correctamente. La guarda de
/// generación de la bandeja cubre las llegadas viejas.
Future<ConteosRemotosPorDecidir> cargarRemotasPorDecidir() async {
  Future<int?> tolerante(Future<int?> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return null;
    }
  }

  final r = await Future.wait<int?>([
    tolerante(() => contarValesPorAprobar()),
    tolerante(() async =>
        (await PlusReportesService().pendientes()).length),
    tolerante(() => contarReportesComunidadNuevos()),
    tolerante(() async =>
        (await invitados_svc.InvitadosService().solicitudesPendientes())
            .length),
  ]);
  return ConteosRemotosPorDecidir(
      vales: r[0], plus: r[1], comunidad: r[2], solicitudes: r[3]);
}

class BandejaPorDecidir extends StatefulWidget {
  /// Conteos locales que Home ya calculó (incidencias del
  /// espejo local, buzón de rellenos y adelantos).
  final int incidencias;
  final int rellenos;
  final int adelantos;

  /// Navegación a pantallas sueltas (el _ir de Home).
  final void Function(Widget pantalla) onIr;

  /// Cargadores inyectables (tests); null = los reales.
  final Future<ConteosRemotosPorDecidir> Function()? cargarRemotas;
  final Future<({bool ok, int pendientes})> Function()?
      cargarCongelaciones;
  final Future<List<Map<String, dynamic>>> Function()? cargarArqueos;

  /// 1.32 (Fase 3 — Momento 4, 5º): alertas de catálogo
  /// locales (stock crítico o precio sin fijar).
  final Future<int> Function()? cargarCatalogo;

  const BandejaPorDecidir({
    super.key,
    required this.incidencias,
    required this.rellenos,
    required this.adelantos,
    required this.onIr,
    this.cargarRemotas,
    this.cargarCongelaciones,
    this.cargarArqueos,
    this.cargarCatalogo,
  });

  @override
  State<BandejaPorDecidir> createState() => _BandejaPorDecidirState();
}

class _BandejaPorDecidirState extends State<BandejaPorDecidir> {
  FotoRemotaPorDecidir? _foto;
  ConteosRemotosPorDecidir? _remotasAhora;
  int _gen = 0;
  int? _congelaciones;
  bool _congelacionesOk = true;
  int _alertasCatalogo = 0;
  bool _catalogoOk = true;
  List<Map<String, dynamic>> _arqueos = const [];

  @override
  void initState() {
    super.initState();
    _cargarFotoYRefrescar();
    _cargarLocalesExtra();
  }

  Future<void> _cargarFotoYRefrescar() async {
    final foto = await leerFotoPorDecidir();
    if (!mounted) return;
    setState(() => _foto = foto);
    await _refrescarRemotas();
  }

  Future<void> _refrescarRemotas() async {
    final gen = ++_gen;
    final r = await (widget.cargarRemotas ?? cargarRemotasPorDecidir)();
    if (!mounted || gen != _gen) return;
    setState(() => _remotasAhora = r);
    // Fusión POR FUENTE (fusionarFotoPorDecidir): un éxito
    // parcial actualiza solo su fuente y conserva el último
    // valor verificado de las demás. Y la foto solo se
    // RENUEVA si algo verificó ahora: con 0 verificadas no
    // se guarda ni se le mueve la hora (la hora de una foto
    // es la de su última verificación real).
    final fusion = fusionarFotoPorDecidir(_foto?.conteos, r);
    if (!fusion.verificadoAhora) return;
    await guardarFotoPorDecidir(fusion.conteos);
    if (!mounted || gen != _gen) return;
    setState(() => _foto =
        FotoRemotaPorDecidir(fusion.conteos, ahoraHabana()));
  }

  Future<void> _cargarLocalesExtra() async {
    try {
      final r = await (widget.cargarCongelaciones ??
          () async {
            final e = await CongelacionesService.instance.leerEspejo();
            return (
              ok: e.ok,
              pendientes: e.datos.where((c) => c.esPendiente).length,
            );
          })();
      if (mounted) {
        setState(() {
          _congelacionesOk = r.ok;
          _congelaciones = r.pendientes;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _congelacionesOk = false);
    }
    try {
      final a = await (widget.cargarArqueos ?? entrenadoresConPendiente)();
      if (mounted) setState(() => _arqueos = a);
    } catch (_) {}
    // 1.32 (Fase 3 — Momento 4, 5º): las alertas de
    // catálogo salen del espejo LOCAL de suplementos
    // (sin red, como todo lo local de esta bandeja).
    // Si la lectura falla, la fila no se finge vacía:
    // se marca no-ok y la bandeja lo dice, como con
    // las congelaciones (error ≠ vacío).
    try {
      final n = await (widget.cargarCatalogo ??
          () async => conteoAlertasCatalogo(
              await LocalDb.instance.allMirror('suplementos')))();
      if (mounted) {
        setState(() {
          _catalogoOk = true;
          _alertasCatalogo = n;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _catalogoOk = false);
    }
  }

  /// El valor EFECTIVO de una remota: el de ahora si
  /// verificó; si no, el de la foto (marcado); si no hay
  /// ninguno, null = «sin verificar».
  ({int? valor, bool deFoto}) _efectivo(
      int? ahora, int? foto) {
    if (ahora != null) return (valor: ahora, deFoto: false);
    if (foto != null) return (valor: foto, deFoto: true);
    return (valor: null, deFoto: false);
  }

  @override
  Widget build(BuildContext context) {
    final ahora = _remotasAhora;
    final foto = _foto?.conteos;
    final vVales = _efectivo(ahora?.vales, foto?.vales);
    final vPlus = _efectivo(ahora?.plus, foto?.plus);
    final vCom = _efectivo(ahora?.comunidad, foto?.comunidad);
    final vSol = _efectivo(ahora?.solicitudes, foto?.solicitudes);
    final efectivas = ConteosRemotosPorDecidir(
      vales: vVales.valor,
      plus: vPlus.valor,
      comunidad: vCom.valor,
      solicitudes: vSol.valor,
    );
    final locales = widget.incidencias +
        widget.rellenos +
        widget.adelantos +
        (_congelacionesOk ? (_congelaciones ?? 0) : 0) +
        (_catalogoOk ? _alertasCatalogo : 0);
    final verificadasAhora = ahora?.todasVerificadas ?? false;
    final algunaSinVerificar = !verificadasAhora;
    final t = titularPorDecidir(
      locales: locales,
      remotasEfectivas: efectivas,
      remotasVerificadasAhora: verificadasAhora,
    );

    Widget fila({
      required IconData icono,
      required String titulo,
      required int? valor,
      bool deFoto = false,
      bool localOk = true,
      required VoidCallback onTap,
    }) {
      // 1.34 Campo 2 (B-2, regla de Jc 2026-11-14): una
      // fila con CERO verificado NO aparece — ni local ni
      // remota (antes las remotas pasaban localOk: false
      // para poder enseñar su «sin verificar» y el cero
      // verificado se les colaba visible, saturando la
      // bandeja con entradas sin nada que atender). El
      // null es otra cosa: «sin verificar» no es un cero,
      // es un estado por atender, y la Compuerta 1 de la
      // 1.32 prohíbe disfrazarlo de vacío — esa fila se
      // queda. El titular ya contaba solo lo accionable
      // (sumaVerificada trata el null como no-cero
      // verificable y el cero no suma): filas y cabecera
      // dicen ahora lo mismo.
      if (valor == 0 || (localOk && valor == null)) {
        return const SizedBox.shrink();
      }
      return ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        // 1.33 (pasada de diseño, veredicto de Jc en campo):
        // el icono va DENTRO del chip de marca con tinte —
        // el mismo IconoModuloBadge.naranja de «Buscar
        // cliente» — en vez del glifo cobalto plano y sin
        // contenedor que se leía «MSDOS del 95». El cobalto
        // desaparece de la bandeja; el ámbar de «sin
        // verificar» se queda: significa alerta, no adorno.
        leading: IconoModuloBadge.naranja(icono),
        title: Text(titulo, style: AppTexto.cuerpo),
        trailing: valor == null
            ? Text('sin verificar',
                style: AppTexto.metadato
                    .copyWith(color: AppColores.alerta))
            : Text(
                deFoto ? '$valor · foto' : '$valor',
                style: AppTexto.conTabulares(
                    AppTexto.subtitulo.copyWith(
                        fontWeight: FontWeight.w700)),
              ),
        onTap: onTap,
      );
    }

    return Tarjeta(
      key: const ValueKey('por-decidir'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 1.33 (diseño): la cabecera de la tarjeta
              // lleva el mismo chip con tinte que las filas
              // (verde cuando todo está al día, marca en
              // cuanto algo espera decisión).
              if (t.todoAlDia)
                IconoModuloBadge.verde(Icons.check_circle_rounded)
              else
                IconoModuloBadge.naranja(Icons.inbox_rounded),
              const SizedBox(width: AppEspacio.sm),
              const Expanded(
                child: Text('Por Decidir', style: AppTexto.titulo),
              ),
            ],
          ),
          Text(t.titular, style: AppTexto.secundario),
          const SizedBox(height: AppEspacio.xs),
          // --- Prioridad del dueño (1.32, Fase 3 —
          // Momento 4 del plano): 1º incidencias y
          // conversiones, 2º Plus, 3º congelaciones,
          // 4º vales, 5º alertas de catálogo. El resto
          // de la bandeja (rellenos, adelantos, comunidad)
          // sigue debajo en su orden de siempre, y los
          // arqueos cierran como franja de acción. Las
          // locales pintan en el frame 1 y las remotas
          // con su foto/sello: el orden visual no cambia
          // esa compuerta (cada fila enseña su estado).
          fila(
            icono: Icons.sync_problem_rounded,
            titulo: 'Incidencias de sincronización',
            valor: widget.incidencias,
            onTap: () => widget.onIr(const ListaIncidenciasScreen()),
          ),
          fila(
            icono: Icons.person_add_rounded,
            titulo: 'Solicitudes de inscripción',
            valor: vSol.valor,
            deFoto: vSol.deFoto,
            localOk: false,
            onTap: () => MarcoNav.irAClientes(
                const DestinoClientes(segmento: 'invitados')),
          ),
          fila(
            icono: Icons.workspace_premium_rounded,
            titulo: 'Reportes App Plus por confirmar',
            valor: vPlus.valor,
            deFoto: vPlus.deFoto,
            localOk: false,
            onTap: () => widget.onIr(const ReportesPlusScreen()),
          ),
          fila(
            icono: Icons.ac_unit_rounded,
            titulo: 'Congelaciones por decidir',
            valor: _congelacionesOk ? _congelaciones : null,
            localOk: _congelacionesOk,
            onTap: () => widget.onIr(const CongelacionesScreen()),
          ),
          if (!_congelacionesOk)
            const Text(
              'Congelaciones: no se pudo leer el espejo local.',
              style: AppTexto.metadato,
            ),
          fila(
            icono: Icons.emoji_events_rounded,
            titulo: 'Vales de premio por aprobar',
            valor: vVales.valor,
            deFoto: vVales.deFoto,
            localOk: false,
            onTap: () => widget.onIr(const PremiosHubScreen()),
          ),
          fila(
            icono: Icons.inventory_2_rounded,
            titulo: 'Alertas de catálogo (stock o precio)',
            valor: _catalogoOk ? _alertasCatalogo : null,
            localOk: _catalogoOk,
            onTap: () => widget.onIr(const SuplementosScreen()),
          ),
          if (!_catalogoOk)
            const Text(
              'Catálogo: no se pudo leer el espejo local.',
              style: AppTexto.metadato,
            ),
          fila(
            icono: Icons.science_rounded,
            titulo: 'Pomos por rellenar',
            valor: widget.rellenos,
            onTap: () => MarcoNav.irAPilar(PilarGestion.tienda),
          ),
          fila(
            icono: Icons.request_quote_rounded,
            titulo: 'Adelantos por responder',
            valor: widget.adelantos,
            onTap: () =>
                widget.onIr(const ui_adelantos.SolicitudesAdelantoScreen()),
          ),
          fila(
            icono: Icons.groups_rounded,
            titulo: 'Reportes de Comunidad',
            valor: vCom.valor,
            deFoto: vCom.deFoto,
            localOk: false,
            onTap: () => widget.onIr(const ComunidadPanelScreen()),
          ),
          // --- Arqueos (Momento 3A): liquidar sin salir ---
          for (final e in _arqueos.take(2))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              // 1.33 (diseño): la fila de arqueo también va
              // en chip con tinte, pero ÁMBAR: aquí el color
              // significa «efectivo esperando» (alerta), no
              // es adorno — se conserva el significado y se
              // le da el contenedor de la familia.
              leading: const IconoModuloBadge(
                icono: Icons.account_balance_wallet_rounded,
                tinte: AppColores.alerta,
                iconoOscuro: AppColores.ambarTactico,
                iconoClaro: AppColores.ambarTierra,
              ),
              title: Text(
                  'Efectivo de ${e['nombre'] ?? ''} por recoger',
                  // 1.32 (integración, RD-7): con nombres
                  // largos a 360 dp el título sin tope
                  // comprimía el botón «Liquidar Arqueo» o
                  // desalineaba la bandeja a 3 líneas.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTexto.cuerpo),
              subtitle: Text(
                [
                  if (((e['cup'] as num?)?.toDouble() ?? 0) > 0)
                    '${fmtMonto((e['cup'] as num).toDouble())} CUP',
                  if (((e['usd'] as num?)?.toDouble() ?? 0) > 0)
                    '${fmtMonto((e['usd'] as num).toDouble())} USD',
                ].join(' · '),
                style: AppTexto.conTabulares(AppTexto.secundario),
              ),
              trailing: FilledButton.tonal(
                // Pasada (Argón): trailing más compacto —
                // el título (2 líneas con elipsis) gana el
                // aire que el botón ancho le quitaba con
                // nombres compuestos a 360 dp.
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppEspacio.sm),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _liquidarRapido(e),
                child: const Text('Liquidar Arqueo'),
              ),
            ),
          if (algunaSinVerificar)
            // 1.33 (diseño): el aviso de «sin conexión» va
            // integrado en la tarjeta como línea con su
            // icono, no como texto suelto al pie: mismo
            // mensaje, mismo ámbar de alerta.
            Padding(
              padding: const EdgeInsets.only(top: AppEspacio.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.cloud_off_rounded,
                      size: 14, color: AppColores.alerta),
                  const SizedBox(width: AppEspacio.xs),
                  Expanded(
                    child: Text(
                      _foto == null
                          ? 'bandejas remotas sin verificar (sin conexión)'
                          : 'Sin conexión: se enseña la última foto de '
                              'las ${_foto!.hora.hour.toString().padLeft(2, '0')}:'
                              '${_foto!.hora.minute.toString().padLeft(2, '0')}.',
                      style: AppTexto.metadato
                          .copyWith(color: AppColores.alerta),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _liquidarRapido(Map<String, dynamic> e) async {
    final tid = (e['telegram_id'] as num?)?.toInt();
    if (tid == null) return;
    final nombre = '${e['nombre'] ?? ''}';
    final messenger = ScaffoldMessenger.of(context);
    final r = await mostrarHojaLiquidarArqueo(context,
        telegramId: tid, nombre: nombre);
    if (r == null) return;
    if (r.modo == ModoHojaArqueo.entregaC1) {
      mostrarSnackEnMessenger(
        messenger,
        'Entrega anticipada registrada para $nombre '
        '(${r.entregado.toStringAsFixed(0)} CUP).',
        significado: SignificadoChip.exito,
      );
    } else {
      mostrarAvisoLiquidacionConDeshacer(
        messenger,
        mensaje: 'Liquidación registrada para $nombre.',
        liqId: r.liquidacion!.liqId,
        alDeshacer: () async {
          await _cargarLocalesExtra();
        },
      );
    }
    await _cargarLocalesExtra();
  }
}
