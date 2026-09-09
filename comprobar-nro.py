#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comprobar-nro.py — lee de vuelta lo que Empaquetar.ps1 escribio en un .nro.

El empaquetador rehace la seccion ASET de cada <slug>.nro con el icono, el
nombre, el autor y el title id del juego. Escribirlo no demuestra nada: un
offset mal puesto deja un fichero del tamano correcto que la consola rechaza sin
decir por que, y probarlo cuesta copiar el .nro a una tarjeta y encender la
Switch. Esto lo lee como lo leeria hbmenu y lo dice en cuatro lineas.

    python comprobar-nro.py <fichero.nro> [--todos]

--todos ensena las 16 entradas de idioma, no solo las tres que se rellenan.

Formato (switchbrew, "NRO"):
    0x10  "NRO0", version, 0x18 tamano del NRO (u32)
    Si el fichero es mas largo que ese tamano, ahi empieza el ASET:
    0x00  "ASET"  0x04 version (u32)
    0x08  icono:  offset (u64) + size (u64)   -- relativos al inicio del ASET
    0x18  NACP:   offset (u64) + size (u64)
    0x28  romfs:  offset (u64) + size (u64)
El NACP mide 0x4000: 16 entradas de idioma de 0x300 (0x200 nombre + 0x100
autor). El title id no vive en un sitio, vive en cuatro, y no se dedujo de la
documentacion sino de nacptool: se generaron dos NACP identicos salvo por
--titleid y se restaron. Escribe el id en 0x3038 (PresenceGroupId), en 0x3078
(SaveDataOwnerId) y en 0x30B0 (LocalCommunicationId), y el id + 0x1000 en 0x3070
(AddOnContentBaseId). Los cuatro tienen que cuadrar o la consola se hace un lio
con las partidas guardadas. (0x3040 NO es el duenno de la partida: son las
clasificaciones por edad, y en el NRO del motor valen 0c 0c 0c ff...)
"""
import struct
import sys

IDIOMAS = [
    "AmericanEnglish", "BritishEnglish", "Japanese", "French",
    "German", "LatinAmericanSpanish", "Spanish", "Italian",
    "Dutch", "CanadianFrench", "Portuguese", "Russian",
    "Korean", "TraditionalChinese", "SimplifiedChinese", "BrazilianPortuguese",
]


def texto(b):
    return b.split(b"\0", 1)[0].decode("utf-8", "replace")



def romfs(img):
    """Lista el RomFS y ensena juego.txt, que es a lo que se viene.

    Cabecera de 0x50 bytes: headerSize y luego cuatro pares offset/size (tablas
    de hash y de metadatos de directorios y de ficheros) y el offset de los
    datos. La tabla de metadatos de ficheros es una lista encadenada: cada
    entrada trae el padre, el hermano siguiente, el offset y el tamano del
    fichero dentro de la zona de datos, y el nombre en UTF-16LE.
    """
    if len(img) < 0x50:
        print("  romfs: la imagen no llega ni a la cabecera")
        return
    tam_cab = struct.unpack_from("<Q", img, 0)[0]
    if tam_cab != 0x50:
        print("  romfs: cabecera de %d bytes, se esperaban 80" % tam_cab)
    fm_off, fm_len = struct.unpack_from("<QQ", img, 0x38)
    datos = struct.unpack_from("<Q", img, 0x48)[0]
    print("  romfs %d bytes: meta de ficheros en +%d (%d bytes), datos en +%d"
          % (len(img), fm_off, fm_len, datos))

    # Se recorre la tabla entera de principio a fin en vez de seguir la cadena
    # de hermanos: asi salen los ficheros de todos los directorios, no solo los
    # de la raiz. Cada entrada mide 0x20 mas el nombre, redondeado a 4.
    o = 0
    while o + 0x20 <= fm_len:
        base = fm_off + o
        d_off, d_tam = struct.unpack_from("<QQ", img, base + 8)
        largo = struct.unpack_from("<I", img, base + 0x1C)[0]
        nombre = img[base + 0x20:base + 0x20 + largo].decode("utf-8", "replace")
        print("    /%s  %d bytes" % (nombre, d_tam))
        if nombre.lower() == "juego.txt":
            cont = img[datos + d_off:datos + d_off + d_tam]
            print("      -> %r" % cont.decode("utf-8", "replace"))
        o += 0x20 + ((largo + 3) & ~3)


def main(ruta, todos=False):
    d = open(ruta, "rb").read()
    if d[0x10:0x14] != b"NRO0":
        sys.exit("no es un NRO: falta la marca NRO0 en 0x10")
    tam = struct.unpack_from("<I", d, 0x18)[0]
    print("NRO      %s" % ruta)
    print("  cuerpo %d bytes, fichero %d bytes" % (tam, len(d)))
    if len(d) <= tam:
        sys.exit("  este NRO no lleva ASET: ni icono ni NACP")

    a = tam
    if d[a:a + 4] != b"ASET":
        sys.exit("  en el desplazamiento %d no hay un ASET" % a)
    ver = struct.unpack_from("<I", d, a + 4)[0]
    io_, is_ = struct.unpack_from("<QQ", d, a + 8)
    no, ns = struct.unpack_from("<QQ", d, a + 0x18)
    ro, rs = struct.unpack_from("<QQ", d, a + 0x28)
    print("  ASET v%d  icono %d bytes (+%d)  nacp %d bytes (+%d)  romfs %d bytes (+%d)"
          % (ver, is_, io_, ns, no, rs, ro))

    icono = d[a + io_:a + io_ + is_]
    if icono[:2] != b"\xff\xd8":
        print("  AVISO: el icono no empieza por la marca JPEG ffd8")
    # El romfs es la segunda via de CONVENCIONES 3 y la unica que contesta en
    # Ryujinx, que lanza los .nro con argc = 0. Un ASET que lo declare a cero
    # ademas mata al emulador (commit 6128ea3).
    if rs == 0:
        print("  AVISO: ASET sin romfs (size 0). Ryujinx no arranca un .nro asi.")
    else:
        romfs(d[a + ro:a + ro + rs])
    if a + no + ns > len(d):
        sys.exit("  el NACP se sale del fichero")
    nacp = d[a + no:a + no + ns]
    if len(nacp) != 0x4000:
        print("  AVISO: el NACP mide %d bytes y deberia medir 16384" % len(nacp))

    vistos = 0
    for i in range(16):
        o = i * 0x300
        if o + 0x300 > len(nacp):
            break
        nombre = texto(nacp[o:o + 0x200])
        autor = texto(nacp[o + 0x200:o + 0x300])
        if not nombre and not autor:
            if todos:
                print("  %-22s (vacia)" % IDIOMAS[i])
            continue
        vistos += 1
        if todos or i in (0, 5, 6):
            print("  %-22s %r / %r" % (IDIOMAS[i], nombre, autor))
    print("  entradas de idioma con nombre: %d de 16" % vistos)

    if len(nacp) >= 0x30B8:
        tid = struct.unpack_from("<Q", nacp, 0x3038)[0]
        dlc = struct.unpack_from("<Q", nacp, 0x3070)[0]
        duenno = struct.unpack_from("<Q", nacp, 0x3078)[0]
        local = struct.unpack_from("<Q", nacp, 0x30B0)[0]
        print("  title id            %016X   (0x3038 presence group)" % tid)
        print("  save data owner     %016X   (0x3078)" % duenno)
        print("  local communication %016X   (0x30B0)" % local)
        print("  add-on content base %016X   (0x3070, = title id + 0x1000)" % dlc)
        if duenno != tid or local != tid:
            print("  AVISO: los cuatro identificadores no cuadran entre si")
        version = texto(nacp[0x3060:0x3070])
        print("  version             %r" % version)
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        sys.exit(__doc__)
    sys.exit(main(args[0], "--todos" in sys.argv))
