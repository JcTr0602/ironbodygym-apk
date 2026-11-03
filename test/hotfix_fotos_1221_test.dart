/// Hotfix 1.22.1 (campo): el avatar decodifica SIN
/// deformar — un solo eje (ancho); con ancho+alto a la
/// vez ResizeImage (policy exact) estiraba la foto.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';

void main() {
  testWidgets('AvatarCliente: provider acotado por ancho, '
      'alto libre', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AvatarCliente(
          nombre: 'Ana Pérez',
          foto: File('/sin-foto-real.png'),
          tamano: TamanoAvatar.l,
        ),
      ),
    ));
    final imagen = t.widget<Image>(find.byType(Image));
    final prov = imagen.image as ResizeImage;
    // TamanoAvatar.l = 56 de diámetro, borde 1 -> di=54;
    // DPR de test = 1.0; ancho = 2*54*1 = 108.
    expect(prov.width, 108);
    expect(prov.height, isNull);
  });
}
