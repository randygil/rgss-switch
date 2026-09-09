#!/usr/bin/env python3
"""reconstruir-src.py — rehacer src/mkxp-z desde el original y los parches.

src/ esta en .gitignore. Lo unico que queda de todo el trabajo hecho sobre
mkxp-z son los parches de patches/, y hasta el 6 de septiembre de 2026 nadie
habia comprobado que basten para rehacer el arbol. Ese dia aparecieron tres
ficheros con cambios y sin ningun parche que los mencionara —texpool.h,
gl-util.h y bitmap.cpp, este ultimo con veintitres trozos de trabajo— y un
cuarto con el parche desfasado tras un arreglo. Los cuatro se habrian perdido
en silencio el dia que alguien clonara el repositorio en otra maquina.

EL PUNTO DE PARTIDA es src/mkxpz.tar.gz, el mkxp-z 2.4.2 original, que ya viaja
en el arbol. No los .orig sueltos: un .orig solo existe si alguien se acordo de
hacerlo, y de sharedstate.cpp -que tocan dos parches- no hay ninguno.

EL ORDEN NO ESTABA ESCRITO, ASI QUE SE DEDUCE. Varios parches tocan el mismo
fichero -filesystem.cpp lo tocan cuatro- y hay que aplicarlos en un orden
concreto que no consta en ninguna parte. Aqui se descubre solo: vuelta tras
vuelta se prueba cual de los que quedan aplica limpio sobre lo que hay, y el que
aplica se aplica. Cuando en una vuelta entera no aplica ninguno, o se ha
terminado o los que quedan estan rotos.

Es lento a proposito —prueba todos contra todos— porque se ejecuta a mano y de
vez en cuando, no en cada compilacion.

Al final compara con src/mkxp-z fichero a fichero. Si sale igual, los parches
bastan para rehacer el arbol y el orden queda impreso; si no, dice que fichero
se desvia. Las diferencias de fin de linea no cuentan: los .c y .cpp del porteo
son CRLF y los parches se generan en LF.

    python reconstruir-src.py            comprueba y no toca nada
    python reconstruir-src.py --orden    ademas escribe patches/ORDEN.txt
"""
import os, re, glob, shutil, subprocess, sys, tarfile, tempfile

RAIZ = os.path.dirname(os.path.abspath(__file__))
FUENTE = os.path.join(RAIZ, "src", "mkxp-z")
TARBALL = os.path.join(RAIZ, "src", "mkxpz.tar.gz")


def cabeceras(parche):
    """(nivel -p, [ficheros que toca]) tal y como los nombra su cabecera."""
    ficheros, nivel = [], None
    with open(parche, encoding="utf-8", errors="replace") as fh:
        for l in fh:
            if l.startswith("+++ "):
                crudo = l[4:].split("\t")[0].strip()
                if nivel is None:
                    nivel = 1 if re.match(r"^[ab]/", crudo) else 0
                ficheros.append(re.sub(r"^[ab]/", "", crudo))
    return nivel or 0, ficheros


def donde_aplicar(arbol, parche):
    """Desde que carpeta hay que llamar a patch, y con que -p.

    Las cabeceras vienen de tres sitios distintos y no dicen lo mismo: unas son
    "a/src/x.cpp" (git), otras "src/x.cpp", y las que se generaron con
    `diff -u x.cpp.orig x.cpp` dentro de la propia carpeta son
    "display/gl/texpool.cpp.orig". Llamar a patch desde la raiz con -p0 hace que
    esta ultima no encuentre nada, y patch lo dice como "can't find file", que
    se lee como si el parche estuviera roto cuando lo unico que pasa es que se
    le llamo desde el sitio equivocado.

    Asi que se busca donde vive de verdad el fichero y se llama a patch desde
    ahi: cwd = la parte de delante, -p0 sobre la de detras."""
    nivel, ficheros = cabeceras(parche)
    if not ficheros:
        return None, 0
    cola = ficheros[0]
    if nivel:
        cola = "/".join(cola.split("/")[nivel:])
    rel = resuelve(arbol, cola)
    if rel is None:
        return None, nivel
    # rel termina en cola (o en su cola). Lo de delante es el cwd.
    partes_rel, partes_cola = rel.split("/"), cola.split("/")
    while partes_cola and partes_rel and partes_rel[-1] == partes_cola[-1]:
        partes_rel.pop(); partes_cola.pop()
    if partes_cola:
        return None, nivel      # no encaja: que lo diga el patch de verdad
    cwd = os.path.join(arbol, *partes_rel) if partes_rel else arbol
    return cwd, nivel


def resuelve(base, ruta):
    """El destino se escribe de tres maneras segun quien generara el parche
    -"a/src/x.cpp", "src/x.cpp", "display/gl/x.cpp"-, asi que en vez de adivinar
    la raiz se busca el fichero por su cola dentro del arbol original."""
    cand = [ruta, os.path.join("src", ruta), os.path.join("binding", ruta)]
    cola = ruta
    while "/" in cola:
        cola = cola.split("/", 1)[1]
        cand.append(cola)
        cand.append(os.path.join("src", cola))
    for c in cand:
        p = os.path.join(base, c.replace("/", os.sep))
        if os.path.isfile(p):
            return os.path.relpath(p, base).replace(os.sep, "/")
    return None


def igual(a, b):
    da = open(a, "rb").read().replace(b"\r\n", b"\n")
    db = open(b, "rb").read().replace(b"\r\n", b"\n")
    return da == db


def main():
    if not os.path.isfile(TARBALL):
        print("no esta %s: sin el original no hay nada que reconstruir" % TARBALL)
        return 1

    tmp = tempfile.mkdtemp()
    try:
        with tarfile.open(TARBALL) as t:
            try:
                t.extractall(tmp, filter="data")
            except TypeError:
                t.extractall(tmp)   # Python anterior al filtro
        raices = [os.path.join(tmp, d) for d in os.listdir(tmp)
                  if os.path.isdir(os.path.join(tmp, d))]
        arbol = raices[0]

        parches = sorted(glob.glob(os.path.join(RAIZ, "patches", "mkxpz-*.patch")))

        # Que ficheros toca cada parche, resueltos contra el arbol de verdad.
        tocados = {}
        for p in parches:
            _n, ficheros = cabeceras(p)
            for f in ficheros:
                cola = "/".join(f.split("/")[_n:]) if _n else f
                rel = resuelve(arbol, cola)
                if rel:
                    tocados[rel] = True
                else:
                    print("NO ENCUENTRO  %-38s %s"
                          % (os.path.basename(p), f))

        quedan, orden = list(parches), []
        while quedan:
            entro = None
            for p in quedan:
                cwd, nivel = donde_aplicar(arbol, p)
                if cwd is None:
                    continue
                orden_patch = ["patch", "-p%d" % nivel, "-s", "-f",
                               "--no-backup-if-mismatch", "-i", p]
                r = subprocess.run(orden_patch + ["--dry-run"], cwd=cwd,
                                   capture_output=True, text=True)
                if r.returncode == 0:
                    subprocess.run(orden_patch, cwd=cwd,
                                   capture_output=True, text=True)
                    orden.append(p); entro = p; break
            if entro is None:
                break
            quedan.remove(entro)

        print()
        print("ORDEN DEDUCIDO (%d de %d parches):" % (len(orden), len(parches)))
        for i, p in enumerate(orden, 1):
            print("  %2d. %s" % (i, os.path.basename(p)))
        if quedan:
            print()
            print("NO APLICAN sobre lo anterior (%d):" % len(quedan))
            for p in quedan:
                print("  %s" % os.path.basename(p))

        print()
        iguales, distintos, ausentes = 0, [], []
        for rel in sorted(tocados):
            hecho = os.path.join(arbol, rel.replace("/", os.sep))
            real = os.path.join(FUENTE, rel.replace("/", os.sep))
            if not os.path.isfile(real):
                ausentes.append(rel); continue
            if igual(hecho, real):
                iguales += 1
            else:
                distintos.append(rel)
        for rel in distintos:
            print("SE DESVIA     %s" % rel)
        for rel in ausentes:
            print("NO ESTA EN src/  %s" % rel)
        print()
        print("%d fichero(s) salen identicos, %d se desvian" % (iguales, len(distintos)))

        limpio = not quedan and not distintos and not ausentes
        if "--orden" in sys.argv and limpio:
            with open(os.path.join(RAIZ, "patches", "ORDEN.txt"), "w",
                      encoding="utf-8", newline="\n") as fh:
                fh.write("# Orden en que se aplican los parches de mkxp-z sobre\n"
                         "# mkxp-z 2.4.2 (src/mkxpz.tar.gz). Lo deduce y lo\n"
                         "# comprueba reconstruir-src.py: no se edita a mano.\n")
                for p in orden:
                    fh.write(os.path.basename(p) + "\n")
            print("escrito patches/ORDEN.txt")
        return 0 if limpio else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
