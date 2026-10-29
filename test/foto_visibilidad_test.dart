import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/localdb.dart';

void main() {
  test('intención eliminar nunca muestra la foto', () {
    expect(
      mostrarFotoFicha(
        intencionBd: 'eliminar',
        consultaFallida: false,
        eliminadaEnSesion: false,
      ),
      isFalse,
    );
    expect(
      mostrarFotoFicha(
        intencionBd: 'eliminar',
        consultaFallida: true,
        eliminadaEnSesion: true,
      ),
      isFalse,
    );
  });

  test('intención poner o null con consulta OK muestra la foto', () {
    expect(
      mostrarFotoFicha(
        intencionBd: 'poner',
        consultaFallida: false,
        eliminadaEnSesion: false,
      ),
      isTrue,
    );
    expect(
      mostrarFotoFicha(
        intencionBd: null,
        consultaFallida: false,
        eliminadaEnSesion: false,
      ),
      isTrue,
    );
  });

  test('consulta fallida sin tombstone muestra (fail-open del caso real)',
      () {
    expect(
      mostrarFotoFicha(
        intencionBd: null,
        consultaFallida: true,
        eliminadaEnSesion: false,
      ),
      isTrue,
    );
  });

  test('consulta fallida con tombstone NO muestra (no resucitar, F2)',
      () {
    expect(
      mostrarFotoFicha(
        intencionBd: null,
        consultaFallida: true,
        eliminadaEnSesion: true,
      ),
      isFalse,
    );
  });

  test('tombstone de sesión se marca y se limpia al poner foto', () {
    const clienteId = 999998;
    expect(LocalDb.fotoEliminadaEnSesion(clienteId), isFalse);
    LocalDb.marcarFotoEliminadaSesion(clienteId);
    expect(LocalDb.fotoEliminadaEnSesion(clienteId), isTrue);
    LocalDb.limpiarFotoEliminadaSesion(clienteId);
    expect(LocalDb.fotoEliminadaEnSesion(clienteId), isFalse);
  });
}
