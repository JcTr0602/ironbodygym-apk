/// Panel delta-2 (cobertura): la fuente de la foto de un
/// suplemento es ÚNICA — tarjeta y detalle resuelven el
/// MISMO archivo, para que el Hero de T2 vuele con el
/// mismo FileImage en ambos extremos también en la rama
/// de foto local recién tomada.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos.dart';

void main() {
  late Directory tmp;
  late File fotoLocal;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('foto_sup_');
    fotoLocal = File('${tmp.path}/recien_tomada.jpg');
    await fotoLocal.writeAsBytes([1, 2, 3]);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('foto local existente: síncrono y futuro dan el '
      'MISMO archivo', () async {
    final sup = {
      'foto_local': fotoLocal.path,
      'foto_storage': 'suplementos/x.webp',
    };
    final sinc = archivoFotoLocalSuplemento(sup);
    expect(sinc, isNotNull);
    expect(sinc!.path, fotoLocal.path);
    final resuelto = await resolverFotoSuplemento(sup);
    expect(resuelto, isNotNull);
    expect(resuelto!.path, sinc.path);
  });

  test('foto local ausente en disco: no se inventa; sin '
      'remota, null', () async {
    final sup = {
      'foto_local': '${tmp.path}/no_existe.jpg',
      'foto_storage': null,
    };
    expect(archivoFotoLocalSuplemento(sup), isNull);
    expect(await resolverFotoSuplemento(sup), isNull);
  });

  test('sin foto local ni remota: null en ambas vías', () async {
    final sup = <String, dynamic>{};
    expect(archivoFotoLocalSuplemento(sup), isNull);
    expect(await resolverFotoSuplemento(sup), isNull);
  });
}
