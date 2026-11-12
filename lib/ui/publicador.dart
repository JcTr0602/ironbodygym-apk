/// 1.32 (Oleada 2, Fase 3) — el PUBLICADOR UNIFICADO de
/// comunicados (fusión visual de G-63 + G-64 del plano
/// maestro): una sola pantalla «Publicar a Clientes»
/// donde el dueño escribe y elige con un selector si
/// sale como ANUNCIO DE PORTADA (G-63, la tarjeta de la
/// pantalla principal de la app de Clientes) o como
/// AVISO (G-64, el centro de avisos con su enlace).
/// Acaba con la confusión de nombres entre «Anuncios»
/// y «Avisos» SIN tocar las tablas ni las RPC del
/// servidor: cada segmento sigue siendo su pantalla de
/// siempre, con sus guardas, sus comprobaciones
/// post-fallo y su copia local con sello (Compuerta 3).
///
/// Solo dueño: las dos RPC exigen es_dueno()/es_admin()
/// en el servidor y esta pantalla se protege igual.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'editor_avisos_clientes.dart';
import 'panel_anuncios.dart';

class PublicadorScreen extends StatefulWidget {
  /// Segmento inicial: 0 = anuncio de portada,
  /// 1 = aviso a clientes. Los enlaces hondos (la lupa,
  /// el hub de Comunicación) abren directo en Avisos.
  final int segmentoInicial;

  /// Cuerpos inyectables para los tests; null = los
  /// segmentos reales (las dos pantallas embebidas).
  final Widget? cuerpoAnuncios;
  final Widget? cuerpoAvisos;

  const PublicadorScreen({
    super.key,
    this.segmentoInicial = 0,
    this.cuerpoAnuncios,
    this.cuerpoAvisos,
  });

  @override
  State<PublicadorScreen> createState() => _PublicadorScreenState();
}

class _PublicadorScreenState extends State<PublicadorScreen> {
  late int _segmento =
      widget.segmentoInicial == 1 ? 1 : 0;

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Publicar a Clientes'),
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño',
          subtitulo:
              'Los comunicados a los clientes los publica el dueño.',
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(context, 'Publicar a Clientes'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppEspacio.lg,
                AppEspacio.md, AppEspacio.lg, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Un solo sitio para hablar con tus '
                  'clientes. El anuncio sale en la portada '
                  'de su app; el aviso llega a su centro '
                  'de avisos.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: AppEspacio.md),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      icon: Icon(Icons.campaign_rounded),
                      label: Text('Anuncio de portada'),
                    ),
                    ButtonSegment(
                      value: 1,
                      icon: Icon(Icons.mark_chat_read_rounded),
                      label: Text('Aviso a clientes'),
                    ),
                  ],
                  selected: {_segmento},
                  onSelectionChanged: (s) =>
                      setState(() => _segmento = s.first),
                ),
              ],
            ),
          ),
          // IndexedStack: los dos segmentos quedan
          // montados — cambiar de segmento no pierde lo
          // cargado ni lo tecleado a medias en el otro.
          Expanded(
            child: IndexedStack(
              index: _segmento,
              children: [
                widget.cuerpoAnuncios ??
                    const PanelAnunciosScreen(embebida: true),
                widget.cuerpoAvisos ??
                    const EditorAvisosClientesScreen(
                        embebida: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
