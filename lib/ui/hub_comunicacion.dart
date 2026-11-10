// lib/ui/hub_comunicacion.dart
// 1.25 T108: el hub «Comunicación» — UNA sola entrada
// para todo lo que el gym le dice a alguien: la bandeja
// de hoy, cumpleaños, campañas, los avisos de las dos
// apps, las plantillas y los recordatorios. Antes cada
// pieza vivía en un módulo distinto (Campañas colgaba
// de Control de Acceso) y nada las presentaba como un
// solo lugar. Las piezas ya comparten lo importante
// desde T42: un motor de plantillas con una sintaxis
// (doble llave, con la simple tolerada) y la marca de
// «ya contactado» entre Bandeja y Cumpleaños.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import 'app_bar.dart';
import 'avisos_entrenador.dart';
import 'bandeja_whatsapp.dart';
import 'campana_wa.dart';
import 'componentes.dart';
import 'cumpleanos.dart';
import 'diseno.dart';
import 'editor_avisos_clientes.dart';
import 'plantillas_mensaje.dart';
import 'recordatorios.dart';

/// Un destino del hub. La lista es el índice completo de
/// la comunicación del gym (pura, para test).
class DestinoComunicacion {
  final String id;
  final String titulo;
  final String ayuda;
  final IconData icono;

  const DestinoComunicacion({
    required this.id,
    required this.titulo,
    required this.ayuda,
    required this.icono,
  });
}

const destinosComunicacion = <DestinoComunicacion>[
  DestinoComunicacion(
    id: 'bandeja',
    titulo: 'Hoy · Bandeja de WhatsApp',
    ayuda: 'Vencidos, vencen hoy, recibos y cumpleaños, con su progreso',
    icono: Icons.mark_chat_unread_rounded,
  ),
  DestinoComunicacion(
    id: 'cumpleanos',
    titulo: 'Cumpleaños',
    ayuda: 'Próximos días, mes y regalo en un toque',
    icono: Icons.cake_rounded,
  ),
  DestinoComunicacion(
    id: 'campanas',
    titulo: 'Campañas',
    ayuda: 'Mensajes a muchos clientes, uno a uno y con su tanda',
    icono: Icons.campaign_rounded,
  ),
  DestinoComunicacion(
    id: 'avisos_clientes',
    titulo: 'Avisos a clientes',
    ayuda: 'El centro de avisos de la app de clientes',
    icono: Icons.notifications_active_rounded,
  ),
  DestinoComunicacion(
    id: 'avisos_entrenadores',
    titulo: 'Avisos para entrenadores',
    ayuda: 'PopUp en el Home de cada entrenador',
    icono: Icons.campaign_rounded,
  ),
  DestinoComunicacion(
    id: 'plantillas',
    titulo: 'Plantillas de mensajes',
    ayuda: 'Un solo motor y una sola sintaxis: {{variable}}',
    icono: Icons.message_rounded,
  ),
  DestinoComunicacion(
    id: 'recordatorios',
    titulo: 'Recordatorios automáticos',
    ayuda: 'Hoy, con anti-duplicado; masivos solo en tu teléfono',
    icono: Icons.notifications_rounded,
  ),
];

/// La pantalla destino de un id del hub (null si el id
/// no existe: el índice y las pantallas no se separan).
Widget? pantallaDestinoComunicacion(String id) {
  switch (id) {
    case 'bandeja':
      return const BandejaWhatsappScreen();
    case 'cumpleanos':
      return const CumpleanosScreen();
    case 'campanas':
      return const CampanaWaScreen();
    case 'avisos_clientes':
      return const EditorAvisosClientesScreen();
    case 'avisos_entrenadores':
      return const AvisosEntrenadorScreen();
    case 'plantillas':
      return const PlantillasScreen();
    case 'recordatorios':
      return const RecordatoriosScreen();
  }
  return null;
}

class HubComunicacionScreen extends StatelessWidget {
  const HubComunicacionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Yunque R5-M1-4: defensa propia — el hub no depende
    // solo de la puerta de Administración que hoy lo monta.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Comunicación'),
        body: const Center(
          child: Text('La comunicación es solo del dueño.'),
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Comunicación'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          const Text(
            'Todo lo que el gym le dice a alguien, en un solo lugar.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: AppEspacio.md),
          for (final d in destinosComunicacion) ...[
            Tarjeta(
              onTap: () {
                final pantalla = pantallaDestinoComunicacion(d.id);
                if (pantalla == null) return;
                Navigator.of(context)
                    .push(RutaIron(builder: (_) => pantalla));
              },
              child: Row(
                children: [
                  Icon(d.icono, color: AppColores.naranja, size: 26),
                  const SizedBox(width: AppEspacio.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(d.titulo, style: AppTexto.subtitulo),
                        const SizedBox(height: 2),
                        Text(d.ayuda, style: AppTexto.secundario),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
            const SizedBox(height: AppEspacio.sm),
          ],
        ],
      ),
    );
  }
}
