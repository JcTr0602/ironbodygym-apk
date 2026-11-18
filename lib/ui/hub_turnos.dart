/// Hub operativo de turnos (24/25): UN solo lugar para el día.
///
/// Reúne lo que hoy vive en pantallas separadas:
/// - Quién está de turno en cada franja (programado ⊕ apertura
///   viva, con la misma resolución que la app de clientes).
/// - Abrir / cerrar MI turno (entrenador).
/// - Pendiente a entregar (mío para el entrenador; por entrenador
///   para el dueño, con salto al Arqueo).
/// No sustituye al hub de Horario y turnos (patrón semanal y
/// calendario de excepciones): ese configura, este opera el día.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../auth.dart';
import '../localdb.dart';
import '../permisos_entrenador.dart';
import '../negocio.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../turno_service.dart';
import '../turnos_resolucion.dart';
import 'app_bar.dart';
import 'arqueo.dart';
import 'cierre_turno.dart';
import 'avatar_entrenador.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'mi_turno.dart';
import 'permisos_ui.dart';
import 'horario_turnos.dart';
import 'turnos_calendario.dart'
    show CalendarioTurnosScreen, colorChipEntrenador;
import 'turno_abrir.dart';
import '../errores_sync.dart';
import '../app_log.dart';

class HubTurnosScreen extends StatefulWidget {
  const HubTurnosScreen({super.key});
  @override
  State<HubTurnosScreen> createState() => _HubTurnosScreenState();
}

class _HubTurnosScreenState extends State<HubTurnosScreen> {
  bool _cargando = true;
  bool _procesando = false;
  // 1.25 T01: la carga fallida se DICE. Antes el catch
  // apagaba el spinner y la pantalla pintaba sus listas
  // vacías («Nada pendiente.») como si fueran el dato:
  // un fallo disfrazado de "todo bien".
  bool _errorCarga = false;
  bool _errorPendientes = false;
  // Panel Terra B1 (bloqueante): _hoy nace inicializado. Antes era
  // `late` y solo se asignaba en el setState de éxito de _cargar:
  // si una lectura fallaba antes, el catch apagaba el spinner y el
  // siguiente build leía _hoy sin inicializar (LateInitializationError).
  DateTime _hoy = ahoraHabana();
  String? _franjaActual;
  Map<int, Map<String, String?>> _patron = {};
  Map<String, Map<String, String?>> _excepciones = {};
  List<AperturaTurno> _aperturas = [];
  List<Map<String, dynamic>> _cierres = [];
  // 1.28 (M3-B5): las filas CRUDAS del espejo de aperturas,
  // para componer el detalle real de cualquier día al
  // tocarlo (las resueltas de _aperturasPorDia no traen la
  // hora de cierre ni el id de la fila).
  List<Map<String, dynamic>> _aperturasEspejo = [];
  // 1.28 (M3-B2): la comprobación de cierres a demanda va en
  // curso (deshabilita el botón y enseña su progreso).
  bool _comprobando = false;
  // SL-11 (G12-6): la tarjeta de contingencia «¿Un cierre no
  // baja?» nace PLEGADA; este es su estado de despliegue.
  bool _ayudaCierreAbierta = false;
  // 1.28 (M3-A7): aperturas resueltas por día de la semana
  // visible (clave: fecha ISO), para que el mapa de calor
  // cuente lo que de verdad pasó CADA día y no solo lo de hoy.
  Map<String, List<AperturaTurno>> _aperturasPorDia = {};
  Map<String, dynamic>? _miTurnoVisible;
  // Pendientes: (nombre, telegramId, cup, usd).
  List<({String nombre, int tid, double cup, double usd})> _pendientes =
      [];

  bool get _soyDueno => AuthService().isOwner;

  // 1.36 H-B3 (136-777): reloj del hub — _hoy/_franjaActual
  // nacen en _cargar y sin esto el marcador «ahora» quedaba
  // falso con la app abierta (cruzaba la franja o el día y
  // la pantalla seguía en la anterior).
  Timer? _relojHub;

  @override
  void initState() {
    super.initState();
    _cargar();
    _relojHub = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      final ahora = ahoraHabana();
      final mismoDia = ahora.year == _hoy.year &&
          ahora.month == _hoy.month &&
          ahora.day == _hoy.day;
      if (!mismoDia) {
        // Cambió el día: todo el mapa depende de la fecha.
        _cargar();
      } else if (franjaDeInstante(ahora) != _franjaActual) {
        setState(() {
          _hoy = ahora;
          _franjaActual = franjaDeInstante(ahora);
        });
      }
    });
  }

  @override
  void dispose() {
    _relojHub?.cancel();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _errorCarga = false;
      _errorPendientes = false;
    });
    try {
      final hoy = ahoraHabana();
      final hoyIso = isoFechaTurno(hoy);
      final db = LocalDb.instance;
      final ajustes = await db.getAjustes();
      final patron =
          parsePatronTurnos(ajustes['horario_turnos']);
      final excepciones =
          parseExcepcionesTurnos(ajustes['horario_excepciones']);
      final apMirror = await db.allMirror('turnos_apertura');
      final cierresEspejo = await db.allMirror('turnos_cierre');
      // Mi turno local es más fresco que el espejo: si tengo un
      // turno abierto hoy, cuenta como apertura viva aunque el
      // espejo aún no lo traiga.
      Map<String, dynamic>? miVisible;
      if (!_soyDueno) {
        miVisible = await TurnoService.instance.turnoVisible();
      }
      // 1.28 (M3-A7): y si CERRÉ hoy en este teléfono, mi
      // apertura del espejo tampoco debe seguir «viva» hasta
      // que baje el cierre por sync (antes la franja se pintaba
      // «Abierto» con el turno ya cerrado). Se superpone un
      // cierre SINTÉTICO local — sin turno_id a propósito: la
      // correspondencia cae a fecha + franja + telegram/nombre,
      // que es exactamente lo que se quiere casar.
      final cierres = [...cierresEspejo];
      if (!_soyDueno &&
          miVisible != null &&
          '${miVisible['fecha_turno']}' == hoyIso &&
          '${miVisible['estado']}'.startsWith('cerrado')) {
        cierres.add({
          'fecha': hoyIso,
          'turno': '${miVisible['turno']}',
          'entrenador_nombre': AuthService().displayName,
          'telegram_id': AuthService().telegramId,
        });
      }
      var aperturas = aperturasHoyConViva(
          aperturas: apMirror, cierres: cierres, fechaIso: hoyIso);
      if (!_soyDueno) {
        final abierto =
            await TurnoService.instance.turnoActual();
        if (abierto != null) {
          final en = DateTime.tryParse(
              '${abierto['hora_apertura'] ?? ''}');
          if (en != null) {
            final nombre = AuthService().displayName;
            // 1.36 H-B3 (136-778): la superposición solo
            // sustituye MI apertura de la franja ABIERTA
            // (abierto['turno'], con su ventana ±45): mis
            // aperturas de la OTRA franja se conservan —
            // antes el filtro por nombre las borraba todas
            // y el día perdía la franja ya trabajada.
            final vAbierta =
                ventanaFranja(hoy, '${abierto['turno'] ?? ''}');
            bool esDeLaFranjaAbierta(AperturaTurno a) {
              if (vAbierta == null) return true;
              final desde =
                  instanteParedDeMinutos(hoy, vAbierta.inicio - 45);
              final hasta =
                  instanteParedDeMinutos(hoy, vAbierta.fin + 45);
              return !a.aperturaEn.isBefore(desde) &&
                  a.aperturaEn.isBefore(hasta);
            }

            aperturas = [
              for (final a in aperturas)
                if (normalizarNombreTurno(a.nombre) !=
                        normalizarNombreTurno(nombre) ||
                    !esDeLaFranjaAbierta(a))
                  a,
              (
                nombre: nombre,
                aperturaEn: en,
                viva: true,
                cubreA: ('${abierto['cubre_a'] ?? ''}'.trim().isEmpty)
                    ? null
                    : '${abierto['cubre_a']}'.trim(),
              ),
            ];
          }
        }
      }
      // Pendientes: el dueño ve a cada entrenador; el entrenador
      // solo el suyo.
      final pendientes =
          <({String nombre, int tid, double cup, double usd})>[];
      var pendientesParcial = false;
      if (_soyDueno) {
        final yo = AuthService().telegramId;
        try {
          final raw = await db.getMeta('usuarios_apk');
          if (raw != null && raw.isNotEmpty) {
            for (final u in jsonDecode(raw) as List) {
              final m = Map<String, dynamic>.from(u as Map);
              final tid =
                  LocalDb.normalizarTelegramId(m['telegram_id']);
              final nombre =
                  '${m['nombre'] ?? m['username'] ?? ''}'.trim();
              if (tid == null || nombre.isEmpty || tid == yo) {
                continue;
              }
              pendientes.add((
                nombre: nombre,
                tid: tid,
                cup: await pendienteEntrega(tid),
                usd: await pendienteEntregaUsd(tid),
              ));
            }
          }
        } catch (_) {
          // T01: la lista puede quedar incompleta; se
          // avisa en su sección en vez de callarlo.
          pendientesParcial = true;
        }
      } else {
        final tid = AuthService().telegramId;
        if (tid != null) {
          pendientes.add((
            nombre: AuthService().displayName,
            tid: tid,
            cup: await pendienteEntrega(tid),
            usd: await pendienteEntregaUsd(tid),
          ));
        }
      }
      // 1.28 (M3-A7): aperturas resueltas de CADA día de la
      // semana visible, para el mapa de calor. El de hoy es la
      // lista ya compuesta arriba (con la superposición de mi
      // turno local); los demás días salen del espejo con los
      // cierres efectivos.
      final aperturasPorDia = <String, List<AperturaTurno>>{};
      final lunes =
          DateTime(hoy.year, hoy.month, hoy.day - (hoy.weekday - 1));
      for (var i = 0; i < 7; i++) {
        final dia = DateTime(lunes.year, lunes.month, lunes.day + i);
        final iso = isoFechaTurno(dia);
        aperturasPorDia[iso] = iso == hoyIso
            ? aperturas
            : aperturasHoyConViva(
                aperturas: apMirror, cierres: cierres, fechaIso: iso);
      }
      if (!mounted) return;
      setState(() {
        _hoy = hoy;
        _franjaActual = franjaDeInstante(hoy);
        _patron = patron;
        _excepciones = excepciones;
        _aperturas = aperturas;
        _aperturasEspejo = apMirror;
        _cierres = cierres;
        _aperturasPorDia = aperturasPorDia;
        _miTurnoVisible = miVisible;
        _pendientes = pendientes;
        _errorPendientes = pendientesParcial;
        _cargando = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _errorCarga = true;
        });
      }
    }
  }

  void _snack(String texto) {
    if (!mounted) return;
    mostrarSnack(context, texto);
  }

  Future<void> _abrir() async {
    // G#34 (Hy4): la guarda se marca ANTES del await del
    // permiso — con el doble toque, dos flujos pasaban el
    // permiso en paralelo y solapaban dos diálogos de
    // suplencia (el turno no se duplicaba: abrirTurnoAtomico
    // devuelve creado=false; el daño era el doble diálogo).
    if (_procesando) return;
    setState(() => _procesando = true);
    try {
    // 1.25 cierre (autoauditoría ronda 2): abrir turno
    // cuelga de can_gestionar_turnos, como en Home y
    // Mi Turno (el hub no lo comprobaba). El cierre ya
    // la trae dentro de cerrarTurnoConDialogo.
    if (!await permisoOperativoOkConRefresco(context,
        () => PermisosEntrenador().canGestionarTurnos, 'gestionar turnos')) {
      return;
    }
      // F9: al abrir se puede marcar a quién se cubre.
      final abiertoOk = await abrirTurnoConSuplente(context);
      if (!abiertoOk) return;
      _snack('Turno abierto.');
      await _cargar();
    } catch (e) {
      AppLog.error('hub_turnos', 'abrir_turno_fallo', d: '$e');
      _snack('No se pudo abrir el turno: ${mensajeErrorAmable(e)}');
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  Future<void> _cerrar() async {
    // (1.36 H-A2 136-776) guarda síncrona antes del primer
    // await: un segundo toque no apila dos diálogos de cierre.
    if (_procesando) return;
    setState(() => _procesando = true);
    try {
      // 1.25 T84: el cierre vive en cierre_turno.dart,
      // compartido con Mi Turno (una sola implementación
      // del preparar → confirmar → cerrar).
      final cerrado = await cerrarTurnoConDialogo(context);
      if (cerrado) {
        _snack('Turno cerrado.');
        await _cargar();
      }
    } catch (e) {
      AppLog.error('hub_turnos', 'cerrar_turno_fallo', d: '$e');
      _snack('No se pudo cerrar el turno: ${mensajeErrorAmable(e)}');
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  String _hora(String? iso) {
    if (iso == null || iso.length < 16) return '—';
    return iso.substring(11, 16);
  }

  /// T1 (estéticas 1.19): quién trabaja hoy, de un vistazo
  /// (nombres distintos de las franjas del día, sin duplicar).
  List<String> _quienesTrabajanHoy() {
    if (_hoy.weekday == 7) return const [];
    final franjas = ['manana', if (_hoy.weekday != 6) 'tarde'];
    final nombres = <String>[];
    for (final f in franjas) {
      final m = estadoFranjaCompleto(
        fecha: _hoy,
        franja: f,
        patron: _patron,
        excepciones: _excepciones,
        aperturas: _aperturas,
        cierres: _cierres,
      ).mostrado;
      if (m != null && m.isNotEmpty && !nombres.contains(m)) {
        nombres.add(m);
      }
    }
    return nombres;
  }

  Widget _filaFranja(String franja, String titulo) {
    final est = estadoFranjaCompleto(
      fecha: _hoy,
      franja: franja,
      patron: _patron,
      excepciones: _excepciones,
      aperturas: _aperturas,
      cierres: _cierres,
    );
    final esActual = _franjaActual == franja;
    final estadoTexto = switch (est.estado) {
      'abierto' => 'Abierto',
      'cerrado' => 'Cerrado',
      _ => 'Sin abrir',
    };
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$titulo${esActual ? ' · ahora' : ''}',
                  style: AppTexto.subtitulo,
                ),
              ),
              Text(estadoTexto, style: AppTexto.cuerpo),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Text('De turno: ', style: AppTexto.cuerpo),
              if (est.mostrado != null) ...[
                // 1.25 T83: la foto del entrenador (o su
                // inicial con su color), no solo un punto.
                AvatarEntrenador(
                    nombre: est.mostrado!, tamano: 26),
                const SizedBox(width: AppEspacio.sm),
              ],
              Flexible(
                child: Text(
                  '${est.mostrado ?? 'Sin asignar'}'
                  '${est.cubriendo ? ' (cubriendo)' : ''}',
                  style: AppTexto.cuerpo,
                ),
              ),
            ],
          ),
          if (est.programado != null &&
              est.programado != est.mostrado)
            Text('Programado: ${est.programado}',
                style: AppTexto.secundario),
        ],
      ),
    );
  }

  /// 1.25 T82: la franja horizontal del día.
  Widget _lineaDeTiempo() {
    final vM = ventanaFranja(_hoy, 'manana');
    final vT = ventanaFranja(_hoy, 'tarde');
    if (vM == null && vT == null) return const SizedBox.shrink();
    final inicio = vM?.inicio ?? vT!.inicio;
    var fin = vM?.fin ?? 0;
    if (vT != null && vT.fin > fin) fin = vT.fin;
    if (fin <= inicio) return const SizedBox.shrink();
    final ahoraMin = _hoy.hour * 60 + _hoy.minute;

    Widget bloque(({int inicio, int fin}) v, String franja) {
      final est = estadoFranjaCompleto(
        fecha: _hoy,
        franja: franja,
        patron: _patron,
        excepciones: _excepciones,
        aperturas: _aperturas,
        cierres: _cierres,
      );
      final mostrado = est.mostrado;
      final color = mostrado != null
          ? colorChipEntrenador(mostrado)
          : AppColores.error;
      final fracIni = (v.inicio - inicio) / (fin - inicio);
      final fracFin = (v.fin - inicio) / (fin - inicio);
      return Positioned(
        left: fracIni * _anchoLinea,
        width: (fracFin - fracIni) * _anchoLinea,
        top: 0,
        bottom: 0,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.30),
            border: Border.all(color: color, width: 1),
            borderRadius: BorderRadius.circular(AppRadio.sm),
          ),
          alignment: Alignment.center,
          child: Text(
            mostrado ?? 'Sin cubrir',
            style: AppTexto.minuscula.copyWith(
                fontWeight: FontWeight.w700,
                color: AppColores.texto(context)),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, cons) {
              _anchoLinea = cons.maxWidth;
              // UI136-08: la franja crece con la escala de
              // letra (a 1,45× el nombre no cabe en 34 dp).
              final escala =
                  MediaQuery.textScalerOf(context).scale(1);
              return SizedBox(
                height: 34 * escala.clamp(1.0, 1.45),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (vM != null) bloque(vM, 'manana'),
                    if (vT != null) bloque(vT, 'tarde'),
                    if (ahoraMin >= inicio && ahoraMin <= fin)
                      Positioned(
                        left: (ahoraMin - inicio) /
                                (fin - inicio) *
                                cons.maxWidth -
                            1,
                        top: -4,
                        bottom: -4,
                        child: Container(
                          width: 2.5,
                          color: AppColores.naranja,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: AppEspacio.xs),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(horaMinutosLinea(inicio),
                  style: AppTexto.minuscula),
              if (ahoraMin >= inicio && ahoraMin <= fin)
                Text('▲ ahora (${horaMinutosLinea(ahoraMin)})',
                    style: AppTexto.minuscula.copyWith(
                        color: AppColores.naranja,
                        fontWeight: FontWeight.w700)),
              Text(horaMinutosLinea(fin),
                  style: AppTexto.minuscula),
            ],
          ),
        ],
      ),
    );
  }

  double _anchoLinea = 0;

  /// M5 (1.20): mini mapa de calor de la semana. Domingo
  /// cerrado; sábado sin tarde.
  /// 1.28 (M3-A7): en días pasados y hoy la celda cuenta las
  /// franjas con apertura REAL de ese día (lo que de verdad
  /// pasó); en días futuros, las franjas con entrenador
  /// programado (patrón + excepciones).
  /// 1.28 (M3-C2): la celda lo DICE con dos lenguajes: SÓLIDA
  /// cuando cuenta lo que pasó (real) y en CONTORNO cuando
  /// cuenta lo programado, con la leyenda bajo la fila. El
  /// conteo lo resuelve la función pura resumenCeldaSemana
  /// (la misma semántica de A7). 1.28 (M3-B5): tocar la
  /// celda abre el detalle real del día.
  Widget _semanaCalor() {
    final lunes = _hoy.subtract(Duration(days: _hoy.weekday - 1));
    const letras = ['L', 'M', 'X', 'J', 'V', 'S', 'D'];
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Semana', style: AppTexto.subtitulo),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (var i = 0; i < 7; i++)
                _celdaDia(lunes.add(Duration(days: i)), letras[i]),
            ],
          ),
          const SizedBox(height: 10),
          // 1.28 (M3-C2): la leyenda del doble lenguaje.
          // SL-11 (G12-9): en Wrap, no en Row rígido — a
          // 360 dp la fila desbordaba (37 px medidos).
          Wrap(
            spacing: AppEspacio.md,
            runSpacing: AppEspacio.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: AppColores.naranja.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('Lo que pasó', style: AppTexto.metadato),
                ],
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(
                          color: AppColores.naranja, width: 1.5),
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('Lo programado', style: AppTexto.metadato),
                ],
              ),
              Text('Toca un día para verlo',
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _celdaDia(DateTime dia, String letra) {
    final esHoy = dia.year == _hoy.year &&
        dia.month == _hoy.month &&
        dia.day == _hoy.day;
    Widget caja(Widget hijo,
        {Color? fondo, bool bordeHoy = false, bool contorno = false}) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: fondo,
          borderRadius: BorderRadius.circular(AppRadio.sm),
          border: Border.all(
              color: bordeHoy
                  ? AppColores.naranja
                  : contorno
                      ? AppColores.naranja.withValues(alpha: 0.75)
                      : AppColores.borde(context),
              width: bordeHoy || contorno ? 1.5 : 1),
        ),
        // UI136-08: la rejilla conserva sus 36 dp; la cifra
        // («2/2») encoge con FittedBox en vez de tocar los
        // bordes con la escala de letra grande.
        child: Center(
            child: FittedBox(fit: BoxFit.scaleDown, child: hijo)),
      );
    }

    final celda = Column(
      children: [
        Text(letra, style: AppTexto.metadato),
        const SizedBox(height: 4),
        if (dia.weekday == 7)
          caja(const Text('—', style: AppTexto.secundario),
              bordeHoy: esHoy)
        else
          Builder(builder: (_) {
            // 1.28 (M3-A7 + C2): el conteo lo resuelve la
            // función pura (días pasados/hoy = aperturas
            // reales de ESE día; futuros = programado) y la
            // clase decide el lenguaje: sólido = real,
            // contorno = programado.
            final r = resumenCeldaSemana(
              dia: dia,
              hoy: _hoy,
              patron: _patron,
              excepciones: _excepciones,
              aperturasDia: _aperturasPorDia[isoFechaTurno(dia)] ??
                  const <AperturaTurno>[],
              cierres: _cierres,
            );
            final cobertura =
                r.total == 0 ? 0.0 : r.asignadas / r.total;
            return caja(
              Text('${r.asignadas}/${r.total}',
                  style: AppTexto.etiqueta
                      .copyWith(fontWeight: FontWeight.bold)),
              fondo: r.esReal
                  ? AppColores.naranja
                      .withValues(alpha: 0.10 + 0.45 * cobertura)
                  : null,
              bordeHoy: esHoy,
              contorno: !r.esReal,
            );
          }),
        const SizedBox(height: 4),
        Text('${dia.day}', style: AppTexto.minuscula),
      ],
    );
    // 1.28 (M3-B5): el día se abre al tocarlo.
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadio.sm),
      onTap: () => _abrirDetalleDia(dia),
      child: celda,
    );
  }

  /// 1.28 (M3-B5): la hoja del día tocado en el mapa semanal:
  /// por franja, lo programado y lo que DE VERDAD pasó (quién
  /// abrió, a qué hora, si cerró, a quién cubría), compuesto
  /// con la función pura detalleDiaTurnos sobre las filas
  /// crudas del espejo de ESE día. El dueño puede además
  /// registrar la suplencia o el cambio de programado de ese
  /// día (la misma excepción que escribe el calendario).
  Future<void> _abrirDetalleDia(DateTime dia) async {
    final iso = isoFechaTurno(dia);
    final apsDia = [
      for (final a in _aperturasEspejo)
        if ('${a['fecha_turno'] ?? ''}' == iso) a,
    ];
    final detalle = detalleDiaTurnos(
      fecha: dia,
      patron: _patron,
      excepciones: _excepciones,
      aperturasDia: apsDia,
      cierres: _cierres,
    );
    final esFuturo =
        dia.isAfter(DateTime(_hoy.year, _hoy.month, _hoy.day));
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppEspacio.lg, 0, AppEspacio.lg, AppEspacio.lg),
          // 1.36 H-B3 (136-772): el detalle del día rueda —
          // con varias aperturas por franja y texto grande
          // la columna fija desbordaba la hoja.
          child: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                dia.weekday == 7
                    ? 'Domingo ${dia.day}/${dia.month}/${dia.year}'
                    : '${dia.day}/${dia.month}/${dia.year}',
                style: AppTexto.subtitulo,
              ),
              const SizedBox(height: 10),
              if (dia.weekday == 7)
                const Text('El gym no abre los domingos.',
                    style: AppTexto.cuerpo)
              else
                for (final d in detalle) ...[
                  Text(
                    d.franja == 'manana' ? '🌅 Mañana' : '🌇 Tarde',
                    style: AppTexto.cuerpo
                        .copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    d.programado == null
                        ? 'Programado: sin asignar'
                        : 'Programado: ${d.programado}',
                    style: AppTexto.secundario,
                  ),
                  if (d.entradas.isEmpty && !esFuturo)
                    const Text('No abrió nadie.',
                        style: AppTexto.secundario),
                  for (final e in d.entradas)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '✓ ${e.nombre} abrió ${e.apertura}'
                        // 1.36 H-B3 (136-794): cerrado sin
                        // hora = cierre administrativo (la
                        // hora ya no se fabrica en la
                        // resolución desde creada_en).
                        '${e.cerrado ? (e.cierre != null ? ' · cerró ${e.cierre}' : ' · cierre administrativo') : ' · sin cerrar'}'
                        '${e.cubreA != null ? ' · cubre a ${e.cubreA}' : ''}',
                        style: AppTexto.cuerpo,
                      ),
                    ),
                  const SizedBox(height: 10),
                ],
              if (_soyDueno && dia.weekday != 7) ...[
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  icon: const Icon(Icons.swap_horiz_rounded),
                  label: const Text('Marcar suplencia de este día'),
                  onPressed: () async {
                    Navigator.of(ctx).pop();
                    await _marcarSuplencia(dia);
                  },
                ),
              ],
            ],
              )),
        ),
      ),
    );
  }

  /// 1.28 (M3-B5), solo dueño: registra la excepción del día
  /// (quién trabaja una franja, o nadie) por la MISMA vía que
  /// el calendario de excepciones: op `ajuste` con la clave
  /// horario_excepciones + escritura local inmediata. La
  /// suplencia queda visible al momento en todo el hub.
  Future<void> _marcarSuplencia(DateTime dia) async {
    final nombres = <String>{
      for (final f in _patron.values) ...f.values.whereType<String>(),
      for (final p in _pendientes) p.nombre,
    }.toList()
      ..sort();
    if (nombres.isEmpty) {
      _snack('No hay entrenadores conocidos para asignar.');
      return;
    }
    final r = await showDialog<({String franja, String? nombre})>(
      context: context,
      builder: (_) => _DialogoSuplenciaDia(
        nombres: nombres,
        conTarde: dia.weekday != 6,
      ),
    );
    if (r == null || !mounted) return;
    final copia = <String, Map<String, String?>>{
      for (final e in _excepciones.entries)
        e.key: Map<String, String?>.from(e.value),
    };
    final delDia =
        Map<String, String?>.from(copia[isoFechaTurno(dia)] ?? {});
    delDia[r.franja] = r.nombre;
    copia[isoFechaTurno(dia)] = delDia;
    podarExcepciones(copia,
        hoy: DateTime(_hoy.year, _hoy.month, _hoy.day));
    try {
      // La misma escritura que el calendario de excepciones:
      // op ajuste con uuid propio + ajustes completos.
      final mapa = <String, dynamic>{
        for (final e in copia.entries)
          e.key: {
            for (final f in e.value.entries) f.key: f.value,
          },
      };
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': 'horario_excepciones', 'valor': mapa},
      );
      final aj = await LocalDb.instance.getAjustes();
      aj['horario_excepciones'] = mapa;
      await LocalDb.instance.setAjustes(aj);
      unawaited(SyncEngine.instance.run());
      _snack(r.nombre == null
          ? 'Franja sin nadie ese día.'
          : 'Suplencia registrada: ${r.nombre} ese día.');
      await _cargar();
    } catch (e) {
      _snack('No se pudo registrar la suplencia.');
    }
  }

  /// 1.28 (M3-B2): «Comprobar cierres con el servidor» a
  /// demanda. La reconciliación ya corría sola en segundo
  /// plano (M3-A5 la sacó del camino del Home); aquí el
  /// entrenador la pide y VE su resultado en llano. La RPC
  /// lleva su timeout de 12 s en el servicio; lo local no
  /// cambia si la comprobación falla.
  Future<void> _comprobarCierres() async {
    if (_comprobando) return;
    setState(() => _comprobando = true);
    // 1.36 H-C2 (136-775): try/finally — si la
    // reconciliación LANZA (fuera de sus caminos con
    // ok=false), el spinner baja y el fallo se dice.
    try {
      final r = await TurnoService.instance.reconciliarConServidor();
      if (!mounted) return;
      _snack(textoComprobacionCierres(ok: r.ok, marcados: r.marcados));
      if (r.ok && r.marcados > 0) await _cargar();
    } catch (e) {
      if (mounted) {
        _snack('No se pudo comprobar los cierres: '
            '${mensajeErrorAmable(e)}');
      }
    } finally {
      if (mounted) setState(() => _comprobando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // T1: se calcula una vez (estado puro, barato, pero sin
    // duplicar el trabajo en cada rebuild).
    final quienesHoy =
        _cargando || _hoy.weekday == 7 ? const <String>[] : _quienesTrabajanHoy();
    return Scaffold(
      appBar: appBarIron(
        context,
        'Turnos de hoy',
        acciones: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Actualizar',
            onPressed: _cargando ? null : _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando turnos…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                Text(
                  'Hoy ${_hoy.day}/${_hoy.month}/${_hoy.year}'
                  '${_franjaActual == null ? ' · fuera de horario' : ''}',
                  style: AppTexto.subtitulo,
                ),
                const SizedBox(height: 12),
                // 1.25 T82: el día como UNA línea de
                // tiempo — los bloques de cada franja con
                // su entrenador, el «ahora» marcado y los
                // huecos sin cubrir en rojo suave.
                if (!_errorCarga) _lineaDeTiempo(),
                if (_errorCarga) ...[
                  Tarjeta(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '⚠️ No se pudo cargar la información '
                          'de turnos. Lo que se ve abajo puede '
                          'estar incompleto o desactualizado.',
                          style: AppTexto.cuerpo,
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: _cargar,
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                // T1 (estéticas 1.19): quién trabaja hoy.
                if (_hoy.weekday != 7) ...[
                  Tarjeta(
                    child: Row(
                      children: [
                        Icon(Icons.group_rounded,
                            color: AppColores.textoSecundario(context)),
                        const SizedBox(width: 8),
                        const Text('Hoy trabajan:',
                            style: AppTexto.cuerpo),
                        const SizedBox(width: 8),
                        // 1.25 T119 (F3-29): las personas van en
                        // un Wrap dentro de Expanded — antes la
                        // fila era un Row pelado y con varios
                        // entrenadores o letra grande desbordaba.
                        Expanded(
                          child: quienesHoy.isEmpty
                              ? Text('sin asignar',
                                  style: AppTexto.secundario)
                              : Wrap(
                                  spacing: 10,
                                  runSpacing: 4,
                                  crossAxisAlignment:
                                      WrapCrossAlignment.center,
                                  children: [
                                    for (final n in quienesHoy)
                                      Row(
                                        mainAxisSize:
                                            MainAxisSize.min,
                                        children: [
                                          CircleAvatar(
                                            radius: 13,
                                            backgroundColor:
                                                colorChipEntrenador(n)
                                                    .withValues(
                                                        alpha: 0.18),
                                            child: Text(
                                              n.trim().isEmpty
                                                  ? '?'
                                                  : n.trim()[0]
                                                      .toUpperCase(),
                                              style: AppTexto.etiqueta
                                                  .copyWith(
                                                      color:
                                                          colorChipEntrenador(
                                                              n),
                                                      fontWeight:
                                                          FontWeight
                                                              .bold),
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Text(n,
                                              style: AppTexto.cuerpo),
                                        ],
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (_hoy.weekday == 7)
                  const Tarjeta(
                    child: Text(
                      'Domingo: el gym no abre. Abajo sigue el '
                      'pendiente a entregar.',
                      style: AppTexto.cuerpo,
                    ),
                  )
                else ...[
                  _filaFranja('manana', 'Mañana'),
                  const SizedBox(height: 8),
                  if (_hoy.weekday != 6) ...[
                    _filaFranja('tarde', 'Tarde'),
                    const SizedBox(height: 8),
                  ],
                ],
                // F9: suplencias de hoy (quién cubre a quién).
                Builder(builder: (_) {
                  final suplen = [
                    for (final a in _aperturas)
                      if (a.cubreA != null) a,
                  ];
                  if (suplen.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: AppEspacio.sm),
                    child: Tarjeta(
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.start,
                        children: [
                          for (final a in suplen)
                            Text(
                              '🔁 ${a.nombre} cubre a ${a.cubreA}',
                              style: AppTexto.cuerpo,
                            ),
                        ],
                      ),
                    ),
                  );
                }),
                _semanaCalor(),
                // 1.28 (M3-B2): comprobar los cierres con el
                // servidor A DEMANDA (el entrenador la pide y
                // ve el resultado; antes solo corría sola en
                // segundo plano y su efecto era invisible).
                if (!_soyDueno) ...[
                  const SizedBox(height: 8),
                  // SL-11 (G12-6): la comprobación es
                  // CONTINGENCIA, no contenido diario: va
                  // PLEGADA (regla anti-regueros de Jc). El
                  // título resume su estado y al desplegar
                  // el «Comprobar» sigue accesible.
                  // Plegado propio (Align heightFactor 0 +
                  // ClipRect), no ExpansionTile: el contenido
                  // queda en el árbol con alto pintado CERO y
                  // sin recibir toques (contrato M3-B2/C2:
                  // «Comprobar» vive en el hub), pero no
                  // ocupa espacio permanente.
                  Tarjeta(
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                          title: const Text('¿Un cierre no baja?',
                              style: AppTexto.cuerpo),
                          trailing: Icon(_ayudaCierreAbierta
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded),
                          onTap: () => setState(() =>
                              _ayudaCierreAbierta =
                                  !_ayudaCierreAbierta),
                        ),
                        ClipRect(
                          child: Align(
                            heightFactor:
                                _ayudaCierreAbierta ? 1 : 0,
                            alignment: Alignment.topCenter,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  AppEspacio.lg, 0, AppEspacio.lg,
                                  AppEspacio.md),
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Compruébalo con el servidor. '
                                    'Si el servidor no responde, '
                                    'lo de este teléfono no '
                                    'cambia.',
                                    style: AppTexto.cuerpo,
                                  ),
                                  const SizedBox(height: 8),
                                  OutlinedButton.icon(
                                    icon: _comprobando
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child:
                                                CircularProgressIndicator(
                                                    strokeWidth:
                                                        2),
                                          )
                                        : const Icon(Icons
                                            .cloud_sync_rounded),
                                    label: const Text('Comprobar'),
                                    onPressed: _comprobando
                                        ? null
                                        : _comprobarCierres,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                // Mi turno (entrenador).
                if (!_soyDueno) ...[
                  const SizedBox(height: 8),
                  Tarjeta(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Mi turno',
                            style: AppTexto.subtitulo),
                        const SizedBox(height: 8),
                        Builder(
                          builder: (_) {
                            final v = _miTurnoVisible;
                            final estado = '${v?['estado'] ?? ''}';
                            if (v == null) {
                              return const Text(
                                'No tienes turno hoy.',
                                style: AppTexto.cuerpo,
                              );
                            }
                            if (estado.startsWith('abierto')) {
                              final cubre =
                                  '${v['cubre_a'] ?? ''}'.trim();
                              return Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Abierto a las ${_hora('${v['hora_apertura']}')} '
                                    '(${v['turno'] ?? ''}).',
                                    style: AppTexto.cuerpo,
                                  ),
                                  if (cubre.isNotEmpty)
                                    Text(
                                      'Cubres a $cubre.',
                                      style: AppTexto.secundario,
                                    ),
                                  TextButton(
                                    onPressed: () async {
                                      await marcarCubreA(context);
                                      await _cargar();
                                    },
                                    child: Text(cubre.isEmpty
                                        ? 'Marcar a quién cubro'
                                        : 'Cambiar a quién cubro'),
                                  ),
                                ],
                              );
                            }
                            if (estado.startsWith('cerrado')) {
                              return const Text(
                                'Turno de hoy cerrado.',
                                style: AppTexto.cuerpo,
                              );
                            }
                            // 1.36 H-B3 (136-779): el estado
                            // lleva acción directa — antes
                            // era texto muerto y el cierre
                            // quedaba a dos pantallas.
                            return Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Turno anterior sin cerrar.',
                                  style: AppTexto.cuerpo,
                                ),
                                TextButton(
                                  onPressed: () =>
                                      Navigator.of(context).push(
                                    RutaIron(
                                      builder: (_) =>
                                          const MiTurnoScreen(),
                                    ),
                                  ),
                                  child: const Text(
                                      'Ver y cerrar en Mi Turno'),
                                ),
                              ],
                            );
                          },
                        ),
                        const SizedBox(height: 8),
                        if (_miTurnoVisible == null ||
                            '${_miTurnoVisible!['estado'] ?? ''}'
                                .startsWith('abierto'))
                          FilledButton(
                            onPressed: _procesando
                                ? null
                                : (_miTurnoVisible != null &&
                                        '${_miTurnoVisible!['estado'] ?? ''}'
                                            .startsWith('abierto')
                                    ? _cerrar
                                    : _abrir),
                            child: Text(_procesando
                                ? 'Trabajando…'
                                : (_miTurnoVisible != null
                                    ? 'Cerrar turno'
                                    : 'Abrir turno')),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text('Pendiente a entregar',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 8),
                if (_errorCarga)
                  const Tarjeta(
                    child: Text(
                        'Sin datos: la carga falló, no es que '
                        'no haya pendientes.',
                        style: AppTexto.cuerpo),
                  )
                else if (_pendientes.isEmpty && !_errorPendientes)
                  const Tarjeta(
                    child: Text('Nada pendiente.',
                        style: AppTexto.cuerpo),
                  )
                else
                  for (final p in _pendientes)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
                      child: Tarjeta(
                        child: InkWell(
                          onTap: () => Navigator.of(context).push(
                            RutaIron(
                              builder: (_) => _soyDueno
                                  ? const ArqueoScreen()
                                  : const MiTurnoScreen(),
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(p.nombre,
                                    style: AppTexto.subtitulo),
                              ),
                              Text(
                                '${fmtMonto(p.cup)} CUP'
                                '${p.usd > 0 ? ' + ${fmtMonto(p.usd)} USD' : ''}',
                                style: AppTexto.cuerpo,
                              ),
                              // 1.36 H-B3 (136-779): token de
                              // la casa, no Colors.grey crudo.
                              Icon(Icons.chevron_right_rounded,
                                  color: AppColores.textoSecundario(
                                      context),
                                  size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                if (_errorPendientes && !_errorCarga) ...[
                  const Tarjeta(
                    child: Text(
                        '⚠️ No se pudieron calcular todos los '
                        'pendientes: la lista puede estar '
                        'incompleta. Actualiza con el botón '
                        'de arriba.',
                        style: AppTexto.cuerpo),
                  ),
                  const SizedBox(height: 12),
                ],
                const SizedBox(height: 12),
                // SL-11 (G12-4): fuera la tarjeta que abría el
                // otro hub («Horario y turnos (patrón y
                // calendario)»): era una SEGUNDA puerta al
                // mismo calendario desde este hub (ese hub
                // trae la suya) y con la de abajo sumaban dos
                // caminos duplicados. Aquí queda UNA sola
                // puerta al calendario: la de «Plan y ajustes»
                // de abajo. El hub de configuración sigue
                // alcanzable desde Administración.
                // T3 (estéticas 1.19): explicación del hub,
                // 1.25 T80: el dueño configura SIN salir
                // del hub — el plan y los ajustes viven
                // también aquí, bajo el día. La pantalla
                // intermedia del Panel deja de ser el
                // único camino al patrón.
                if (_soyDueno) ...[
                  const EncabezadoSeccion(
                      titulo: 'Plan y ajustes de turnos'),
                  Tarjeta(
                    onTap: () => Navigator.of(context).push(
                      RutaIron(
                        builder: (_) =>
                            const HorarioTurnosScreen(),
                      ),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.calendar_view_week_rounded,
                            color: AppColores.naranja),
                        SizedBox(width: AppEspacio.md),
                        Expanded(
                          child: Text('Patrón semanal',
                              style: AppTexto.cuerpo),
                        ),
                        Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  Tarjeta(
                    onTap: () => Navigator.of(context).push(
                      RutaIron(
                        builder: (_) =>
                            const CalendarioTurnosScreen(),
                      ),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.edit_calendar_rounded,
                            color: AppColores.naranja),
                        SizedBox(width: AppEspacio.md),
                        Expanded(
                          child: Text(
                              'Calendario de excepciones',
                              style: AppTexto.cuerpo),
                        ),
                        Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                  ),
                ],
                // plegable para no ocupar sitio a diario.
                const SizedBox(height: 12),
                const ExpansionTile(
                  title: Text('¿Cómo funciona este hub?'),
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text(
                        // SL-11 (G12-4): sin re-explicar la
                        // precedencia (programado vs apertura
                        // real): esa explicación vive UNA sola
                        // vez, en el hub de configuración.
                        'Arriba ves quién está de turno hoy en '
                        'cada franja. Abrir y Cerrar son tu '
                        'turno del día; al cerrar se liquida el '
                        'pendiente. «Pendiente a entregar» es el '
                        'efectivo que falta por entregar de la '
                        'caja. El patrón semanal y el calendario '
                        'de excepciones se configuran abajo, en '
                        '«Plan y ajustes de turnos».',
                        style: AppTexto.cuerpo,
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// 1.28 (M3-B5): el diálogo de la suplencia de un día desde
/// el hub (franja + quién la trabaja, o nadie). Sin
/// controladores de texto: la elección sale de listas, así
/// que no hay nada que disponer.
class _DialogoSuplenciaDia extends StatefulWidget {
  const _DialogoSuplenciaDia({
    required this.nombres,
    required this.conTarde,
  });

  final List<String> nombres;
  final bool conTarde;

  @override
  State<_DialogoSuplenciaDia> createState() =>
      _DialogoSuplenciaDiaState();
}

class _DialogoSuplenciaDiaState extends State<_DialogoSuplenciaDia> {
  String _franja = 'manana';
  String? _nombre;

  @override
  void initState() {
    super.initState();
    _nombre = widget.nombres.first;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Suplencia de este día'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Franja', style: AppTexto.etiqueta),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Mañana'),
                selected: _franja == 'manana',
                onSelected: (_) => setState(() => _franja = 'manana'),
              ),
              if (widget.conTarde)
                ChoiceChip(
                  label: const Text('Tarde'),
                  selected: _franja == 'tarde',
                  onSelected: (_) =>
                      setState(() => _franja = 'tarde'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          const Text('Quién la trabaja', style: AppTexto.etiqueta),
          const SizedBox(height: 6),
          SelectorIron<String?>(
            valor: _nombre,
            tituloPanel: 'Quién la trabaja',
            opciones: [
              const OpcionSelector<String?>(null, 'Sin nadie'),
              for (final n in widget.nombres)
                OpcionSelector<String?>(n, n),
            ],
            alCambiar: (v) => setState(() => _nombre = v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context)
              .pop((franja: _franja, nombre: _nombre)),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
