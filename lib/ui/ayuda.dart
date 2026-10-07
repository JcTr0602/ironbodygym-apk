/// ❓ Ayuda para entrenadores.
///
/// Secciones plegables + "🎉 Lo Nuevo" destacada con los cambios por versión.
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
      appBar: AppBar(title: const Text('❓ Ayuda')),
      body: Column(
        children: [
          const SyncBanner(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _novedadesCard(),
                const _Seccion(
                  'Cómo inscribir un cliente',
                  '1. Toca "Inscribir" en el inicio.\n'
                  '2. Escribe el nombre y, si quieres, teléfono, carnet y foto.\n'
                  '3. Elige el período de pago y confirma.\n'
                  '4. Revisa que no sea un duplicado (la app te avisa).\n'
                  'Todo se guarda en el teléfono aunque no haya internet.',
                  emoji: '📝',
                  color: Colors.blue,
                ),
                const _Seccion(
                  'Cómo cobrar una mensualidad',
                  '1. Busca al cliente o ábrelo desde las listas.\n'
                  '2. Toca "💰 Registrar pago" (o el botón 💰 de la lista).\n'
                  '3. Elige el período (semana, quincena, meses o personalizado) y el método (efectivo o transferencia).\n'
                  '4. Confirma el resumen.\n'
                  'Si el cliente está vencido, en su ficha verás "🔄 Renovación rápida" para cobrarle 1 mes con un toque.',
                  emoji: '💰',
                  color: Colors.green,
                ),
                const _Seccion(
                  'Pago diario y transferencia',
                  '• Pago diario: para quien entrena un día suelto. Se registra en "Pago diario" del inicio.\n'
                  '• Transferencia: muestra los datos de las tarjetas para que el cliente transfiera y confirme por WhatsApp al 58191577.',
                  emoji: '💵',
                  color: Colors.teal,
                ),
                const _Seccion(
                  '¿Cómo funciona la app?',
                  'La app guarda todo en el teléfono, no necesita internet para trabajar. '
                  'Inscribes y cobras con normalidad en el gym, y cuando tengas conexión '
                  'los datos se envían solos al sistema.',
                  emoji: '📱',
                  color: Colors.orange,
                ),
                const _Seccion(
                  'Sincronización',
                  '• La app revisa automáticamente si hay cambios de otros entrenadores cada 2 minutos.\n'
                  '• Tus cambios se suben cada hora, en segundo plano, o cuando toques "Sincronizar ahora".\n'
                  '• Las fotos se suben por partes: si se corta la conexión, continúan donde quedaron.\n'
                  '• En el inicio siempre verás la hora de la última sincronización correcta. '
                  'Si es vieja, busca mejor cobertura.',
                  emoji: '🔄',
                  color: Colors.blue,
                ),
                const _Seccion(
                  'Cola de sincronización',
                  'Todo lo que haces sin conexión queda en la cola como "pendiente a subir". '
                  'Nada se pierde: al sincronizar, sube en orden. '
                  'Puedes cancelar una operación tuya que aún no haya subido si te equivocaste. '
                  'La franja de arriba te muestra el progreso de lo que falta.',
                  emoji: '⏳',
                  color: Colors.amber,
                ),
                const _Seccion(
                  'Pendiente a entregar',
                  'Es el dinero en efectivo que cobraste y aún no le has entregado a Jc. '
                  'Baja solo cuando él lo confirma en su sistema. No es un error: es tu cuenta pendiente.',
                  emoji: '💰',
                  color: Colors.green,
                ),
                const _Seccion(
                  'Listas',
                  '• 📅 Vencen hoy: pagan hoy.\n'
                  '• 🔜 Por vencer: vencen en los próximos 3 días.\n'
                  '• ⏳ -30d: atrasados de menos de un mes.\n'
                  '• 🚨 +30d: atrasados de más de un mes.\n'
                  '• 🎂 Cumpleaños: cumplen años esta semana (la fecha sale del carnet).\n'
                  '• Toca 💰 en cualquier fila para cobrar sin entrar a la ficha.\n'
                  '• Puedes ordenar cada lista por nombre, vencimiento o días restantes.',
                  emoji: '📋',
                  color: Colors.purple,
                ),
                const _Seccion(
                  'Papelera',
                  'Los clientes inactivos van a la papelera. Desde ahí puedes recuperarlos '
                  'sin inscribirlos de nuevo, o recuperarlos y renovarles el pago de una vez. '
                  'Solo Jc puede eliminarlos definitivamente.',
                  emoji: '🗑️',
                  color: Colors.grey,
                ),
                const _Seccion(
                  'Mi turno',
                  'Muestra lo que cobraste hoy y tu pendiente a entregar. '
                  'Cada entrenador solo ve lo suyo.',
                  emoji: '👤',
                  color: Colors.indigo,
                ),
                const _Seccion(
                  'Tus datos y tu privacidad',
                  '• Cada entrenador solo ve sus propios datos: tu pendiente a entregar, tu turno y tus cobros son solo tuyos. '
                  'No puedes ver los de otros entrenadores, ni ellos los tuyos.\n'
                  '• El dueño (Jc) tiene acceso a muchos más datos: los cobros de todos, los totales y las estadísticas. '
                  'Esos datos los verifica su asistente personal de inteligencia artificial, diseñado y programado por él '
                  'para llevar el control del gimnasio.',
                  emoji: '🔒',
                  color: Colors.red,
                ),
                const _Seccion(
                  'Si algo falla',
                  '• "Sin conexión a internet": sigue trabajando, todo se guarda y sube después.\n'
                  '• "Conexión muy lenta": ten paciencia, las fotos continúan donde quedaron.\n'
                  '• "Error del servidor": reintenta luego; si sigue, avisa a Jc.\n'
                  '• Si te saca al login: tu sesión venció, entra de nuevo con tu usuario.\n'
                  '• Si un cliente no aparece: sincroniza manualmente y revisa la hora de última sincronización.',
                  emoji: '⚠️',
                  color: Colors.red,
                ),
                const _Seccion(
                  'Contacto',
                  '¿Dudas con la app? Escríbele a Jc por WhatsApp: ${AppConfig.whatsappContacto}.',
                  emoji: '📞',
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

  static Widget _novedadesCard() {
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
          child: Text('🎉', style: TextStyle(fontSize: 20)),
        ),
        title: const Text('Lo Nuevo',
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 16)),
        subtitle:
            const Text('Versión ${AppConfig.appVersion}'),
        children: [
          for (final n in novedades) ...[
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
                padding:
                    const EdgeInsets.fromLTRB(24, 2, 16, 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('• $c',
                      style: const TextStyle(fontSize: 13)),
                ),
              ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _Seccion extends StatelessWidget {
  final String titulo;
  final String texto;
  final String emoji;
  final Color color;
  const _Seccion(this.titulo, this.texto,
      {required this.emoji, required this.color});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          child: Text(emoji,
              style: const TextStyle(fontSize: 20)),
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
                  style: const TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }
}
