import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth.dart';
import '../localdb.dart';
import '../adelantos.dart';
import '../negocio.dart';
import '../nomina_bonos.dart';
import '../nomina_calc.dart';
import '../nomina_precalc.dart';
import '../perfil.dart';
import '../permisos_entrenador.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'mi_nomina.dart';

/// v1.3.7 (Fase A, 6.1): pre-cálculo de nómina mensual.
/// v1.3.9 Sprint 3 (#8): + bono manual editable por el dueño.
/// Fórmula (Jc): (clientes que pagaron el mes) × 150 CUP + bono manual.
/// El dueño ve todo; el entrenador ve su tarjeta en el Home.
class NominaScreen extends StatefulWidget {
  const NominaScreen({super.key});

  @override
  State<NominaScreen> createState() => _NominaScreenState();
}

class _NominaScreenState extends State<NominaScreen> {
  bool _cargando = true;
  // Pasada 2 de Argón (1.20): candado de las acciones de
  // dinero de esta pantalla (bono, tarifa) contra doble toque.
  bool _operando = false;
  int _clientesPagados = 0;
  // v1.4.0: sello del pre-cálculo ("Actualizado: ...").
  String _actualizadoEtiqueta = '';
  String _mesEtiqueta = '';
  // v1.3.9: lista de bonos por entrenador [{id, entrenador, monto, nota}]
  List<Map<String, dynamic>> _bonos = [];
  final _bonoMontoCtrl = TextEditingController();
  final _bonoNotaCtrl = TextEditingController();
  String _bonoEntrenador = 'ambos'; // 'duany', 'gabriel', 'ambos'
  final _tarifaCtrl = TextEditingController();
  double _tarifa = 150;
  // v1.8.0: comisión por dosis del mes por entrenador (clave
  // 'duany'/'gabriel'; el entrenador además la ve bajo 'mi').
  Map<String, ({int dosis, double total})> _comisionDosis = {};

  // v1.8.0: adelantos — personas (username -> identidad APK),
  // libro del mes en curso por entrenador, eventos completos y
  // si la nómina del mes ya está liquidada para cada uno.
  Map<String, ({String id, int? telegramId, String nombre})>
      _personasAdelantos = {};
  Map<String, MesLibroAdelantos> _libroMes = {};
  Map<String, List<Map<String, dynamic>>> _eventosAdelantos = {};
  Map<String, bool> _nominaLiquidadaMes = {};
  // T22 (1.20): confirmación de recepción por entrenador
  // (espejo u op local), para mostrar el acuse al dueño.
  Map<String, Map<String, dynamic>?> _confirmacionMes = {};

  String _bonosKey(DateTime d) =>
      'nomina_bonos_${d.year}_${d.month}';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _bonoMontoCtrl.dispose();
    _bonoNotaCtrl.dispose();
    _tarifaCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final ahora = ahoraHabana();
    final pref = hoyHabanaIso().substring(0, 7); // YYYY-MM
    _mesEtiqueta = _nombreMes(ahora.month);
    // Misma fuente que "Pagos realizados": clientes únicos con pago
    // este mes. v1.4.0: cálculo compartido en NominaCalc (lo usan
    // también el home y el pre-cálculo; no pueden divergir).
    // Primero se sirve la caché del pre-cálculo (apertura instantánea);
    // si su huella quedó vieja, se recalcula en segundo plano y la
    // pantalla se refresca sola cuando termina.
    final cache = await NominaPrecalc.instance.leer(pref);
    final desdeCache = cache != null && cache.fresco;
    // Solo se compone dinero con una base FRESCA: si la caché está
    // vieja se espera el recálculo (asegurar) en vez de mostrar una
    // nómina provisional calculada con la cifra anterior
    // (auditoría del código, terra). Con caché fresca la apertura
    // sigue siendo instantánea, que es el objetivo del pre-cálculo.
    final clientesPagados = desdeCache
        ? cache.clientes
        : await NominaPrecalc.instance.asegurar(pref);
    if (mounted) {
      final prefs = await SharedPreferences.getInstance();
      // La pantalla pudo cerrarse durante los awaits: no seguir
      // hasta el setState con el widget desmontado (auditoría, terra).
      if (!mounted) return;
      // Fase A 2026-10-25 (A4): los bonos ya NO viven en
      // SharedPreferences sino en gym.db sincronizado. La lista
      // vieja de prefs (si queda) se migra UNA vez: se encola
      // como ops y luego se borran las claves, para no duplicar
      // en la próxima apertura.
      List<Map<String, dynamic>> bonos = [];
      final jsonStr = prefs.getString(_bonosKey(ahoraHabana()));
      if (jsonStr != null && jsonStr.isNotEmpty) {
        try {
          final lista = jsonDecode(jsonStr) as List;
          bonos = lista
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        } catch (_) {}
      } else {
        // Migración: bono simple viejo → entrada en la lista
        final bonoViejo =
            prefs.getDouble('nomina_bono_${ahora.year}_${ahora.month}');
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
          await BonosNominaService.instance
              .migrarDesdePrefs(bonos, pref);
        }
        await prefs.remove(_bonosKey(ahoraHabana()));
        await prefs.remove(
            'nomina_bono_${ahora.year}_${ahora.month}');
      }
      bonos = await BonosNominaService.instance.leerBonos(pref);
      final tarifa =
          await PerfilService.instance.getPagoEntrenador();
      // v1.8.0: comisión por dosis del mes (espejo de ventas de
      // servicios; función pura de NominaCalc). La clave sale del
      // nombre registrado del vendedor.
      final comisionDosis = <String, ({int dosis, double total})>{};
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
        for (final tid in nombrePorTid.keys) {
          final r = NominaCalc.comisionDosisDesdeVentas(
              ventasServ, tid, pref);
          if (r.total == 0 && r.dosis == 0) continue;
          // #6 (Argón nómina): llave única (igual que el libro).
          final clave = NominaCalc.claveEntrenador(nombrePorTid[tid]);
          if (clave != null) comisionDosis[clave] = r;
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
            final username =
                NominaCalc.claveEntrenador('${m['username'] ?? ''}');
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
        final libro = libroAdelantos(
          eventos: eventos,
          brutoPorMes: brutoPorMes,
          comisionesPorMes: e.value.telegramId == null
              ? {pref: comisionDosis[e.key]?.total ?? 0}
              : NominaCalc.comisionesPorMesDesdeVentas(
                  ventasServ, e.value.telegramId!, primero, pref),
          // #2 (Argón nómina): los bonos suman a la capacidad
          // del mes.
          bonosPorMes: await BonosNominaService.instance
              .bonosPorMes(e.key, primero, pref),
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
      // #7 (Argón nómina): el doble chequeo era redundante.
      if (!mounted) return;
      setState(() {
        _comisionDosis = comisionDosis;
        _personasAdelantos = personasAdelantos;
        _libroMes = libroMes;
        _eventosAdelantos = eventosPorEnt;
        _nominaLiquidadaMes = liquidadas;
        _confirmacionMes = confirmaciones;
        _clientesPagados = clientesPagados;
        _bonos = bonos;
        _tarifa = tarifa.toDouble();
        _tarifaCtrl.text = tarifa.toString();
        _actualizadoEtiqueta = _etiquetaActualizado(desdeCache
            ? cache.calculadoEn
            : ahoraHabana().toIso8601String());
        _cargando = false;
      });
    }
  }

  /// "20 de octubre, 12:40" a partir de un ISO guardado por el
  /// pre-cálculo. Si el ISO no parsea, devuelve el texto tal cual.
  String _etiquetaActualizado(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} de ${_nombreMes(d.month).toLowerCase()}, $hh:$mm';
  }

  /// Suma solo los bonos generales ('ambos'), contados una vez.
  /// Respaldo defensivo cuando no se puede identificar al entrenador.
  double _bonoSoloAmbos() => NominaCalc.bonoSoloAmbos(_bonos);

  /// Suma de bonos aplicables a un entrenador ('duany' o 'gabriel').
  double _bonoPara(String entrenador) =>
      NominaCalc.bonosPara(_bonos, entrenador);

  Future<void> _agregarBono() async {
    // Ronda 17 M4-H1: agregar bonos es solo del dueño
    // (la UI ya oculta el botón; esto cubre pantalla abierta
    // con cambio de sesión).
    if (!AuthService().isOwner) return;
    if (_operando) return;
    final texto =
        _bonoMontoCtrl.text.trim().replaceAll(',', '.');
    final monto = double.tryParse(texto) ?? 0;
    if (monto == 0) {
      mostrarSnack(context, 'Ingresa un monto válido', significado: SignificadoChip.alerta);
      return;
    }
    // Pasada 2 de Argón (1.20): capturar la nota y LIMPIAR los
    // controladores sincrónicamente, antes del primer await;
    // con la limpieza tras el await, un doble toque insertaba
    // el bono dos veces.
    final notaBono = _bonoNotaCtrl.text.trim();
    _bonoMontoCtrl.clear();
    _bonoNotaCtrl.clear();
    _operando = true;
    // Fase A 2026-10-25 (A4): el bono se guarda sincronizado
    // (espejo + op), no en SharedPreferences.
    final pref = hoyHabanaIso().substring(0, 7);
    await BonosNominaService.instance.agregar(
      mes: pref,
      entrenador: _bonoEntrenador,
      monto: monto,
      nota: notaBono,
    );
    _operando = false;
    final actualizados =
        await BonosNominaService.instance.leerBonos(pref);
    if (!mounted) return;
    setState(() {
      _bonos = actualizados;
      _bonoMontoCtrl.clear();
      _bonoNotaCtrl.clear();
    });
    if (mounted) {
      mostrarSnack(context, 'Bono agregado', significado: SignificadoChip.exito);
    }
  }

  Future<void> _eliminarBono(String id) async {
    // Ronda 17 M4-H1: eliminar bonos es solo del dueño.
    if (!AuthService().isOwner) return;
    // Fase A 2026-10-25 (A4): encola la eliminación; la lectura
    // fusionada lo oculta al instante.
    await BonosNominaService.instance.eliminar(id);
    final pref = hoyHabanaIso().substring(0, 7);
    final actualizados =
        await BonosNominaService.instance.leerBonos(pref);
    if (!mounted) return;
    setState(() => _bonos = actualizados);
    if (mounted) {
      mostrarSnack(context, 'Bono eliminado', significado: SignificadoChip.exito);
    }
  }

  String _nombreMes(int m) {
    const meses = [
      '',
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre'
    ];
    return (m >= 1 && m <= 12) ? meses[m] : '';
  }

  /// Filas por entrenador con su total (base + sus bonos).
  List<Widget> _buildFilasEntrenadores(
      BuildContext context, double base) {
    final esDueno = AuthService().isOwner;
    // El dueño ve las dos filas. El entrenador ve solo la suya: SÍ se
    // puede identificar por AuthService().username ('duany'/'gabriel').
    // (Ajuste Argón, revisión Paso 1: antes la vista 'mi' sumaba los
    // bonos de ambos y duplicaba los bonos marcados 'ambos', además de
    // mezclar los bonos individuales del otro entrenador.)
    final yo = AuthService().username;
    final entrenadores = esDueno
        ? ['duany', 'gabriel']
        : [
            if (yo == 'duany' || yo == 'gabriel') yo else 'mi',
          ];
    return entrenadores.map((ent) {
      final nombre = ent == 'duany'
          ? 'Duany'
          : ent == 'gabriel'
              ? 'Gabriel'
              : 'Pago por entrenador';
      // 'mi' solo como respaldo si el username no es de un entrenador
      // conocido: en ese caso únicamente los bonos generales ('ambos'),
      // contados UNA sola vez.
      final bono = ent == 'mi' ? _bonoSoloAmbos() : _bonoPara(ent);
      // v1.8.0: la comisión por dosis se suma a la nómina del mes.
      final comision = _comisionDosis[ent] ?? (dosis: 0, total: 0.0);
      // v1.8.0: los adelantos del mes (por mes_nomina) y la deuda
      // arrastrada DESCUENTAN; el total mostrado es el neto a
      // pagar (nunca negativo: el exceso queda como deuda).
      final libro = _libroMes[ent];
      final adelantosMes = libro?.adelantos ?? 0;
      final deudaEntrante = libro?.deudaEntrante ?? 0;
      // 1.14 (M5.1): la fórmula vive en NominaCalc.totalVivo.
      final total = NominaCalc.totalVivo(
        base: base,
        bono: bono,
        comision: comision.total,
        adelantos: adelantosMes,
        deudaEntrante: deudaEntrante,
      );
      final liquidada = _nominaLiquidadaMes[ent] ?? false;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                nombre,
                style: AppTexto.cuerpo.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${fmtMonto(total)} CUP',
                  style: AppTexto.tituloPagina.copyWith(color: AppColores.exito),
                ),
                if (bono != 0)
                  Text(
                    '${bono > 0 ? '+' : ''}${fmtMonto(bono)} bono',
                    style: AppTexto.metadato.copyWith(color: bono > 0
                          ? AppColores.exito
                          : Colors.red),
                  ),
                if (comision.total != 0)
                  Text(
                    '${comision.total > 0 ? '+' : ''}'
                    '${fmtMonto(comision.total)} comisión dosis '
                    '(${comision.dosis})',
                    style: AppTexto.metadato.copyWith(color: comision.total > 0
                          ? AppColores.exito
                          : Colors.red),
                  ),
                if (adelantosMes != 0)
                  Text(
                    '−${fmtMonto(adelantosMes)} adelantos',
                    style: AppTexto.metadato.copyWith(color: Colors.red),
                  ),
                if (deudaEntrante > 0)
                  Text(
                    '−${fmtMonto(deudaEntrante)} deuda anterior',
                    style: AppTexto.metadato.copyWith(color: Colors.red),
                  ),
                if (liquidada)
                  Text(
                    '✓ nómina pagada',
                    style: AppTexto.metadato.copyWith(color: AppColores.exito),
                  ),
              ],
            ),
          ],
        ),
      );
    }).toList();
  }

  /// Nombre legible del destino del bono.
  String _nombreDestino(String d) {
    if (d == 'duany') return 'Duany';
    if (d == 'gabriel') return 'Gabriel';
    return 'Ambos';
  }

  /// Fila de bono con nota y botón eliminar.
  Widget _buildFilaBono(
      BuildContext context, Map<String, dynamic> b) {
    final monto = (b['monto'] as num?)?.toDouble() ?? 0;
    final nota = '${b['nota'] ?? ''}';
    final destino = _nombreDestino('${b['entrenador'] ?? 'ambos'}');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(
          monto >= 0 ? Icons.add_circle_rounded : Icons.remove_circle_rounded,
          color: monto >= 0 ? AppColores.exito : Colors.red,
        ),
        title: Text(
          '${monto > 0 ? '+' : ''}${fmtMonto(monto)} CUP — $destino',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: nota.isNotEmpty ? Text(nota) : null,
        trailing: IconButton(
          icon: const Icon(Icons.delete_rounded, color: Colors.red),
          tooltip: 'Eliminar bono',
          onPressed: () => _eliminarBono('${b['id']}'),
        ),
      ),
    );
  }

  Future<void> _guardarTarifa() async {
    // Ronda 17 M4-H1: cambiar la tarifa es solo del dueño.
    if (!AuthService().isOwner) return;
    if (_operando) return;
    _operando = true;
    final texto = _tarifaCtrl.text.trim().replaceAll(',', '.');
    final tarifa = double.tryParse(texto) ?? 150;
    if (tarifa <= 0) {
      _operando = false;
      mostrarSnack(context, 'Ingresa una tarifa válida', significado: SignificadoChip.alerta);
      return;
    }
    await PerfilService.instance.setPagoEntrenador(tarifa.toInt());
    // Argón Acceso #9: que el cambio viaje ya, no en el próximo
    // evento de sync.
    SyncEngine.instance.push();
    _operando = false;
    setState(() => _tarifa = tarifa);
    if (mounted) {
      mostrarSnack(context, 'Tarifa actualizada', significado: SignificadoChip.exito);
    }
  }

  @override
  Widget build(BuildContext context) {
    // v1.3.9: el entrenador también puede ver su nómina.
    // El dueño ve el desglose completo + bonos por entrenador.
    final pagoPorCliente = _tarifa;
    final base = _clientesPagados * pagoPorCliente;
    final ahora = ahoraHabana();
    final proyeccion =
        'Proyección al día ${ahora.day.toString().padLeft(2, '0')}/'
        '${ahora.month.toString().padLeft(2, '0')}';
    final esDueno = AuthService().isOwner;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nómina del mes'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando nómina…')
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Tarjeta(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconoModuloBadge.naranja(
                              Icons.payments_rounded),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              esDueno
                                  ? 'Nómina por entrenador'
                                  : 'Mi nómina',
                              style: AppTexto.titulo,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Ronda 17 M4-H1 (decisión Jc 2026-10-28):
                      // sin can_ver_cifras no se muestra el conteo
                      // global; el entrenador ve solo su monto base.
                      if (esDueno ||
                          PermisosEntrenador().canVerCifras)
                        Text(
                          '$_clientesPagados clientes pagados en $_mesEtiqueta '
                          '× ${fmtMonto(pagoPorCliente)} CUP',
                          style: AppTexto.cuerpo.copyWith(
                            color: AppColores.textoSecundario(
                                context),
                          ),
                        ),
                      const SizedBox(height: 4),
                      // v1.4.0: sello del pre-cálculo automático.
                      Text(
                        'Actualizado: $_actualizadoEtiqueta',
                        style: AppTexto.etiqueta.copyWith(
                          color: AppColores.textoSecundario(
                              context),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Desglose por entrenador
                      ..._buildFilasEntrenadores(
                          context, base),
                      // v1.8.0: adelantos del mes por entrenador.
                      ..._buildSeccionesAdelantos(context),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AppColores.naranja
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(
                              AppRadio.md),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                                Icons.info_outline_rounded,
                                size: 16,
                                color: AppColores.info),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                '$proyeccion — no es la cifra final. '
                                'El pago se hace el último día del mes.',
                                style: AppTexto.etiqueta.copyWith(
                                  color: AppColores
                                      .textoSecundario(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // v1.3.9: bonos por entrenador (solo dueño)
                if (esDueno) ...[
                  const SizedBox(height: 16),
                  Tarjeta(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Bonos del mes',
                          style: AppTexto.titulo,
                        ),
                        const SizedBox(height: 8),
                        if (_bonos.isEmpty)
                          Text(
                            'Sin bonos este mes.',
                            style: AppTexto.cuerpo.copyWith(
                              color: AppColores
                                  .textoSecundario(context),
                            ),
                          ),
                        for (final b in _bonos)
                          _buildFilaBono(context, b),
                        const Divider(height: 24),
                        Text(
                          'Agregar bono',
                          style: AppTexto.cuerpo
                              .copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        // Selector de entrenador
                        DropdownButtonFormField<String>(
                          value: _bonoEntrenador,
                          decoration: const InputDecoration(
                            labelText: 'Para',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: 'ambos',
                                child: Text('Ambos')),
                            DropdownMenuItem(
                                value: 'duany',
                                child: Text('Duany')),
                            DropdownMenuItem(
                                value: 'gabriel',
                                child: Text('Gabriel')),
                          ],
                          onChanged: (v) => setState(
                              () => _bonoEntrenador =
                                  v ?? 'ambos'),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              // N1 (estéticas 1.19): campo del
                              // sistema; el 'CUP' va en el hint
                              // (CampoTexto no tiene afijos).
                              child: CampoTexto(
                                controller:
                                    _bonoMontoCtrl,
                                teclado: const TextInputType
                                    .numberWithOptions(
                                        decimal: true,
                                        signed: true),
                                hint: 'Monto en CUP '
                                    '(Ej: 2000 o -500)',
                                icono: Icons.payments_rounded,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        CampoTexto(
                          controller: _bonoNotaCtrl,
                          hint: 'Nota: por qué se otorga...',
                          icono: Icons.note_rounded,
                          maxLineas: 2,
                        ),
                        const SizedBox(height: 8),
                        BotonPrimario(
                          texto: 'Agregar bono',
                          icono: Icons.add_rounded,
                          onPressed: _agregarBono,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Tarifa por cliente (movido desde Administración)
                  Tarjeta(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tarifa por cliente',
                          style: AppTexto.cuerpo
                              .copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'CUP por cada cliente que pagó:',
                                style: AppTexto.cuerpo,
                              ),
                            ),
                            SizedBox(
                              width: 100,
                              // N1 (estéticas 1.19): campo del
                              // sistema (la etiqueta vive en el
                              // texto de la fila).
                              child: CampoTexto(
                                controller:
                                    _tarifaCtrl,
                                teclado:
                                    TextInputType.number,
                              ),
                            ),
                            const SizedBox(width: 8),
                            BotonPrimario(
                              texto: 'Guardar',
                              onPressed: _guardarTarifa,
                              expandido: false,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  // ----------------------------------------------------------------
  // v1.8.0: Adelantos — sección por entrenador (lista del mes,
  // registrar/anular solo dueño, marcar nómina como pagada).
  // ----------------------------------------------------------------

  List<Widget> _buildSeccionesAdelantos(BuildContext context) {
    final esDueno = AuthService().isOwner;
    final yo = AuthService().username;
    final claves = esDueno
        ? ['duany', 'gabriel']
        : [
            if (yo == 'duany' || yo == 'gabriel') yo,
          ];
    return [
      for (final ent in claves)
        if (_personasAdelantos.containsKey(ent))
          _seccionAdelantos(context, ent),
    ];
  }

  /// T22 (1.20): línea de acuse de la nómina liquidada: si
  /// el entrenador ya confirmó (espejo), su fecha; si no,
  /// que sigue pendiente de su confirmación.
  Widget _lineaAcuseNomina(
      BuildContext context, String ent, String nombre) {
    final conf = _confirmacionMes[ent];
    final fechaConf = '${conf?['confirmada_en'] ?? ''}';
    if (conf != null && fechaConf.length >= 10) {
      return Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          '✓ $nombre confirmó que recibió su nómina el '
          '${fmtFecha(fechaConf.substring(0, 10))}.',
          style:
              AppTexto.cuerpo.copyWith(color: AppColores.exito),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        'Nómina liquidada · $nombre aún no confirma la '
        'recepción.',
        style: AppTexto.secundario,
      ),
    );
  }

  Widget _seccionAdelantos(BuildContext context, String ent) {
    final persona = _personasAdelantos[ent]!;
    final libro = _libroMes[ent];
    final pref = AdelantosService.mesActual();
    final items = (libro?.items ?? const [])
        .where((e) => '${e['mes_nomina']}' == pref)
        .toList();
    final todos = _eventosAdelantos[ent] ?? const [];
    final anulados = <int>{
      for (final e in todos)
        if (e['reverso_de'] != null)
          (e['reverso_de'] as num).toInt(),
    };
    final esDueno = AuthService().isOwner;
    final liquidada = _nominaLiquidadaMes[ent] ?? false;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Row(
            children: [
              Icon(Icons.payments_rounded,
                  size: 18, color: AppColores.textoSecundario(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Adelantos de ${persona.nombre}',
                    style: AppTexto.subtitulo),
              ),
              if (esDueno)
                TextButton.icon(
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Registrar'),
                  onPressed: () =>
                      _dialogoRegistrarAdelanto(context, ent),
                ),
            ],
          ),
          if (items.isEmpty)
            const Text('Sin adelantos este mes.',
                style: AppTexto.cuerpo)
          else
            for (final e in items)
              _filaAdelanto(context, e, anulados, esDueno,
                  liquidada: liquidada,
                  entrenadorId: persona.id,
                  mesNomina: pref),
          if (libro != null && libro.deudaSaliente > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Queda una deuda de ${fmtMonto(libro.deudaSaliente)} '
                'CUP para el mes que viene.',
                style: AppTexto.metadato.copyWith(color: Colors.red),
              ),
            ),
          // T22 (1.20): acuse del entrenador (solo lectura
          // para el dueño; el entrenador confirma en su
          // pantalla «Mi nómina»).
          if (liquidada) _lineaAcuseNomina(context, ent, persona.nombre),
          if (esDueno && !liquidada)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.fact_check_rounded, size: 18),
                label: const Text('Marcar nómina del mes como pagada'),
                onPressed: () async {
                  // T22 (1.20): el resumen se calcula ANTES
                  // del diálogo: lo que el dueño ve al
                  // confirmar es exactamente la foto que
                  // viaja con la liquidación.
                  final libroLiq = _libroMes[ent];
                  final baseLiq = _clientesPagados * _tarifa;
                  final bonoLiq = ent == 'mi'
                      ? _bonoSoloAmbos()
                      : _bonoPara(ent);
                  final comisionLiq =
                      _comisionDosis[ent]?.total ?? 0;
                  final adelantosLiq = libroLiq?.adelantos ?? 0;
                  final deudaLiq = libroLiq?.deudaEntrante ?? 0;
                  final netoLiq = NominaCalc.totalVivo(
                    base: baseLiq,
                    bono: bonoLiq,
                    comision: comisionLiq,
                    adelantos: adelantosLiq,
                    deudaEntrante: deudaLiq,
                  );
                  if (!context.mounted) return;
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('¿Nómina pagada?'),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Resumen de ${persona.nombre}:',
                              style: AppTexto.subtitulo),
                          const SizedBox(height: AppEspacio.sm),
                          Text('Clientes que pagaron: '
                              '$_clientesPagados × '
                              '${fmtMonto(_tarifa)} CUP'),
                          Text('Base: ${fmtMonto(baseLiq)} CUP'),
                          if (bonoLiq > 0)
                            Text('Bono: ${fmtMonto(bonoLiq)} CUP'),
                          if (comisionLiq > 0)
                            Text('Comisión por dosis: '
                                '${fmtMonto(comisionLiq)} CUP'),
                          if (adelantosLiq > 0)
                            Text('Adelantos: '
                                '−${fmtMonto(adelantosLiq)} CUP'),
                          if (deudaLiq > 0)
                            Text('Deuda del mes anterior: '
                                '−${fmtMonto(deudaLiq)} CUP'),
                          const Divider(),
                          Text('Neto a pagar: '
                              '${fmtMonto(netoLiq)} CUP',
                              style: AppTexto.subtitulo),
                          const SizedBox(height: AppEspacio.sm),
                          const Text(
                              'Se marca la nómina de este mes '
                              'como PAGADA. Desde ese momento, '
                              'los adelantos que se registren '
                              'con fecha de este mes caerán en '
                              'la nómina del mes siguiente (el '
                              'mes pagado no se reescribe). El '
                              'entrenador verá este resumen y '
                              'podrá confirmar que la recibió.'),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(ctx).pop(false),
                          child: const Text('Cancelar'),
                        ),
                        FilledButton(
                          onPressed: () =>
                              Navigator.of(ctx).pop(true),
                          child: const Text('Sí, pagada'),
                        ),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  await AdelantosService.instance.liquidarNomina(
                    mes: pref,
                    entrenadorId: persona.id,
                    entrenadorNombre: persona.nombre,
                    entrenadorTelegramId: persona.telegramId,
                    tarifaPorCliente: _tarifa,
                    neto: netoLiq,
                    base: baseLiq,
                    bonos: bonoLiq,
                    comisiones: comisionLiq,
                    adelantos: adelantosLiq,
                    deudaEntrante: deudaLiq,
                  );
                  if (mounted) {
                    mostrarSnack(context, 'Nómina marcada como pagada', significado: SignificadoChip.exito);
                    _cargar();
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _filaAdelanto(BuildContext context, Map<String, dynamic> e,
      Set<int> anulados, bool esDueno,
      {bool liquidada = false,
      String? entrenadorId,
      String? mesNomina}) {
    final id = (e['id'] as num?)?.toInt();
    final esReverso = e['reverso_de'] != null;
    final estaAnulado = id != null && anulados.contains(id);
    final pendiente = e['pendiente'] == 1;
    final anulacionPendiente = e['anulacion_pendiente'] == 1;
    final monto = (e['monto'] as num?)?.toDouble() ?? 0;
    final origen = '${e['origen'] ?? ''}' == 'fondo_dueno'
        ? 'del bolsillo de Jc'
        : 'de la caja del turno';
    final metodo = '${e['metodo'] ?? 'efectivo'}';
    final nota = '${e['nota'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text('${e['fecha'] ?? ''}',
                style: AppTexto.metadato),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  esReverso
                      ? 'Anulación de adelanto'
                      : 'Adelanto ($metodo, $origen)',
                  style: AppTexto.secundario.copyWith(
                    decoration: estaAnulado
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                if (nota.isNotEmpty)
                  Text(nota,
                      style: AppTexto.metadato),
                if (estaAnulado)
                  Text('anulado',
                      style: AppTexto.metadato.copyWith(color: Colors.red)),
                if (anulacionPendiente)
                  const Text('anulación en curso…',
                      style: AppTexto.metadato),
                if (pendiente)
                  const Text('pendiente de sincronizar',
                      style: AppTexto.metadato),
              ],
            ),
          ),
          Text(
            '${monto >= 0 ? '' : '+'}${fmtMonto(monto.abs())} CUP',
            style: AppTexto.secundario.copyWith(color: esReverso ? AppColores.exito : Colors.red, fontWeight: FontWeight.w700),
          ),
          if (esDueno &&
              !liquidada &&
              !esReverso &&
              !estaAnulado &&
              !anulacionPendiente &&
              id != null)
            IconButton(
              icon: const Icon(Icons.undo_rounded, size: 18),
              tooltip: 'Anular adelanto',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('¿Anular este adelanto?'),
                    content: const Text(
                        'Se crea el apunte contrario (nunca se '
                        'borra). Si la caja de ese día ya se '
                        'liquidó, la anulación queda marcada como '
                        'fuera de cierre y no toca arqueos '
                        'cerrados.'),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            Navigator.of(ctx).pop(false),
                        child: const Text('Cancelar'),
                      ),
                      FilledButton(
                        onPressed: () =>
                            Navigator.of(ctx).pop(true),
                        child: const Text('Anular'),
                      ),
                    ],
                  ),
                );
                if (ok != true) return;
                try {
                  await AdelantosService.instance.anular(id,
                      entrenadorId: entrenadorId,
                      mesNomina: mesNomina);
                } catch (err) {
                  // M1: mes liquidado (u otro rechazo): se avisa
                  // y no se recarga como si hubiera funcionado.
                  if (mounted) {
                    mostrarSnack(context, '$err', significado: SignificadoChip.error);
                  }
                  return;
                }
                if (mounted) _cargar();
              },
            ),
          // W3 (1.20): corregir el origen (solo dueño, mes sin
          // liquidar; mismas guardas que anular). Sin sentido
          // si ya es fondo_dueno por transferencia: no hay a
          // dónde moverlo.
          if (esDueno &&
              !liquidada &&
              !esReverso &&
              !estaAnulado &&
              !anulacionPendiente &&
              id != null &&
              ('${e['origen'] ?? 'caja_turno'}' == 'caja_turno' ||
                  metodo == 'efectivo'))
            IconButton(
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              tooltip: 'Corregir origen',
              onPressed: () => _dialogoCorregirOrigen(context, e,
                  entrenadorId: entrenadorId, mesNomina: mesNomina),
            ),
        ],
      ),
    );
  }

  /// W3 (1.20): diálogo de corrección de origen de un adelanto.
  /// Explica el efecto en simple por dirección; la op la
  /// valida el servidor (guarda de mes liquidado incluida).
  Future<void> _dialogoCorregirOrigen(
      BuildContext context, Map<String, dynamic> e,
      {String? entrenadorId, String? mesNomina}) async {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    final origenActual = '${e['origen'] ?? 'caja_turno'}';
    final metodo = '${e['metodo'] ?? 'efectivo'}';
    var destino =
        origenActual == 'caja_turno' ? 'fondo_dueno' : 'caja_turno';
    // Gaveta inicial: la actual si se reconoce; si no, la del
    // propio adelanto.
    final gavetaActual = LocalDb.normalizarTelegramId(e['descuenta_a']);
    var gaveta = entrenadorId ?? 'duany';
    for (final entry in _personasAdelantos.entries) {
      if (entry.value.telegramId != null &&
          entry.value.telegramId == gavetaActual) {
        gaveta = entry.key;
        break;
      }
    }
    final nombreEntrenador =
        _personasAdelantos[entrenadorId]?.nombre ?? 'el entrenador';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Corregir origen del adelanto'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                origenActual == 'caja_turno'
                    ? 'Hoy este adelanto cuenta como que salió de '
                        'la caja del turno (está en el «pendiente '
                        'a entregar» de un entrenador).'
                    : 'Hoy este adelanto cuenta como que salió de '
                        'tu bolsillo (no está en el «pendiente a '
                        'entregar» de nadie).',
                style: AppTexto.secundario,
              ),
              const SizedBox(height: 12),
              Text('¿De dónde salió en realidad?',
                  style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w700)),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Mi bolsillo'),
                    selected: destino == 'fondo_dueno',
                    onSelected: (_) =>
                        setLocal(() => destino = 'fondo_dueno'),
                  ),
                  if (metodo == 'efectivo')
                    ChoiceChip(
                      label: const Text('Caja del turno'),
                      selected: destino == 'caja_turno',
                      onSelected: (_) =>
                          setLocal(() => destino = 'caja_turno'),
                    ),
                ],
              ),
              if (destino == 'caja_turno') ...[
                const SizedBox(height: 8),
                const Text('Sale de la gaveta de:',
                    style: AppTexto.metadato),
                DropdownButton<String>(
                  value: _personasAdelantos.containsKey(gaveta)
                      ? gaveta
                      : (_personasAdelantos.keys.isNotEmpty
                          ? _personasAdelantos.keys.first
                          : gaveta),
                  isExpanded: true,
                  items: [
                    for (final entry in _personasAdelantos.entries)
                      DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value.nombre)),
                  ],
                  onChanged: (v) =>
                      setLocal(() => gaveta = v ?? gaveta),
                ),
                Text(
                  'Pasará a contar en el «pendiente a entregar» '
                  'de ese entrenador y seguirá descontando de la '
                  'nómina de $nombreEntrenador.',
                  style: AppTexto.metadato,
                ),
              ] else
                Text(
                  'Dejará de contar como pendiente a entregar de '
                  'cualquier entrenador. Seguirá descontando de '
                  'la nómina de $nombreEntrenador.',
                  style: AppTexto.metadato,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Corregir'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await AdelantosService.instance.corregirOrigen(id,
          nuevoOrigen: destino,
          descuentaA: destino == 'caja_turno'
              ? _personasAdelantos[gaveta]?.telegramId
              : null,
          entrenadorId: entrenadorId,
          mesNomina: mesNomina);
    } catch (err) {
      if (mounted) {
        mostrarSnack(context, '$err',
            significado: SignificadoChip.error);
      }
      return;
    }
    if (mounted) {
      mostrarSnack(context,
          'Origen corregido (se sincronizará)',
          significado: SignificadoChip.exito);
      _cargar();
    }
  }

  Future<void> _dialogoRegistrarAdelanto(
      BuildContext context, String ent) async {
    // Ronda 17 M4-H1: registrar adelantos es solo del dueño.
    if (!AuthService().isOwner) return;
    final persona = _personasAdelantos[ent]!;
    final montoCtrl = TextEditingController();
    final notaCtrl = TextEditingController();
    var fecha = ahoraHabana();
    var metodo = 'efectivo';
    var origen = 'caja_turno';
    var gaveta = ent; // username de cuya gaveta sale
    final guardado = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Adelanto a ${persona.nombre}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: montoCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Monto (CUP entero)'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Fecha: '),
                    TextButton(
                      onPressed: () async {
                        final f = await showDatePicker(
                          context: ctx,
                          initialDate: fecha,
                          firstDate: DateTime(fecha.year - 1, 1, 1),
                          lastDate: ahoraHabana(),
                        );
                        if (f != null) {
                          setLocal(() => fecha = f);
                        }
                      },
                      child: Text(
                          '${fecha.year}-${fecha.month.toString().padLeft(2, '0')}-${fecha.day.toString().padLeft(2, '0')}'),
                    ),
                  ],
                ),
                Text('Método',
                    style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w700)),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Efectivo'),
                      selected: metodo == 'efectivo',
                      onSelected: (_) =>
                          setLocal(() => metodo = 'efectivo'),
                    ),
                    ChoiceChip(
                      label: const Text('Transferencia'),
                      selected: metodo == 'transferencia',
                      onSelected: (_) =>
                          setLocal(() => metodo = 'transferencia'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('¿De dónde sale?',
                    style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w700)),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Caja del turno'),
                      selected: origen == 'caja_turno',
                      onSelected: (_) =>
                          setLocal(() => origen = 'caja_turno'),
                    ),
                    ChoiceChip(
                      label: const Text('Mi bolsillo'),
                      selected: origen == 'fondo_dueno',
                      onSelected: (_) =>
                          setLocal(() => origen = 'fondo_dueno'),
                    ),
                  ],
                ),
                if (origen == 'caja_turno' &&
                    metodo == 'efectivo') ...[
                  const SizedBox(height: 8),
                  const Text('Sale de la gaveta de:',
                      style: AppTexto.metadato),
                  DropdownButton<String>(
                    value: gaveta,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                          value: 'duany', child: Text('Duany')),
                      DropdownMenuItem(
                          value: 'gabriel',
                          child: Text('Gabriel')),
                    ],
                    onChanged: (v) =>
                        setLocal(() => gaveta = v ?? ent),
                  ),
                  const Text(
                    'Ese dinero ya no estará en su «pendiente a '
                    'entregar»: cuadra con su arqueo.',
                    style: AppTexto.metadato,
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: notaCtrl,
                  maxLength: 80,
                  decoration: const InputDecoration(
                      labelText: 'Nota (opcional)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () {
                final monto = int.tryParse(montoCtrl.text.trim());
                if (monto == null || monto <= 0) {
                  mostrarSnack(ctx, 'Monto inválido: entero mayor que 0', significado: SignificadoChip.alerta);
                  return;
                }
                Navigator.of(ctx).pop(true);
              },
              child: const Text('Registrar'),
            ),
          ],
        ),
      ),
    );
    // #7 (Argón nómina): al cancelar también se liberan los
    // controladores del diálogo (antes solo se liberaban al
    // guardar).
    if (guardado != true) {
      montoCtrl.dispose();
      notaCtrl.dispose();
      return;
    }
    final monto = int.tryParse(montoCtrl.text.trim()) ?? 0;
    final gavetaPersona = _personasAdelantos[gaveta];
    await AdelantosService.instance.registrar(
      entrenadorId: persona.id,
      entrenadorNombre: persona.nombre,
      entrenadorTelegramId: persona.telegramId,
      monto: monto,
      fecha: fecha,
      nota: notaCtrl.text,
      metodo: metodo,
      origen: origen,
      descuentaA: gavetaPersona?.telegramId,
    );
    montoCtrl.dispose();
    notaCtrl.dispose();
    if (mounted) {
      mostrarSnack(context, 'Adelanto registrado (se sincronizará)', significado: SignificadoChip.exito);
      _cargar();
    }
  }
}

/// Tarjeta compacta para el Home del entrenador (v1.3.9 #8).
class TarjetaNominaEntrenador extends StatelessWidget {
  const TarjetaNominaEntrenador({super.key});

  @override
  Widget build(BuildContext context) {
    return Tarjeta(
      padding: const EdgeInsets.all(16),
      child: InkWell(
        onTap: () {
          // #1 (Argón nómina + decisión Jc): la tarjeta del
          // entrenador abre SU resumen (MiNominaScreen, con sus
          // bonos), no la pantalla del dueño.
          Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const MiNominaScreen()),
          );
        },
        child: Row(
          children: [
            IconoModuloBadge.naranja(
                Icons.payments_rounded),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Mi nómina (estimado)',
                style: AppTexto.cuerpo,
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}
