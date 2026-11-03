/// 1.23 (B3 Paso 3b, diseño de Argón): la FOTO de componentes
/// de la nómina del mes, compartida entre la pantalla de
/// Nómina y la tarjeta de nómina del Panel del dueño.
///
/// Argón pidió «extraer el neto a NominaCalc y consumirlo en
/// ambos». El ensamblado no vive en nomina_calc.dart porque
/// nomina_bonos.dart ya importa nomina_calc.dart (el ciclo
/// impediría que NominaCalc usara BonosNominaService); vive
/// aquí, a nivel de datos, sin UI: tarifa, comisiones por
/// dosis del espejo de ventas, libro corrido de adelantos con
/// sus fotos de liquidación, y el estado liquidada/
/// confirmación por entrenador.
///
/// También vive aquí [leerBonosMesConMigracion] (la migración
/// legada de bonos desde SharedPreferences + la lectura del
/// mes): pantalla y panel deben leer los bonos por el MISMO
/// camino o sus cifras divergen (delta del panel B3 Paso 3).
/// Lo que NO incluye: el conteo de clientes del mes
/// (NominaPrecalc / NominaCalc, que cada pantalla lee por su
/// cuenta pero de la misma definición única).
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'adelantos.dart';
import 'auth.dart';
import 'localdb.dart';
import 'nomina_bonos.dart';
import 'nomina_calc.dart';
import 'perfil.dart';
import 'tiempo.dart';

/// La foto del mes: todo lo que la pantalla de Nómina y la
/// tarjeta del panel necesitan para armar el neto por
/// entrenador con [NominaCalc.totalVivo].
typedef FotoNominaMes = ({
  int tarifa,
  Map<String, ({int dosis, double total})> comisionDosis,
  Map<String, ({String id, int? telegramId, String nombre})> personas,
  Map<String, List<Map<String, dynamic>>> eventosPorEnt,
  Map<String, MesLibroAdelantos> libroMes,
  Map<String, bool> liquidadas,
  Map<String, Map<String, dynamic>?> confirmaciones,
});

/// Saldo PENDIENTE de pago a los entrenadores en el mes de la
/// foto, para la línea «a pagar» del dueño: suma de
/// [NominaCalc.totalVivo] de duany y gabriel (la misma lista
/// fija de la pantalla) con la base compartida
/// clientes×tarifa, EXCLUYENDO a quien ya tiene la nómina del
/// mes liquidada (ya cobró: no es «a pagar»). Si ambos están
/// liquidados, el pendiente es 0.
///
/// null si la foto está INCOMPLETA para algún entrenador de
/// la lista fija (no está en usuarios_apk, su id viene vacío
/// o su vuelta del ensamblado no terminó — sin entrada en
/// `liquidadas`): una cifra parcial disfrazada de completa
/// sobreestima el importe; el panel pinta «-- CUP», nunca un
/// número inventado (regla de Argón + delta del panel B3-3).
double? netoTotalDueno(
  FotoNominaMes foto, {
  required int clientesPagados,
  required List<Map<String, dynamic>> bonos,
}) {
  for (final ent in const ['duany', 'gabriel']) {
    final persona = foto.personas[ent];
    if (persona == null ||
        persona.id.isEmpty ||
        !foto.liquidadas.containsKey(ent)) {
      return null;
    }
  }
  final base = clientesPagados * foto.tarifa.toDouble();
  var total = 0.0;
  for (final ent in const ['duany', 'gabriel']) {
    if (foto.liquidadas[ent] == true) continue;
    final comision = foto.comisionDosis[ent] ?? (dosis: 0, total: 0.0);
    final libro = foto.libroMes[ent];
    total += NominaCalc.totalVivo(
      base: base,
      bono: NominaCalc.bonosPara(bonos, ent),
      comision: comision.total,
      adelantos: libro?.adelantos ?? 0,
      deudaEntrante: libro?.deudaEntrante ?? 0,
    );
  }
  return total;
}

/// Los bonos del mes [pref] con la migración legada aplicada:
/// si en SharedPreferences queda la lista vieja del mes en
/// curso (o el bono simple anterior), se migra UNA vez a
/// gym.db (ops + sello en [BonosNominaService.migrarDesdePrefs])
/// y se borran las claves; después se lee la lista vigente.
///
/// Vive aquí, compartida entre la pantalla de Nómina y el
/// Panel del dueño (delta del panel B3 Paso 3): el panel leía
/// los bonos SIN migrar y su neto podía omitir un bono legado
/// que la pantalla sí incorporaba al abrirla — dos cifras
/// distintas para el mismo mes. Cuerpo movido verbatim desde
/// _NominaScreenState._cargar.
Future<List<Map<String, dynamic>>> leerBonosMesConMigracion(
    String pref) async {
  final prefs = await SharedPreferences.getInstance();
  final ahora = ahoraHabana();
  final claveLista = 'nomina_bonos_${ahora.year}_${ahora.month}';
  final claveSimple = 'nomina_bono_${ahora.year}_${ahora.month}';
  List<Map<String, dynamic>> bonos = [];
  final jsonStr = prefs.getString(claveLista);
  if (jsonStr != null && jsonStr.isNotEmpty) {
    try {
      final lista = jsonDecode(jsonStr) as List;
      bonos = lista
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {}
  } else {
    // Migración: bono simple viejo → entrada en la lista.
    final bonoViejo = prefs.getDouble(claveSimple);
    if (bonoViejo != null && bonoViejo != 0) {
      bonos.add({
        'id': DateTime.now().millisecondsSinceEpoch.toString(),
        'entrenador': 'ambos',
        'monto': bonoViejo,
        'nota': 'Migrado del sistema anterior',
        'creado_en': ahoraHabana().toIso8601String(),
      });
    }
  }
  if (bonos.isNotEmpty) {
    // 1.14 (Fix 4): si el sello ya existe, la migración YA
    // entró (cierre entre el commit y el borrado de prefs):
    // no se re-encola, solo se borran las prefs. Si no hay
    // sello, migrarDesdePrefs encola + sella en una sola
    // transacción y luego se borran las prefs.
    final sello = BonosNominaService.claveSelloMigracionPrefs(pref);
    if (await LocalDb.instance.getMeta(sello) != '1') {
      await BonosNominaService.instance.migrarDesdePrefs(bonos, pref);
    }
    await prefs.remove(claveLista);
    await prefs.remove(claveSimple);
  }
  return BonosNominaService.instance.leerBonos(pref);
}

/// Arma la foto del mes [pref] ('YYYY-MM'). Cuerpo movido
/// verbatim desde _NominaScreenState._cargar (1.23): la
/// pantalla lo consume para su estado y el panel para su
/// tarjeta; no pueden divergir.
Future<FotoNominaMes> fotoNominaMes(String pref) async {
  final tarifa =
      await PerfilService.instance.getPagoEntrenador();
  // v1.8.0: comisión por dosis del mes (espejo de ventas de
  // servicios; función pura de NominaCalc). La clave sale del
  // nombre registrado del vendedor.
  final comisionDosis = <String, ({int dosis, double total})>{};
  // Autoauditoría 1.22 #1: clave → TODOS sus telegram_id
  // (para las comisiones POR MES del libro, ver
  // comisionesPorMesDesdeVentasMulti).
  var tidsPorClave = <String, List<int>>{};
  var ventasServ = <Map<String, dynamic>>[];
  try {
    ventasServ =
        await LocalDb.instance.allMirror('servicio_ventas');
    final miTid = AuthService().telegramId;
    // Fix 1.15 (caso 2026-10-27): iterar también a quienes
    // GANARON comisión, no solo a quienes registraron. El
    // nombre del que solo ganó sale de usuarios_apk.
    final usuariosApk = <Map<String, dynamic>>[];
    try {
      final rawApk = await LocalDb.instance.getMeta('usuarios_apk');
      if (rawApk != null && rawApk.isNotEmpty) {
        for (final u in jsonDecode(rawApk) as List) {
          usuariosApk.add(Map<String, dynamic>.from(u as Map));
        }
      }
    } catch (_) {}
    final nombrePorTid = NominaCalc.tidsConComisionServicio(
        ventasServ, usuariosApk);
    tidsPorClave = {};
    for (final e in nombrePorTid.entries) {
      final clave = NominaCalc.claveEntrenador(e.value);
      if (clave != null) {
        tidsPorClave.putIfAbsent(clave, () => []).add(e.key);
      }
    }
    for (final tid in nombrePorTid.keys) {
      final r = NominaCalc.comisionDosisDesdeVentas(
          ventasServ, tid, pref);
      if (r.total == 0 && r.dosis == 0) continue;
      // #6 (Argón nómina): llave única (igual que el libro).
      // N-3 (1.22): ACUMULAR, no sobrescribir (dos tid
      // históricos pueden caer en la misma clave).
      final clave = NominaCalc.claveEntrenador(nombrePorTid[tid]);
      if (clave != null) {
        final prev = comisionDosis[clave];
        comisionDosis[clave] = prev == null
            ? r
            : (
                dosis: prev.dosis + r.dosis,
                total: prev.total + r.total
              );
      }
      if (tid == miTid) comisionDosis['mi'] = r;
    }
  } catch (_) {
    // Sin espejo de servicios (BD vieja): la nómina clásica
    // no se rompe por esto.
  }
  // v1.8.0: adelantos — libro corrido hasta el mes en curso.
  // El bruto de cada mes sale de la MISMA definición de
  // «pagaron el mes» (NominaCalc) para que la cadena de deuda
  // sea auditable; las comisiones de cada mes salen del
  // espejo de ventas (fix Argón post-1.15: con solo la del
  // mes en curso, un mes anterior con adelantos por encima
  // de su base pero cubiertos por sus dosis generaba una
  // deuda entrante falsa). La lista de ventas se izó fuera
  // del try de comisiones para poder usarla aquí.
  final personasAdelantos =
      <String, ({String id, int? telegramId, String nombre})>{};
  try {
    final raw = await LocalDb.instance.getMeta('usuarios_apk');
    if (raw != null && raw.isNotEmpty) {
      for (final u in jsonDecode(raw) as List) {
        final m = Map<String, dynamic>.from(u as Map);
        // #6 (Argón nómina): llave única (antes filtro
        // estricto aquí y contains en comisiones).
        // Argón Dinero #8: respaldo por NOMBRE si el
        // username no resuelve la clave (un username sin el
        // nombre dejaba a la persona fuera del mapa).
        final username =
            NominaCalc.claveEntrenador('${m['username'] ?? ''}') ??
                NominaCalc.claveEntrenador(
                    '${m['nombre'] ?? ''}');
        if (username != null) {
          personasAdelantos[username] = (
            id: '${m['id'] ?? ''}',
            telegramId: (m['telegram_id'] as num?)?.toInt() ??
                int.tryParse('${m['telegram_id'] ?? ''}'),
            nombre: (m['nombre'] as String?) ?? username,
          );
        }
      }
    }
  } catch (_) {}
  final libroMes = <String, MesLibroAdelantos>{};
  final eventosPorEnt = <String, List<Map<String, dynamic>>>{};
  final liquidadas = <String, bool>{};
  final confirmaciones = <String, Map<String, dynamic>?>{};
  // #6 (Argón nómina): conteo por mes memorizado (antes se
  // recalculaba por entrenador).
  final conteoCache = <String, int>{};
  for (final e in personasAdelantos.entries) {
    if (e.value.id.isEmpty) continue;
    final eventos = await AdelantosService.instance
        .eventosDe(e.value.id, telegramId: e.value.telegramId);
    eventosPorEnt[e.key] = eventos;
    var primero = pref;
    for (final ev in eventos) {
      final mm = '${ev['mes_nomina'] ?? ''}';
      if (mm.length == 7 && mm.compareTo(primero) < 0) {
        primero = mm;
      }
    }
    final brutoPorMes = <String, double>{};
    var mes = primero;
    while (mes.compareTo(pref) <= 0) {
      conteoCache[mes] ??=
          await NominaCalc.clientesQuePagaronElMes(mes);
      brutoPorMes[mes] = conteoCache[mes]! * tarifa.toDouble();
      mes = mesSiguiente(mes);
    }
    // Autoauditoría 1.22 #1: las comisiones POR MES suman
    // TODOS los tid de la clave (el libro debe cuadrar con
    // el total N-3 y con la foto al liquidar); sin tid
    // conocidos se degrada como antes.
    final tidsClave = tidsPorClave[e.key] ?? const <int>[];
    final comisionesPorMes = tidsClave.isNotEmpty
        ? NominaCalc.comisionesPorMesDesdeVentasMulti(
            ventasServ, tidsClave, primero, pref)
        : (e.value.telegramId == null
            ? {pref: comisionDosis[e.key]?.total ?? 0}
            : NominaCalc.comisionesPorMesDesdeVentas(
                ventasServ, e.value.telegramId!, primero, pref));
    // #2 (Argón nómina): los bonos suman a la capacidad
    // del mes.
    final bonosPorMes = await BonosNominaService.instance
        .bonosPorMes(e.key, primero, pref);
    // N-5 (1.22): los meses ya liquidados mandan por su
    // foto, no por la tarifa viva (ver aplicarFotosLibro).
    await AdelantosService.instance.aplicarFotosLibro(
      brutoPorMes: brutoPorMes,
      comisionesPorMes: comisionesPorMes,
      bonosPorMes: bonosPorMes,
      conteoPorMes: conteoCache,
      entrenadorId: e.value.id,
      telegramId: e.value.telegramId,
    );
    final libro = libroAdelantos(
      eventos: eventos,
      brutoPorMes: brutoPorMes,
      comisionesPorMes: comisionesPorMes,
      bonosPorMes: bonosPorMes,
      hastaMes: pref,
    );
    for (final m in libro) {
      if (m.mes == pref) libroMes[e.key] = m;
    }
    liquidadas[e.key] = await AdelantosService.instance
        .nominaLiquidada(pref, e.value.id);
    confirmaciones[e.key] =
        await AdelantosService.instance.confirmacionNomina(
            pref,
            entrenadorId: e.value.id,
            telegramId: e.value.telegramId);
  }

  return (
    tarifa: tarifa,
    comisionDosis: comisionDosis,
    personas: personasAdelantos,
    eventosPorEnt: eventosPorEnt,
    libroMes: libroMes,
    liquidadas: liquidadas,
    confirmaciones: confirmaciones,
  );
}
