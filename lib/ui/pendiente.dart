/// 💰 Pendiente a entregar / 📥 Pendiente a recoger.
///
/// Entrenadores: ven su propio efectivo pendiente de entregar al dueño.
/// Dueño (v1.0.15): ve el desglose por entrenador (nombre, cantidad de
/// pagos, total) y confirma el recibido de cada uno individualmente.
/// La confirmación encola la op `confirmar_entrega` y se aplica al
/// sincronizar; el espejo local se actualiza en el siguiente pull.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth.dart';
import '../bloque2_resto.dart';
import '../cobro_parcial.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import '../models/pendiente.dart';
import 'package:flutter/services.dart';
import '../sync.dart';
import 'app_bar.dart';
import 'arqueo.dart';
import 'hoja_cobrar_parcial.dart';
import 'hoja_liquidar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'skeleton.dart';
import 'widgets.dart';
import '../app_log.dart';

class PendienteScreen extends StatefulWidget {
  /// 1.32 «Mostrador Táctico»: embebida = pestaña «A Entregar»
  /// de Mi Caja (Pilar 4), sin su AppBar.
  final bool embebida;
  const PendienteScreen({super.key, this.embebida = false});
  @override
  State<PendienteScreen> createState() => _PendienteScreenState();
}

class _PendienteScreenState extends State<PendienteScreen> {
  // Vista entrenador: su propio pendiente.
  List<Map<String, dynamic>> _mens = [];
  List<Map<String, dynamic>> _diarios = [];
  List<Map<String, dynamic>> _servicios = [];
  // Ronda 17 M4-H2: suplementos en efectivo en CUP pendientes
  // de entrega (la vista del dueño ya los incluía).
  List<Map<String, dynamic>> _suplementos = [];
  // v1.3.0 (Pendiente v2): agrupado Entrenador > Días.
  List<EntrenadorPendiente> _entrenadores = [];
  List<Map<String, dynamic>> _crudos = [];
  // Gemini: totales USD separados (no mezclar con CUP).
  double _totalUsd = 0;
  // H11 (Argón caja): total CUP autoritativo (el mismo que usa la
  // liquidación) y su ajuste neto frente a la suma bruta de la
  // lista. Null hasta que _cargar lo calcula.
  double? _totalAutoritativoCup;
  double? _ajusteNetoCup;
  // v1.3.4 (C2d): detalle de ventas de suplementos indexado por id,
  // para el badge de "precio modificado" en el arqueo de caja.
  Map<int, Map<String, dynamic>> _detalleVentasSup = {};
  // 1.26.1 (Cobrar Parcial): saldo de arrastre vivo CUP
  // por entrenador (clave: trainerTelegramId en texto),
  // para la línea «Saldo de cobros parciales» de su
  // tarjeta y para enrutar su «Cobrar todo».
  Map<String, double> _arrastresCup = {};
  bool _cargando = true;
  bool _confirmando = false;
  late final bool _esDueno;

  @override
  void initState() {
    super.initState();
    _esDueno = AuthService().isOwner;
    _cargar();
  }

  /// 1.26.1 (ajuste 1 de Argón): reconstruye la lista de
  /// tarjetas desde los crudos CONSERVANDO la tarjeta
  /// sintética de quien sigue debiendo solo arrastre.
  /// procesarPendientes solo ve pagos: sin esta
  /// reinyección, un cobro parcial que consume todos los
  /// pagos de un entrenador pero deja arrastre haría
  /// desaparecer su tarjeta en la vista optimista aunque
  /// el saldo siga vivo en _arrastresCup.
  List<EntrenadorPendiente> _reconstruirEntrenadores(
    List<Map<String, dynamic>> crudos,
    Map<String, double> arrastres, {
    Map<String, String> nombresPrevios = const {},
  }) =>
      reconstruirEntrenadores(crudos, arrastres,
          nombresPrevios: nombresPrevios);

  Map<String, String> get _nombresActuales =>
      {for (final e in _entrenadores) e.trainerTelegramId: e.nombre};

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final auth = AuthService();
    if (_esDueno) {
      // El dueño no se cuenta a sí mismo en lo pendiente a recoger.
      final crudos = await pagosPendientesDetalle(
          excluirTid: auth.telegramId);
      // Gemini: USD separado del CUP.
      final usd = await pendienteRecogerUsd(
          excluirTelegramId: auth.telegramId);
      // H11 (Argón caja): el total autoritativo del dueño (misma
      // fuente que la liquidación) y su ajuste neto frente a la
      // suma bruta de la lista.
      final autCup =
          await pendienteRecoger(excluirTelegramId: auth.telegramId);
      final lista = procesarPendientes(crudos);
      // 1.26.1: arrastre vivo por entrenador (para la
      // línea de saldo y el enrutado de «Cobrar todo»).
      final arrastres = <String, double>{};
      for (final e in lista) {
        final t = int.tryParse(e.trainerTelegramId);
        if (t != null) {
          arrastres[e.trainerTelegramId] =
              await arrastreVivoCup(t);
        }
      }
      // 1.26.1: un entrenador que debe SOLO arrastre
      // (un parcial cubrió todos sus pagos) no sale de
      // pagosPendientesDetalle: se añade su tarjeta con
      // la línea de saldo para que el resto nunca quede
      // invisible; su cobro va por las mismas vías
      // («Cobrar parcial» con op_ids vacío, «Cobrar
      // todo» por liquidación).
      for (final e in (await arrastresVivosCup()).entries) {
        if (e.key == auth.telegramId) continue;
        final clave = '${e.key}';
        if (arrastres.containsKey(clave)) continue;
        arrastres[clave] = e.value.total;
        lista.add(EntrenadorPendiente(
          nombre:
              e.value.nombre.isNotEmpty ? e.value.nombre : 'Entrenador',
          trainerTelegramId: clave,
          dias: const [],
        ));
      }
      double brutoCup = 0;
      for (final e in lista) {
        brutoCup += e.totalPorMoneda('CUP');
      }
      final ajusteCup = brutoCup - autCup;
      // v1.3.4 (C2d): espejo de ventas para el badge de precio modificado.
      final ventasSup =
          await LocalDb.instance.allMirror('ventas_suplementos');
      if (mounted) {
        setState(() {
          _crudos = crudos;
          _entrenadores = lista;
          _arrastresCup = arrastres;
          _totalUsd = usd;
          _totalAutoritativoCup = autCup;
          _ajusteNetoCup = ajusteCup.abs() > 0.01 ? ajusteCup : 0;
          _detalleVentasSup = {
            for (final v in ventasSup)
              (v['id'] as num).toInt(): v
          };
          _cargando = false;
        });
      }
    } else {
      final tid = auth.telegramId;
      final (m, d, s, _) = await detallePendiente(tid);
      // Ronda 17 M4-H2: los suplementos en efectivo en CUP
      // también son pendiente a entregar (misma fuente que
      // la vista del dueño, filtrada por este entrenador).
      // Los USD ya van en _totalUsd (pendienteEntregaUsd).
      final sups = <Map<String, dynamic>>[];
      if (tid != null) {
        for (final p in await pagosPendientesDetalle()) {
          if (p['tipo'] == 'suplemento' &&
              p['trainer_telegram_id'] == tid &&
              p['moneda'] == 'CUP') {
            sups.add(p);
          }
        }
      }
      // Gemini: USD separado del CUP.
      final usd = await pendienteEntregaUsd(tid);
      // H11 (Argón caja): total autoritativo del entrenador (el
      // mismo que usa su liquidación: pendienteDeltaC1) y ajuste
      // neto frente a la suma bruta de sus listas.
      final autCup = tid != null ? await pendienteDeltaC1(tid) : 0.0;
      double bruto = 0;
      for (final p in m) {
        bruto += (p['monto'] as num?)?.toDouble() ?? 0;
      }
      for (final dd in d) {
        bruto += (dd['total'] as num?)?.toDouble() ?? 0;
      }
      for (final sv in s) {
        bruto += ((sv['precio_unitario'] as num?)?.toDouble() ?? 0) *
            ((sv['cantidad'] as num?)?.toDouble() ?? 0);
      }
      for (final sp in sups) {
        bruto += (sp['monto'] as num?)?.toDouble() ?? 0;
      }
      final ajusteCup = bruto - autCup;
      if (mounted) {
        setState(() {
          _mens = m;
          _diarios = d;
          _servicios = s;
          _suplementos = sups;
          _totalUsd = usd;
          _totalAutoritativoCup = autCup;
          _ajusteNetoCup = ajusteCup.abs() > 0.01 ? ajusteCup : 0;
          _cargando = false;
        });
      }
    }
  }

  double get _totalEntrenador {
    double t = 0;
    for (final p in _mens) {
      t += (p['monto'] as num?)?.toDouble() ?? 0;
    }
    for (final d in _diarios) {
      t += (d['total'] as num?)?.toDouble() ?? 0;
    }
    for (final s in _servicios) {
      t += ((s['precio_unitario'] as num?)?.toDouble() ?? 0) *
          ((s['cantidad'] as num?)?.toDouble() ?? 0);
    }
    // Ronda 17 M4-H2: suplementos en efectivo en CUP.
    for (final s in _suplementos) {
      t += (s['monto'] as num?)?.toDouble() ?? 0;
    }
    return t;
  }

  double get _totalDueno {
    double t = 0;
    for (final e in _entrenadores) {
      t += e.totalPorMoneda('CUP');
    }
    return t;
  }

  /// v1.3.0 (Pendiente v2): confirma por lista de IDs (día o todo).
  /// Optimistic UI: actualiza al instante, persiste en background.
  Future<void> _confirmarPorIds(PendienteDia dia, String nombre,
      String etiqueta, String trainerTelegramId) async {
    // Ronda 17 M4-H3: confirmar recibidos es solo del dueño
    // (la vista del entrenador es de lectura).
    if (!_esDueno) return;
    // H11 (Argón caja): la confirmación ciega por IDs NO descuenta
    // adelantos ni restos C1: con adelantos vivos o resto ≠ 0, no
    // se confirma aquí; se redirige a Arqueo, donde la liquidación
    // sí los descuenta. Sin esto, confirmar 1000 con 400 de
    // adelanto dejaba un descuadre de 400.
    final tidBloqueo = int.tryParse(trainerTelegramId);
    if (tidBloqueo != null) {
      final adelantos = await adelantosEnPendiente(tidBloqueo);
      double restoC1 = 0;
      for (final e in await historialEntregasC1(tidBloqueo)) {
        restoC1 += (e['resto_sin_ids'] as num?)?.toDouble() ?? 0;
      }
      if (adelantos > 0.01 || restoC1.abs() > 0.01) {
        if (!mounted) return;
        mostrarSnack(context, 'Este entrenador tiene adelantos o entregas parciales sin liquidar: liquida desde Arqueo para no dejar descuadres.', significado: SignificadoChip.alerta);
        Navigator.push(context,
            RutaIron(builder: (_) => const ArqueoScreen()));
        return;
      }
    }
    // (M2-A A2) la foto de pantalla puede estar vieja: otro
    // flujo (una liquidación, una entrega por el bot) pudo
    // cerrar parte de estos pagos tras cargar la lista, y
    // confirmar los ids de la FOTO marcaba como entregado lo
    // ya liquidado — o lo dejaba fuera del total mostrado. Se
    // re-derivan los ids vivos y el día se filtra a los que
    // SIGUEN pendientes; el diálogo de abajo ya enseña el
    // total filtrado, no el de la foto.
    if (tidBloqueo != null) {
      final frescos =
          await idsPendientesEntrega(trainerId: tidBloqueo);
      final vivosPorTipo = <String, Set<int>>{
        'mensual': frescos.pagos.toSet(),
        'diario': frescos.diarios.toSet(),
        'suplemento': frescos.suplementos.toSet(),
        'servicio': frescos.servicios.toSet(),
      };
      final filtrados = [
        for (final p in dia.pagos)
          if (vivosPorTipo[p.tipo]?.contains(p.id) ?? false) p,
      ];
      if (filtrados.isEmpty) {
        if (!mounted) return;
        mostrarSnack(context, 'Ese pendiente ya cambió: recargué la lista para que confirmes con la foto actual.', significado: SignificadoChip.alerta);
        await _cargar();
        return;
      }
      if (filtrados.length != dia.pagos.length) {
        dia = PendienteDia(fecha: dia.fecha, pagos: filtrados);
      }
    }
    // Campo 2026-11-02 (1.22): un día que no es CUP NO se
    // confirma por esta vía: confirmar_entrega valida solo
    // efectivo CUP y el servidor rechaza la op entera (la
    // venta USD #5 bloqueó la entrega de Gabriel). El USD se
    // liquida en el Arqueo principal (liquidar_caja), como los
    // adelantos de H11: se redirige en vez de encolar una op
    // condenada.
    // Autoauditoría 1.22 #1: la guarda mira CUALQUIER pago no
    // CUP del grupo, no solo el primero (un pseudo-día mezclado
    // con el primer pago en CUP colaba la venta USD igual).
    final monedaDia = dia.pagos
        .where((p) => p.moneda != 'CUP')
        .firstOrNull
        ?.moneda;
    if (monedaDia != null) {
      if (!mounted) return;
      mostrarSnack(context, 'El pendiente en $monedaDia se liquida en el Arqueo principal, no en la confirmación de entrega.', significado: SignificadoChip.alerta);
      Navigator.push(context,
          RutaIron(builder: (_) => const ArqueoScreen()));
      return;
    }
    // Fix #15 (Sol): el día ya viene separado por moneda (ver
    // procesarPendientes), pero mostramos la moneda real por seguridad.
    final moneda = dia.pagos.isEmpty
        ? 'CUP'
        : dia.pagos.first.moneda;
    final total = dia.totalPorMoneda(moneda);
    // Verificación: todos los pagos del día deben ser de la misma moneda.
    final mixto =
        dia.pagos.any((p) => p.moneda != moneda);
    // Argón B2: si es mixto, mostrar ambos totales.
    final totalCup = dia.totalPorMoneda('CUP');
    final totalUsd = dia.totalPorMoneda('USD');
    final textoMontos = mixto
        ? '${fmtMonto(totalCup)} CUP + ${fmtMonto(totalUsd)} USD'
        : '${fmtMonto(total)} $moneda';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Confirmar recibido de $nombre'),
        content: Text(
            '¿Confirmas que recibiste $textoMontos de $nombre?\n\n'
            '$etiqueta'
            '${mixto ? '\n\n⚠️ Este grupo mezcla monedas.' : ''}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          BotonPrimario(
            texto: 'Confirmar',
            onPressed: () => Navigator.pop(ctx, true),
            expandido: false,
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (_confirmando) return;
    // Gemini: UIDs compuestos para evitar colisión de IDs.
    final uids = dia.pagos.map((p) => p.uid).toSet();
    // Optimistic UI: quitar de la lista al instante.
    final crudosAnteriores =
        List<Map<String, dynamic>>.from(_crudos);
    setState(() {
      _crudos.removeWhere((p) {
        final tipo = '${p['tipo']}';
        final id = p['id'] as int? ?? -1;
        return uids.contains('${tipo}_$id');
      });
      _entrenadores = _reconstruirEntrenadores(_crudos, _arrastresCup,
          nombresPrevios: _nombresActuales);
      // Argón B2: recalcular _totalUsd en el setState optimista.
      _totalUsd = _entrenadores.fold(
          0.0, (acc, e) => acc + e.totalPorMoneda('USD'));
      _confirmando = true;
    });
    try {
      // Gemini: solo el guardado local va en el try.
      final tidConf = int.tryParse(trainerTelegramId);
      await confirmarEntregaPorIds(
        mensualIds: dia.mensualIds,
        diarioIds: dia.diarioIds,
        // v1.3.1 (Alto #1): incluir ventas de suplementos o reaparecen.
        suplementoIds: dia.suplementoIds,
        // Ítem 10: y las de servicios, con los ids que se ven.
        servicioIds: dia.servicioIds,
        // Argón Dinero #2: saldar también los adelantos de su
        // gaveta ya neteados en el total que se está
        // confirmando (pendientePorEntrenador los resta).
        adelantoIds: tidConf == null
            ? const []
            : (await idsPendientesEntrega(trainerId: tidConf))
                .adelantos,
        entrenadorNombre: nombre,
        trainerTelegramId: tidConf,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _crudos = crudosAnteriores;
          _entrenadores = _reconstruirEntrenadores(
              _crudos, _arrastresCup,
              nombresPrevios: _nombresActuales);
          _totalUsd = _entrenadores.fold(
              0.0, (acc, e) => acc + e.totalPorMoneda('USD'));
        });
        mostrarSnack(context, 'Error al guardar, intenta de nuevo', significado: SignificadoChip.error);
      }
      return;
    } finally {
      if (mounted) setState(() => _confirmando = false);
    }
    // Gemini: push fuera del try — si falla por red, queda en cola
    // y NO revierte la UI (ya está guardado localmente).
    unawaited(SyncEngine.instance.push());
    if (!mounted) return;
    mostrarSnack(context, 'Recibido de $nombre confirmado '
            '(se aplicará al sincronizar)', significado: SignificadoChip.exito);
    // Gemini: NO llamar _cargar() aquí — el estado optimista ya está
    // actualizado. Recargar ahora haría reaparecer los pagos porque
    // el mirror aún no se actualizó (el push va en background).
  }

  /// (M2-A A1) mensaje al fallar una liquidación: si el
  /// servicio rechazó por liquidación YA EN COLA, se dice tal
  /// cual (es accionable: esperar a que sincronice); el resto
  /// conserva el genérico de siempre.
  String _msgErrorLiquidacion(Object e) =>
      '$e'.contains('en cola de sincronización')
          ? '$e'.replaceFirst('Exception: ', '')
          : 'Error al guardar, intenta de nuevo';

  /// H11 compartido (1.26.1): si el entrenador tiene
  /// adelantos vivos o resto C1 sin liquidar, avisar y
  /// llevar al Arqueo, donde la liquidación sí los
  /// descuenta. Devuelve true si redirigió (el llamador
  /// aborta su flujo). Es la misma guarda que
  /// _confirmarPorIds aplica en línea.
  Future<bool> _redirigirArqueoSiBloqueado(int tid) async {
    final adelantos = await adelantosEnPendiente(tid);
    double restoC1 = 0;
    for (final e in await historialEntregasC1(tid)) {
      restoC1 += (e['resto_sin_ids'] as num?)?.toDouble() ?? 0;
    }
    if (adelantos <= 0.01 && restoC1.abs() <= 0.01) return false;
    if (!mounted) return true;
    mostrarSnack(context, 'Este entrenador tiene adelantos o entregas parciales sin liquidar: liquida desde Arqueo para no dejar descuadres.', significado: SignificadoChip.alerta);
    Navigator.push(context,
        RutaIron(builder: (_) => const ArqueoScreen()));
    return true;
  }

  /// 1.26.1: «Cobrar parcial» — el dueño teclea cuánto
  /// recogió; el monto se compone FIFO (arrastre primero,
  /// luego los pagos más viejos) y se encola como
  /// liquidar_caja, sin partir ningún pago.
  Future<void> _abrirCobrarParcial(
      EntrenadorPendiente ent) async {
    if (!_esDueno || _confirmando) return;
    final tid = int.tryParse(ent.trainerTelegramId);
    if (tid == null) return;
    if (await _redirigirArqueoSiBloqueado(tid)) return;
    final foto = await fotoCobroParcial(tid);
    final arq = await pendienteArqueo(tid);
    if (!mounted) return;
    if (foto.total <= 0.01) {
      mostrarSnack(context, '${ent.nombre} no tiene pendiente en CUP por recoger.', significado: SignificadoChip.alerta);
      return;
    }
    // Cruce con la cifra de la liquidación: si no
    // coinciden, el estado no es el limpio que el
    // compositor supone (ajustes C1 en vuelo) y la vía
    // segura es el Arqueo.
    if ((arq.cup - foto.total).abs() > 0.01) {
      mostrarSnack(context, 'El pendiente de ${ent.nombre} tiene ajustes en curso: liquídalo desde el Arqueo.', significado: SignificadoChip.alerta);
      Navigator.push(context,
          RutaIron(builder: (_) => const ArqueoScreen()));
      return;
    }
    final monto = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      builder: (_) => HojaCobrarParcial(
          nombre: ent.nombre,
          total: foto.total,
          arrastre: foto.arrastre),
    );
    if (monto == null || !mounted) return;
    // Punto D (Argón): reverificar contra una foto
    // fresca antes de encolar. Si el pendiente cambió
    // mientras la hoja estaba abierta (llegó un sync),
    // no se encola sobre la foto vieja: se avisa y la
    // pantalla se recarga para confirmar de nuevo
    // (el patrón del Arqueo).
    final fresca = await fotoCobroParcial(tid);
    if (!mounted) return;
    var mismas = fresca.filas.length == foto.filas.length;
    if (mismas) {
      for (var i = 0; i < fresca.filas.length; i++) {
        if (fresca.filas[i].uid != foto.filas[i].uid ||
            fresca.filas[i].monto != foto.filas[i].monto) {
          mismas = false;
          break;
        }
      }
    }
    if ((fresca.total - foto.total).abs() > 0.01 || !mismas) {
      mostrarSnack(context, 'El pendiente de ${ent.nombre} cambió mientras decidías (era ${fmtMonto(foto.total)} CUP y ahora es ${fmtMonto(fresca.total)} CUP). Revísalo y confirma de nuevo.', significado: SignificadoChip.alerta);
      _cargar();
      return;
    }
    final comp = componerCobroParcial(
        filasFifo: fresca.filas,
        arrastre: fresca.arrastre,
        monto: monto);
    if (comp == null) {
      mostrarSnack(context, 'Cantidad inválida para el pendiente actual.', significado: SignificadoChip.error);
      return;
    }
    setState(() => _confirmando = true);
    String liqIdParcial;
    try {
      liqIdParcial = await crearLiquidacion(
        entrenadorTelegramId: tid,
        entrenadorNombre: ent.nombre,
        montoEsperado: comp.montoEsperado,
        montoEntregado: comp.montoEntregado,
        opIds: comp.opIds,
        moneda: 'CUP',
        nota: 'Cobro parcial (Pendiente a recoger)',
      );
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, _msgErrorLiquidacion(e), significado: SignificadoChip.error);
      }
      return;
    } finally {
      if (mounted) setState(() => _confirmando = false);
    }
    // Optimista, como _confirmarPorIds: salen los pagos
    // cubiertos y el arrastre pasa a ser el nuevo (la
    // liquidación aún no bajó al espejo; recargar
    // ahora lo desharía visualmente).
    final uids = comp.cubiertas.map((f) => f.uid).toSet();
    setState(() {
      _crudos.removeWhere(
          (p) => uids.contains('${p['tipo']}_${p['id']}'));
      // 1.26.1 (ajuste 1 de Argón): el arrastre nuevo se
      // fija ANTES de reconstruir y la reconstrucción
      // conserva la tarjeta sintética si el entrenador
      // quedó debiendo solo saldo de parciales.
      _arrastresCup[ent.trainerTelegramId] = comp.nuevoArrastre;
      _entrenadores = _reconstruirEntrenadores(_crudos, _arrastresCup,
          nombresPrevios: _nombresActuales);
      _totalUsd = _entrenadores.fold(
          0.0, (acc, e) => acc + e.totalPorMoneda('USD'));
      if (_totalAutoritativoCup != null) {
        _totalAutoritativoCup =
            (_totalAutoritativoCup! - monto).clamp(0.0, double.infinity);
      }
    });
    unawaited(SyncEngine.instance.push());
    if (!mounted) return;
    // (M2-BC B2) el aviso del cobro parcial (una
    // liquidación) también lleva «Deshacer» mientras la op
    // siga en el teléfono.
    mostrarAvisoLiquidacionConDeshacer(
      ScaffoldMessenger.of(context),
      mensaje: 'Cobro parcial de ${fmtMonto(monto)} CUP de '
          '${ent.nombre} registrado (se aplicará al sincronizar)',
      liqId: liqIdParcial,
      alDeshacer: () async {
        if (mounted) await _cargar();
      },
    );
  }

  /// 1.26.1 (Argón, punto 1 del veredicto): «Cobrar
  /// todo» con saldo de arrastre vivo va por
  /// liquidar_caja (esperado = entregado =
  /// pendienteArqueo, con todos los IDs vivos): la vía
  /// confirmar_entrega solo marca IDs y dejaría el
  /// arrastre sucio en liquidaciones_caja para siempre.
  Future<void> _cobrarTodoConArrastre(
      EntrenadorPendiente ent) async {
    if (!_esDueno || _confirmando) return;
    final tid = int.tryParse(ent.trainerTelegramId);
    if (tid == null) return;
    // 1.26.1 (ajuste 2 de Argón): la misma guarda H11
    // que _abrirCobrarParcial y _confirmarPorIds — con
    // adelanto vivo o resto del libro C1, «Cobrar todo»
    // también se resuelve en el Arqueo, no aquí.
    if (await _redirigirArqueoSiBloqueado(tid)) return;
    var esperado = (await pendienteArqueo(tid)).cup;
    if (!mounted) return;
    if (esperado <= 0.01) {
      mostrarSnack(context, '${ent.nombre} no tiene pendiente confirmado en CUP.', significado: SignificadoChip.alerta);
      return;
    }
    final usdPendiente = ent.totalPorMoneda('USD');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Cobrar todo de ${ent.nombre}'),
        content: Text(
            '¿Confirmas que recibiste ${fmtMonto(esperado)} CUP de ${ent.nombre}?\n\n'
            'Incluye el saldo de cobros parciales anteriores y se liquida con las reglas del arqueo.'
            '${usdPendiente > 0.01 ? '\n\nEl pendiente en USD (${fmtMonto(usdPendiente)} USD) no entra aquí: se liquida en el Arqueo principal.' : ''}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          BotonPrimario(
            texto: 'Confirmar',
            onPressed: () => Navigator.pop(ctx, true),
            expandido: false,
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Reverificación (patrón Arqueo): si la cifra
    // cambió desde el diálogo, no se encola sobre la
    // foto vieja.
    final fresco = (await pendienteArqueo(tid)).cup;
    if (!mounted) return;
    if ((fresco - esperado).abs() > 0.01) {
      mostrarSnack(context, 'El pendiente cambió: era ${fmtMonto(esperado)} CUP y ahora es ${fmtMonto(fresco)} CUP. La pantalla se actualizó; confirma de nuevo.', significado: SignificadoChip.alerta);
      _cargar();
      return;
    }
    esperado = fresco;
    setState(() => _confirmando = true);
    String liqIdTotal;
    try {
      final opIds = await idsPendienteArqueo(tid, moneda: 'CUP');
      liqIdTotal = await crearLiquidacion(
        entrenadorTelegramId: tid,
        entrenadorNombre: ent.nombre,
        montoEsperado: esperado,
        montoEntregado: esperado,
        opIds: opIds,
        moneda: 'CUP',
        nota: 'Cobro total con saldo de parciales (Pendiente a recoger)',
      );
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, _msgErrorLiquidacion(e), significado: SignificadoChip.error);
      }
      return;
    } finally {
      if (mounted) setState(() => _confirmando = false);
    }
    setState(() {
      // Solo sale lo CUP (lo liquidado); el pendiente
      // USD del entrenador NO se tocó y sigue visible
      // (autoauditoría 1.26.1: la retirada optimista
      // inicial borraba también sus filas USD).
      _crudos.removeWhere((p) =>
          '${p['trainer_telegram_id'] ?? p['entrenador_id'] ?? ''}' ==
              ent.trainerTelegramId &&
          (p['moneda'] as String? ?? 'CUP') == 'CUP');
      // 1.26.1 (ajuste 1 de Argón): mismo criterio que
      // en el cobro parcial — arrastre a 0 primero y
      // reconstrucción que conserva las tarjetas
      // sintéticas de los DEMÁS entrenadores.
      _arrastresCup[ent.trainerTelegramId] = 0;
      _entrenadores = _reconstruirEntrenadores(_crudos, _arrastresCup,
          nombresPrevios: _nombresActuales);
      _totalUsd = _entrenadores.fold(
          0.0, (acc, e) => acc + e.totalPorMoneda('USD'));
      if (_totalAutoritativoCup != null) {
        _totalAutoritativoCup =
            (_totalAutoritativoCup! - esperado).clamp(0.0, double.infinity);
      }
    });
    unawaited(SyncEngine.instance.push());
    if (!mounted) return;
    // (M2-BC B2) «Deshacer» también aquí (es una
    // liquidación): mientras la op siga en el teléfono.
    mostrarAvisoLiquidacionConDeshacer(
      ScaffoldMessenger.of(context),
      mensaje: 'Recibido de ${ent.nombre} confirmado '
          '(se aplicará al sincronizar)',
      liqId: liqIdTotal,
      alDeshacer: () async {
        if (mounted) await _cargar();
      },
    );
  }

  /// (M2-BC B6) «Liquidar con arrastre» sin salir de
  /// Pendiente: abre la hoja con la liquidación completa
  /// del entrenador (la misma del Arqueo) y, al éxito,
  /// aplica la actualización optimista de la tarjeta y el
  /// aviso con «Deshacer» (B2).
  Future<void> _liquidarConArrastre(EntrenadorPendiente ent) async {
    if (!_esDueno || _confirmando) return;
    final tid = int.tryParse(ent.trainerTelegramId);
    if (tid == null) {
      mostrarSnack(context,
          'No se pudo liquidar a ${ent.nombre}.',
          significado: SignificadoChip.error);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final res = await showModalBottomSheet<ResultadoLiquidacion>(
      context: context,
      isScrollControlled: true,
      builder: (_) => HojaLiquidar(telegramId: tid, nombre: ent.nombre),
    );
    if (res == null || !mounted) return;
    // Optimista (mismo criterio que _cobrarTodoConArrastre):
    // salen los pagos cubiertos por la liquidación y el
    // arrastre CUP pasa a ser esperado − entregado.
    const tipoPorTabla = {
      'pagos': 'mensual',
      'pagos_diarios': 'diario',
      'ventas_suplementos': 'suplemento',
      'servicio_ventas': 'servicio',
    };
    final uids = <String>{
      for (final e in res.opIds.entries)
        if (tipoPorTabla[e.key] != null)
          for (final id in e.value) '${tipoPorTabla[e.key]}_$id',
    };
    setState(() {
      _crudos.removeWhere(
          (p) => uids.contains('${p['tipo']}_${p['id']}'));
      if (res.moneda == 'CUP') {
        _arrastresCup[ent.trainerTelegramId] =
            (res.esperado - res.entregado)
                .clamp(0.0, double.infinity);
        if (_totalAutoritativoCup != null) {
          _totalAutoritativoCup =
              (_totalAutoritativoCup! - res.entregado)
                  .clamp(0.0, double.infinity);
        }
      }
      _entrenadores = _reconstruirEntrenadores(_crudos, _arrastresCup,
          nombresPrevios: _nombresActuales);
      _totalUsd = _entrenadores.fold(
          0.0, (acc, e) => acc + e.totalPorMoneda('USD'));
    });
    mostrarAvisoLiquidacionConDeshacer(
      messenger,
      mensaje: 'Liquidación de ${ent.nombre} registrada '
          '(${fmtMonto(res.entregado)} ${res.moneda})',
      liqId: res.liqId,
      alDeshacer: () async {
        if (mounted) await _cargar();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: widget.embebida
          ? null
          : appBarIron(
              context,
              _esDueno ? 'Pendiente a recoger' : 'Pendiente a entregar',
            ),
      body: Column(
        children: [
          // SL-5B G04-1: embebida en Mi Caja, la sync ya la
          // dice la cabecera del marco — el banner solo va
          // suelto (patrón de Bandeja WhatsApp).
          if (!widget.embebida) const SyncBanner(),
          if (!_cargando) _tarjetaTotal(),
          Expanded(
            child: CruceEstados(
              // Corrección A1-D4: fundido esqueleto→contenido
              // con el cruce de la casa (antes, ternario seco).
              estado: _cargando ? 'cargando' : 'contenido',
              child: _cargando
                  // (M2-BC C5) esqueleto estructural de la
                  // pantalla (total + tarjetas) en vez del
                  // spinner genérico.
                  ? const SkeletonPendiente()
                  : RefrescoIron(
                      onRefresh: _cargar,
                      child: _esDueno
                          ? _listaDueno()
                          : _listaEntrenador(),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// v1.2.1: rediseñada al estilo oscuro/naranja de la app
  /// (antes fondo beige que no combinaba).
  /// Gemini: muestra CUP y USD por separado (no mezclar monedas).
  Widget _tarjetaTotal() {
    // H11 (Argón caja): la tarjeta muestra el valor autoritativo
    // (el mismo que usa la liquidación), no la suma bruta: con
    // adelantos o parciales la suma bruta miente (ej. 1000 vs 600).
    final crudo = _esDueno ? _totalDueno : _totalEntrenador;
    final total = _totalAutoritativoCup ?? crudo;
    final hayPendiente = total > 0 || _totalUsd > 0;
    final subtitulo = _esDueno
        ? (hayPendiente
            ? 'por recoger de los entrenadores'
            : 'al día, nada que recoger')
        : (hayPendiente
            ? 'por entregar al dueño'
            : 'al día, nada pendiente');
    final colorAcento =
        hayPendiente ? AppColores.naranja : AppColores.exito;
    // Gemini: montos por moneda, sin mezclar.
    // 1.29 (Oleada 2, D-19): el pendiente total CUENTA
    // hasta su cifra cuando cambia (MontoAnimado, 300 ms)
    // en vez de saltar de golpe: al cobrar o liquidar se
    // nota al instante si el número se movió y a cuánto.
    // (1.30 D4 · UI130-13): el animado formatea SOLO el
    // CUP; el USD deja de viajar pegado en esta cadena y
    // se pinta en su propia línea bajo el total, como
    // métrica secundaria y sin animar.
    String formatoTotal(double v) =>
        v > 0 ? '${fmtMonto(v)} CUP' : '0 CUP';

    return Padding(
      padding: const EdgeInsets.all(AppEspacio.md),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  hayPendiente
                      ? Icons.account_balance_wallet_rounded
                      : Icons.check_circle_outline_rounded,
                  color: colorAcento,
                  size: 28,
                ),
                const SizedBox(width: AppEspacio.sm),
                Flexible(
                  child: MontoAnimado(
                    valor: total,
                    formato: formatoTotal,
                    style: AppTexto.display.copyWith(
                      color: colorAcento,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.xs),
            Text(subtitulo,
                style: AppTexto.secundario.copyWith(
                    color:
                        AppColores.textoSecundario(context))),
            // (1.30 D4 · UI130-13) USD como métrica propia:
            // su línea, con su formato de siempre (dos
            // decimales), sin mezclarse con el total CUP.
            if (_totalUsd > 0)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.xs),
                child: Text(
                    '${_totalUsd.toStringAsFixed(2)} USD',
                    style: AppTexto.subtitulo.copyWith(
                        color: AppColores.textoSecundario(context))),
              ),
            // H11 (Argón caja): desglose solo cuando el autoritativo
            // difiere del bruto (adelantos, parciales, arrastres).
            if (_ajusteNetoCup != null && _ajusteNetoCup!.abs() > 0.01)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.xs),
                child: Text(
                    'Ajuste neto ${_ajusteNetoCup! > 0 ? '-' : '+'}${fmtMonto(_ajusteNetoCup!.abs())} CUP por adelantos, entregas parciales o arrastres',
                    textAlign: TextAlign.center,
                    style: AppTexto.secundario.copyWith(
                        color: AppColores.textoSecundario(context))),
              ),
          ],
        ),
      ),
    );
  }

  // (1.30 D4 · UI130-13) la fila del desglose vive ahora
  // en componentes.dart como FilaLibro, compartida con
  // Nómina: el libro de pendiente se lee igual en los
  // dos roles y en las dos pantallas de dinero.

  /// (1.30 D4 · UI130-13) Tarjeta de un concepto del
  /// desglose del entrenador: título y sus filas de
  /// libro, con el mismo patrón que el resto de
  /// pantallas de dinero.
  Widget _tarjetaConceptoPendiente({
    required String titulo,
    required List<Widget> filas,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        padding: const EdgeInsets.all(AppEspacio.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(titulo, style: AppTexto.subtitulo),
            const SizedBox(height: AppEspacio.xs),
            ...filas,
          ],
        ),
      ),
    );
  }

  /// Vista del entrenador: su propio pendiente, agrupado
  /// por concepto en tarjetas con FilaLibro (UI130-13);
  /// los datos y los montos son los de siempre.
  Widget _listaEntrenador() {
    if (_mens.isEmpty &&
        _diarios.isEmpty &&
        _servicios.isEmpty &&
        _suplementos.isEmpty) {
      return ListView(
        padding:
            const EdgeInsets.symmetric(horizontal: AppEspacio.lg),
        children: const [
          EstadoVacio(
            icono: Icons.account_balance_wallet_rounded,
            titulo: 'Sin pagos pendientes de entrega.',
          ),
        ],
      );
    }
    return ListView(
      padding:
          const EdgeInsets.symmetric(horizontal: AppEspacio.lg),
      children: [
        if (_mens.isNotEmpty)
          _tarjetaConceptoPendiente(
            titulo: 'Mensualidades en efectivo',
            filas: [
              for (final p in _mens)
                FilaLibro(
                  icono: Icons.payments_rounded,
                  colorIcono: AppColores.exito,
                  metodo: '${p['metodo'] ?? ''}',
                  concepto: 'Mensualidad — ${p['metodo']}',
                  detalle:
                      '${fmtFecha(p['fecha'] as String?)} · ${p['meses'] ?? 1} mes(es)',
                  monto: '${fmtMonto(p['monto'])} CUP',
                ),
            ],
          ),
        if (_diarios.isNotEmpty)
          _tarjetaConceptoPendiente(
            titulo: 'Pagos diarios',
            filas: [
              for (final d in _diarios)
                FilaLibro(
                  icono: Icons.today_rounded,
                  colorIcono: AppColores.info,
                  concepto: 'Pago diario',
                  detalle:
                      '${fmtFecha(d['fecha'] as String?)} · ${d['turno'] ?? ''} x${d['cantidad'] ?? '?'}',
                  monto: '${fmtMonto(d['total'])} CUP',
                ),
            ],
          ),
        if (_servicios.isNotEmpty)
          _tarjetaConceptoPendiente(
            titulo: 'Servicios (dosis y agua)',
            filas: [
              for (final s in _servicios)
                FilaLibro(
                  icono: Icons.bolt_rounded,
                  colorIcono: AppColores.naranja,
                  concepto: switch ('${s['tipo']}') {
                    'dosis_con_agua' => 'Dosis con agua',
                    'agua_suelta' => 'Agua',
                    _ => 'Dosis',
                  },
                  detalle: '${fmtFecha(s['fecha'] as String?)}'
                      '${'${s['cliente_nombre'] ?? ''}'.isNotEmpty ? ' · ${s['cliente_nombre']}' : ''}',
                  monto:
                      '${fmtMonto(((s['precio_unitario'] as num?)?.toDouble() ?? 0) * ((s['cantidad'] as num?)?.toDouble() ?? 0))} CUP',
                ),
            ],
          ),
        // Ronda 17 M4-H2: suplementos en efectivo en CUP.
        if (_suplementos.isNotEmpty)
          _tarjetaConceptoPendiente(
            titulo: 'Suplementos en efectivo',
            filas: [
              for (final s in _suplementos)
                FilaLibro(
                  icono: Icons.shopping_bag_rounded,
                  colorIcono: AppColores.naranja,
                  concepto: 'Suplemento',
                  detalle: '${s['descripcion'] ?? 'Venta suplemento'} · '
                      '${fmtFecha(s['creada_en'] as String?)}',
                  monto: '${fmtMonto(s['monto'])} CUP',
                ),
            ],
          ),
      ],
    );
  }

  /// v1.3.0 (Pendiente v2): Entrenador > Días.
  Widget _listaDueno() {
    if (_entrenadores.isEmpty) {
      return ListView(
        padding: const EdgeInsets.symmetric(horizontal: AppEspacio.lg),
        children: const [
          Padding(
            padding: EdgeInsets.only(top: AppEspacio.xxl),
            child: Text(
                'Nada pendiente de recoger.',
                textAlign: TextAlign.center,
                style: AppTexto.secundario),
          ),
        ],
      );
    }
    return ListView.builder(
      padding:
          const EdgeInsets.symmetric(horizontal: AppEspacio.lg, vertical: AppEspacio.xs),
      itemCount: _entrenadores.length,
      itemBuilder: (ctx, i) {
        // (M2-BC C3) porción del total CUP a recoger (con
        // arrastres) que le corresponde a este entrenador.
        final totalGeneral = _entrenadores.fold<double>(
            0,
            (s, e) =>
                s +
                e.totalPorMoneda('CUP') +
                (_arrastresCup[e.trainerTelegramId] ?? 0));
        final mio = _entrenadores[i].totalPorMoneda('CUP') +
            (_arrastresCup[_entrenadores[i].trainerTelegramId] ?? 0);
        return _EntrenadorCard(
        entrenador: _entrenadores[i],
        porcion: totalGeneral > 0 ? mio / totalGeneral : 0,
        confirmando: _confirmando,
        // v1.3.4 (C2d): detalle de ventas para el badge de precio.
        detalleVentas: _detalleVentasSup,
        // 1.26.1: arrastre vivo y cobro parcial.
        arrastreCup:
            _arrastresCup[_entrenadores[i].trainerTelegramId] ?? 0,
        onCobrarParcial: () =>
            _abrirCobrarParcial(_entrenadores[i]),
        onConfirmarDia: (dia) => _confirmarPorIds(
          dia,
          _entrenadores[i].nombre,
          'Se marcarán como entregados los ${dia.pagos.length} '
          'pagos del ${dia.etiquetaFecha.toLowerCase()}.',
          _entrenadores[i].trainerTelegramId,
        ),
        onConfirmarTodo: () {
          // 1.26.1 (Argón, Cobrar Parcial punto 1): con
          // saldo de arrastre vivo, «Cobrar todo» NO va
          // por confirmar_entrega (dejaría el arrastre
          // sucio): se liquida completo por liquidar_caja.
          if ((_arrastresCup[_entrenadores[i]
                      .trainerTelegramId] ??
                  0) >
              0.01) {
            _cobrarTodoConArrastre(_entrenadores[i]);
            return;
          }
          // Autoauditoría 1.22 #1 (2026-11-03): «Cobrar todo»
          // NO remezcla monedas. Los días vienen separados por
          // fecha+moneda (Fix #15) y el pseudo-día viejo los
          // volvía a juntar: con el primer pago en CUP, la venta
          // USD viajaba en la op y el servidor la rechazaba
          // ENTERA (el bug de campo de la 1B por otra puerta);
          // con el primero en USD, ni la parte CUP se confirmaba.
          // Aquí solo entra lo CUP; lo demás se avisa y sigue
          // su vía (Arqueo principal), como el día no-CUP.
          final todos = _entrenadores[i].dias
              .expand((d) => d.pagos)
              .toList();
          final cup = [
            for (final p in todos)
              if (p.moneda == 'CUP') p,
          ];
          final hayOtraMoneda = cup.length != todos.length;
          if (cup.isEmpty) {
            mostrarSnack(context, 'El pendiente de ${_entrenadores[i].nombre} es en USD: se liquida en el Arqueo principal, no en la confirmación de entrega.', significado: SignificadoChip.alerta);
            Navigator.push(context,
                RutaIron(builder: (_) => const ArqueoScreen()));
            return;
          }
          final pseudo = PendienteDia(
              fecha: ahoraHabana(), pagos: cup);
          _confirmarPorIds(
            pseudo,
            _entrenadores[i].nombre,
            'Se marcarán como entregados todos sus pagos pendientes en CUP.'
            '${hayOtraMoneda ? '\n\nEl pendiente en USD no entra aquí: se liquida en el Arqueo principal.' : ''}',
            _entrenadores[i].trainerTelegramId,
          );
        },
        onWhatsApp: () =>
            _copiarCuadre(_entrenadores[i]),
        onLiquidar: () async {
          final tid =
              int.tryParse(_entrenadores[i].trainerTelegramId);
          if (tid == null) {
            mostrarSnack(context,
                'No se pudo abrir el arqueo de ${_entrenadores[i].nombre}.',
                significado: SignificadoChip.error);
            return;
          }
          await Navigator.push(
            context,
            RutaIron(
              builder: (_) => DetalleArqueoScreen(
                telegramId: tid,
                nombre: _entrenadores[i].nombre,
              ),
            ),
          );
          if (mounted) _cargar();
        },
        // (M2-BC B6) liquidar con arrastre sin salir de
        // Pendiente (hoja con la liquidación completa).
        onLiquidarArrastre: () =>
            _liquidarConArrastre(_entrenadores[i]),
        );
      },
    );
  }

  /// Copia el texto de cuadre al portapapeles (Gemini #5).
  Future<void> _copiarCuadre(
      EntrenadorPendiente ent) async {
    final totalCup = ent.totalPorMoneda('CUP');
    final totalUsd = ent.totalPorMoneda('USD');
    // 1.26.1: el saldo de cobros parciales también es
    // dinero en su mano — el cuadre lo nombra y lo suma,
    // como hace el resumen del servidor.
    final arrastre = _arrastresCup[ent.trainerTelegramId] ?? 0;
    final buf = StringBuffer();
    buf.writeln(
        '${ent.nombre}, pendiente a entregar:');
    for (final dia in ent.dias) {
      // Argón B2: usar moneda real del día.
      final m = dia.pagos.isEmpty
          ? 'CUP'
          : dia.pagos.first.moneda;
      buf.writeln(
          '• ${dia.etiquetaFecha}: '
          '${fmtMonto(dia.totalPorMoneda(m))} $m '
          '(${dia.pagos.length} pagos)');
    }
    if (arrastre > 0.01) {
      buf.writeln(
          '• Saldo de cobros parciales: ${fmtMonto(arrastre)} CUP');
    }
    buf.write('Total: ${fmtMonto(totalCup + arrastre)} CUP');
    if (totalUsd > 0) {
      buf.write(' + ${fmtMonto(totalUsd)} USD');
    }
    await Clipboard.setData(
        ClipboardData(text: buf.toString()));
    if (!mounted) return;
    mostrarSnack(context, 'Texto copiado, pégalo en WhatsApp');
  }
}

/// Tarjeta de entrenador con sus días (v1.3.0).
class _EntrenadorCard extends StatelessWidget {
  final EntrenadorPendiente entrenador;
  final bool confirmando;
  final void Function(PendienteDia dia) onConfirmarDia;
  final VoidCallback onConfirmarTodo;
  final VoidCallback onWhatsApp;

  /// 1.26.1: saldo de arrastre vivo CUP del entrenador
  /// (de cobros parciales anteriores) y la acción de
  /// cobrar parcialmente con monto tecleado.
  final double arrastreCup;
  final VoidCallback onCobrarParcial;

  /// 1.25 T70: liquidar en el arqueo de ESTE entrenador
  /// sin salir a buscar la pantalla (el paso final del
  /// flujo único «Efectivo por entregar»).
  final VoidCallback onLiquidar;

  /// (M2-BC B6) liquidar con arrastre SIN salir de
  /// Pendiente: la hoja con la liquidación completa.
  final VoidCallback onLiquidarArrastre;

  /// (M2-BC C3) porción del total a recoger que le
  /// corresponde a este entrenador (0..1): la barra de
  /// su tarjeta.
  final double porcion;
  // v1.3.4 (C2d): ventas de suplementos por id (badge precio modificado).
  final Map<int, Map<String, dynamic>> detalleVentas;

  const _EntrenadorCard({
    required this.entrenador,
    required this.confirmando,
    required this.onConfirmarDia,
    required this.onConfirmarTodo,
    required this.onWhatsApp,
    required this.onLiquidar,
    required this.onLiquidarArrastre,
    required this.onCobrarParcial,
    this.porcion = 0,
    this.arrastreCup = 0,
    this.detalleVentas = const {},
  });

  @override
  Widget build(BuildContext context) {
    final nombre = entrenador.nombre;
    // Argón B2: mostrar CUP y USD.
    // 1.26.1: el total de la tarjeta incluye el saldo
    // de cobros parciales (es dinero en su mano y es lo
    // que «Cobrar todo» cobra en CUP por la vía de
    // liquidación cuando hay arrastre).
    final totalCup =
        entrenador.totalPorMoneda('CUP') + arrastreCup;
    final totalUsd = entrenador.totalPorMoneda('USD');
    final totalTxt = totalUsd > 0
        ? '${fmtMonto(totalCup)} CUP + ${fmtMonto(totalUsd)} USD'
        : '${fmtMonto(totalCup)} CUP';
    final n = entrenador.totalPagos;
    return Card(
      margin: const EdgeInsets.only(bottom: AppEspacio.md),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor:
              AppColores.naranja.withValues(alpha: 0.15),
          child: Text(
            nombre.isNotEmpty
                ? nombre[0].toUpperCase()
                : '?',
            style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: AppColores.naranja),
          ),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(nombre,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold)),
            ),
            if (entrenador.tieneRetraso) ...[
              const SizedBox(width: 8),
              const Icon(Icons.warning_amber_rounded,
                  color: AppColores.alerta, size: 18),
            ],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(n == 0
                ? 'Solo saldo de cobros parciales'
                : '$n pago${n == 1 ? '' : 's'} sin entregar'),
            // (M2-BC C3) urgencia visible: la antigüedad del
            // día más viejo sin entregar, coloreada por nivel
            // (ámbar 2–3 días, rojo 4+; la regla de
            // PendienteDia.nivelAlerta).
            if (entrenador.diasMasViejo > 0) ...[
              const SizedBox(height: 2),
              Text(
                'Día más viejo: hace ${entrenador.diasMasViejo} '
                'día${entrenador.diasMasViejo == 1 ? '' : 's'}',
                style: AppTexto.metadato.copyWith(
                  color: entrenador.nivelAlertaMax == 2
                      ? AppColores.error
                      : entrenador.nivelAlertaMax == 1
                          ? AppColores.alerta
                          : AppColores.textoSecundario(context),
                  fontWeight: entrenador.nivelAlertaMax > 0
                      ? FontWeight.w600
                      : null,
                ),
              ),
            ],
            // (M2-BC C3) barra de porción: qué parte del
            // total a recoger le corresponde a este
            // entrenador.
            if (porcion > 0) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: porcion.clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: AppColores.borde(context)
                            .withValues(alpha: 0.3),
                        valueColor:
                            const AlwaysStoppedAnimation<Color>(
                                AppColores.naranja),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 1.29 (GD-12, caza del test): con porción
                  // 100 % el texto fijo no cabía junto a la
                  // barra en anchos estrechos y la fila
                  // desbordaba; Flexible + elipsis.
                  Flexible(
                    child: Text(
                        '${(porcion * 100).round()}% del total',
                        overflow: TextOverflow.ellipsis,
                        style: AppTexto.metadato.copyWith(
                            color: AppColores.textoSecundario(
                                context))),
                  ),
                ],
              ),
            ],
          ],
        ),
        trailing: Text(
          totalTxt,
          style: AppTexto.subtitulo.copyWith(
              color: AppColores.textoNaranja(context),
              fontWeight: FontWeight.bold),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppEspacio.md, vertical: AppEspacio.xs),
            child: Column(
              children: [
                for (final dia in entrenador.dias)
                  _DiaTile(
                    dia: dia,
                    detalleVentas: detalleVentas,
                    onConfirmar: confirmando
                        ? null
                        : () => onConfirmarDia(dia),
                  ),
                // 1.26.1 (rediseño + Cobrar Parcial): el
                // saldo de parciales se VE en su propia
                // línea — un resto sin pagos concretos
                // nunca queda invisible.
                if (arrastreCup > 0.01) ...[
                  // (1.30 D4 · UI130-13) la línea del saldo
                  // adopta la FilaLibro del libro único.
                  FilaLibro(
                    icono: Icons.autorenew_rounded,
                    colorIcono: AppColores.textoNaranja(context),
                    concepto: 'Saldo de cobros parciales',
                    monto: '${fmtMonto(arrastreCup)} CUP',
                    colorMonto: AppColores.textoNaranja(context),
                  ),
                ],
                if (totalCup > 0 || arrastreCup > 0.01) ...[
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.payments_rounded,
                          size: 18),
                      label: const Text('Cobrar parcial'),
                      onPressed:
                          confirmando ? null : onCobrarParcial,
                      style: OutlinedButton.styleFrom(
                        foregroundColor:
                            AppColores.textoNaranja(context),
                        side: const BorderSide(
                            color: AppColores.naranja),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                ],
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check_circle_outline_rounded,
                        size: 18),
                    label: Text(
                        'Cobrar todo ($totalTxt)'),
                    onPressed: confirmando
                        ? null
                        : onConfirmarTodo,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColores.exito,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                // (M2-BC B6) liquidar con arrastre AQUÍ
                // mismo: la hoja trae la liquidación
                // completa (esperado canónico, entregado,
                // moneda) sin navegar al Arqueo.
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(
                        Icons.point_of_sale_rounded,
                        size: 16),
                    label: const Text('Liquidar con arrastre…'),
                    onPressed:
                        confirmando ? null : onLiquidarArrastre,
                  ),
                ),
                const SizedBox(height: 4),
                // 1.25 T70: Liquidar es el paso final del
                // flujo en esta misma pantalla: abre el
                // arqueo de este entrenador (adelantos,
                // parciales y USD van por esa vía) y al
                // volver la lista se recarga aquí.
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(
                        Icons.account_balance_wallet_rounded,
                        size: 16),
                    label: const Text('Liquidar en arqueo…'),
                    onPressed: onLiquidar,
                  ),
                ),
                // 1.26.1 (rediseño): el cuadre baja a
                // acción de texto discreta; los botones
                // de cobro son los protagonistas.
                Center(
                  child: TextButton.icon(
                    icon:
                        const Icon(Icons.share_rounded, size: 15),
                    label: const Text('Cuadre a WhatsApp'),
                    onPressed: onWhatsApp,
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta plana de un día (Gemini #4): sin acordeón doble.
class _DiaTile extends StatefulWidget {
  final PendienteDia dia;
  final VoidCallback? onConfirmar;
  // v1.3.4 (C2d): ventas de suplementos por id (badge precio modificado).
  final Map<int, Map<String, dynamic>> detalleVentas;

  const _DiaTile({
    required this.dia,
    this.onConfirmar,
    this.detalleVentas = const {},
  });

  @override
  State<_DiaTile> createState() => _DiaTileState();
}

class _DiaTileState extends State<_DiaTile> {
  // 1.29 (Oleada 2, GD-12): la tarjeta ya NO esconde
  // pagos tras un «Ver N pagos más...»: pinta SIEMPRE
  // todos los del día (ver el cuerpo de build).

  // 1.25 T118 (F2-13): insignia con tokens semánticos del
  // tema — antes colores Material fijos (red/amber.shade100,
  // textos black87) que en modo oscuro quedaban como un
  // parche claro sobre la tarjeta de tema.
  Color _badgeBg(int nivel) {
    if (nivel == 2) return AppColores.error.withValues(alpha: 0.15);
    if (nivel == 1) return AppColores.alerta.withValues(alpha: 0.18);
    return AppColores.bannerGrisA.withValues(alpha: 0.18);
  }

  Color _badgeFg(BuildContext context, int nivel) {
    if (nivel == 2) return AppColores.errorOscuro;
    if (nivel == 1) return AppColores.alertaOscuro;
    return AppColores.textoSecundario(context);
  }

  /// v1.3.4 (C2d): chip ámbar cuando una venta de suplemento se cobró a
  /// un precio distinto del oficial. Comparación en centavos enteros
  /// (candado a de auditoría). Muestra también la `nota_precio` si existe.
  Widget _chipPrecioModificado(PagoPendiente p) {
    if (p.tipo != 'suplemento') return const SizedBox.shrink();
    final v = widget.detalleVentas[p.id];
    if (v == null) return const SizedBox.shrink();
    // Priorizar centavos enteros (candado a); fallback a doubles.
    final oficialCent = (v['precio_oficial_centavos'] as num?)?.toInt() ??
        (((v['precio_oficial'] as num?)?.toDouble() ?? 0) * 100).round();
    final cobradoCent = (v['precio_venta_centavos'] as num?)?.toInt() ??
        (((v['precio'] as num?)?.toDouble() ?? 0) * 100).round();
    if (oficialCent == 0 || cobradoCent == 0) {
      return const SizedBox.shrink();
    }
    if (cobradoCent == oficialCent) {
      return const SizedBox.shrink();
    }
    final mon = '${v['moneda'] ?? p.moneda}';
    final nota = (v['nota_precio'] as String?)?.trim();
    return Padding(
      padding: const EdgeInsets.only(left: 20, top: 3, right: AppEspacio.xs),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
            horizontal: AppEspacio.sm, vertical: 5),
        decoration: BoxDecoration(
          color: AppColores.alerta.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppRadio.sm),
          border: Border.all(color: AppColores.alertaOscuro),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '⚠️ Precio modificado '
              '(Oficial: ${(oficialCent / 100).toStringAsFixed(2)} $mon → '
              'Cobrado: ${(cobradoCent / 100).toStringAsFixed(2)} $mon)',
              style: AppTexto.metadato.copyWith(color: AppColores.alertaOscuro, fontWeight: FontWeight.w700),
            ),
            if (nota != null && nota.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  nota,
                  style: AppTexto.metadato.copyWith(color: AppColores.textoSecundario(context)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dia = widget.dia;
    // Argón #15: usar la moneda real del día, no 'CUP' fijo.
    final monedaDia =
        dia.pagos.isEmpty ? 'CUP' : dia.pagos.first.moneda;
    final total = dia.totalPorMoneda(monedaDia);
    // 1.25 T118 (F2-22): si el día mezcla monedas, la cabecera
    // muestra el subtotal de CADA una («100 CUP · 20 USD»);
    // antes solo se veía la del primer pago y el resto exigía
    // abrir el día fila a fila.
    final monedasDia =
        dia.pagos.map((p) => p.moneda).toSet().toList()..sort();
    final totalTexto = monedasDia.length <= 1
        ? '${fmtMonto(total)} $monedaDia'
        : monedasDia
            .map((m) => '${fmtMonto(dia.totalPorMoneda(m))} $m')
            .join(' · ');
    // 1.29 (Oleada 2, GD-12 — síntoma de campo de Jc,
    // 2026-11-07): se pintan TODOS los pagos del día, sin
    // tope. El mecanismo anterior cortaba a 3 y dejaba el
    // resto tras un enlace «Ver N pagos más...» en letra
    // pequeña al pie de la tarjeta (y la tarjeta del
    // entrenador arranca plegada): en campo, el día de
    // Gabriel enseñaba 3 pagos de 5 y el total no se
    // podía comprobar fila a fila — cobrar a ciegas.
    // P-02 del plan: sin mecanismo de expandir.
    final visibles = dia.pagos;
    // F2-13: sin emoji de semáforo — la insignia ya dice la
    // urgencia con su color y la etiqueta («HACE 4 DÍAS»);
    // dos lenguajes a la vez sobraban.

    return Container(
      margin: const EdgeInsets.only(bottom: AppEspacio.sm),
      padding: const EdgeInsets.all(AppEspacio.md),
      decoration: BoxDecoration(
        // 1.23 (Delta Argón 6ª): tokens del tema en vez del
        // fondo claro fijo (grey.shade50/300) — en modo oscuro
        // la tarjeta ya no queda como un parche blanco.
        color: AppColores.superficie(context),
        borderRadius: BorderRadius.circular(AppRadio.md),
        border: Border.all(
            color: AppColores.borde(context)),
      ),
      // v1.3.2 → 1.23: el texto se blinda con el TOKEN de texto
      // del tema (antes black87 fijo sobre el fondo claro fijo).
      child: DefaultTextStyle.merge(
        style: TextStyle(color: AppColores.texto(context)),
        child: Column(
        crossAxisAlignment:
            CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppEspacio.sm, vertical: AppEspacio.xs),
                decoration: BoxDecoration(
                  color:
                      _badgeBg(dia.nivelAlerta),
                  borderRadius:
                      BorderRadius.circular(AppRadio.sm),
                ),
                child: Text(
                  dia.etiquetaFecha,
                  style: AppTexto.metadato.copyWith(color: _badgeFg(
                        context, dia.nivelAlerta), fontWeight: FontWeight.w700),
                ),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  totalTexto,
                  textAlign: TextAlign.end,
                  style: AppTexto.cuerpo.copyWith(color: AppColores.texto(context), fontWeight: FontWeight.bold),
                ),
              ),
              // 1.29 (Oleada 2, D-12): «Cobrar este día»
              // deja de ser un iconito compacto de ~40 px
              // sin texto y pasa a botón con su nombre y
              // objetivo ≥ 48, como mandan las acciones de
              // dinero (con las manos en el mostrador, un
              // icono de 20 px sin etiqueta se falla).
              TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  foregroundColor: AppColores.exito,
                ),
                icon: const Icon(Icons.done_all_rounded, size: 20),
                label: const Text('Cobrar'),
                onPressed: widget.onConfirmar,
              ),
            ],
          ),
          const SizedBox(height: 4),
          for (final p in visibles)
            Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: 2),
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        p.tipo == 'mensual'
                            ? Icons.calendar_month_rounded
                            : p.tipo == 'servicio'
                                ? Icons.bolt_rounded
                                : Icons.today_rounded,
                        size: 16,
                        color: AppColores.textoSecundario(context),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          // 1.26.1 (rediseño): contraste
                          // pleno — en la captura de Jc
                          // las filas salían atenuadas
                          // como si estuvieran
                          // deshabilitadas.
                          '${p.descripcion} (${p.tipo})',
                          style: AppTexto.cuerpo.copyWith(color: AppColores.texto(context)),
                          overflow:
                              TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${fmtMonto(p.monto)} ${p.moneda}',
                        style: AppTexto.cuerpo.copyWith(color: AppColores.texto(context), fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  // v1.3.4 (C2d): badge si se cobró distinto del oficial.
                  _chipPrecioModificado(p),
                ],
              ),
            ),
        ],
        ),
      ),
    );
  }
}
