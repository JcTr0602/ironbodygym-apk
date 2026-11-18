// lib/ui/centro_control.dart
// 1.25 T112: el Centro de control — UNA entrada con
// pestañas de nombres en sencillo para las cuatro
// miradas de auditoría que antes eran cuatro pantallas
// que no se distinguían por el nombre («Actividad»,
// «Auditoría», «Auditoría silenciosa», «Auditoría por
// persona») y había que memorizar:
// - «Qué pasó»: el feed de actividad reciente.
// - «Registro»: el registro de operaciones (quién hizo
//   qué, con el antes → después de Panel 9).
// - «Por persona»: el resumen de una persona en un
//   período.
// - «Anomalías»: la detección silenciosa (solo dueño;
//   la pantalla se guarda a sí misma).
// Cada pestaña es la pantalla de siempre en modo
// embebida (sin su barra): ningún dato ni traductor
// cambia, solo la puerta.
library;

import 'package:flutter/material.dart';

import 'actividad.dart';
import 'primitivas.dart';
import 'auditoria.dart';
import 'auditoria_persona.dart';
import 'auditoria_silenciosa.dart';

/// Una pestaña del centro (pura, para test).
class PestanaControl {
  final String id;
  final String titulo;
  const PestanaControl({required this.id, required this.titulo});
}

const pestanasCentroControl = <PestanaControl>[
  PestanaControl(id: 'que_paso', titulo: 'Qué pasó'),
  PestanaControl(id: 'registro', titulo: 'Registro'),
  PestanaControl(id: 'por_persona', titulo: 'Por persona'),
  PestanaControl(id: 'anomalias', titulo: 'Anomalías'),
];

/// La vista embebida de una pestaña (null si el id no
/// existe: índice y vistas no se separan).
Widget? vistaPestanaControl(String id) {
  switch (id) {
    case 'que_paso':
      return const ActividadScreen(embebida: true);
    case 'registro':
      return const AuditoriaScreen(embebida: true);
    case 'por_persona':
      return const AuditoriaPersonaScreen(embebida: true);
    case 'anomalias':
      return const AuditoriaSilenciosaScreen(embebida: true);
  }
  return null;
}

class CentroControlScreen extends StatelessWidget {
  const CentroControlScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: pestanasCentroControl.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Centro de control'),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            // 1.36 H-B1 (136-324): cambiar de pestaña se
            // siente, como en los segmentos de los pilares.
            onTap: (_) => Tacto.seleccion(),
            tabs: [
              for (final p in pestanasCentroControl) Tab(text: p.titulo),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            for (final p in pestanasCentroControl)
              vistaPestanaControl(p.id) ?? const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }
}
