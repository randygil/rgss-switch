#!/usr/bin/env python3
"""resolver-pila.py — convierte un volcado [exc] de un jugador en una pila con
nombres de funcion.

Por que existe: el 5 de septiembre de 2026 llego el registro de un jugador de la
1.0.0 (compilacion b14) con el juego cayendose al hablar con un Pidgey. Todo lo
que daba el volcado era una direccion relativa:

    [exc] base=0x440063d000 pc=0x4400de8d30 (+0x7abd30)

El .elf de la b14 no se archivo con la publicacion, asi que addr2line no tenia
con que trabajar. Se resolvio desensamblando el .nro publicado en crudo y
comparando firmas de instrucciones contra una compilacion posterior que si
conservaba simbolos. Funciono porque la funcion no habia cambiado. Es suerte, y
la suerte no se planifica: desde entonces construir.sh archiva el .elf de cada
compilacion en release/simbolos/<version>-b<n>/ y esto lo lee.

Lo que hace, en orden:

  1. Averigua de que compilacion es el registro. Si no se dice con --sello, se
     busca en el propio registro la linea que el motor escribe al arrancar:
         [build] 1.0.0 b14 01/09 17:43
  2. Localiza release/simbolos/<version>-b<n>/. Si esta el .elf, cada direccion
     se pasa por addr2line y sale el nombre de la funcion.
  3. Si NO esta el .elf pero si el .nro (el de la entrega, o el archivado),
     degrada al metodo del Pidgey: desensambla en crudo alrededor de la
     direccion, ensena la instruccion exacta que fallo, y saca de otra
     compilacion que si tenga simbolos los nombres candidatos comparando la
     firma de instrucciones. Lo dice claramente: son candidatos, no certezas.
  4. Si no hay ni .elf ni .nro, lo dice y no inventa.

Sobre las direcciones: el enlazador coloca .text en el vaddr 0 y elf2nro copia
los segmentos sin moverlos, de modo que el desplazamiento que imprime el volcado
(pc menos base de carga) es a la vez el vaddr del .elf y el offset dentro del
fichero .nro. Por eso las tres cosas —addr2line sobre el .elf, objdump sobre el
.elf y objdump -b binary sobre el .nro— hablan del mismo numero sin conversion.

Uso:

    python resolver-pila.py docs/consola/20260905-pidgey/mkxp-boot.log
    python resolver-pila.py --sello "1.0.0 b14" mkxp-boot.log
    python resolver-pila.py --sello 1.0.0-b14 +0x7abd30 +0x7062b0
    python resolver-pila.py --listar

Con --dis N ensena N instrucciones de contexto alrededor de cada direccion,
que es lo que dice si el fallo fue un `ldrh w7,[x20,#14]` con x20 a cero.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

RAIZ = os.path.dirname(os.path.abspath(__file__))
SIMBOLOS = os.path.join(RAIZ, "release", "simbolos")
RELEASE = os.path.join(RAIZ, "release")

# El prefijo de devkitA64. En MSYS2 ya esta en el PATH; desde PowerShell no,
# asi que se prueban tambien las rutas de instalacion habituales.
#
# DEVKITPRO se MIRA, pero no se cree a ciegas. La shell de Git para Windows
# traduce las rutas de estilo Unix al abrir el proceso, asi que un
# DEVKITPRO=/opt/devkitpro perfectamente razonable llega aqui convertido en
# "C:/Program Files/Git/opt/devkitpro", que no existe. Si esa fuera la unica
# candidata, la herramienta se rendiria teniendo devkitA64 instalado dos
# carpetas mas alla. Se prueban todas por orden y gana la primera que exista.
PREFIJO = "aarch64-none-elf-"
CANDIDATOS = []
if os.environ.get("DEVKITPRO"):
    CANDIDATOS.append(os.environ["DEVKITPRO"])
CANDIDATOS += ["C:/devkitPro", "/opt/devkitpro"]
EXTRA_PATH = [os.path.join(d, "devkitA64", "bin") for d in CANDIDATOS]


def herramienta(nombre):
    """Ruta de una herramienta de devkitA64, o None si no esta."""
    cual = shutil.which(PREFIJO + nombre)
    if cual:
        return cual
    for d in EXTRA_PATH:
        for ext in ("", ".exe"):
            cand = os.path.join(d, PREFIJO + nombre + ext)
            if os.path.isfile(cand):
                return cand
    return None


def correr(orden):
    return subprocess.run(orden, capture_output=True, text=True, errors="replace").stdout


# ---------------------------------------------------------------- el registro

RE_BUILD = re.compile(r"\[build\]\s+(\d+\.\d+\.\d+)\s+(b\d+)")
RE_PC = re.compile(r"\[exc\].*?\(\+(0x[0-9a-fA-F]+)\)")
RE_LR = re.compile(r"\[exc\].*?\slr=\+(0x[0-9a-fA-F]+)")
RE_MARCO = re.compile(r"\[exc\]\s+#(\d+)\s+\+(0x[0-9a-fA-F]+)")
RE_CABECERA = re.compile(r"\[exc\]\s+((?:otra|abort|SError|SVC|instruccion|desconocida|prefetch|alineacion)[^\n]*)")
RE_SUELTA = re.compile(r"^\s*\+?(0x[0-9a-fA-F]+)\s*$")


def leer_registro(ruta):
    """Devuelve (sello, cabecera, [(etiqueta, direccion), ...]) de un log."""
    with open(ruta, "r", encoding="utf-8", errors="replace") as f:
        texto = f.read()

    sello = None
    m = RE_BUILD.search(texto)
    if m:
        sello = (m.group(1), m.group(2))

    cabecera = []
    marcos = []
    for linea in texto.splitlines():
        if "[exc]" not in linea:
            continue
        m = RE_CABECERA.search(linea)
        if m and "far=" in linea:
            cabecera.append(linea.strip())
        m = RE_PC.search(linea)
        if m:
            cabecera.append(linea.strip())
            marcos.append(("pc", int(m.group(1), 16)))
            m2 = RE_LR.search(linea)
            if m2:
                marcos.append(("lr", int(m2.group(1), 16)))
            continue
        m = RE_MARCO.search(linea)
        if m:
            marcos.append(("#" + m.group(1), int(m.group(2), 16)))
    return sello, cabecera, marcos


# ---------------------------------------------------------------- el archivo

def archivos():
    """Todas las compilaciones archivadas, de la mas nueva a la mas vieja."""
    if not os.path.isdir(SIMBOLOS):
        return []
    salida = []
    for nombre in sorted(os.listdir(SIMBOLOS)):
        d = os.path.join(SIMBOLOS, nombre)
        if not os.path.isdir(d):
            continue
        datos = {"nombre": nombre, "dir": d, "elf": None, "nro": None, "sello": nombre}
        for f, clave in (("pokemon-anil.elf", "elf"), ("pokemon-anil.nro", "nro")):
            p = os.path.join(d, f)
            if os.path.isfile(p):
                datos[clave] = p
        s = os.path.join(d, "SELLO.txt")
        if os.path.isfile(s):
            with open(s, encoding="utf-8", errors="replace") as fh:
                for linea in fh:
                    if linea.startswith("sello:"):
                        datos["sello"] = linea.split(":", 1)[1].strip()
                    if linea.startswith("publicada:"):
                        datos["publicada"] = linea.split(":", 1)[1].strip()
        salida.append(datos)
    salida.sort(key=lambda d: os.path.getmtime(d["dir"]), reverse=True)
    return salida


def normalizar(sello):
    """'1.0.0 b14 01/09 17:43', '1.0.0 b14' y '1.0.0-b14' son el mismo sitio."""
    if sello is None:
        return None
    m = re.search(r"(\d+\.\d+\.\d+)[\s-]+(b\d+)", sello)
    if m:
        return m.group(1) + "-" + m.group(2)
    m = re.search(r"(\d+\.\d+\.\d+)", sello)
    return m.group(1) if m else sello.strip()


def buscar(sello):
    """Compilacion archivada que corresponde al sello, o None."""
    clave = normalizar(sello)
    if not clave:
        return None
    todos = archivos()
    for d in todos:
        if d["nombre"] == clave:
            return d
    # Solo se dio la version, sin numero de compilacion. Lo que un jugador
    # tiene instalado es lo PUBLICADO, asi que esa es la mejor apuesta; si de
    # esa version no hay nada publicado archivado, vale la mas reciente. En
    # cualquier caso no es la compilacion exacta y quien llama lo avisa.
    delaversion = [d for d in todos if d["nombre"].startswith(clave + "-")]
    for d in delaversion:
        if d.get("publicada") == "si":
            return d
    return delaversion[0] if delaversion else None


def nro_de_entrega(version):
    """El .nro publicado de una version, que sobrevive aunque no haya .elf."""
    p = os.path.join(RELEASE, "anil-switch-" + version, "pokemon-anil.nro")
    return p if os.path.isfile(p) else None


# ---------------------------------------------------------------- resolucion

def por_addr2line(elf, direcciones):
    a2l = herramienta("addr2line")
    if not a2l:
        return None
    orden = [a2l, "-f", "-C", "-i", "-e", elf] + ["0x%x" % d for d in direcciones]
    salida = correr(orden).splitlines()
    # addr2line escupe pares funcion/fichero, y con -i puede dar varios pares
    # por direccion. Sin -g no hay lineas, asi que el fichero sale como '??:?'
    # y lo unico util es el nombre; se toma el primer par de cada direccion.
    nombres = []
    i = 0
    for _ in direcciones:
        nombre = salida[i] if i < len(salida) else "??"
        fichero = salida[i + 1] if i + 1 < len(salida) else "??:?"
        i += 2
        nombres.append((nombre, fichero))
    return nombres


def desensamblar_elf(elf, direccion, contexto):
    od = herramienta("objdump")
    if not od:
        return []
    ini = max(0, direccion - 4 * contexto)
    fin = direccion + 4 * (contexto + 1)
    salida = correr([od, "-d", "-C", "--start-address=0x%x" % ini,
                     "--stop-address=0x%x" % fin, elf])
    return [l.rstrip() for l in salida.splitlines() if re.match(r"^\s+[0-9a-f]+:", l) or l.startswith("00")]


def desensamblar_nro(nro, direccion, contexto):
    """El metodo del Pidgey: el .nro no tiene simbolos, pero si instrucciones."""
    od = herramienta("objdump")
    if not od:
        return []
    ini = max(0, direccion - 4 * contexto)
    fin = direccion + 4 * (contexto + 1)
    salida = correr([od, "-D", "-b", "binary", "-m", "aarch64",
                     "--start-address=0x%x" % ini, "--stop-address=0x%x" % fin, nro])
    return [l.rstrip() for l in salida.splitlines() if re.match(r"^\s+[0-9a-f]+:", l)]


def palabras(nro, direccion, cuantas):
    """Las `cuantas` palabras de 32 bits que empiezan en `direccion`."""
    with open(nro, "rb") as f:
        f.seek(direccion)
        crudo = f.read(4 * cuantas)
    return [int.from_bytes(crudo[i:i + 4], "little") for i in range(0, len(crudo) - 3, 4)]


def candidatos_por_firma(nro, direccion, elf_ref, huella=10):
    """Busca en un .elf con simbolos la misma secuencia de instrucciones.

    Es lo que se hizo a mano con el Pidgey: si diez instrucciones consecutivas
    coinciden byte a byte —saltos relativos incluidos— es la misma funcion
    compilada igual, y el nombre que tenga alli vale aqui. No es una prueba:
    dos compilaciones distintas pueden haber movido la funcion o haberla
    cambiado, y entonces no hay coincidencia y no se inventa ninguna.
    """
    firma = palabras(nro, direccion, huella)
    if len(firma) < huella:
        return []
    patron = b"".join(w.to_bytes(4, "little") for w in firma)
    od = herramienta("objcopy")
    if not od:
        return []
    tmp = os.path.join(RAIZ, "tmp", "resolver-pila.text.bin")
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    correr([od, "-O", "binary", "--only-section=.text", elf_ref, tmp])
    if not os.path.isfile(tmp):
        return []
    with open(tmp, "rb") as f:
        texto = f.read()
    encontrados = []
    desde = 0
    while True:
        i = texto.find(patron, desde)
        if i < 0:
            break
        encontrados.append(i)
        desde = i + 4
        if len(encontrados) > 4:
            break
    a2l = herramienta("addr2line")
    salida = []
    for pos in encontrados:
        nombre = "??"
        if a2l:
            r = correr([a2l, "-f", "-C", "-e", elf_ref, "0x%x" % pos]).splitlines()
            if r:
                nombre = r[0]
        salida.append((pos, nombre))
    try:
        os.remove(tmp)
    except OSError:
        pass
    return salida


# ---------------------------------------------------------------- presentacion

def listar():
    todos = archivos()
    if not todos:
        print("No hay nada en release/simbolos/. Lo llena ./construir.sh en cada compilacion.")
        return 1
    print("Compilaciones archivadas (release/simbolos/):")
    for d in todos:
        piezas = []
        if d["elf"]:
            piezas.append("elf %.0f MB" % (os.path.getsize(d["elf"]) / 1e6))
        else:
            piezas.append("SIN elf")
        if d["nro"]:
            piezas.append("nro")
        if d.get("publicada") == "si":
            piezas.append("PUBLICADA")
        print("  %-18s %-30s %s" % (d["nombre"], d["sello"], ", ".join(piezas)))
    return 0


def main():
    ap = argparse.ArgumentParser(
        description="Resuelve una pila [exc] de un jugador con el .elf archivado de su compilacion.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Ejemplo:  python resolver-pila.py --sello '1.0.0 b14' mkxp-boot.log")
    ap.add_argument("entrada", nargs="*",
                    help="un mkxp-boot.log, o direcciones sueltas (+0x7abd30)")
    ap.add_argument("--sello", help="'1.0.0 b14', '1.0.0-b14' o solo '1.0.0'; "
                                    "si no se dice, se lee del propio registro")
    ap.add_argument("--dis", type=int, default=0, metavar="N",
                    help="ensena N instrucciones de contexto alrededor de cada direccion")
    ap.add_argument("--listar", action="store_true", help="lista lo archivado y sale")
    args = ap.parse_args()

    if args.listar:
        return listar()
    if not args.entrada:
        ap.print_help()
        return 2
    if not herramienta("addr2line") and not herramienta("objdump"):
        print("No encuentro las herramientas de devkitA64 (%saddr2line)." % PREFIJO)
        print("Ejecuta esto desde la shell de MSYS2 de devkitPro, o pon DEVKITPRO en el entorno.")
        return 1

    # Entrada: o un fichero de registro, o direcciones sueltas.
    sello = args.sello
    cabecera, marcos = [], []
    for e in args.entrada:
        if os.path.isfile(e):
            s, c, m = leer_registro(e)
            if s and not sello:
                sello = "%s %s" % s
            cabecera += c
            marcos += m
        else:
            m = RE_SUELTA.match(e.replace("+", ""))
            if not m:
                print("no entiendo '%s': ni es un fichero ni una direccion +0x..." % e)
                return 2
            marcos.append(("dir", int(m.group(1), 16)))

    if not marcos:
        print("No hay ninguna linea [exc] con direccion en lo que me has dado.")
        return 1
    if not sello:
        print("No se de que compilacion es esto: el registro no trae la linea [build]")
        print("y no me has dicho --sello. Sin eso no se que .elf mirar.")
        return 1

    version = normalizar(sello).split("-")[0]
    d = buscar(sello)
    for l in cabecera:
        print(l)
    print()
    print("Compilacion: %s" % sello)

    elf = d["elf"] if d else None
    nro = (d["nro"] if d else None) or nro_de_entrega(version)

    if d and d["nombre"] != normalizar(sello):
        print("AVISO: no hay archivo exacto para %s; uso %s, que es OTRA compilacion."
              % (normalizar(sello), d["nombre"]))
        print("       Los nombres valen solo para las funciones que no hayan cambiado.")

    # --- camino bueno: el .elf de esa compilacion -------------------------
    if elf and d["nombre"] == normalizar(sello):
        print("Simbolos:    %s" % os.path.relpath(elf, RAIZ))
        print()
        nombres = por_addr2line(elf, [a for _, a in marcos])
        for (etiq, dir_), (nombre, fichero) in zip(marcos, nombres or []):
            # Sin -g no hay numeros de linea y addr2line contesta '??:?' o
            # ':?'. Lo que a veces si sabe es de que fichero salio la funcion,
            # y eso vale la pena ensenarlo; el ':?' vacio, no.
            corto = re.sub(r":[?0]$", "", fichero.strip())
            extra = "" if corto in ("", "??") else "  " + corto
            print("  %-4s +0x%-10x %s%s" % (etiq, dir_, nombre, extra))
            if args.dis:
                for l in desensamblar_elf(elf, dir_, args.dis):
                    print("        " + l)
        return 0

    # --- degradado: el .nro en crudo, como con el Pidgey -------------------
    print()
    print("NO hay .elf archivado de esta compilacion.")
    if not nro:
        print("Y tampoco encuentro su .nro (ni en release/simbolos/ ni en release/anil-switch-%s/)."
              % version)
        print("Sin uno de los dos no hay nada que leer. Lo unico que queda es recompilar")
        print("ese commit exacto, si se sabe cual es: mira release/simbolos/*/SELLO.txt.")
        return 1

    ref = next((x for x in archivos() if x["elf"]), None)
    print("Caigo al metodo del desensamblado en crudo (bitacora §5.65):")
    print("  binario:   %s" % os.path.relpath(nro, RAIZ))
    if ref:
        print("  referencia: %s (%s) para poner nombres por firma de instrucciones"
              % (os.path.relpath(ref["elf"], RAIZ), ref["sello"]))
    else:
        print("  sin ninguna compilacion con simbolos para comparar: solo instrucciones.")
    print("  Lo que salga son CANDIDATOS: valen si la funcion no cambio entre las dos")
    print("  compilaciones, y no hay forma de saberlo desde aqui.")
    print()
    for etiq, dir_ in marcos:
        print("  %-4s +0x%x" % (etiq, dir_))
        for l in desensamblar_nro(nro, dir_, args.dis or 2):
            marca = "  <-- aqui" if re.match(r"^\s+%x:" % dir_, l) else ""
            print("        " + l + marca)
        if ref:
            for pos, nombre in candidatos_por_firma(nro, dir_, ref["elf"]):
                print("        candidato: %s  (en %s, +0x%x)" % (nombre, ref["nombre"], pos))
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
