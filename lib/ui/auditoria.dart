/// Auditoría mejorada (v1.0.12): quién hizo qué, a qué cliente,
/// qué cambió y foto asociada.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../localdb.dart';

class AuditoriaScreen extends StatefulWidget {
  const AuditoriaScreen({super.key});

  @override
  State<AuditoriaScreen> createState() => _AuditoriaScreenState();
}

class _AuditoriaScreenState extends State<AuditoriaScreen> {
  List<Map<String, dynamic>> _ops = [];
  bool _cargando = true;
  // cliente_id -> nombre (caché)
  final Map<int, String> _nombres = {};
  // cliente_id -> foto_path local (caché)
  final Map<int, String?> _fotos = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final ops = await LocalDb.instance.recentOps(limit: 100);
    // Precargar nombres y fotos de clientes mencionados
    final clientes = await LocalDb.instance.allMirror('clientes');
    final porId = <int, Map<String, dynamic>>{
      for (final c in clientes)
        (c['id'] as int): c,
    };
    for (final op in ops) {
      final p = _payload(op);
      final cid = _clienteId(p, '${op['tipo']}');
      if (cid != null && !_nombres.containsKey(cid)) {
        final c = porId[cid];
        if (c != null) {
          _nombres[cid] = '${c['nombre'] ?? 'Cliente $cid'}';
          _fotos[cid] = c['foto_local'] as String?;
        }
      }
    }
    if (mounted) {
      setState(() {
        _ops = ops;
        _cargando = false;
      });
    }
  }

  Map<String, dynamic> _payload(Map<String, dynamic> op) {
    try {
      final p = op['payload'];
      if (p is String) return Map<String, dynamic>.from(jsonDecode(p));
      if (p is Map) return Map<String, dynamic>.from(p);
    } catch (_) {}
    return {};
  }

  int? _clienteId(Map<String, dynamic> p, String tipo) {
    for (final k in ['cliente_id', 'id', 'cliente']) {
      final v = p[k];
      if (v is int) return v;
      if (v is String) {
        final n = int.tryParse(v);
        if (n != null) return n;
      }
    }
    return null;
  }

  String _nombreTipo(String tipo) {
    switch (tipo) {
      case 'inscribir':
        return 'Inscripción';
      case 'pago_mensual':
        return 'Pago mensual';
      case 'pago_diario':
        return 'Pago diario';
      case 'cambiar_estado':
        return 'Cambio de estado';
      case 'foto':
        return 'Foto';
      case 'gasto':
        return 'Gasto';
      case 'editar_cliente':
        return 'Edición de cliente';
      case 'admin_usuario':
        return 'Gestión de usuario';
      default:
        return tipo;
    }
  }

  /// Describe qué cambió en la operación.
  String _detalle(Map<String, dynamic> op) {
    final tipo = '${op['tipo']}';
    final p = _payload(op);
    final cid = _clienteId(p, tipo);
    final nombre = cid != null ? (_nombres[cid] ?? 'Cliente $cid') : null;

    switch (tipo) {
      case 'editar_cliente':
        final campos = {
          'nombre': 'nombre',
          'telefono': 'teléfono',
          'carnet': 'carnet',
          'notas': 'notas',
          'sexo': 'sexo',
          'pagado_hasta': 'vencimiento',
        };
        final cambiados = [
          for (final k in p.keys)
            if (campos.containsKey(k)) campos[k]!
        ];
        final q = cambiados.isEmpty ? '' : ' (${cambiados.join(', ')})';
        return nombre != null ? 'Editó a $nombre$q' : 'Edición$q';
      case 'pago_mensual':
        final monto = p['monto'];
        final metodo = p['metodo'] ?? 'efectivo';
        return nombre != null
            ? '$nombre — ${monto ?? '?'} CUP ($metodo)'
            : 'Pago ${monto ?? '?'} CUP';
      case 'inscribir':
        final n = '${p['nombre'] ?? nombre ?? '?'}';
        return 'Inscribió a $n';
      case 'foto':
        return nombre != null ? 'Foto de $nombre' : 'Foto';
      case 'cambiar_estado':
        final est = p['estado'] ?? '?';
        return nombre != null ? '$nombre → $est' : 'Estado → $est';
      case 'gasto':
        return '${p['concepto'] ?? 'Gasto'} (${p['monto'] ?? '?'} CUP)';
      case 'admin_usuario':
        return '${p['accion'] ?? '?'}: ${p['username'] ?? '?'}';
      default:
        return nombre ?? '';
    }
  }

  String _usuario(Map<String, dynamic> op) {
    final p = _payload(op);
    for (final k in ['registrado_por', 'usuario', 'username']) {
      final v = p[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return 'Este dispositivo';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Auditoría'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _ops.isEmpty
              ? const Center(child: Text('Sin operaciones registradas'))
              : RefreshIndicator(
                  onRefresh: _cargar,
                  child: ListView.builder(
                    itemCount: _ops.length,
                    itemBuilder: (ctx, i) {
                      final op = _ops[i];
                      final tipo = '${op['tipo']}';
                      final estado = '${op['estado']}';
                      final fecha =
                          '${op['creada_ts']}'.substring(0, 16).replaceAll('T', ' ');
                      final detalle = _detalle(op);
                      final usuario = _usuario(op);
                      final p = _payload(op);
                      final cid = _clienteId(p, tipo);
                      final fotoPath = cid != null ? _fotos[cid] : null;
                      final tieneFoto = fotoPath != null &&
                          fotoPath.isNotEmpty &&
                          File(fotoPath).existsSync();

                      return Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: ListTile(
                          leading: tieneFoto
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: Image.file(
                                    File(fotoPath),
                                    width: 40,
                                    height: 40,
                                    fit: BoxFit.cover,
                                  ),
                                )
                              : CircleAvatar(
                                  child: Text(
                                    usuario.isNotEmpty
                                        ? usuario[0].toUpperCase()
                                        : '?',
                                  ),
                                ),
                          title: Text(_nombreTipo(tipo)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (detalle.isNotEmpty)
                                Text(detalle,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w500)),
                              Text(usuario),
                              Text(fecha),
                              Text(
                                'Estado: $estado',
                                style: TextStyle(
                                  color: estado == 'aplicada'
                                      ? Colors.green
                                      : estado == 'rechazada'
                                          ? Colors.red
                                          : Colors.orange,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
