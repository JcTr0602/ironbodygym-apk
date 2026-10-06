/// ❓ Ayuda para entrenadores (texto aprobado por Jc).
library;

import 'package:flutter/material.dart';

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
              children: const [
                _Seccion('¿Cómo funciona la app?',
                    'La app guarda todo en el teléfono, no necesita internet para trabajar. '
                    'Inscribes y cobras con normalidad en el gym, y cuando tengas conexión '
                    'los datos se envían solos al sistema.'),
                _Seccion('🔄 Sincronización',
                    '• La app revisa automáticamente si hay cambios de otros entrenadores cada 2 minutos.\n'
                    '• Tus cambios se suben cada hora o cuando toques "Sincronizar ahora".\n'
                    '• En el inicio siempre verás la hora de la última sincronización correcta. '
                    'Si es vieja, busca mejor cobertura.'),
                _Seccion('⏳ Cola de sincronización',
                    'Todo lo que haces sin conexión queda en la cola como "pendiente a subir". '
                    'Nada se pierde: al sincronizar, sube en orden. '
                    'Puedes cancelar una operación tuya que aún no haya subido si te equivocaste.'),
                _Seccion('💰 Pendiente a entregar',
                    'Es el dinero en efectivo que cobraste y aún no le has entregado a Jc. '
                    'Baja solo cuando él lo confirma en su sistema. No es un error: es tu cuenta pendiente.'),
                _Seccion('📋 Listas',
                    '• 📅 Vencen hoy: pagan hoy.\n'
                    '• 🔜 Por vencer: vencen en los próximos 3 días.\n'
                    '• ⏳ -30d: atrasados de menos de un mes.\n'
                    '• 🚨 +30d: atrasados de más de un mes.\n'
                    '• Toca 💰 en cualquier fila para cobrar sin entrar a la ficha.'),
                _Seccion('🔒 Tus datos y tu privacidad',
                    '• Cada entrenador solo ve sus propios datos: tu pendiente a entregar, tu turno y tus cobros son solo tuyos. '
                    'No puedes ver los de otros entrenadores, ni ellos los tuyos.\n'
                    '• El dueño (Jc) tiene acceso a muchos más datos: los cobros de todos, los totales y las estadísticas. '
                    'Esos datos los verifica su asistente personal de inteligencia artificial, diseñado y programado por él '
                    'para llevar el control del gimnasio.'),
                _Seccion('⚠️ Si algo falla',
                    '• "Sin conexión": sigue trabajando, todo se guarda y sube después.\n'
                    '• Si te saca al login: tu sesión venció, entra de nuevo con tu usuario.\n'
                    '• Si un cliente no aparece: sincroniza manualmente y revisa la hora de última sincronización.'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Seccion extends StatelessWidget {
  final String titulo;
  final String texto;
  const _Seccion(this.titulo, this.texto);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(titulo,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(texto, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
  }
}
