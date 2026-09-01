#!/usr/bin/env python3
"""anilftp.py — desplegar Anil en la Switch por FTP, y traerse los registros.

Por que FTP y no la tarjeta: el 1 de septiembre de 2026 la microSD se corrompio
cinco veces en un dia escribiendo desde el PC por el lector, y hubo que
reconstruir el sistema de ficheros dos veces. Copiando por red no se saca la
tarjeta, no se escribe en ella desde Windows, y la consola gestiona sus propias
escrituras. Ademas cierra el ciclo de depuracion sin levantarse del sitio.

Lo que hace:

    subir    sincroniza out/sdcard/switch/pokemon-anil -> /switch/pokemon-anil
             saltandose lo que ya coincide en tamano. En la practica solo sube
             el .nro y los .rb, que es lo que cambia entre pruebas.
    traer    se trae mkxp-boot.log, mkxp-debug.log, mkxp-ruby.log y errorlog.txt
             a docs/consola/<fecha>/ . Sustituye a recoger.ps1 y a sacar la SD.

Sobre la verificacion, que es la leccion cara del dia: despues de subir cada
fichero se pregunta su tamano al servidor y se compara. Se cuentan los
verificados contra los pedidos y se sale con error si no cuadran. Una
comprobacion que no puede fallar no es una comprobacion.

sys-ftpd sin config usa el puerto 5000 y acepta anonimo.

Uso:
    python anilftp.py subir 192.168.1.50
    python anilftp.py subir 192.168.1.50 --solo nro
    python anilftp.py traer 192.168.1.50
"""
import argparse, ftplib, hashlib, json, os, sys, time, datetime

LOCAL  = "C:/anilswitch/out/sdcard/switch/pokemon-anil"
REMOTO = "/switch/pokemon-anil"
# Que se subio la ultima vez, por ruta: {"rel": [tamano, md5]}. Hace falta
# porque el servidor solo sabe decir tamanos, y el 1 de septiembre de 2026 una
# version nueva del .nro peso exactamente lo mismo que la vieja —los campos del
# NACP son de tamano fijo— asi que la comparacion por tamano la dio por subida
# y la consola siguio arrancando el binario de antes. Una comprobacion que no
# puede fallar no es una comprobacion.
ESTADO = "C:/anilswitch/.anilftp-estado.json"
REGISTROS = ["mkxp-boot.log", "mkxp-debug.log", "mkxp-ruby.log", "errorlog.txt"]

# Lo que cambia entre una prueba y la siguiente. Subir esto son segundos;
# sincronizar los 22.151 ficheros del juego son minutos.
SOLO = {
    "nro":  ["pokemon-anil.nro"],
    "ruby": ["mkxp.json", "preload.rb"],
    "todo": None,
}


def conectar(host, puerto, usuario, clave):
    ftp = ftplib.FTP()
    ftp.connect(host, puerto, timeout=30)
    ftp.login(usuario, clave)
    ftp.voidcmd("TYPE I")          # binario: sin esto SIZE miente en algunos servidores
    return ftp


def tam_remoto(ftp, ruta):
    try:
        return ftp.size(ruta)
    except (ftplib.error_perm, ftplib.error_temp):
        return None


def asegura_dir(ftp, ruta, creados):
    """Crea la ruta remota entera, recordando lo ya creado para no preguntar dos veces."""
    if ruta in creados:
        return
    partes, acum = [p for p in ruta.split("/") if p], ""
    for p in partes:
        acum += "/" + p
        if acum not in creados:
            try:
                ftp.mkd(acum)
            except ftplib.error_perm:
                pass               # ya existia
            creados.add(acum)
    creados.add(ruta)


def resumen(ruta):
    h = hashlib.md5()
    with open(ruta, "rb") as fh:
        for trozo in iter(lambda: fh.read(1 << 20), b""):
            h.update(trozo)
    return h.hexdigest()


def lee_estado():
    try:
        with open(ESTADO, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def guarda_estado(estado):
    try:
        with open(ESTADO, "w", encoding="utf-8") as fh:
            json.dump(estado, fh, indent=0, sort_keys=True)
    except Exception as e:
        print("aviso: no pude guardar %s (%s)" % (ESTADO, e))


def subir(ftp, solo):
    lista = []
    for raiz, _, ficheros in os.walk(LOCAL):
        for f in ficheros:
            abs_ = os.path.join(raiz, f).replace("\\", "/")
            rel = os.path.relpath(abs_, LOCAL).replace("\\", "/")
            if solo is not None and not any(rel == s or rel.startswith(s + "/") for s in solo):
                continue
            lista.append((abs_, rel))
    if solo and "lib" in [s.split("/")[0] for s in solo]:
        pass
    print("ficheros a considerar: %d" % len(lista))

    creados, subidos, iguales, verificados, fallos = set(), 0, 0, 0, []
    bytes_ = 0
    estado = lee_estado()
    t0 = time.time()
    for i, (abs_, rel) in enumerate(sorted(lista, key=lambda x: x[1]), 1):
        destino = REMOTO + "/" + rel
        local_tam = os.path.getsize(abs_)
        local_md5 = resumen(abs_)
        remoto_tam = tam_remoto(ftp, destino)
        anotado = estado.get(rel)

        # Saltarselo exige las dos cosas: que el servidor diga ese tamano Y que
        # sea el mismo contenido que dejamos alli la ultima vez. Sin lo segundo,
        # editar un fichero sin cambiarle el tamano pasa desapercibido.
        if (remoto_tam == local_tam and anotado
                and anotado[0] == local_tam and anotado[1] == local_md5):
            iguales += 1
            verificados += 1
        else:
            asegura_dir(ftp, os.path.dirname(destino), creados)
            try:
                with open(abs_, "rb") as fh:
                    ftp.storbinary("STOR " + destino, fh, blocksize=64 * 1024)
            except Exception as e:
                fallos.append("%s: %s" % (rel, e))
                continue
            subidos += 1
            bytes_ += local_tam
            # La comprobacion: preguntar al servidor, no dar por hecho.
            if tam_remoto(ftp, destino) == local_tam:
                verificados += 1
                estado[rel] = [local_tam, local_md5]
            else:
                estado.pop(rel, None)
                fallos.append("%s: subido pero el tamano remoto no coincide" % rel)

        if i % 200 == 0 or i == len(lista):
            seg = max(time.time() - t0, 0.01)
            print("  %d/%d  subidos %d  iguales %d  %.1f MB a %.2f MB/s"
                  % (i, len(lista), subidos, iguales, bytes_ / 1e6, bytes_ / 1e6 / seg),
                  flush=True)

    guarda_estado(estado)
    print("\nsubidos %d, ya iguales %d, verificados %d de %d"
          % (subidos, iguales, verificados, len(lista)))
    for f in fallos[:20]:
        print("  FALLO %s" % f)
    return 0 if (verificados == len(lista) and not fallos) else 1


def traer(ftp):
    fecha = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    destino = "C:/anilswitch/docs/consola/" + fecha
    os.makedirs(destino, exist_ok=True)
    traidos = 0
    for nombre in REGISTROS:
        ruta = REMOTO + "/" + nombre
        if tam_remoto(ftp, ruta) is None:
            print("  (no esta) %s" % nombre)
            continue
        local = os.path.join(destino, nombre)
        with open(local, "wb") as fh:
            ftp.retrbinary("RETR " + ruta, fh.write)
        print("  %-18s %d B" % (nombre, os.path.getsize(local)))
        traidos += 1
    print("\n%d registros en %s" % (traidos, destino))

    boot = os.path.join(destino, "mkxp-boot.log")
    if os.path.exists(boot):
        texto = open(boot, encoding="latin-1").read().splitlines()
        for marca in ("[reloj]", "[mem]", "[tiron]"):
            hay = [l for l in texto if marca in l]
            if hay:
                print("\n--- %s (%d lineas) ---" % (marca, len(hay)))
                for l in hay[:6]:
                    print("  " + l)
    return 0 if traidos else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("accion", choices=["subir", "traer"])
    ap.add_argument("host")
    ap.add_argument("--puerto", type=int, default=5000)
    ap.add_argument("--usuario", default="anonymous")
    ap.add_argument("--clave", default="anonymous")
    ap.add_argument("--solo", choices=sorted(SOLO), default="todo",
                    help="nro = solo el binario; ruby = configuracion; todo = el juego entero")
    a = ap.parse_args()

    try:
        ftp = conectar(a.host, a.puerto, a.usuario, a.clave)
    except Exception as e:
        print("no pude conectar a %s:%d -> %s" % (a.host, a.puerto, e))
        print("¿Esta la consola encendida y en la misma red? sys-ftpd escucha en el 5000.")
        return 1
    print("conectado a %s:%d" % (a.host, a.puerto))
    try:
        if a.accion == "subir":
            solo = SOLO[a.solo]
            if a.solo == "ruby":
                solo = solo + ["lib"]
            return subir(ftp, solo)
        return traer(ftp)
    finally:
        try:
            ftp.quit()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
