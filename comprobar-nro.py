#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""comprobar-nro.py — lee de vuelta lo que Empaquetar.ps1 escribio en un .nro.

El empaquetador rehace la seccion ASET de cada <slug>.nro con el icono, el
nombre, el autor y el title id del juego. Escribirlo no demuestra nada: un
offset mal puesto deja un fichero del tamano correcto que la consola rechaza sin
decir por que, y probarlo cuesta copiar el .nro a una tarjeta y encender la
Switch. Esto lo lee como lo leeria hbmenu y lo dice en cuatro lineas.

    python comprobar-nro.py <fichero.nro> [--todos] [--comparar ref.nro]

--todos ensena las 16 entradas de idioma, no solo las tres que se rellenan.
--comparar contrasta el .nro con uno de referencia hecho por elf2nro: primero
las estructuras (cabecera NRO0, cabecera ASET, tamanos) y luego los bytes,
diciendo en que tramos difieren y a que campo del NACP caen. Es como se
encontro que los cuatro identificadores del NACP eran lo unico distinto entre
un .nro que arrancaba y otro que no.

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
        # LA comprobacion que faltaba. En un homebrew, Ryujinx saca el program id
        # del proceso del SaveDataOwnerId y, si no es cero, le prepara la partida
        # guardada con ese id. Un id del rango 05.. -el nuestro por CONVENCIONES
        # 4- no es una aplicacion que el emulador conozca: la preparacion falla,
        # el proceso no nace y lo unico que se lee en el registro es "Loading as
        # homebrew" seguido de nada. elf2nro deja estos campos a cero y por eso
        # sus .nro arrancan.
        if tid == 0 and duenno == 0 and local == 0:
            print("  (los cuatro a cero: es lo que lleva un .nro homebrew; el title id va en el NSP)")
        if duenno != 0:
            print("  AVISO: SaveDataOwnerId no es cero en un .nro. Ryujinx no creara el proceso:")
            print("         un .nro homebrew lleva estos cuatro identificadores a cero, como los deja elf2nro.")
            print("         El title id va en el NSP (NACP + NPDM), no aqui.")
        version = texto(nacp[0x3060:0x3070])
        print("  version             %r" % version)
    return 0


CAMPOS = [
    (0x3000, 0x3025, "Isbn"),
    (0x3025, 0x3026, "StartupUserAccount"),
    (0x302C, 0x3030, "SupportedLanguageFlag"),
    (0x3030, 0x3034, "ParentalControlFlag"),
    (0x3038, 0x3040, "PresenceGroupId"),
    (0x3040, 0x3060, "RatingAge"),
    (0x3060, 0x3070, "DisplayVersion"),
    (0x3070, 0x3078, "AddOnContentBaseId"),
    (0x3078, 0x3080, "SaveDataOwnerId"),
    (0x3080, 0x3088, "UserAccountSaveDataSize"),
    (0x30B0, 0x30B8, "LocalCommunicationId"),
]


def campo(off):
    """A que campo del NACP cae un desplazamiento, para que un tramo distinto
    diga algo mas que un numero."""
    if off < 0x3000:
        return "entrada de idioma %d (%s)" % (off // 0x300,
                                              "nombre" if (off % 0x300) < 0x200 else "autor")
    for a, b, nombre in CAMPOS:
        if a <= off < b:
            return nombre
    return "?"


def secciones(d):
    tam = struct.unpack_from("<I", d, 0x18)[0]
    if len(d) <= tam:
        return tam, None
    a = tam
    v = {"ASET": a}
    v["ver"] = struct.unpack_from("<I", d, a + 4)[0]
    v["icono"] = struct.unpack_from("<QQ", d, a + 8)
    v["nacp"] = struct.unpack_from("<QQ", d, a + 0x18)
    v["romfs"] = struct.unpack_from("<QQ", d, a + 0x28)
    return tam, v


def comparar(ruta, ref):
    a = open(ruta, "rb").read()
    b = open(ref, "rb").read()
    print("COMPARAR")
    print("  %s  %d bytes" % (ruta, len(a)))
    print("  %s  %d bytes  (referencia)" % (ref, len(b)))

    ta, va = secciones(a)
    tb, vb = secciones(b)
    if ta != tb:
        print("  el cuerpo mide %d y el de referencia %d" % (ta, tb))
    if a[:0x40] != b[:0x40]:
        print("  la cabecera NRO0 (0x00-0x40) DIFIERE")
    if va and vb:
        for k in ("ver", "icono", "nacp", "romfs"):
            if va[k] != vb[k]:
                print("  ASET %s: %r vs %r" % (k, va[k], vb[k]))
        # El fichero tiene que medir exactamente cuerpo + cabecera + secciones.
        for nombre, d_, t_ in (("este", va, ta), ("referencia", vb, tb)):
            esperado = t_ + 0x38 + d_["icono"][1] + d_["nacp"][1] + d_["romfs"][1]
            real = len(a) if nombre == "este" else len(b)
            if esperado != real:
                print("  %s: el fichero mide %d y cuerpo+0x38+icono+nacp+romfs son %d"
                      % (nombre, real, esperado))

    idx = [i for i in range(min(len(a), len(b))) if a[i] != b[i]]
    if not idx and len(a) == len(b):
        print("  IDENTICOS byte a byte.")
        return 0
    runs = []
    for i in idx:
        if runs and i == runs[-1][1] + 1:
            runs[-1][1] = i
        else:
            runs.append([i, i])
    print("  %d bytes distintos en %d tramos:" % (len(idx), len(runs)))
    for s, e in runs[:40]:
        donde = "cuerpo"
        if va and s >= ta:
            rel = s - ta
            if rel < 0x38:
                donde = "cabecera ASET +0x%X" % rel
            elif va["nacp"][0] <= rel < va["nacp"][0] + va["nacp"][1]:
                donde = "NACP 0x%04X %s" % (rel - va["nacp"][0], campo(rel - va["nacp"][0]))
            elif va["icono"][0] <= rel < va["icono"][0] + va["icono"][1]:
                donde = "icono"
            else:
                donde = "romfs"
        print("    0x%X..0x%X (%d)  %s" % (s, e, e - s + 1, donde))
        if (e - s) < 16:
            print("      este %s" % a[s:e + 1].hex())
            print("      ref  %s" % b[s:e + 1].hex())
    if len(runs) > 40:
        print("    ... y %d tramos mas" % (len(runs) - 40))
    return 1


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if "--comparar" in sys.argv:
        i = sys.argv.index("--comparar")
        ref = sys.argv[i + 1]
        args = [a for a in args if a != ref]
        if len(args) != 1:
            sys.exit(__doc__)
        main(args[0], "--todos" in sys.argv)
        print()
        sys.exit(comparar(args[0], ref))
    if len(args) != 1:
        sys.exit(__doc__)
    sys.exit(main(args[0], "--todos" in sys.argv))
