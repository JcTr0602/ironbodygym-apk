import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
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
  String _mesEtiqueta = '';
  // v1.3.9: lista de bonos por entrenador [{id, entrenador, monto, nota}]
  List<Map<String, dynamic>> _bonos = [];
  final _bonoMontoCtrl = TextEditingController();
  final _bonoNotaCtrl = TextEditingController();
  String _bonoEntrenador = 'ambos'; // 'duany', 'gabriel', 'ambos'
  final _tarifaCtrl = TextEditingController();
  double _tarifa = 150;

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
    // este mes (se queda el pago más reciente por cliente).
    final vistos = <int>{};
    try {
      final pagos = await LocalDb.instance.pagosDelMes(pref);
      for (final p in pagos) {
        final cid = p['cliente_id'];
        final id = cid is int ? cid : int.tryParse('$cid');
        if (id != null) vistos.add(id);
      }
    } catch (_) {}
    if (mounted) {
      final prefs = await SharedPreferences.getInstance();
      // v1.3.9: leer lista de bonos (migrar bono simple viejo si existe)
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
          await prefs.setString(
              _bonosKey(ahoraHabana()), jsonEncode(bonos));
          await prefs.remove(
              'nomina_bono_${ahora.year}_${ahora.month}');
        }
      }
      final tarifa =
          await PerfilService.instance.getPagoEntrenador();
      setState(() {
        _clientesPagados = vistos.length;
        _bonos = bonos;
        _tarifa = tarifa.toDouble();
        _tarifaCtrl.text = tarifa.toString();
        _cargando = false;
      });
    }
  }

  /// Suma de bonos aplicables a un entrenador ('duany' o 'gabriel').
  double _bonoPara(String entrenador) {
    double total = 0;
    for (final b in _bonos) {
      final para = '${b['entrenador'] ?? 'ambos'}';
      if (para == 'ambos' || para == entrenador) {
        total += (b['monto'] as num?)?.toDouble() ?? 0;
      }
    }
    return total;
  }

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
    final prefs = await SharedPreferences.getInstance();
    final nuevo = {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'entrenador': _bonoEntrenador,
      'monto': monto,
      'nota': _bonoNotaCtrl.text.trim(),
      'creado_en': ahoraHabana().toIso8601String(),
    };
    final actualizados = [..._bonos, nuevo];
    await prefs.setString(
        _bonosKey(ahoraHabana()), jsonEncode(actualizados));
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
    final prefs = await SharedPreferences.getInstance();
    final actualizados =
        _bonos.where((b) => '${b['id']}' != id).toList();
    await prefs.setString(
        _bonosKey(ahoraHabana()), jsonEncode(actualizados));
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
    // Si es entrenador, solo mostrar su fila. Determinar quién es:
    // por ahora mostramos ambos para el dueño, y el total genérico
    // para el entrenador (sin saber cuál es).
    final entrenadores = esDueno
        ? ['duany', 'gabriel']
        : ['mi'];
    return entrenadores.map((ent) {
      final nombre = ent == 'duany'
          ? 'Duany'
          : ent == 'gabriel'
              ? 'Gabriel'
              : 'Pago por entrenador';
      final bono = ent == 'mi' ? _bonoPara('duany') + _bonoPara('gabriel') : _bonoPara(ent);
      // Para 'mi' sumamos todos (no sabemos cuál entrenador es)
      final total = base + bono;
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
                      const SizedBox(height: 12),
                      // Desglose por entrenador
                      ..._buildFilasEntrenadores(
                          context, base),
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
