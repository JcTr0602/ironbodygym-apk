/// Ayuda para entrenadores.
///
/// Secciones plegables por tema + "Lo Nuevo" con la versión actual destacada.
library;

import 'package:flutter/material.dart';

import '../config.dart';
import '../novedades.dart';
import 'widgets.dart';

class AyudaScreen extends StatelessWidget {
  const AyudaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ayuda')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _novedadesCard(),
                const _Tema('Tu trabajo diario'),
                const _Seccion(
                  'Inscribir un cliente',
                  '1. Toca "Inscribir" en el inicio.\n'
                  '2. Escribe el nombre y, si quieres, teléfono, carnet y foto.\n'
                  '3. Elige el período de pago y confirma.\n'
                  '4. Si ya existe alguien parecido, la app te avisa.\n\n'
                  'Todo se guarda en el teléfono aunque no haya internet.',
                  icono: Icons.edit_note,
                  color: Colors.blue,
                ),
                const _Seccion(
                  'Cobrar una mensualidad',
                  '1. Busca al cliente o ábrelo desde las listas.\n'
                  '2. Toca "Registrar pago" (o el botón Pagar de la lista).\n'
                  '3. Elige el período y el método (efectivo o transferencia).\n'
                  '4. Confirma el resumen.\n\n'
                  'Si está vencido, en su ficha verás "Renovación rápida" '
                  'para cobrarle 1 mes con un toque.',
                  icono: Icons.payments,
                  color: Colors.green,
                ),
                const _Seccion(
                  'Pago diario',
                  'Para quien entrena un día suelto. Se registra en '
                  '"Pago diario" del inicio.',
                  icono: Icons.receipt_long,
                  color: Colors.teal,
                ),
                const _Seccion(
                  'Las listas',
                  '• Vencen hoy: pagan hoy.\n'
                  '• Por vencer: vencen en los próximos 3 días.\n'
                  '• -30d: atrasados de menos de un mes.\n'
                  '• +30d: atrasados de más de un mes.\n'
                  '• Cumpleaños: cumplen años esta semana.\n\n'
                  'Toca Pagar en cualquier fila para cobrar sin entrar a la ficha.',
                  icono: Icons.list_alt,
                  color: Colors.purple,
                ),
                const _Seccion(
                  'Mi turno',
                  'Lo que cobraste hoy y tu pendiente a entregar. '
                  'Cada entrenador solo ve lo suyo.',
                  icono: Icons.person,
                  color: Colors.indigo,
                ),
                const _Tema('Dinero'),
                const _Seccion(
                  'Pendiente a entregar',
                  'Es el efectivo que cobraste y aún no le entregaste a Jc. '
                  'Baja solo cuando él lo confirma. No es un error.',
                  icono: Icons.handshake,
                  color: Colors.green,
                ),
                const _Seccion(
                  'Cobro por transferencia',
                  'Muestra los datos de las tarjetas para que el cliente '
                  'transfiera y confirme por WhatsApp al '
                  '${AppConfig.whatsappContacto}.',
                  icono: Icons.smartphone,
                  color: Colors.teal,
                ),
                const _Tema('La app'),
                const _Seccion(
                  '¿Necesita internet?',
                  'No para trabajar. Inscribes y cobras con normalidad en el gym; '
                  'cuando tengas conexión, los datos se envían solos.',
                  icono: Icons.signal_cellular_alt,
                  color: Colors.orange,
                ),
                const _Seccion(
                  'Sincronización',
                  '• Revisa cambios de otros entrenadores cada 2 minutos.\n'
                  '• Tus cambios suben cada hora, en segundo plano, o al tocar '
                  '"Sincronizar ahora".\n'
                  '• Si ves ⏳ "N por subir", son tus cambios esperando conexión.\n'
                  '• En el inicio verás la hora de la última sincronización. '
                  'Si es vieja, busca mejor cobertura.',
                  icono: Icons.sync,
                  color: Colors.blue,
                ),
                const _Seccion(
                  'Papelera',
                  'Los clientes inactivos van a la papelera. Desde ahí puedes '
                  'recuperarlos sin inscribirlos de nuevo. '
                  'Solo Jc puede eliminarlos definitivamente.',
                  icono: Icons.delete_outline,
                  color: Colors.grey,
                ),
                const _Tema('Si algo falla'),
                const _Seccion(
                  'Problemas comunes',
                  '• "Sin conexión": sigue trabajando, todo se guarda y sube después.\n'
                  '• "Conexión muy lenta": ten paciencia, las fotos continúan '
                  'donde quedaron.\n'
                  '• "Error del servidor": reintenta luego; si sigue, avisa a Jc.\n'
                  '• "Te saca al login": tu sesión venció, entra de nuevo.\n'
                  '• "Un cliente no aparece": sincroniza manualmente.',
                  icono: Icons.warning,
                  color: Colors.red,
                ),
                const _Seccion(
                  'Tu privacidad',
                  'Solo ves tus datos: tu pendiente, tu turno, tus cobros. '
                  'Jc ve los totales de todos para llevar el control del gym.',
                  icono: Icons.lock,
                  color: Colors.red,
                ),
                const _Seccion(
                  'Contacto',
                  '¿Dudas con la app? Escríbele a Jc por WhatsApp: '
                  '${AppConfig.whatsappContacto}.',
                  icono: Icons.phone,
                  color: Colors.green,
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    'Iron Body Gym · versión ${AppConfig.appVersion}',
                    style: TextStyle(
                        color: Colors.grey, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Tarjeta "Lo Nuevo": la versión actual destacada, las anteriores plegadas.
  static Widget _novedadesCard() {
    if (novedades.isEmpty) return const SizedBox.shrink();
    final actual = novedades.first;
    final anteriores = novedades.skip(1).toList();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(
            color: Color(0xFFE8821A), width: 2),
      ),
      child: ExpansionTile(
        initiallyExpanded: true,
        leading: const CircleAvatar(
          backgroundColor: Color(0xFFFFE3C2),
          child:
              Icon(Icons.new_releases, color: Color(0xFFE8821A)),
        ),
        title: const Text('Lo Nuevo',
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 16)),
        subtitle: Text('Versión ${actual.version}'),
        children: [
          for (final c in actual.cambios)
            Padding(
              padding:
                  const EdgeInsets.fromLTRB(24, 3, 16, 3),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('• $c',
                    style: const TextStyle(fontSize: 14)),
              ),
            ),
          if (anteriores.isNotEmpty)
            ExpansionTile(
              title: const Text('Versiones anteriores',
                  style: TextStyle(
                      fontSize: 13, color: Colors.grey)),
              children: [
                for (final n in anteriores) ...[
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Versión ${n.version}',
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                    ),
                  ),
                  for (final c in n.cambios)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          24, 2, 16, 2),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text('• $c',
                            style: const TextStyle(
                                fontSize: 13,
                                color: Colors.black87)),
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
              ],
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Encabezado de grupo temático.
class _Tema extends StatelessWidget {
  final String texto;
  const _Tema(this.texto);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(texto,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Color(0xFFE8821A))),
      ),
    );
  }
}

class _Seccion extends StatelessWidget {
  final String titulo;
  final String texto;
  final IconData icono;
  final Color color;
  const _Seccion(this.titulo, this.texto,
      {required this.icono, required this.color});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Icon(icono, size: 20, color: color),
        ),
        title: Text(titulo,
            style: const TextStyle(
                fontWeight: FontWeight.bold, fontSize: 15)),
        children: [
          Padding(
            padding:
                const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(texto,
                  style: const TextStyle(
                      fontSize: 14, height: 1.4)),
            ),
          ),
        ],
      ),
    );
  }
}
