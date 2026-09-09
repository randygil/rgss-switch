#!/usr/bin/env python3
"""Lista y extrae ficheros de un archivo RGSSAD v1 (RPG Maker XP cifrado).

Uranium es el unico juego del censo que sigue siendo RPG Maker XP original:
sus datos viven dentro de Uranium.rgssad y no hay forma de mirarlos sin
descifrarlos. El formato esta implementado en
src/mkxp-z/src/crypto/rgssad.cpp y esto lo reproduce en Python:

  - cabecera "RGSSAD\\0" + un byte de version (1).
  - la clave arranca en 0xDEADCAFE y avanza key = (key * 7 + 3) & 0xFFFFFFFF.
  - por cada entrada: un u32 con la longitud del nombre (XOR con la clave,
    que avanza una vez), luego el nombre byte a byte (cada byte XOR con el
    byte bajo de la clave, avanzando la clave por CADA byte), luego un u32
    con el tamano (XOR con la clave, que avanza otra vez). La clave que queda
    en ese momento es la clave de partida del contenido.
  - el contenido se descifra en palabras de 4 bytes: cada u32 se XORea con la
    clave del fichero y esa clave avanza una vez por palabra.

Uso:
  dump-rgssad.py <archivo.rgssad>                 lista las entradas
  dump-rgssad.py <archivo.rgssad> <ruta> <salida> extrae una entrada
"""
import sys, os, struct

MAGIC = 0xDEADCAFE


def avanza(key):
    """Devuelve (clave_actual, clave_siguiente)."""
    return key, (key * 7 + 3) & 0xFFFFFFFF


def entradas(raw):
    assert raw[:7] == b'RGSSAD\x00', "no es un RGSSAD"
    assert raw[7] == 1, "solo se soporta la version 1, esta es %d" % raw[7]
    i = 8
    key = MAGIC
    fuera = []
    while i + 4 <= len(raw):
        n, = struct.unpack_from('<I', raw, i)
        i += 4
        cur, key = avanza(key)
        n ^= cur
        if n <= 0 or n > 512 or i + n + 4 > len(raw):
            break
        nombre = bytearray()
        for k in range(n):
            cur, key = avanza(key)
            c = raw[i + k] ^ (cur & 0xFF)
            nombre.append(ord('/') if c == ord('\\') else c)
        i += n
        tam, = struct.unpack_from('<I', raw, i)
        i += 4
        cur, key = avanza(key)
        tam ^= cur
        fuera.append((nombre.decode('cp932', 'replace'), i, tam, key))
        i += tam
    return fuera


def descifra(raw, off, tam, key):
    out = bytearray()
    p = 0
    while p < tam:
        trozo = raw[off + p:off + p + 4]
        d = int.from_bytes(trozo.ljust(4, b'\0'), 'little')
        cur, key = avanza(key)
        d ^= cur
        out += d.to_bytes(4, 'little')[:min(4, tam - p)]
        p += 4
    return bytes(out)


def main():
    raw = open(sys.argv[1], 'rb').read()
    lista = entradas(raw)
    if len(sys.argv) == 2:
        total = 0
        for nombre, off, tam, key in lista:
            print("%10d  %s" % (tam, nombre))
            total += tam
        print("--- %d entradas, %d bytes" % (len(lista), total))
        return
    quiere = sys.argv[2].replace('\\', '/').lower()
    for nombre, off, tam, key in lista:
        if nombre.lower() == quiere:
            datos = descifra(raw, off, tam, key)
            with open(sys.argv[3], 'wb') as f:
                f.write(datos)
            print("%s -> %s (%d bytes)" % (nombre, sys.argv[3], len(datos)))
            return
    sys.exit("no esta en el archivo: %s" % sys.argv[2])


main()
