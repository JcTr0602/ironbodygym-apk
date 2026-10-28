import 'dart:convert';

import 'adelantos.dart';
import 'localdb.dart';
import 'nomina_bonos.dart';
import 'nomina_calc.dart';
import 'perfil.dart';

/// Total neto a pagar a los entrenadores (post-1.15, fix principal).
///
/// ANTES la principal mostraba `pagaron × 300` (150 por entrenador × 2):
/// el BRUTO, sin descontar adelantos ni sumar comisiones por dosis.
/// Eso no es «lo que hay que pagarles»: el neto real es la suma de
/// las filas de la pantalla de Nómina, y esta es la ÚNICA fuente
/// para esa cifra en la principal.
///
/// La función pura [totalNetoNomina] replica EXACTAMENTE la fórmula
/// de las filas de Nómina ([NominaCalc.totalVivo] por entrenador):
/// base + bono + comisión por dosis − adelantos del mes − deuda
/// arrastrada, con suelo 0 por entrenador. Los bonos usan
/// [NominaCalc.bonosPara] ('ambos' cuenta para los dos). Si un
/// entrenador no tiene fila en [libroMes], sus adelantos y su deuda
/// son 0, igual que en la pantalla.
///
/// El wrapper [totalNetoNominaMes] carga los mismos insumos que la
/// pantalla de Nómina (tarifa, conteo de pagaron, bonos, comisiones
/// por dosis con el fix 1.15 de ganadores, libro de adelantos mes a
/// mes) y devuelve null si no se pudo calcular: la llamadora
/// conserva entonces el valor anterior en vez de mostrar un neto
/// inventado. Las comisiones fallidas se degradan a vacías, igual
/// que en la pantalla; un fallo en el libro de adelantos anula el
/// cálculo completo (mostrar base+comisión sin descontar adelantos
/// sobreestimaría lo que hay que pagar).
double totalNetoNomina({
  required double base,
  required List<Map<String, dynamic>> bonos,
  required Map<String, ({int dosis, double total})> comisionDosis,
  required Map<String, MesLibroAdelantos> libroMes,
}) {
  var total = 0.0;
  for (final ent in const ['duany', 'gabriel']) {
    final libro = libroMes[ent];
    total += NominaCalc.totalVivo(
      base: base,
      bono: NominaCalc.bonosPara(bonos, ent),
      comision: comisionDosis[ent]?.total ?? 0,
      adelantos: libro?.adelantos ?? 0,
      deudaEntrante: libro?.deudaEntrante ?? 0,
    );
  }
  return total;
}

/// Usuarios APK desde el meta local (misma lectura que la pantalla
/// de Nómina): lista vacía si el meta falta o no parsea.
Future<List<Map<String, dynamic>>> _usuariosApk() async {
  try {
    final raw = await LocalDb.instance.getMeta('usuarios_apk');
    if (raw == null || raw.isEmpty) return const [];
    return (jsonDecode(raw) as List)
        .map((u) => Map<String, dynamic>.from(u as Map))
        .toList();
  } catch (_) {
    return const [];
  }
}

Future<double?> totalNetoNominaMes(String pref) async {
  try {
    final tarifa = await PerfilService.instance.getPagoEntrenador();
    final pagaron = await NominaCalc.clientesQuePagaronElMes(pref);
    final base = pagaron * tarifa.toDouble();
    final bonos = await BonosNominaService.instance.leerBonos(pref);
    final usuariosApk = await _usuariosApk();
    // Comisiones por dosis (igual que NominaScreen, fix 1.15:
    // se itera a quienes GANARON comisión, no solo a quienes
    // registraron; sin espejo, vacías). La lista se iza fuera
    // del try para que el libro de abajo también la use (fix
    // Argón post-1.15: comisiones mes a mes, no solo el mes).
    final comisionDosis = <String, ({int dosis, double total})>{};
    var ventasServ = <Map<String, dynamic>>[];
    try {
      ventasServ =
          await LocalDb.instance.allMirror('servicio_ventas');
      final nombrePorTid =
          NominaCalc.tidsConComisionServicio(ventasServ, usuariosApk);
      for (final tid in nombrePorTid.keys) {
        final r =
            NominaCalc.comisionDosisDesdeVentas(ventasServ, tid, pref);
        if (r.total == 0 && r.dosis == 0) continue;
        final nombre = nombrePorTid[tid]!.toLowerCase();
        if (nombre.contains('duany')) {
          comisionDosis['duany'] = r;
        } else if (nombre.contains('gabriel')) {
          comisionDosis['gabriel'] = r;
        }
      }
    } catch (_) {
      // Sin espejo de servicios: comisiones en 0, como la pantalla.
    }
    // Libro de adelantos mes a mes (igual que NominaScreen). Un
    // fallo aquí anula el cálculo: sin el libro no se puede
    // descontar y el neto saldría sobreestimado.
    final libroMes = <String, MesLibroAdelantos>{};
    for (final u in usuariosApk) {
      final username = '${u['username'] ?? ''}'.toLowerCase();
      if (username != 'duany' && username != 'gabriel') continue;
      final id = '${u['id'] ?? ''}';
      if (id.isEmpty) continue;
      final telegramId = (u['telegram_id'] as num?)?.toInt() ??
          int.tryParse('${u['telegram_id'] ?? ''}');
      final eventos = await AdelantosService.instance
          .eventosDe(id, telegramId: telegramId);
      var primero = pref;
      for (final ev in eventos) {
        final mm = '${ev['mes_nomina'] ?? ''}';
        if (mm.length == 7 && mm.compareTo(primero) < 0) primero = mm;
      }
      final brutoPorMes = <String, double>{};
      var mes = primero;
      while (mes.compareTo(pref) <= 0) {
        final n = await NominaCalc.clientesQuePagaronElMes(mes);
        brutoPorMes[mes] = n * tarifa.toDouble();
        mes = mesSiguiente(mes);
      }
      // Fix Argón post-1.15 (MEDIO): el libro arrastra deuda mes
      // a mes, así que necesita la comisión de CADA mes, no solo
      // la del mes en curso. Antes, un mes anterior con adelantos
      // por encima de su base pero cubiertos por sus dosis
      // generaba una deuda entrante falsa en el mes en curso.
      // Sin tid no se puede atribuir comisión: se degrada al
      // mapa viejo (solo el mes en curso).
      final libro = libroAdelantos(
        eventos: eventos,
        brutoPorMes: brutoPorMes,
        comisionesPorMes: telegramId == null
            ? {pref: comisionDosis[username]?.total ?? 0}
            : NominaCalc.comisionesPorMesDesdeVentas(
                ventasServ, telegramId, primero, pref),
        hastaMes: pref,
      );
      for (final m in libro) {
        if (m.mes == pref) libroMes[username] = m;
      }
    }
    return totalNetoNomina(
      base: base,
      bonos: bonos,
      comisionDosis: comisionDosis,
      libroMes: libroMes,
    );
  } catch (_) {
    return null;
  }
}
