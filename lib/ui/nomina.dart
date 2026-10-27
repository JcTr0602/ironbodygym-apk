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
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';

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
      try {
        final ventasServ =
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
          final nombre = nombrePorTid[tid]!.toLowerCase();
          if (nombre.contains('duany')) {
            comisionDosis['duany'] = r;
          } else if (nombre.contains('gabriel')) {
            comisionDosis['gabriel'] = r;
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
      // sea auditable; las comisiones pasadas no se conocen (la
      // función es nueva) y entran en 0.
      final personasAdelantos =
          <String, ({String id, int? telegramId, String nombre})>{};
      try {
        final raw = await LocalDb.instance.getMeta('usuarios_apk');
        if (raw != null && raw.isNotEmpty) {
          for (final u in jsonDecode(raw) as List) {
            final m = Map<String, dynamic>.from(u as Map);
            final username = '${m['username'] ?? ''}'.toLowerCase();
            if (username == 'duany' || username == 'gabriel') {
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
          final n = await NominaCalc.clientesQuePagaronElMes(mes);
          brutoPorMes[mes] = n * tarifa.toDouble();
          mes = mesSiguiente(mes);
        }
        final libro = libroAdelantos(
          eventos: eventos,
          brutoPorMes: brutoPorMes,
          comisionesPorMes: {
            pref: comisionDosis[e.key]?.total ?? 0,
          },
          hastaMes: pref,
        );
        for (final m in libro) {
          if (m.mes == pref) libroMes[e.key] = m;
        }
        liquidadas[e.key] = await AdelantosService.instance
            .nominaLiquidada(pref, e.value.id);
      }
      if (!mounted) return;
      if (!mounted) return;
      setState(() {
        _comisionDosis = comisionDosis;
        _personasAdelantos = personasAdelantos;
        _libroMes = libroMes;
        _eventosAdelantos = eventosPorEnt;
        _nominaLiquidadaMes = liquidadas;
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
    final texto =
        _bonoMontoCtrl.text.trim().replaceAll(',', '.');
    final monto = double.tryParse(texto) ?? 0;
    if (monto == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Ingresa un monto válido')),
      );
      return;
    }
    // Fase A 2026-10-25 (A4): el bono se guarda sincronizado
    // (espejo + op), no en SharedPreferences.
    final pref = hoyHabanaIso().substring(0, 7);
    await BonosNominaService.instance.agregar(
      mes: pref,
      entrenador: _bonoEntrenador,
      monto: monto,
      nota: _bonoNotaCtrl.text.trim(),
    );
    final actualizados =
        await BonosNominaService.instance.leerBonos(pref);
    if (!mounted) return;
    setState(() {
      _bonos = actualizados;
      _bonoMontoCtrl.clear();
      _bonoNotaCtrl.clear();
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bono agregado')),
      );
    }
  }

  Future<void> _eliminarBono(String id) async {
    // Fase A 2026-10-25 (A4): encola la eliminación; la lectura
    // fusionada lo oculta al instante.
    await BonosNominaService.instance.eliminar(id);
    final pref = hoyHabanaIso().substring(0, 7);
    final actualizados =
        await BonosNominaService.instance.leerBonos(pref);
    if (!mounted) return;
    setState(() => _bonos = actualizados);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bono eliminado')),
      );
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
                  style: const TextStyle(
                    color: AppColores.exito,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (bono != 0)
                  Text(
                    '${bono > 0 ? '+' : ''}${fmtMonto(bono)} bono',
                    style: TextStyle(
                      fontSize: 12,
                      color: bono > 0
                          ? AppColores.exito
                          : Colors.red,
                    ),
                  ),
                if (comision.total != 0)
                  Text(
                    '${comision.total > 0 ? '+' : ''}'
                    '${fmtMonto(comision.total)} comisión dosis '
                    '(${comision.dosis})',
                    style: TextStyle(
                      fontSize: 12,
                      color: comision.total > 0
                          ? AppColores.exito
                          : Colors.red,
                    ),
                  ),
                if (adelantosMes != 0)
                  Text(
                    '−${fmtMonto(adelantosMes)} adelantos',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.red),
                  ),
                if (deudaEntrante > 0)
                  Text(
                    '−${fmtMonto(deudaEntrante)} deuda anterior',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.red),
                  ),
                if (liquidada)
                  const Text(
                    '✓ nómina pagada',
                    style: TextStyle(
                        fontSize: 12, color: AppColores.exito),
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
          monto >= 0 ? Icons.add_circle : Icons.remove_circle,
          color: monto >= 0 ? AppColores.exito : Colors.red,
        ),
        title: Text(
          '${monto > 0 ? '+' : ''}${fmtMonto(monto)} CUP — $destino',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: nota.isNotEmpty ? Text(nota) : null,
        trailing: IconButton(
          icon: const Icon(Icons.delete, color: Colors.red),
          tooltip: 'Eliminar bono',
          onPressed: () => _eliminarBono('${b['id']}'),
        ),
      ),
    );
  }

  Future<void> _guardarTarifa() async {
    final texto = _tarifaCtrl.text.trim().replaceAll(',', '.');
    final tarifa = double.tryParse(texto) ?? 150;
    if (tarifa <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Ingresa una tarifa válida')),
      );
      return;
    }
    await PerfilService.instance.setPagoEntrenador(tarifa.toInt());
    setState(() => _tarifa = tarifa);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tarifa actualizada')),
      );
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
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
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
                              style: AppTexto.titulo
                                  .copyWith(fontSize: 18),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
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
                                Icons.info_outline,
                                size: 16,
                                color: AppColores.naranja),
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
                          style: AppTexto.titulo
                              .copyWith(fontSize: 16),
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
                          style: AppTexto.titulo
                              .copyWith(fontSize: 14),
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
                              child: TextField(
                                controller:
                                    _bonoMontoCtrl,
                                keyboardType:
                                    const TextInputType
                                        .numberWithOptions(
                                            decimal: true,
                                            signed: true),
                                decoration:
                                    const InputDecoration(
                                  hintText: 'Ej: 2000 o -500',
                                  border:
                                      OutlineInputBorder(),
                                  prefixText: '\$ ',
                                  suffixText: 'CUP',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _bonoNotaCtrl,
                          decoration: const InputDecoration(
                            hintText:
                                'Nota: por qué se otorga...',
                            border: OutlineInputBorder(),
                          ),
                          maxLines: 2,
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _agregarBono,
                            icon: const Icon(Icons.add),
                            label:
                                const Text('Agregar bono'),
                          ),
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
                          style: AppTexto.titulo
                              .copyWith(fontSize: 14),
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
                              child: TextField(
                                controller:
                                    _tarifaCtrl,
                                keyboardType:
                                    TextInputType.number,
                                decoration:
                                    const InputDecoration(
                                  border:
                                      OutlineInputBorder(),
                                  suffixText: 'CUP',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ElevatedButton(
                              onPressed:
                                  _guardarTarifa,
                              child:
                                  const Text('Guardar'),
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
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Row(
            children: [
              const Icon(Icons.payments_rounded,
                  size: 18, color: AppColores.naranja),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Adelantos de ${persona.nombre}',
                    style: AppTexto.subtitulo),
              ),
              if (esDueno)
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 17),
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
                style: const TextStyle(
                    fontSize: 12, color: Colors.red),
              ),
            ),
          if (esDueno && !liquidada)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.fact_check_rounded, size: 17),
                label: const Text('Marcar nómina del mes como pagada'),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('¿Nómina pagada?'),
                      content: Text(
                          'Se marca la nómina de este mes de '
                          '${persona.nombre} como PAGADA. Desde ese '
                          'momento, los adelantos que se registren '
                          'con fecha de este mes caerán en la '
                          'nómina del mes siguiente (el mes pagado '
                          'no se reescribe).'),
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
                  );
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text(
                                'Nómina marcada como pagada')));
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
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text('${e['fecha'] ?? ''}',
                style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  esReverso
                      ? 'Anulación de adelanto'
                      : 'Adelanto ($metodo, $origen)',
                  style: TextStyle(
                    fontSize: 13,
                    decoration: estaAnulado
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                if (nota.isNotEmpty)
                  Text(nota,
                      style: const TextStyle(fontSize: 12)),
                if (estaAnulado)
                  const Text('anulado',
                      style: TextStyle(
                          fontSize: 11, color: Colors.red)),
                if (anulacionPendiente)
                  const Text('anulación en curso…',
                      style: TextStyle(fontSize: 11)),
                if (pendiente)
                  const Text('pendiente de sincronizar',
                      style: TextStyle(fontSize: 11)),
              ],
            ),
          ),
          Text(
            '${monto >= 0 ? '' : '+'}${fmtMonto(monto.abs())} CUP',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: esReverso ? AppColores.exito : Colors.red,
            ),
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
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$err')));
                  }
                  return;
                }
                if (mounted) _cargar();
              },
            ),
        ],
      ),
    );
  }

  Future<void> _dialogoRegistrarAdelanto(
      BuildContext context, String ent) async {
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
                const SizedBox(height: 10),
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
                const Text('Método',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
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
                const Text('¿De dónde sale?',
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w700)),
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
                      style: TextStyle(fontSize: 12)),
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
                    style: TextStyle(fontSize: 11),
                  ),
                ],
                const SizedBox(height: 10),
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
                  ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Monto inválido: entero mayor que 0')));
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
    if (guardado != true) return;
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Adelanto registrado (se sincronizará)')));
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
          Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    const NominaScreen()),
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
                style: TextStyle(fontSize: 14),
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
