// lib/ui/cumpleanos_mes.dart
// v1.3.9 Sprint 4 (#11): cumpleaños próximos 30 días.
// 🎂 Hoy + 📅 Próximos 30 días. Maneja cambio de año.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';

class Cumpleanero {
  final String nombre;
  final String telefono;
  final DateTime fechaCumple; // próximo cumpleaños
  final int edad;
  final bool esHoy;

  Cumpleanero({
    required this.nombre,
    required this.telefono,
    required this.fechaCumple,
    required this.edad,
    required this.esHoy,
  });
}

class CumpleanosMes extends StatefulWidget {
  const CumpleanosMes({super.key});

  @override
  State<CumpleanosMes> createState() =>
      _CumpleanosMesState();
}

class _CumpleanosMesState
    extends State<CumpleanosMes> {
  bool _cargando = true;
  List<Cumpleanero> _hoy = [];
  List<Cumpleanero> _proximos = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    try {
      final hoy = ahoraHabana();
      final hoySinHora =
          DateTime(hoy.year, hoy.month, hoy.day);
      final hoyList = <Cumpleanero>[];
      final proxList = <Cumpleanero>[];

      for (final c
          in await LocalDb.instance.allMirror(
              'clientes')) {
        // Solo activos: no eliminados y no vencidos hace >60 días
        if (c['eliminado'] == true ||
            c['eliminado'] == 1) continue;
        // Argón #10-2: un entrenador no ve clientes protegidos
        // del dueño (nombres, fechas ni teléfonos).
        if (esVistaProtegida(c)) continue;
        // Filtrar clientes inactivos hace mucho tiempo
        final pagadoHasta =
            '${c['pagado_hasta'] ?? ''}';
        if (pagadoHasta.length >= 10) {
          try {
            final fp = pagadoHasta
                .substring(0, 10)
                .split('-');
            final venc = DateTime(
              int.parse(fp[0]),
              int.parse(fp[1]),
              int.parse(fp[2]),
            );
            final diasVencido = hoySinHora
                .difference(venc)
                .inDays;
            if (diasVencido > 60) continue;
          } catch (_) {}
        }

        final carnet = '${c['carnet'] ?? ''}';
        final nac = fechaNacDeCarnet(carnet);
        if (nac == null) continue;

        // Calcular próximo cumpleaños (maneja cambio de año)
        var proximo = DateTime(
            hoy.year, nac.month, nac.day);
        if (proximo.isBefore(hoySinHora)) {
          proximo = DateTime(
              hoy.year + 1, nac.month, nac.day);
        }
        final diff =
            proximo.difference(hoySinHora).inDays;
        if (diff > 30) continue;

        final edad = proximo.year - nac.year;
        final nombre = '${c['nombre'] ?? 'Sin nombre'}';
        final telefono = '${c['telefono'] ?? ''}';

        final cum = Cumpleanero(
          nombre: nombre,
          telefono: telefono,
          fechaCumple: proximo,
          edad: edad,
          esHoy: diff == 0,
        );
        if (diff == 0) {
          hoyList.add(cum);
        } else {
          proxList.add(cum);
        }
      }

      // Ordenar próximos por fecha
      proxList.sort((a, b) => a.fechaCumple
          .compareTo(b.fechaCumple));

      if (mounted) {
        setState(() {
          _hoy = hoyList;
          _proximos = proxList;
          _cargando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cargando = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _felicitar(
      Cumpleanero c) async {
    // Argón #10-5: usar el normalizador canónico (un fijo de 8
    // dígitos pasaba como válido y fallaba en wa.me) y no reventar
    // si no hay app que abra el enlace.
    final tel = normalizarTelefonoWaMe(c.telefono);
    if (tel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Sin teléfono válido')),
      );
      return;
    }
    final texto =
        'Feliz cumpleaños ${c.nombre}! Te desea el equipo de Iron Body Gym. Que tengas un día lleno de alegría y muchos éxitos!';
    final uri = Uri.parse(
      'https://wa.me/$tel?text=${Uri.encodeComponent(texto)}',
    );
    try {
      await launchUrl(uri,
          mode: LaunchMode.externalApplication);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('No se pudo abrir WhatsApp')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cumpleaños'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          ? const Center(
              child: CircularProgressIndicator())
          : _hoy.isEmpty && _proximos.isEmpty
              ? const Center(
                  child: Text(
                    'No hay cumpleaños en los próximos 30 días.',
                    style:
                        TextStyle(color: Colors.grey),
                  ),
                )
              : ListView(
                  padding:
                      const EdgeInsets.all(16),
                  children: [
                    if (_hoy.isNotEmpty) ...[
                      const Text(
                        '🎂 Hoy',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._hoy.map((c) =>
                          _buildCard(c, true)),
                      const SizedBox(height: 16),
                    ],
                    if (_proximos.isNotEmpty) ...[
                      const Text(
                        '📅 Próximos 30 días',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._proximos.map(
                          (c) => _buildCard(c, false)),
                    ],
                  ],
                ),
    );
  }

  Widget _buildCard(
      Cumpleanero c, bool esHoy) {
    return Card(
      color: esHoy
          ? const Color(0xFFFF6B00)
              .withOpacity(0.1)
          : null,
      margin:
          const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: esHoy
              ? const Color(0xFFFF6B00)
              : Colors.grey[300],
          child: Text(
            '${c.edad}',
            style: TextStyle(
              color: esHoy
                  ? Colors.white
                  : Colors.black87,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        title: Text(
          c.nombre,
          style: const TextStyle(
              fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          esHoy
              ? '¡Cumple hoy!'
              : '${c.fechaCumple.day}/${c.fechaCumple.month}',
        ),
        trailing: IconButton(
          icon: const Icon(Icons.chat,
              color: Colors.green),
          tooltip: 'Felicitar por WhatsApp',
          onPressed: () => _felicitar(c),
        ),
      ),
    );
  }
}
