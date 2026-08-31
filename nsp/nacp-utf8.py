#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Escribe el nombre y el autor del juego en el NACP, en UTF-8 de verdad.

nacptool los toma de la linea de ordenes, y ahi es donde se pierden: el shell de
MSYS2 pasa los argumentos en la pagina de codigos ANSI, asi que "Pokemon Anil"
con acentos llega al fichero como Latin-1 —"Pok\xe9mon A\xf1il"— y Horizon, que
espera UTF-8, pinta un nombre roto en el menu HOME.

El NACP empieza con 16 entradas de idioma de 0x300 bytes: 0x200 para el nombre y
0x100 para el autor. Se reescriben todas con los mismos bytes correctos, que es
lo que hace nacptool salvo por la codificacion.
"""
import sys

ENTRADAS = 16
TAM_ENTRADA = 0x300
TAM_NOMBRE = 0x200
TAM_AUTOR = 0x100


def main(ruta, nombre, autor):
    n = nombre.encode("utf-8")
    a = autor.encode("utf-8")
    if len(n) >= TAM_NOMBRE or len(a) >= TAM_AUTOR:
        sys.exit("nombre o autor demasiado largos para el NACP")

    with open(ruta, "r+b") as f:
        datos = bytearray(f.read())
        for i in range(ENTRADAS):
            o = i * TAM_ENTRADA
            # las entradas que nacptool dejo vacias se quedan vacias: una entrada
            # a cero significa "este idioma no esta soportado", no "sin nombre"
            if not datos[o]:
                continue
            datos[o:o + TAM_NOMBRE] = n.ljust(TAM_NOMBRE, b"\0")
            datos[o + TAM_NOMBRE:o + TAM_ENTRADA] = a.ljust(TAM_AUTOR, b"\0")
        f.seek(0)
        f.write(datos)
    print("NACP: %r / %r en UTF-8" % (nombre, autor))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("uso: nacp-utf8.py <control.nacp> <nombre> <autor>")
    main(sys.argv[1], sys.argv[2], sys.argv[3])
