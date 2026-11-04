/// Tests de la 1.23 #9 (auditoría extra): imagen de la Guía
/// versionada por imagen_rev.
///
/// El contrato que sostiene el fix:
/// - el objeto de una ficha con imagen_rev N se llama
///   `<slug>-vN.webp`: la foto viva es la de la revisión
///   publicada, y una subida cuya op luego se rechaza queda
///   huérfana con el nombre de la revisión NUNCA aceptada;
/// - la subida usa el nombre de la revisión destino (la
///   publicada + 1), que es exactamente la que el servidor
///   asigna al aceptar (`_op_guia_upsert_publicado`: prev + 1
///   si imagen_cambiada o cambió tiene_imagen; 1 en la primera
///   imagen de una ficha nueva) — app y servidor ya calculaban
///   lo mismo para el espejo optimista;
/// - rev <= 0 cae al nombre legado (defensivo).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/config.dart';

void main() {
  group('objetoImagenGuia', () {
    test('revisión positiva: nombre versionado', () {
      expect(AppConfig.objetoImagenGuia('press-banca', 1),
          'press-banca-v1.webp');
      expect(AppConfig.objetoImagenGuia('press-banca', 12),
          'press-banca-v12.webp');
    });

    test('rev 0 o negativa: nombre legado defensivo', () {
      expect(AppConfig.objetoImagenGuia('press-banca', 0),
          'press-banca.webp');
      expect(AppConfig.objetoImagenGuia('press-banca', -3),
          'press-banca.webp');
    });
  });

  group('urlImagenGuia', () {
    test('URL pública del bucket con el nombre versionado', () {
      final u = AppConfig.urlImagenGuia('remo-polea', 3);
      expect(
          u,
          '${AppConfig.supabaseUrl}/storage/v1/object/public/'
          'guia-imagenes/remo-polea-v3.webp');
      // Sin ?v=: el nombre versionado ya invalida la caché.
      expect(u.contains('?'), isFalse);
    });
  });
}
