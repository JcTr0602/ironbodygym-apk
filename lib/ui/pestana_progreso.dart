// lib/ui/pestana_progreso.dart
// v1.3.9 Sprint 2 (#3 + #13): pestaña de progreso con mediciones.
// Gráfico de peso + lista + formulario de registro.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../auth.dart';
import '../mediciones_cliente.dart';
import '../tiempo.dart';
import '../permisos_entrenador.dart';
import 'editor_plan_nutricional.dart';
import 'grafico_peso.dart';

class Medicion {
  final int id;
  final String clienteId;
  final double pesoKg;
  final double? grasaPct;
  final double? pechoCm;
  final double? cinturaCm;
  final double? caderaCm;
  final double? brazoCm;
  final double? musloCm;
  final String? notas;
  final String registradoPor;
  final DateTime createdAt;

  Medicion({
    required this.id,
    required this.clienteId,
    required this.pesoKg,
    this.grasaPct,
    this.pechoCm,
    this.cinturaCm,
    this.caderaCm,
    this.brazoCm,
    this.musloCm,
    this.notas,
    required this.registradoPor,
    required this.createdAt,
  });

  factory Medicion.fromJson(Map<String, dynamic> j) {
    return Medicion(
      id: (j['id'] as num?)?.toInt() ?? 0,
      clienteId: '${j['cliente_id'] ?? ''}',
      pesoKg: (j['peso_kg'] as num?)?.toDouble() ?? 0,
      grasaPct: (j['grasa_pct'] as num?)?.toDouble(),
      pechoCm: (j['pecho_cm'] as num?)?.toDouble(),
      cinturaCm: (j['cintura_cm'] as num?)?.toDouble(),
      caderaCm: (j['cadera_cm'] as num?)?.toDouble(),
      brazoCm: (j['brazo_cm'] as num?)?.toDouble(),
      // La clave canónica es muslo_cm; 'pierna_cm' solo es lectura
      // defensiva por si un origen futuro la renombra (nunca se
      // escribe: el RPC sigue recibiendo p_muslo_cm).
      musloCm: ((j['muslo_cm'] ?? j['pierna_cm']) as num?)?.toDouble(),
      notas: j['notas']?.toString(),
      registradoPor: '${j['registrado_por'] ?? ''}',
      createdAt: DateTime.tryParse('${j['created_at'] ?? ''}') ??
          DateTime.now(),
    );
  }
}

/// Parsea números aceptando coma decimal (teclados en español).
double? _parseNum(String text) =>
    double.tryParse(text.trim().replaceAll(',', '.'));

class PestanaProgreso extends StatefulWidget {
  final String clienteId;
  final String nombreCliente;

  const PestanaProgreso({
    super.key,
    required this.clienteId,
    required this.nombreCliente,
  });

  @override
  State<PestanaProgreso> createState() => _PestanaProgresoState();
}

class _PestanaProgresoState extends State<PestanaProgreso> {
  List<Medicion> _mediciones = [];
  bool _cargando = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'listar_mediciones_cliente',
        params: {'p_cliente_id': widget.clienteId},
      );
      final lista = ((res as List?) ?? [])
          .map((e) =>
              Medicion.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (mounted) {
        setState(() {
          _mediciones = lista;
          _cargando = false;
        });
      }
    } catch (e) {
      // Argón P1#11: sin red, respaldo con el espejo local
      // (medicionesClienteLocal): el modelo Medicion del RPC se
      // reconstruye desde las filas planas del espejo
      // (medidas: peso_kg, grasa_pct, ...; fecha_medicion).
      final cid = int.tryParse(widget.clienteId);
      final locales =
          cid == null ? <Map<String, dynamic>>[] : await medicionesClienteLocal(cid);
      if (mounted && locales.isNotEmpty) {
        setState(() {
          _mediciones = locales.map((r) {
            final m = (r['medidas'] as Map?) ?? {};
            return Medicion.fromJson({
              'id': int.tryParse('${r['medicion_id'] ?? ''}') ?? 0,
              'cliente_id': widget.clienteId,
              'peso_kg': m['peso_kg'],
              'grasa_pct': m['grasa_pct'],
              'pecho_cm': m['pecho_cm'],
              'cintura_cm': m['cintura_cm'],
              'cadera_cm': m['cadera_cm'],
              'brazo_cm': m['brazo_cm'],
              'muslo_cm': m['muslo_cm'],
              'notas': null,
              'registrado_por': '',
              'created_at': r['fecha_medicion'],
            });
          }).toList();
          _cargando = false;
        });
        return;
      }
      if (mounted) {
        setState(() {
          _error = '$e';
          _cargando = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Progreso: ${widget.nombreCliente}'),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    // Verificar permiso de visualización
    if (!PermisosEntrenador().canViewProgress &&
        !AuthService().isOwner) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No tienes permisos para visualizar el progreso.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    if (_cargando) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Error: $_error'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _cargar,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Botón de plan nutricional
          Card(
            child: ListTile(
              leading: const Icon(Icons.restaurant_menu,
                  color: Colors.green),
              title: const Text('Plan Nutricional'),
              subtitle: const Text(
                  'Ver o editar el plan del cliente'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => EditorPlanNutricional(
                      clienteId: widget.clienteId,
                      nombreCliente: widget.nombreCliente,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),

          // Gráfico de peso (2+) o tarjeta resumen (1 medición)
          if (_mediciones.length >= 2) ...[
            GraficoPesoEntrenador(mediciones: _mediciones),
            const SizedBox(height: 16),
          ] else if (_mediciones.length == 1) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Evolución de peso',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Último: ${_mediciones.first.pesoKg.toStringAsFixed(1)} kg',
                      style:
                          const TextStyle(fontSize: 24),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Botón registrar (solo con permiso)
          if (PermisosEntrenador()
                  .canRecordMeasurements ||
              AuthService().isOwner)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Registrar medición'),
                onPressed: () =>
                    _mostrarFormulario(context, null),
              ),
            ),
          const SizedBox(height: 16),

          // Lista de mediciones
          if (_mediciones.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Sin mediciones registradas.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            )
          else
            ..._mediciones
                .take(20)
                .map((m) => _buildMedicionCard(m)),
        ],
      ),
    );
  }

  Widget _buildMedicionCard(Medicion m) {
    final puedeEditar = AuthService().isOwner ||
        (PermisosEntrenador().canRecordMeasurements &&
            DateTime.now()
                    .difference(m.createdAt)
                    .inHours <
                24);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          '${m.pesoKg.toStringAsFixed(1)} kg',
          style: const TextStyle(
              fontWeight: FontWeight.bold, fontSize: 18),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${fmtFechaHabana(m.createdAt)} • Por: ${m.registradoPor}',
              style: const TextStyle(fontSize: 12),
            ),
            // v1.4.0: solo medidas visibles (sin % grasa/pecho/cadera).
            if (m.cinturaCm != null || m.brazoCm != null || m.musloCm != null)
              Text(
                [
                  if (m.cinturaCm != null)
                    'Cintura ${m.cinturaCm!.toStringAsFixed(1)}',
                  if (m.brazoCm != null)
                    'Brazo ${m.brazoCm!.toStringAsFixed(1)}',
                  if (m.musloCm != null)
                    'Pierna ${m.musloCm!.toStringAsFixed(1)}',
                ].join(' · '),
                style: const TextStyle(fontSize: 12),
              ),
          ],
        ),
        trailing: puedeEditar
            ? PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'editar') {
                    _mostrarFormulario(context, m);
                  } else if (v == 'eliminar') {
                    _confirmarEliminar(m);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                      value: 'editar',
                      child: Text('Editar')),
                  const PopupMenuItem(
                      value: 'eliminar',
                      child: Text('Eliminar',
                          style:
                              TextStyle(color: Colors.red))),
                ],
              )
            : null,
        onTap: () => _verDetalle(m),
      ),
    );
  }

  void _verDetalle(Medicion m) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
            '${m.pesoKg.toStringAsFixed(1)} kg'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Fecha: ${fmtFechaHabana(m.createdAt)}'),
            Text('Registrado por: ${m.registradoPor}'),
            // v1.4.0: el detalle solo muestra las medidas visibles.
            if (m.cinturaCm != null)
              Text(
                  'Cintura: ${m.cinturaCm!.toStringAsFixed(1)} cm'),
            if (m.brazoCm != null)
              Text(
                  'Brazo: ${m.brazoCm!.toStringAsFixed(1)} cm'),
            if (m.musloCm != null)
              Text(
                  'Pierna: ${m.musloCm!.toStringAsFixed(1)} cm'),
            if (m.notas != null && m.notas!.isNotEmpty)
              Text('Notas: ${m.notas}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CERRAR'),
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarFormulario(
      BuildContext context, Medicion? existente) async {
    // v1.4.0 (Paso 3, diseño de Argón): el formulario solo muestra
    // Peso, Cintura, Brazo y Pierna. % grasa, pecho y cadera quedan
    // en la BD: al EDITAR se reenvían los valores previos de la
    // medición (el RPC es de reemplazo completo y no puede cambiar
    // de firma); al CREAR van en null, como hasta ahora.
    final pesoCtrl = TextEditingController(
        text: existente?.pesoKg.toString() ?? '');
    final cinturaCtrl = TextEditingController(
        text: existente?.cinturaCm?.toString() ?? '');
    final brazoCtrl = TextEditingController(
        text: existente?.brazoCm?.toString() ?? '');
    final musloCtrl = TextEditingController(
        text: existente?.musloCm?.toString() ?? '');
    final notasCtrl = TextEditingController(
        text: existente?.notas ?? '');

    final guardar = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existente == null
            ? 'Nueva medición'
            : 'Editar medición'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pesoCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(
                        decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Peso (kg) *',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: cinturaCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(
                        decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Cintura (cm)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: brazoCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(
                        decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Brazo (cm)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: musloCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(
                        decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Pierna (cm)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: notasCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notas',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('GUARDAR'),
          ),
        ],
      ),
    );

    // FIX 2 (Argón): capturar valores y liberar controladores
    final pesoStr = pesoCtrl.text;
    final cinturaStr = cinturaCtrl.text;
    final brazoStr = brazoCtrl.text;
    final musloStr = musloCtrl.text;
    final notasStr = notasCtrl.text;
    // Dispose inmediato para evitar fuga de memoria
    pesoCtrl.dispose();
    cinturaCtrl.dispose();
    brazoCtrl.dispose();
    musloCtrl.dispose();
    notasCtrl.dispose();

    if (guardar != true || !mounted) return;

    final peso = _parseNum(pesoStr);
    if (peso == null || peso <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('El peso es requerido')),
        );
      }
      return;
    }

    try {
      await Supabase.instance.client
          .rpc('guardar_medicion_staff', params: {
        'p_cliente_id': widget.clienteId,
        'p_peso_kg': peso,
        // v1.4.0: campos ocultos en la UI. Al editar se conservan los
        // valores previos; al crear van en null (igual que antes).
        'p_grasa_pct': existente?.grasaPct,
        'p_pecho_cm': existente?.pechoCm,
        'p_cintura_cm': _parseNum(cinturaStr),
        'p_cadera_cm': existente?.caderaCm,
        'p_brazo_cm': _parseNum(brazoStr),
        'p_muslo_cm': _parseNum(musloStr),
        'p_notas': notasStr.trim().isEmpty ? null : notasStr.trim(),
        'p_medicion_id': existente?.id,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Medición guardada')),
        );
        _cargar();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _confirmarEliminar(Medicion m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Eliminar medición'),
        content: Text(
            '¿Eliminar la medición de ${m.pesoKg.toStringAsFixed(1)} kg?'),
        actions: [
          TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(false),
              child: const Text('CANCELAR')),
          TextButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(
                  foregroundColor: Colors.red),
              child: const Text('ELIMINAR')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Supabase.instance.client
          .rpc('eliminar_medicion', params: {
        'p_medicion_id': m.id,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Medición eliminada')),
        );
        _cargar();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}
