#!/usr/bin/env python3
"""triaje.py — leer los registros que manda un jugador y escribir el informe.

El 5 de septiembre de 2026 se analizo a mano la caida de un jugador —el Pidgey
de la ruta 1, docs/consola/20260905-pidgey/analisis.md— y costo una tarde
entera: contar sesiones, restar el pc de la base a mano, seguir la serie de
picos del monton numero a numero, y darse cuenta de que un tiron de 2.582.178 ms
no era un tiron sino la consola dormida. Ninguno de esos pasos exige criterio:
son cuentas. Lo que exige criterio es el veredicto, y para eso hace falta
llegar al veredicto con las cuentas ya hechas.

Esto hace las cuentas. Dada la carpeta que manda el jugador —tal cual la
descomprima, con las subcarpetas que traiga—, busca los registros, los lee, y
deja un informe en espanol en docs/consola/AAAAMMDD-<etiqueta>/analisis.md con
las mismas secciones que el escrito a mano, archivando al lado los registros
crudos para que el caso quede completo.

Lo que sabe mirar:

  * la compilacion (`[build] 1.0.0 b14 01/09 17:43`) y si lleva o no los
    arreglos conocidos —el guardian de §5.64, sobre todo, que esta en main
    desde el 4 de septiembre y no viaja en ninguna publicacion;
  * los volcados `[exc]`: desplazamiento relativo (pc menos base, que es lo
    unico que sirve para resolver), registros, pila, y si dos volcados son el
    mismo camino de codigo o dos distintos;
  * las series que delatan una fuga: tamano del fondo de texturas, picos del
    monton y hueco libre, con minimo, maximo y si suben sin bajar nunca;
  * los tirones, separando el tiron de verdad de la consola suspendida;
  * la partida: cuantas sesiones, cuanto duro cada una y si Essentials dejo
    excepcion en errorlog.txt;
  * los casos ya archivados en docs/consola/, para decir «esto ya lo hemos
    visto» cuando el desplazamiento coincida.

Lo que NO hace por si mismo: poner nombres de funcion a los desplazamientos de
la pila. Eso pide el `.elf` de esa compilacion y es una herramienta aparte,
`resolver-pila.py`, que entra por el punto de enganche `resolver_simbolos()`.
Cuando esa herramienta puede resolver, el informe sale con los nombres puestos;
cuando no —no hay `.elf` archivado, o falta el toolchain—, el informe lo dice y
explica como resolverlos a mano. El triaje no depende de ello.

Uso:
    python triaje.py "C:/Users/Usuario/Downloads/ANIL ERROR" --etiqueta pidgey
    python triaje.py docs/consola/20260905-pidgey --etiqueta pidgey \
           --fecha 20260905 --nombre analisis-automatico.md --sin-archivar
    python triaje.py <carpeta> --etiqueta lo-que-sea --relato "lo que conto"

Sin --etiqueta se usa el nombre de la carpeta; sin --fecha, la de hoy.
"""
import argparse
import datetime
import os
import re
import shutil
import sys

# ---------------------------------------------------------------- constantes

RAIZ = os.path.dirname(os.path.abspath(__file__))
ARCHIVO = os.path.join(RAIZ, "docs", "consola")

REGISTROS = ["mkxp-boot.log", "mkxp-ruby.log", "mkxp-debug.log", "errorlog.txt",
             "mkxp.json"]

# Un marco larguisimo no es un tiron: es que alguien cerro la tapa. Separarlos
# importa dos veces —un tiron falso ensucia la lista de los peores, y su tiempo
# infla la duracion de la sesion—, y el criterio de antes fallaba por mirar
# donde se fue el tiempo en lugar de mirar si el proceso hizo algo.
#
# Son tres reglas, de mas fuerte a mas fina:
#
#   1. Por encima de un minuto no hay nada que discutir. Un fotograma de tres
#      minutos no existe: ningun trabajo del juego —ni descomprimir, ni indexar
#      la tarjeta, ni recompilar shaders— dura eso sin que el jugador hubiera
#      apagado ya la consola. Mande el reparto lo que mande, es una suspension.
#   2. Por debajo, lo que delata al hilo dormido es que la CPU no hizo nada.
#      Un tiron de verdad quema CPU: los peores de estos registros gastan entre
#      700 y 2.300 ms de CPU en fotogramas de dos segundos. Los dormidos gastan
#      nueve, once, diecisiete milisegundos.
#   3. Y ademas ese tiempo tiene que estar en los cajones de esperar, no en los
#      de trabajar. El hilo parado aparece unas veces en `comp` —esperando a
#      componer— y otras en `resto` —lo que ninguna sonda supo colocar—, segun
#      por donde le pillara la suspension; mirar solo `comp`, que es lo que se
#      hacia, dejaba escapar justo las que caian en `resto`.
SUSPENSION_SEGURA_MS = 60000     # regla 1: por encima de esto, siempre
SUSPENSION_MS = 3000             # regla 2: por debajo de esto, ni mirar
SUSPENSION_CPU = 0.05            # regla 2: CPU por debajo del 5% del marco
SUSPENSION_PARTE = 0.9           # regla 3: 90% del marco en comp + resto

# Los arreglos que ya existen en main, con la fecha en que entraron y las
# publicaciones que se sabe que NO los llevan. Cuando salga la publicacion que
# los lleve, se anade aqui y todos los informes futuros lo saben.
ARREGLOS = [
    {
        "clave": "guardian-5.64",
        "nombre": "el guardián de §5.64",
        "que_hace": "preguntar a `glGetError()` antes de colgar la textura del "
                    "FBO, soltar el fondo entero y reintentar",
        "en_main": datetime.date(2026, 9, 4),
        "sin_el": ["1.0.0", "1.1.0"],
    },
    {
        "clave": "contador-32",
        "nombre": "el contador de texturas del fondo ensanchado a 32 bits",
        "que_hace": "que `TexPoolPrivate::objCount` deje de dar la vuelta en "
                    "65.536 texturas, y que `[tiron]` diga cuántas hay",
        "en_main": datetime.date(2026, 9, 4),
        "sin_el": ["1.0.0", "1.1.0"],
    },
]

# ------------------------------------------------------------------ lectura

def lee(camino):
    """Los registros vienen de la consola en UTF-8, pero un errorlog.txt de
    Essentials puede traer cualquier cosa; nunca fallar por un byte suelto."""
    with open(camino, "rb") as f:
        crudo = f.read()
    return crudo.decode("utf-8", "replace")


def busca_registros(carpeta):
    """El jugador manda lo que le sale: a veces los cuatro ficheros sueltos, a
    veces la carpeta `pokemon-anil` entera dentro de otras dos. Se busca en
    todo el arbol y, si hay repetidos, gana el mas grande —un registro truncado
    a cero bytes no sirve de nada—.

    Con una salvedad que costo un error de archivado: si en el arbol hay
    registros de DOS jugadores —«user 1» y «user2», cada uno en su
    subcarpeta—, quedarse con el mayor de cada nombre mezcla a los dos y el
    informe sale hablando de un jugador imaginario hecho de trozos. Paso el 5
    de septiembre de 2026: en el caso del Pidgey se archivo el `mkxp.json` del
    otro jugador. Asi que manda el `mkxp-boot.log`, que es el registro sin el
    cual no hay triaje: los demas solo valen si viven en su misma carpeta, y lo
    que se queda fuera se dice en voz alta en lugar de colarse.

    Devuelve (hallados, descartados): el dict de siempre y la lista de lo que
    se dejo fuera por venir de otra carpeta, para que el informe lo cuente."""
    nombres = [r.lower() for r in REGISTROS]
    candidatos = {}
    for base, _dirs, ficheros in os.walk(carpeta):
        for nombre in ficheros:
            clave = nombre.lower()
            if clave in nombres:
                candidatos.setdefault(clave, []).append(os.path.join(base, nombre))

    boots = candidatos.get("mkxp-boot.log", [])
    if not boots:
        return {}, []
    boot = max(boots, key=os.path.getsize)
    casa = os.path.dirname(os.path.abspath(boot))

    hallados = {"mkxp-boot.log": boot}
    descartados = []
    for clave, caminos in candidatos.items():
        if clave == "mkxp-boot.log":
            de_casa = [c for c in caminos
                       if os.path.dirname(os.path.abspath(c)) != casa]
            descartados.extend(de_casa)
            continue
        propios = [c for c in caminos
                   if os.path.dirname(os.path.abspath(c)) == casa]
        ajenos = [c for c in caminos
                  if os.path.dirname(os.path.abspath(c)) != casa]
        if propios:
            hallados[clave] = max(propios, key=os.path.getsize)
        descartados.extend(ajenos)
    return hallados, sorted(descartados)

# ------------------------------------------------------- gramatica del boot

# El registro escribe `[   123] [tag] cuerpo`, pero dos hilos que escriben a la
# vez se pisan y sale `[ 19812] [ 19814] [nucleo] ...(OK)[tiron] marco ...`.
# Por eso no se lee linea a linea: se buscan las marcas de tiempo y, dentro de
# cada trozo, todas las etiquetas.
MARCA = re.compile(r"\[\s*(\d+)\]\s*(?=\[[a-z])")
ETIQUETA = re.compile(r"\[([a-z]+)\]\s*")


def registros_del_boot(texto):
    """Devuelve [(ms, etiqueta, cuerpo)] en orden, deshaciendo los pisotones."""
    salida = []
    marcas = list(MARCA.finditer(texto))
    for i, m in enumerate(marcas):
        ms = int(m.group(1))
        fin = marcas[i + 1].start() if i + 1 < len(marcas) else len(texto)
        trozo = texto[m.end():fin]
        etiquetas = list(ETIQUETA.finditer(trozo))
        for j, e in enumerate(etiquetas):
            hasta = etiquetas[j + 1].start() if j + 1 < len(etiquetas) else len(trozo)
            cuerpo = trozo[e.end():hasta].strip()
            salida.append((ms, e.group(1), cuerpo))
    return salida


RE_BUILD = re.compile(r"^(\S+)\s+b(\d+)\s+(\d+)/(\d+)(?:\s+(\d+):(\d+))?")
RE_MEM_INICIAL = re.compile(r"total (\d+) MB \| usado (\d+) MB \| monton (\d+) MB")
RE_PICO = re.compile(r"pico del monton (\d+) MB \(libre en el monton (\d+) MB\)")
RE_MARCO = re.compile(r"marco (\d+) ms \| cpu (\d+) ms")
RE_EMBUDO = re.compile(r"\|\s*([a-z]+) (\d+)x (\d+) ms")
RE_FONDO = re.compile(r"fondo (\d+) aciertos (\d+) MB(?: (\d+) tex)?")
# `resto` cierra la linea de `[tiron]` y no lleva cuenta de veces —`resto 5 ms`,
# no `resto 1x 5 ms`—, asi que RE_EMBUDO no lo ve. Es justo el cajon donde cae
# el tiempo de una consola dormida, de modo que no verlo era no ver las
# suspensiones que no pasaban por `comp`.
RE_RESTO = re.compile(r"\|\s*resto (\d+) ms")
# Lineas que la 1.1.1 anadio al registro. Antes de ella no existe ninguna, asi
# que un registro sin estas es, por si solo, un registro viejo.
RE_DONDE = re.compile(r"^mapa (\d+)(?: (.*?))? en \((\d+),(\d+)\)$")
RE_LENTO = re.compile(r"^(\d+) ms abriendo (.+)$")
RE_TEXVIVAS = re.compile(r"texturas vivas: (\d+) MB en (\d+) \| pico (\d+) MB en (\d+)")
RE_REPARTO = re.compile(r"reparto: fondo (\d+) \| img (\d+) \| cad (\d+) \| resto (\d+) MB")
RE_MALLOC = re.compile(r"malloc (\d+) MB en uso")
RE_CENSO = re.compile(r"fallos (\d+) \| con multiplo de 16 serian aciertos (\d+) "
                      r"\((\d+)%, (\d+) tamanos\) \| con potencia de 2, (\d+) \((\d+)%, (\d+)\)")
RE_PRESUPUESTO = re.compile(r"presupuesto inicial (\d+) MB")
RE_MONTADO = re.compile(r"^10a\+ contenedor (.+) montado$")
RE_INTERPRETE = re.compile(r"^11 SharedState OK")
# `[ritmo]` (nx_tirones.c, bitacora 5.74): el fotograma NORMAL, una linea cada
# 15 s. `[tiron]` solo ve los de mas de 250 ms, y el «va lento todo el rato» de
# exteriores eran fotogramas de 20 a 30 ms que no dejaban rastro. Los campos se
# leen por su nombre y no con una sola expresion: `blt`, `txt` y `lote` se
# fueron anadiendo, y un registro de antes tiene que leerse igual.
RE_RITMO = re.compile(r"^(\d+) s: (\d+) f \((\d+) fps\) \| ([\d.]+) ms/f \| "
                      r">\d+ ms (\d+)% >\d+ ms (\d+)% peor (\d+)")
RE_RITMO_CAMPO = re.compile(r"\b(cpu|comp|esp|swap|blt|txt) ([\d.]+)")
RE_RITMO_LOTE = re.compile(r"lote (\d+) dibujos con (\d+) sprites/f")

RE_EXC_CAB = re.compile(r"^(.*?)\s*desc=(\S+)\s+esr=(\S+)\s+far=(\S+)")
RE_EXC_BASE = re.compile(r"base=(\S+)\s+pc=(\S+)\s+\(\+(\S+)\)(?:\s+lr=\+(\S+))?"
                         r"(?:\s+sp=(\S+))?")
RE_EXC_REG = re.compile(r"(x\d+)=(0x[0-9a-f]+)")
RE_EXC_MARCO = re.compile(r"#(\d+)\s+\+(\S+)")


class Sesion(object):
    """Una arrancada del juego: desde su `[build]` hasta el siguiente."""

    def __init__(self):
        self.compilacion = None
        self.memoria = None
        self.reloj = None
        self.gfx = None
        self.ultimo_ms = 0
        self.picos = []        # (ms, pico_mb, libre_mb)
        self.tirones = []      # dicts
        self.volcados = []     # dicts
        self.fondo = []        # (ms, mb, texturas o None)
        self.fs = []
        # `[me]` —una fanfarria que termina: Pokemon capturado, objeto
        # encontrado, subida de nivel— es el unico suceso de DENTRO del juego
        # que llega al registro con hora. No dice donde estaba el jugador, pero
        # dice que estaba jugando y no en un menu.
        self.eventos = []
        self.termino_en_exc = False
        # Lo que la 1.1.1 empezo a contar. Vacio en cualquier registro anterior.
        self.nro = None          # de donde salio el binario
        self.donde = []          # (ms, id, nombre, x, y) en cada cambio de mapa
        self.lentos = []         # (ms, coste_ms, fichero)
        self.texturas = []       # (ms, mb, n, pico_mb, pico_n)
        self.reparto = []        # (ms, malloc, fondo, img, cad, resto)
        self.censo = None        # el ultimo censo de fallos del fondo
        self.presupuesto = None  # MB con los que arranco el fondo
        self.montaje = None      # (ms_montado, nombre del contenedor)
        self.interprete_ms = None
        self.malloc_pendiente = None
        self.ritmo = []          # dicts, una ventana de 15 s cada uno


def analiza_boot(texto):
    """Parte el registro en sesiones y llena cada una con lo suyo."""
    sesiones = []
    actual = None
    volcado = None

    for ms, tag, cuerpo in registros_del_boot(texto):
        arranque = (tag == "build" or
                    (tag == "boot" and cuerpo.startswith("1/3")))
        if arranque and (actual is None or actual.ultimo_ms > 0 or
                         actual.compilacion is not None or actual.picos):
            if tag == "boot" and actual is not None and actual.ultimo_ms <= ms:
                # `[boot] 1/3` justo detras de `[build]`: misma sesion.
                arranque = False
            if arranque:
                actual = Sesion()
                sesiones.append(actual)
                volcado = None
        if actual is None:
            actual = Sesion()
            sesiones.append(actual)
        actual.ultimo_ms = max(actual.ultimo_ms, ms)

        if tag == "build":
            m = RE_BUILD.match(cuerpo)
            if m:
                dia, mes = int(m.group(3)), int(m.group(4))
                actual.compilacion = {
                    "version": m.group(1),
                    "b": int(m.group(2)),
                    "fecha": datetime.date(2026, mes, dia),
                    "hora": "%s:%s" % (m.group(5), m.group(6)) if m.group(5) else "",
                    "linea": cuerpo,
                }
        elif tag == "mem":
            m = RE_MEM_INICIAL.search(cuerpo)
            if m:
                actual.memoria = {
                    "total": int(m.group(1)), "usado": int(m.group(2)),
                    "monton": int(m.group(3)), "linea": cuerpo,
                }
            m = RE_PICO.search(cuerpo)
            if m:
                actual.picos.append((ms, int(m.group(1)), int(m.group(2))))
        elif tag == "reloj":
            actual.reloj = cuerpo
        elif tag == "gfx" and actual.gfx is None:
            actual.gfx = cuerpo
        elif tag == "fs":
            actual.fs.append((ms, cuerpo))
        elif tag == "nro":
            # Solo la primera linea. Las lineas de la pantalla de diagnostico
            # -"Busco el juego en:", los [ OK ]- llevan sello de tiempo pero no
            # etiqueta, asi que el troceador las pega al cuerpo de la anterior.
            actual.nro = cuerpo.splitlines()[0].strip() if cuerpo else ""
        elif tag == "donde":
            m = RE_DONDE.match(cuerpo)
            if m:
                actual.donde.append((ms, int(m.group(1)), m.group(2) or "",
                                     int(m.group(3)), int(m.group(4))))
        elif tag == "lento":
            m = RE_LENTO.match(cuerpo)
            if m:
                actual.lentos.append((ms, int(m.group(1)), m.group(2)))
        elif tag == "monton":
            # El bloque sale siempre en el mismo orden -malloc, reparto,
            # texturas vivas, ruby- asi que el malloc se guarda al vuelo y lo
            # recoge la linea de reparto, que es la que abre la muestra.
            m = RE_MALLOC.search(cuerpo)
            if m:
                actual.malloc_pendiente = int(m.group(1))
            m = RE_REPARTO.search(cuerpo)
            if m:
                actual.reparto.append((ms, actual.malloc_pendiente,
                                       int(m.group(1)), int(m.group(2)),
                                       int(m.group(3)), int(m.group(4))))
                actual.malloc_pendiente = None
            m = RE_TEXVIVAS.search(cuerpo)
            if m:
                actual.texturas.append((ms, int(m.group(1)), int(m.group(2)),
                                        int(m.group(3)), int(m.group(4))))
        elif tag == "fondo":
            m = RE_PRESUPUESTO.search(cuerpo)
            if m:
                actual.presupuesto = int(m.group(1))
            m = RE_CENSO.search(cuerpo)
            if m:
                actual.censo = {
                    "fallos": int(m.group(1)),
                    "r16": int(m.group(2)), "p16": int(m.group(3)),
                    "d16": int(m.group(4)),
                    "rp2": int(m.group(5)), "pp2": int(m.group(6)),
                    "dp2": int(m.group(7)),
                }
        elif tag == "boot":
            m = RE_MONTADO.match(cuerpo)
            if m:
                actual.montaje = (ms, m.group(1))
            if RE_INTERPRETE.match(cuerpo):
                actual.interprete_ms = ms
        elif tag == "me":
            actual.eventos.append((ms, cuerpo))
        elif tag == "ritmo":
            r = analiza_ritmo(ms, cuerpo)
            if r:
                actual.ritmo.append(r)
        elif tag == "tiron":
            t = analiza_tiron(ms, cuerpo)
            if t:
                actual.tirones.append(t)
                if t["fondo_mb"] is not None:
                    actual.fondo.append((ms, t["fondo_mb"], t["fondo_tex"]))
        elif tag == "exc":
            if "desc=" in cuerpo:
                m = RE_EXC_CAB.match(cuerpo)
                volcado = {
                    "ms": ms, "tipo": m.group(1) if m else cuerpo,
                    "desc": m.group(2) if m else "", "esr": m.group(3) if m else "",
                    "far": m.group(4) if m else "", "base": None, "pc": None,
                    "rel": None, "lr": None, "sp": None, "regs": {}, "pila": [],
                }
                actual.volcados.append(volcado)
                actual.termino_en_exc = True
            elif volcado is not None:
                m = RE_EXC_BASE.search(cuerpo)
                if m:
                    volcado["base"] = m.group(1)
                    volcado["pc"] = m.group(2)
                    volcado["rel"] = normaliza_hex(m.group(3))
                    volcado["lr"] = normaliza_hex(m.group(4)) if m.group(4) else None
                    volcado["sp"] = m.group(5)
                    # El registro ya trae el desplazamiento, pero se recalcula:
                    # si base y pc no cuadran con el, hay algo raro y se dice.
                    try:
                        cuenta = int(volcado["pc"], 16) - int(volcado["base"], 16)
                        volcado["rel_calculado"] = "0x%x" % cuenta
                    except (TypeError, ValueError):
                        volcado["rel_calculado"] = None
                for reg, valor in RE_EXC_REG.findall(cuerpo):
                    volcado["regs"][reg] = valor
                m = RE_EXC_MARCO.search(cuerpo)
                if m:
                    volcado["pila"].append((int(m.group(1)),
                                            normaliza_hex(m.group(2))))
    return [s for s in sesiones if s.ultimo_ms or s.compilacion]


def analiza_ritmo(ms, cuerpo):
    m = RE_RITMO.match(cuerpo)
    if not m:
        return None
    r = {"ms": ms, "seg": int(m.group(1)), "marcos": int(m.group(2)),
         "fps": int(m.group(3)), "ms_f": float(m.group(4)),
         "lentos": int(m.group(5)), "muy_lentos": int(m.group(6)),
         "peor": int(m.group(7)), "lotes": None, "lote_sprites": None}
    for k, v in RE_RITMO_CAMPO.findall(cuerpo):
        r[k] = float(v)
    m = RE_RITMO_LOTE.search(cuerpo)
    if m:
        r["lotes"], r["lote_sprites"] = int(m.group(1)), int(m.group(2))
    return r


def mediana(valores):
    v = sorted(valores)
    if not v:
        return None
    n = len(v)
    return v[n // 2] if n % 2 else (v[n // 2 - 1] + v[n // 2]) / 2.0


def resume_ritmo(ventanas):
    """Lo que cuentan las `[ritmo]` de una sesion, en una docena de cifras.

    Las ventanas de la pantalla de titulo y de las cargas tambien cuentan: son
    parte de la partida. Pero el «va lento» se juzga con las de juego normal,
    y por eso se da la mediana de `cpu` ademas del maximo: el maximo casi
    siempre es una carga."""
    if not ventanas:
        return None
    cpu = [v["cpu"] for v in ventanas if "cpu" in v]
    comp = [v["comp"] for v in ventanas if "comp" in v]
    swap = [v["swap"] for v in ventanas if "swap" in v]
    con_lote = [v for v in ventanas if v["lotes"]]
    sin_lote = [v for v in ventanas if v["lotes"] == 0 and v["lote_sprites"] == 0]
    return {
        "n": len(ventanas),
        "fps_med": mediana([v["fps"] for v in ventanas]),
        "fps_min": min(v["fps"] for v in ventanas),
        "bajo_58": sum(1 for v in ventanas if v["fps"] < 58),
        "lentos_med": mediana([v["lentos"] for v in ventanas]),
        "muy_lentos_max": max(v["muy_lentos"] for v in ventanas),
        "cpu_med": mediana(cpu), "cpu_max": max(cpu) if cpu else None,
        "comp_med": mediana(comp), "swap_med": mediana(swap),
        "con_lote": len(con_lote), "sin_lote": len(sin_lote),
        "lote_sprites_max": max([v["lote_sprites"] or 0 for v in ventanas]),
    }


def normaliza_hex(txt):
    txt = txt.strip().rstrip(")")
    if not txt.startswith("0x"):
        txt = "0x" + txt
    try:
        return "0x%x" % int(txt, 16)
    except ValueError:
        return txt


def analiza_tiron(ms, cuerpo):
    m = RE_MARCO.search(cuerpo)
    if not m:
        return None
    embudos = dict((n, (int(v), int(t))) for n, v, t in RE_EMBUDO.findall(cuerpo))
    f = RE_FONDO.search(cuerpo)
    r = RE_RESTO.search(cuerpo)
    return {
        "ms": ms,
        "marco": int(m.group(1)),
        "cpu": int(m.group(2)),
        "embudos": embudos,
        "resto": int(r.group(1)) if r else 0,
        "fondo_mb": int(f.group(2)) if f else None,
        "fondo_tex": int(f.group(3)) if (f and f.group(3)) else None,
        "linea": cuerpo,
    }


def es_suspension(t):
    """Consola dormida, no fallo de rendimiento. Las tres reglas de arriba."""
    if t["marco"] >= SUSPENSION_SEGURA_MS:
        return True
    if t["marco"] < SUSPENSION_MS:
        return False
    quieto = t["embudos"].get("comp", (0, 0))[1] + t.get("resto", 0)
    return (t["cpu"] < SUSPENSION_CPU * t["marco"] and
            quieto >= SUSPENSION_PARTE * t["marco"])


def donde_durmio(t):
    """`comp` o `resto`: por cual de los dos cajones se fue el tiempo parado."""
    comp = t["embudos"].get("comp", (0, 0))[1]
    return "comp" if comp >= t.get("resto", 0) else "resto"


def parte_quieta(t):
    """Que tanto por ciento del fotograma se fue en esperar, en numeros redondos."""
    quieto = t["embudos"].get("comp", (0, 0))[1] + t.get("resto", 0)
    return int(round(100.0 * quieto / t["marco"])) if t["marco"] else 0


def dominante(t):
    """El embudo que se llevo mas tiempo, para resumir el tiron en una palabra."""
    if not t["embudos"]:
        return "-"
    nombre = max(t["embudos"], key=lambda k: t["embudos"][k][1])
    return "%s %d ms" % (nombre, t["embudos"][nombre][1])

# ----------------------------------------------------------- otros registros

def analiza_debug(texto):
    """El mkxp-debug.log no lleva marcas de tiempo, pero dice la GPU, el mando
    y lo que costo indexar los recursos —que delata si el jugador tiene el
    contenedor o las carpetas sueltas—."""
    datos = {"gpu": None, "gl": None, "mesa": None, "cache": [], "mando": None,
             "arranques": 0, "avisos": []}
    for linea in texto.splitlines():
        linea = linea.strip()
        if linea.startswith("[nx] mkxp-z arrancando"):
            datos["arranques"] += 1
        elif linea.startswith("GL Renderer"):
            datos["gpu"] = linea.split(":", 1)[1].strip()
        elif linea.startswith("GL Vendor"):
            datos["gl"] = linea.split(":", 1)[1].strip()
        elif linea.startswith("GL Version"):
            datos["mesa"] = linea.split(":", 1)[1].strip()
        elif linea.startswith("[cache] readdir"):
            datos["cache"].append(linea)
        elif linea.startswith("[hid]"):
            datos["mando"] = linea
        elif "Failed" in linea or "WARNING" in linea:
            if linea not in datos["avisos"]:
                datos["avisos"].append(linea)
    return datos


def analiza_ruby(texto):
    """Del lado Ruby interesa cuantas veces arranco el interprete —que tiene que
    cuadrar con las sesiones del boot— y poco mas, y conviene decir por que.

    Esto buscaba una linea `[pila]` y la vendia como «lo mas cerca que los
    registros estan de decir donde estaba el jugador». No lo es: esa linea la
    escribe una sonda de diagnostico que no viaja en el paquete, asi que en el
    registro de un jugador real no aparece nunca. En las quince caidas de los
    dos jugadores del 6 de septiembre no habia ni una. Se sigue mirando, porque
    si alguna vez llega un registro de una compilacion con la sonda es
    informacion de primera, pero el informe ya no promete lo que no hay.

    Lo unico que varia de sesion a sesion en un `mkxp-ruby.log` real son los
    contadores de la memoria de tiras —`[tira] aciertos N fallos M`—, que
    cuentan cuantos Pokemon distintos se llegaron a dibujar. No dicen donde
    estaba el jugador; dicen cuanto juego le dio tiempo a ver."""
    lineas = texto.splitlines()
    arranques = sum(1 for l in lineas if l.startswith("[nx] constantes de Encoding"))
    pilas = [l for l in lineas if l.startswith("[pila]")]
    tiras = [l.strip() for l in lineas if l.startswith("[tira] aciertos")]
    avisos = []
    for l in lineas:
        limpia = re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
        if "WARNING" in limpia and limpia not in avisos:
            avisos.append(limpia)
    return {"arranques": arranques, "ultima_pila": pilas[-1] if pilas else None,
            "pilas": len(pilas), "tiras": tiras, "avisos": avisos,
            "lineas": len(lineas)}


def analiza_errorlog(texto):
    """errorlog.txt solo existe si Ruby lanzo una excepcion que Essentials
    atrapo. Que no exista es, en si mismo, un dato: la muerte fue del proceso,
    no del juego."""
    if texto is None:
        return None
    bloques = []
    actual = None
    for linea in texto.splitlines():
        if re.match(r"^\s*(Excepci|Exception|\[.*\]\s*Excepci)", linea):
            actual = {"cabecera": linea.strip(), "cuerpo": []}
            bloques.append(actual)
        elif actual is not None:
            if linea.strip():
                actual["cuerpo"].append(linea.rstrip())
    if not bloques and texto.strip():
        bloques.append({"cabecera": "(sin cabecera reconocible)",
                        "cuerpo": texto.strip().splitlines()})
    return bloques

# ------------------------------------------------------------- compilaciones

def estado_de_arreglos(comp):
    """Dice, arreglo por arreglo, si esa compilacion lo lleva. La regla es la
    fecha de la compilacion contra la fecha en que el arreglo entro en main, y
    por encima de eso la lista de publicaciones que se sabe que no lo llevan
    —una publicacion se corta de una rama y puede ser posterior sin llevarlo—."""
    salida = []
    for a in ARREGLOS:
        if comp is None:
            estado, porque = "se desconoce", "no hay linea [build] en el registro"
        elif comp["version"] in a["sin_el"]:
            estado = "NO"
            porque = "la publicación %s no lo lleva" % comp["version"]
        elif comp["fecha"] >= a["en_main"]:
            estado = "probablemente si"
            porque = ("compilada el %s, y el arreglo esta en main desde el %s"
                      % (fecha_es(comp["fecha"]), fecha_es(a["en_main"])))
        else:
            estado = "NO"
            porque = ("compilada el %s, antes de que el arreglo entrara en main "
                      "el %s" % (fecha_es(comp["fecha"]), fecha_es(a["en_main"])))
        salida.append((a, estado, porque))
    return salida


MESES = ["enero", "febrero", "marzo", "abril", "mayo", "junio", "julio",
         "agosto", "septiembre", "octubre", "noviembre", "diciembre"]


def fecha_es(d):
    return "%d de %s" % (d.day, MESES[d.month - 1])


def mil(n):
    """Miles con punto, como se escriben en castellano: 2.582.178."""
    return "{:,}".format(int(n)).replace(",", ".")


def duracion(ms):
    seg = ms / 1000.0
    if seg < 90:
        return "%.0f s" % seg
    minutos = int(seg // 60)
    resto = int(seg - minutos * 60)
    if minutos < 60:
        return "%d min %02d s" % (minutos, resto)
    return "%d h %02d min" % (minutos // 60, minutos % 60)

# --------------------------------------------------------------- las series

def serie(valores):
    """Minimo, maximo y si sube sin bajar nunca. Lo tercero es lo que importa:
    una serie monotona creciente de picos del monton es una fuga; una serie que
    sube y baja es un juego que reserva y suelta, que es lo que debe hacer."""
    if not valores:
        return None
    creciente = all(b >= a for a, b in zip(valores, valores[1:]))
    saltos = [b - a for a, b in zip(valores, valores[1:])]
    return {
        "n": len(valores), "min": min(valores), "max": max(valores),
        "primero": valores[0], "ultimo": valores[-1],
        "monotona": creciente,
        "subida": valores[-1] - valores[0],
        "mayor_salto": max(saltos) if saltos else 0,
    }

# ------------------------------------------- comparacion con lo ya archivado

def indice_del_archivo(excluir=()):
    """Recorre docs/consola/ y saca de cada caso su compilacion y los
    desplazamientos de sus volcados. Es barato —solo se lee el boot.log— y es
    lo que permite decir «esto es lo mismo que el Pidgey de la ruta 1»."""
    casos = []
    if not os.path.isdir(ARCHIVO):
        return casos
    for nombre in sorted(os.listdir(ARCHIVO)):
        carpeta = os.path.join(ARCHIVO, nombre)
        if not os.path.isdir(carpeta) or os.path.abspath(carpeta) in excluir:
            continue
        boot = os.path.join(carpeta, "mkxp-boot.log")
        if not os.path.isfile(boot):
            continue
        try:
            sesiones = analiza_boot(lee(boot))
        except Exception:
            continue
        comp = next((s.compilacion for s in sesiones if s.compilacion), None)
        # Un registro de desarrollo mezcla compilaciones —se prueba una, se
        # recompila, se prueba otra— y un desplazamiento solo significa algo
        # junto a la compilacion de SU sesion. Quedarse con el primer [build]
        # del fichero hacia que un volcado de la b45 se comparase como si fuera
        # de la b14, y el informe lo despachaba como coincidencia casual.
        rels = []
        vigente = comp
        for s in sesiones:
            if s.compilacion:
                vigente = s.compilacion
            for v in s.volcados:
                if v["rel"]:
                    rels.append((v["rel"], v["far"], vigente))
        casos.append({
            "nombre": nombre, "carpeta": carpeta, "compilacion": comp,
            "volcados": rels, "titulo": titulo_de(carpeta),
        })
    return casos


def titulo_de(carpeta):
    """Si el caso tiene analisis escrito, su primer encabezado es su nombre."""
    for cand in ("analisis.md", "analisis-automatico.md"):
        camino = os.path.join(carpeta, cand)
        if os.path.isfile(camino):
            for linea in lee(camino).splitlines():
                if linea.startswith("# "):
                    return linea[2:].strip()
    return None

# ------------------------------------------------------ PUNTO DE ENGANCHE

def resolver_simbolos(compilacion, desplazamientos):
    """PUNTO DE ENGANCHE para la herramienta de simbolos (la escribe otro).

    Aqui entra la herramienta que, dado el `.elf` archivado de una compilacion,
    convierte un desplazamiento relativo —`+0x7abd30`— en nombre de funcion y
    linea de fichero. Esta separada a proposito: necesita el binario de esa
    compilacion concreta y `addr2line` del toolchain, que no siempre estan, y
    el triaje tiene que funcionar igual sin ellos.

    El contrato:
        compilacion      dict con "version" ('1.0.0'), "b" (14) y "fecha";
                         None si el registro no traia linea [build].
        desplazamientos  lista de cadenas hex, '0x7abd30', en el orden en que
                         aparecen (pc primero, luego los marcos de la pila).
        devuelve         (nombres, modo). `nombres` es un dict
                         {desplazamiento: 'nombre_de_funcion  fichero:linea'}
                         con lo que haya sabido resolver; `modo` es None si se
                         resolvio con el `.elf` de esa misma compilacion —los
                         nombres son ciertos— y, si no, la frase que explica de
                         donde salen y por que son candidatos. (None, None) si
                         no se puede resolver nada.

    Hoy lo cumple `resolver-pila.py`, que vive al lado y busca el `.elf` en
    release/simbolos/<version>-b<n>/. Si de esa compilacion se archivo el
    `.elf`, los nombres salen de `addr2line` y son ciertos. Si no —el caso de
    la b14 y la b46, cuyos `.elf` se perdieron—, se degrada al metodo del
    Pidgey: desensamblar el `.nro` archivado y buscar cada firma de diez
    instrucciones en un `.elf` que si tenga simbolos. Eso da candidatos, no
    certezas, y el informe lo dice con esas palabras.
    """
    if not desplazamientos or compilacion is None:
        return None, None
    try:
        return _por_resolver_pila(compilacion, desplazamientos)
    except Exception as e:           # nunca tumbar el triaje por el resolutor
        sys.stderr.write("aviso: el resolutor de simbolos fallo: %s\n" % e)
        return None, None


def _por_resolver_pila(compilacion, desplazamientos):
    """La implementacion de hoy: resolver-pila.py, que vive al lado.

    Se carga por camino porque su nombre lleva guion y no se puede importar
    como modulo. Si no esta, si no hay .elf archivado de esa compilacion, o si
    cambia de forma por dentro, devuelve None y el informe sigue diciendo como
    resolver la pila a mano: el triaje no depende de ello."""
    import importlib.util

    camino = os.path.join(RAIZ, "resolver-pila.py")
    if not os.path.isfile(camino):
        return None, None
    spec = importlib.util.spec_from_file_location("resolver_pila", camino)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    sello = "%s b%d" % (compilacion["version"], compilacion["b"])
    archivada = mod.buscar(sello)
    if not archivada:
        return None, None
    if archivada.get("elf"):
        numeros = [int(d, 16) for d in desplazamientos]
        nombres = _nombres_addr2line(mod, archivada["elf"], numeros)
        if not nombres:
            return None, None
        salida = {}
        for desplazamiento, (nombre, fichero) in zip(desplazamientos, nombres):
            if nombre and nombre != "??":
                # Sin `-g` no hay lineas y addr2line contesta '??:?' o ':?': eso
                # no es informacion, es ruido al lado del nombre.
                hay_fichero = fichero and "?" not in fichero
                salida[desplazamiento] = ("%s  %s" % (nombre, fichero)
                                          if hay_fichero else nombre)
        return (salida or None), None
    return _por_firmas(mod, archivada, compilacion, desplazamientos)


def _nombres_addr2line(mod, elf, direcciones):
    """addr2line en bloque, sin `-i`, emparejando en estricto de dos en dos.

    `resolver-pila.py` tiene su propio `por_addr2line()`, pero pasa `-i` para
    ver las funciones que el compilador metio en linea, y con `-i` una sola
    direccion puede contestar tres pares nombre/fichero en lugar de uno. Al
    llamarlo con veinticinco direcciones de golpe, el primer marco con codigo
    en linea corre todo lo que viene detras y cada marco sale con el nombre del
    siguiente: nombres equivocados, que son peor que ningun nombre. Sin `-i`
    cada direccion contesta exactamente un par —el de la funcion mas interna,
    que es la que resolver-pila.py tambien ensena— y las cuentas cuadran.
    """
    a2l = mod.herramienta("addr2line")
    if not a2l:
        return None
    salida = mod.correr([a2l, "-f", "-C", "-e", elf]
                        + ["0x%x" % d for d in direcciones]).splitlines()
    nombres = []
    for i in range(len(direcciones)):
        nombres.append((salida[2 * i] if 2 * i < len(salida) else "??",
                        salida[2 * i + 1] if 2 * i + 1 < len(salida) else "??:?"))
    return nombres


def _por_firmas(mod, archivada, compilacion, desplazamientos, huella=10):
    """El camino degradado: sin `.elf` de esa compilacion, pero con su `.nro`.

    El `.nro` no tiene simbolos, pero si instrucciones, y el enlazador deja el
    desplazamiento del volcado valiendo a la vez como offset dentro del fichero.
    Se toman las diez instrucciones que empiezan en cada marco y se buscan tal
    cual en el `.text` de otra compilacion que si conserve simbolos: si
    aparecen byte a byte —codificaciones relativas de los saltos incluidas— es
    la misma funcion compilada igual y su nombre de alli vale aqui. Es lo que
    se hizo a mano con el Pidgey.

    `resolver-pila.py` ya sabe hacerlo con `candidatos_por_firma()`, pero
    extrayendo el `.text` de noventa megas una vez por direccion; para una pila
    de veinticinco marcos eso es un minuto largo. Aqui se extrae una sola vez y
    se buscan todas las firmas sobre el mismo bloque, reutilizando sus piezas.
    """
    nro = archivada.get("nro") or mod.nro_de_entrega(compilacion["version"])
    if not nro or not os.path.isfile(nro):
        return None, None

    # La referencia: cualquier compilacion archivada con `.elf` que no sea esta.
    # Se prefiere la de la misma version, que es la que menos habra movido el
    # codigo; a falta de ella, la mas reciente que haya.
    conelf = [d for d in mod.archivos()
              if d.get("elf") and d["nombre"] != archivada["nombre"]]
    if not conelf:
        return None, None
    misma = [d for d in conelf
             if d["nombre"].startswith(compilacion["version"] + "-")]
    ref = (misma or conelf)[0]

    objcopy = mod.herramienta("objcopy")
    a2l = mod.herramienta("addr2line")
    if not objcopy or not a2l:
        return None, None
    tmp = os.path.join(RAIZ, "tmp", "triaje.text.bin")
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    mod.correr([objcopy, "-O", "binary", "--only-section=.text",
                ref["elf"], tmp])
    if not os.path.isfile(tmp):
        return None, None
    try:
        with open(tmp, "rb") as f:
            texto = f.read()
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass

    donde = {}
    for d in desplazamientos:
        firma = mod.palabras(nro, int(d, 16), huella)
        if len(firma) < huella:
            continue
        patron = b"".join(w.to_bytes(4, "little") for w in firma)
        i = texto.find(patron)
        if i < 0:
            continue
        # La misma secuencia dos veces no identifica nada: hay dos funciones
        # que empiezan igual y no se sabe cual es. Callarse es lo honrado.
        if texto.find(patron, i + 4) >= 0:
            continue
        donde[d] = i

    if not donde:
        return None, None
    claves = list(donde)
    resueltos = _nombres_addr2line(mod, ref["elf"], [donde[k] for k in claves])
    if not resueltos:
        return None, None
    salida = {}
    for clave, (nombre, _fichero) in zip(claves, resueltos):
        if nombre and nombre != "??":
            salida[clave] = "%s  (%s +0x%x)" % (nombre, ref["nombre"],
                                                donde[clave])
    modo = ("por firma de instrucciones contra `%s`, porque el `.elf` de %s "
            "se perdió. Son **candidatos**: valen mientras la función no haya "
            "cambiado entre las dos compilaciones, y los marcos que sí "
            "cambiaron salen sin nombre —que es, en sí mismo, un dato—"
            % (ref["sello"], "%s b%d" % (compilacion["version"],
                                         compilacion["b"])))
    return (salida or None), modo

# ---------------------------------------------------------------- veredicto

def agrupa_volcados(sesiones):
    """Agrupa por desplazamiento relativo. Dentro de un grupo se mira si la
    pila es la misma: mismo pc con la misma pila es el mismo camino de codigo;
    mismo pc con pilas distintas es el mismo sitio alcanzado por dos caminos."""
    grupos = {}
    for i, s in enumerate(sesiones):
        for v in s.volcados:
            v["sesion"] = i + 1
            # De que compilacion es ESTE volcado. Un mkxp-boot.log no se trunca
            # y acumula sesiones de varias compilaciones, asi que "hay dos
            # caidas" no dice nada mientras no se sepa si son de la que se esta
            # jugando o de una de hace tres dias que ya se arreglo.
            v["sello"] = ("%s b%d" % (s.compilacion["version"], s.compilacion["b"])
                          if s.compilacion else None)
            grupos.setdefault(v["rel"], []).append(v)
    salida = []
    for rel, vs in sorted(grupos.items(), key=lambda kv: -len(kv[1])):
        listas = [tuple(x[1] for x in v["pila"]) for v in vs]
        pilas = set(listas)
        # Cuantos marcos de arriba coinciden. Dos caidas en el mismo sitio
        # suelen compartir los marcos nativos y separarse mas abajo, donde
        # empieza el interprete de Ruby: ahi es donde se ve que el codigo que
        # se rompe es el mismo aunque quien lo llamo sea otro.
        comun = 0
        while all(len(l) > comun and l[comun] == listas[0][comun] for l in listas):
            comun += 1
        comunes, distintos = {}, []
        todos = [v["regs"] for v in vs]
        for reg in sorted(set(r for regs in todos for r in regs),
                          key=lambda r: int(r[1:])):
            valores = set(regs.get(reg) for regs in todos)
            if len(valores) == 1:
                comunes[reg] = valores.pop()
            else:
                distintos.append(reg)
        salida.append({
            "rel": rel, "volcados": vs, "n": len(vs),
            "sellos": sorted(set(v["sello"] for v in vs if v["sello"])),
            "mismo_camino": len(pilas) == 1, "pilas": len(pilas),
            "marcos_comunes": comun,
            "regs_comunes": comunes, "regs_distintos": distintos,
        })
    return salida


def firma_564(grupo):
    """La firma de §5.64: fallo de acceso a datos leyendo a catorce bytes de un
    puntero nulo. `far=0xe` y un registro base a cero es todo lo que hace
    falta; el resto lo confirma la pila cuando haya con que resolverla."""
    v = grupo["volcados"][0]
    if normaliza_hex(v["far"] or "0x0") != "0xe":
        return False
    if not (v["esr"] or "").startswith("0x9200"):
        return False
    return any(valor == "0x0" for valor in v["regs"].values())


def veredicto(datos):
    """Una frase de titular, y luego lo que procede hacer."""
    grupos = datos["grupos"]
    comp = datos["compilacion"]
    arreglos = dict((a["clave"], (e, p)) for a, e, p in datos["arreglos"])
    lineas, acciones = [], []

    if not grupos:
        lineas.append("**No hay volcado de excepción nativa.** El proceso no "
                      "murió por un fallo de acceso: o terminó bien, o lo que "
                      "fallo esta del lado de Ruby.")
    else:
        con_firma = [g for g in grupos if firma_564(g)]
        if con_firma:
            g = con_firma[0]
            falta = arreglos.get("guardian-5.64", ("", ""))[0] == "NO"
            lineas.append(
                "**Es §5.64**: %d volcado%s con `far=0xe` —una lectura a "
                "catorce bytes de un puntero nulo— en `+%s`. Es la textura que "
                "Mesa cuelga del FBO sin recurso detrás cuando `glTexImage2D` "
                "se queda sin memoria de vídeo."
                % (g["n"], "s" if g["n"] > 1 else "", g["rel"]))
            if falta:
                lineas.append(
                    "La compilación del jugador **no lleva el guardián**, así "
                    "que esta muerte era inevitable: sin él, quedarse sin "
                    "memoria de vídeo mata el proceso sin decir nada.")
                acciones.append(
                    "**Publicar el arreglo.** El guardián de §5.64 convierte "
                    "esta muerte en «se sueltan trescientos megas y se sigue "
                    "jugando». Mientras no salga la publicación que lo lleve, "
                    "cada jugador que se quede sin memoria de vídeo vuelve al "
                    "menú de la consola.")
            else:
                lineas.append(
                    "Pero la compilación **sí debería llevar el guardián**, y "
                    "aun así murió ahi. Eso es nuevo y merece mirarse: o el "
                    "guardián no cubre este camino, o el fallo entró por otro "
                    "sitio.")
                acciones.append(
                    "**Revisar el guardián de §5.64**, porque esta caída "
                    "ocurrio con una compilación que lo lleva.")
        else:
            g = grupos[0]
            lineas.append(
                "**Caída nativa sin firma conocida** en `+%s` (`far=%s`, "
                "`esr=%s`). No coincide con §5.64; hace falta resolver la pila "
                "para saber dónde estaba."
                % (g["rel"], g["volcados"][0]["far"], g["volcados"][0]["esr"]))
            acciones.append(
                "**Resolver la pila** con el `.elf` de la compilación %s, que "
                "es lo único que va a decir que código es ese."
                % (comp["version"] + " b%d" % comp["b"] if comp else "de este caso"))

    fondo = datos["serie_fondo"]
    # Lo que se juzga es el fondo en el instante del fallo, no el de toda la
    # partida: el rango global arrastra la rampa del arranque y hace parecer
    # que el fondo estaba holgado cuando la memoria de video se agoto.
    alcaer = [x["ultimo"] for x in datos["fondo_al_caer"]
              if x["ultimo"] is not None]
    if alcaer and max(alcaer) >= 480:
        acciones.append(
            "**Mirar el techo del fondo de texturas**: en la última medida "
            "antes de caerse llegó a %d MB, que roza el presupuesto de 512 MB "
            "de §5.53. Ahí no falta memoria por una fuga: falta porque el "
            "presupuesto es el que es." % max(alcaer))
    elif alcaer and grupos and any(firma_564(g) for g in grupos):
        acciones.append(
            "**Bajar el presupuesto inicial del fondo.** La memoria de vídeo se "
            "agotó con el fondo entre %d y %d MB en las últimas medidas antes "
            "de cada caída, por debajo de los 512 MB que el presupuesto supone: "
            "el techo real de esta consola está más bajo."
            % (min(alcaer), max(alcaer)))
    elif fondo and fondo["max"] >= 480:
        acciones.append(
            "**Mirar el techo del fondo de texturas**: llegó a %d MB, que roza "
            "el presupuesto de 512 MB de §5.53." % fondo["max"])

    monton = datos["serie_monton"]
    porsesion = [x for x in datos["monton_por_sesion"] if x and x["n"] >= 3]
    if monton and porsesion and all(x["monotona"] for x in porsesion):
        acciones.append(
            "**Mirar el crecimiento del montón**, que sube de %d a %d MB sin "
            "bajar nunca dentro de una sesión, en %s de juego. Es un problema "
            "distinto del de la "
            "memoria de vídeo y está sin diagnosticar."
            % (monton["min"], monton["max"], datos["duracion_total"]))

    if datos["errorlog"]:
        lineas.append("Además hay excepción de Ruby en `errorlog.txt`, que se "
                      "detalla más abajo.")

    if comp and not any(c["nombre"] == "" for c in []):
        acciones.append(
            "**Archivar el `.elf` de cada publicación.** Sin él, resolver la "
            "pila de un jugador depende de que la función no haya cambiado "
            "entre su compilación y una que conserve símbolos.")
    return lineas, acciones

# ----------------------------------------------------------------- informe

def bloque(lineas):
    return "\n".join(lineas)


def escribe_informe(datos, titulo, relato):
    p = []
    a = p.append
    comp = datos["compilacion"]
    ses = datos["sesiones"]

    a("# %s" % titulo)
    a("")
    a("Registros de un jugador, %s. Informe generado por `triaje.py`; el "
      "veredicto y las acciones son propuestas que hay que leer con criterio."
      % fecha_es(datos["fecha"]))
    a("")
    if relato:
        a("Lo que contó: %s" % relato)
        a("")

    # --- 1. lo que dicen los registros -----------------------------------
    a("## Lo que dicen los registros")
    a("")
    if comp:
        a("Motor **%s b%d**, compilado el %s%s."
          % (comp["version"], comp["b"], fecha_es(comp["fecha"]),
             " a las " + comp["hora"] if comp["hora"] else ""))
        if len(datos["sellos_del_registro"]) > 1:
            a("")
            a("**Ojo: el registro mezcla compilaciones** (%s). Cada volcado "
              "hay que leerlo con la compilación de su propia sesión; los "
              "desplazamientos de dos compilaciones distintas no son "
              "comparables entre sí."
              % ", ".join(datos["sellos_del_registro"]))
    else:
        a("El registro **no trae linea `[build]`**: no se sabe con que "
          "compilación jugaba. Sin eso no se puede resolver ninguna pila.")
    a("")
    if datos["memoria"]:
        m = datos["memoria"]
        a("Lanzado como homebrew con memoria de aplicación: %s MB en total, "
          "%s MB de montón." % (mil(m["total"]), mil(m["monton"])))
    d = datos["debug"]
    if d and d["gpu"]:
        a("GPU `%s %s`, %s." % (d["gl"] or "", d["gpu"], d["mesa"] or ""))
    if d and d["cache"]:
        entradas = d["cache"][0]
        a("Recursos: `%s`. %s" % (entradas,
          "Carpetas sueltas, no el contenedor."
          if re.search(r"(\d[\d.]{3,}) entradas", entradas) else ""))
    if datos["reloj"]:
        a("Reloj de la consola: `%s`." % datos["reloj"])
    a("")
    if datos["descartados"]:
        a("Se dejaron fuera %d fichero%s que estaban en el árbol pero **no en "
          "la carpeta del `mkxp-boot.log`**: `%s`. Si son de otro jugador, "
          "tienen su propio caso; mezclarlos aquí daría un informe de un "
          "jugador que no existe."
          % (len(datos["descartados"]), "s" if len(datos["descartados"]) > 1
             else "", "`, `".join(os.path.basename(c)
                                  for c in datos["descartados"])))
        a("")
    a("**%d %s** en el registro%s."
      % (len(ses), "sesiones" if len(ses) != 1 else "sesión",
         ", %d de ellas terminadas en volcado" % datos["sesiones_con_exc"]
         if datos["sesiones_con_exc"] else ", ninguna terminada en volcado"))
    a("")
    a("| sesión | duración | tirones | picos del montón | fondo max | final |")
    a("|---|---|---|---|---|---|")
    for i, s in enumerate(ses):
        fondo = max([f[1] for f in s.fondo]) if s.fondo else None
        picos = "%d-%d MB" % (s.picos[0][1], s.picos[-1][1]) if s.picos else "-"
        a("| %d | %s | %d | %s | %s | %s |"
          % (i + 1, duracion(s.ultimo_ms), len(s.tirones), picos,
             "%d MB" % fondo if fondo is not None else "-",
             "caída (`[exc]`)" if s.termino_en_exc else "sin volcado"))
    a("")

    # --- la compilacion y los arreglos -----------------------------------
    a("### Qué arreglos lleva esa compilación")
    a("")
    for arr, estado, porque in datos["arreglos"]:
        a("* **%s** (%s): **%s** — %s."
          % (arr["nombre"], arr["que_hace"], estado, porque))
    a("")

    # --- 2. los volcados --------------------------------------------------
    a("## Los volcados")
    a("")
    if not datos["grupos"]:
        a("No hay ninguno. El proceso no murió por un fallo de acceso a "
          "memoria; si el jugador vio cerrarse el juego, la causa esta en otro "
          "sitio (mirar `errorlog.txt` y el final de `mkxp-ruby.log`).")
        a("")
    for g in datos["grupos"]:
        v = g["volcados"][0]
        a("### `+%s` — %d volcado%s" % (g["rel"], g["n"],
                                        "s" if g["n"] > 1 else ""))
        a("")
        a("```")
        a("[exc] %s desc=%s esr=%s far=%s" % (v["tipo"], v["desc"], v["esr"],
                                              v["far"]))
        a("[exc] base=%s pc=%s (+%s)" % (v["base"], v["pc"], g["rel"]))
        a("```")
        a("")
        a("El **desplazamiento relativo** —`pc` menos `base`— es `+%s`. Es lo "
          "único comparable entre ejecuciones: la base cambia en cada "
          "arranque%s." % (g["rel"],
          "" if v.get("rel_calculado") in (None, g["rel"])
          else ", y ojo: la cuenta da `%s`, que no es lo que dice el registro"
               % v["rel_calculado"]))
        a("")
        if g["n"] > 1:
            cuando = ", ".join("sesión %d a los %s" % (x["sesion"],
                                                       duracion(x["ms"]))
                               for x in g["volcados"])
            a("Se repite: %s." % cuando)
            if g["mismo_camino"]:
                a("La pila es **idéntica** en los %d: es el mismo camino de "
                  "código, no corrupción aleatoria." % g["n"])
            elif g["marcos_comunes"]:
                a("Los **%d marcos más recientes son idénticos** (`#0` a `#%d`) "
                  "y las pilas se separan a partir de `#%d`: el código que se "
                  "rompe es el mismo las %d veces; lo que cambia es quién lo "
                  "llamó, más abajo, ya dentro del intérprete de Ruby."
                  % (g["marcos_comunes"], g["marcos_comunes"] - 1,
                     g["marcos_comunes"], g["n"]))
            else:
                a("Mismo `pc` pero **%d pilas distintas** desde el primer "
                  "marco: al mismo sitio se llega por caminos diferentes."
                  % g["pilas"])
            if g["regs_distintos"]:
                a("Los registros coinciden salvo `%s`."
                  % "`, `".join(g["regs_distintos"]))
            else:
                a("Todos los registros coinciden.")
            a("")
        nulos = sorted([r for r, val in g["regs_comunes"].items() if val == "0x0"],
                       key=lambda r: int(r[1:]))
        if nulos:
            a("Registros a cero en todos los volcados: `%s`. Con `far=%s`, la "
              "lectura fue a %d bytes de un puntero nulo."
              % ("`, `".join(nulos), v["far"], int(v["far"], 16)
                 if (v["far"] or "").startswith("0x") else 0))
            a("")
        if v["pila"]:
            a("Pila (desplazamientos relativos, del más reciente al más viejo):")
            a("")
            a("```")
            for n, off in v["pila"]:
                nombre = datos["simbolos"].get(off) if datos["simbolos"] else None
                a("#%-3d +%s%s" % (n, off, "  " + nombre if nombre else ""))
            a("```")
            a("")

    # --- 3. resolver la pila (el enganche) -------------------------------
    if datos["grupos"]:
        a("## Cómo resolver la pila")
        a("")
        if datos["simbolos"] and not datos["simbolos_modo"]:
            a("Resuelta con el `.elf` archivado de esta compilación; los "
              "nombres van arriba, junto a cada marco.")
        elif datos["simbolos"]:
            a("Resuelta %s" % datos["simbolos_modo"] + ".")
            a("")
            a("Los nombres van arriba, junto a cada marco. Para verlos con la "
              "instrucción exacta que falló:")
            a("")
            a("```")
            a("python resolver-pila.py --sello \"%s\" --dis 6 \\"
              % ("%s b%d" % (comp["version"], comp["b"]) if comp else "<version> b<n>"))
            a("      docs/consola/%s/mkxp-boot.log" % datos["etiqueta_carpeta"])
            a("```")
        else:
            a("**Sin resolver.** Aquí entra la herramienta de símbolos, que "
              "convierte cada `+0x...` en nombre de función con el `.elf` "
              "archivado de esa compilación. `triaje.py` la llama sola en "
              "`resolver_simbolos()`, y si esta sección sale vacía es que no "
              "había `.elf` de esa compilación, o que no encontró el "
              "`addr2line` de devkitA64 (en PowerShell, con `DEVKITPRO` "
              "apuntando a la instalación).")
            a("")
            a("A mano:")
            a("")
            a("```")
            a("python resolver-pila.py --sello \"%s\" --dis 6 \\"
              % ("%s b%d" % (comp["version"], comp["b"]) if comp else "<version> b<n>"))
            a("      docs/consola/%s/mkxp-boot.log" % datos["etiqueta_carpeta"])
            a("")
            a("# o directamente sobre el .nro publicado:")
            a("aarch64-none-elf-objdump -D -b binary -m aarch64 \\")
            a("      --start-address=%s release/anil-switch-%s/pokemon-anil.nro"
              % (datos["grupos"][0]["rel"],
                 comp["version"] if comp else "<versión>"))
            a("```")
        a("")

    # --- 4. las series ----------------------------------------------------
    a("## Memoria, a lo largo de la partida")
    a("")
    f = datos["serie_fondo"]
    reg = datos["fondo_regimen"]
    if f:
        a("**Fondo de texturas** (%d medidas, de `[tiron]`): entre **%d y %d "
          "MB**%s." % (f["n"], f["min"], f["max"],
                       ", subiendo sin bajar nunca" if f["monotona"]
                       else ", subiendo y bajando"))
        if reg and reg["min"] > f["min"]:
            a("")
            a("Quitada la rampa del arranque, el fondo se mueve entre **%d y "
              "%d MB** con el juego ya en marcha." % (reg["min"], reg["max"]))
        if f["monotona"]:
            a("")
            a("Que suba sin techo es la señal del contador de 16 bits de "
              "§5.64 dándose la vuelta.")
        else:
            a("")
            a("Que suba y baje dice que el fondo está reciclando: el contador "
              "de 16 bits **no** parece estar implicado.")
        if datos["fondo_texturas"]:
            a("")
            a("Texturas contadas: %s. (Las compilaciones anteriores al 4 de "
              "septiembre solo escribian los megas.)" % datos["fondo_texturas"])
        a("")
        if datos["fondo_al_caer"]:
            a("Pero el rango de toda la partida mezcla la rampa del arranque "
              "con el instante del fallo. **El número que decide si se tocó el "
              "techo es el de la última medida antes de cada caída**:")
            a("")
            a("| caída | momento | fondo en la última medida | máximo de esa sesión |")
            a("|---|---|---|---|")
            for x in datos["fondo_al_caer"]:
                a("| sesión %d | %s | %s | %s |"
                  % (x["sesion"], duracion(x["ms"]),
                     "%d MB" % x["ultimo"] if x["ultimo"] is not None else "-",
                     "%d MB" % x["max"] if x["max"] is not None else "-"))
            a("")
    else:
        a("No hay medidas del fondo de texturas: no hubo tirones que las "
          "escribieran.")
        a("")

    m = datos["serie_monton"]
    if m:
        a("**Picos del montón**, en orden:")
        a("")
        a("```")
        for i, s in enumerate(ses):
            if s.picos:
                a("sesión %d   %s MB" % (i + 1,
                  "  ".join(str(p[1]) for p in s.picos)))
        a("```")
        a("")
        porsesion = [x for x in datos["monton_por_sesion"] if x and x["n"] >= 3]
        todas_monotonas = bool(porsesion) and all(x["monotona"] for x in porsesion)
        a("De %d a %d MB, con entre %d y %d MB libres en el montón."
          % (m["min"], m["max"], datos["libre_min"], datos["libre_max"]))
        if todas_monotonas:
            a("")
            a("**Monótono dentro de cada sesión**: sube y no baja nunca. Un "
              "montón que solo crece es una fuga; %s MB en %s de juego."
              % (mil(m["max"]), datos["duracion_total"]))
        else:
            a("")
            a("Sube y baja, así que el montón se esta devolviendo: no hay "
              "señal de fuga en estos números.")
        a("")

    # --- 5. tirones -------------------------------------------------------
    a("## Tirones")
    a("")
    if datos["suspensiones"]:
        for t in datos["suspensiones"]:
            a("`[tiron] marco %s ms` con la CPU parada (%d ms) y el %d %% del "
              "fotograma esperando, casi todo en `%s`: **no es un tirón**, son "
              "%s de consola dormida."
              % (mil(t["marco"]), t["cpu"], parte_quieta(t), donde_durmio(t),
                 duracion(t["marco"])))
        a("")
    reales = datos["tirones_reales"]
    if reales:
        a("Quedan **%d tirones de verdad**, el mayor de %d ms. Los diez "
          "peores:" % (len(reales), reales[0]["marco"]))
        a("")
        a("| momento | marco | cpu | embudo dominante | fondo |")
        a("|---|---|---|---|---|")
        for t in reales[:10]:
            a("| %s | %d ms | %d ms | %s | %s |"
              % (duracion(t["ms"]), t["marco"], t["cpu"], dominante(t),
                 "%d MB" % t["fondo_mb"] if t["fondo_mb"] is not None else "-"))
        a("")
    else:
        a("Ninguno por encima del umbral, quitadas las suspensiones.")
        a("")

    # --- 5-bis. el ritmo ---------------------------------------------------
    con_ritmo = [(i, s, resume_ritmo(s.ritmo)) for i, s in enumerate(ses) if s.ritmo]
    if con_ritmo:
        a("## El fotograma normal (`[ritmo]`)")
        a("")
        a("Una línea cada 15 s con la media de la ventana. `cpu` es el tiempo "
          "de procesador del hilo de Ruby por fotograma: por encima de 16,7 ms "
          "el que no llega al refresco es el procesador; si es pequeño y "
          "`swap` grande, la GPU. `comp` es dibujar la escena y `lote`, los "
          "dibujos del lote de sprites (0 con `sin-lote.txt`).")
        a("")
        a("| sesión | ventanas | fps (mediana / peor) | <58 fps | >17 ms | cpu (mediana / max) | comp | swap | lote |")
        a("|---|---|---|---|---|---|---|---|---|")
        for i, s, r in con_ritmo:
            if r["con_lote"] and r["sin_lote"]:
                lote = "%d con, %d sin" % (r["con_lote"], r["sin_lote"])
            elif r["con_lote"]:
                lote = "sí (hasta %d sprites/f)" % r["lote_sprites_max"]
            elif r["sin_lote"]:
                lote = "apagado"
            else:
                lote = "-"
            a("| %d | %d | %d / %d | %d | %d %% | %.1f / %.1f ms | %.1f ms | %.1f ms | %s |"
              % (i + 1, r["n"], r["fps_med"], r["fps_min"], r["bajo_58"],
                 r["lentos_med"], r["cpu_med"] or 0, r["cpu_max"] or 0,
                 r["comp_med"] or 0, r["swap_med"] or 0, lote))
        a("")
        _i, _s, r = con_ritmo[-1]
        if r["cpu_med"] is not None and r["cpu_med"] > 16.7:
            a("En la última sesión la mediana de `cpu` pasa de 16,7 ms: el juego "
              "va a menos de 60 por el procesador, no por la GPU.")
        elif r["swap_med"] is not None and r["swap_med"] > 8:
            a("En la última sesión `cpu` cabe en el fotograma pero `swap` es "
              "grande: lo que no llega es la GPU.")
        elif r["bajo_58"] == 0:
            a("En la última sesión todas las ventanas van a 58 fps o más.")
        else:
            a("En la última sesión %d de %d ventanas bajan de 58 fps con `cpu` "
              "por debajo del fotograma: mirar las `[tiron]` de esos momentos "
              "(cargas, cambios de mapa) antes de hablar de lentitud general."
              % (r["bajo_58"], r["n"]))
        a("")

    # --- 6. la partida ----------------------------------------------------
    a("## La partida")
    a("")
    a("%d %s, %s en total jugados."
      % (len(ses), "sesiones" if len(ses) != 1 else "sesión",
         datos["duracion_total"]))
    for i, s in enumerate(ses):
        cola = ""
        if s.termino_en_exc:
            cola = " y terminó en caída"
        a("")
        a("* **Sesión %d**: %s%s." % (i + 1, duracion(s.ultimo_ms), cola))
        susp = [t for t in s.tirones if es_suspension(t)]
        if susp:
            a("  Con %s de consola suspendida por medio, así que el juego de "
              "verdad fueron unos %s."
              % (duracion(sum(t["marco"] for t in susp)),
                 duracion(s.ultimo_ms - sum(t["marco"] for t in susp))))
    a("")
    r = datos["ruby"]
    if r:
        a("El lado Ruby arrancó %d %s, que %s con las sesiones del "
          "registro de arranque."
          % (r["arranques"], "veces" if r["arranques"] != 1 else "vez",
             "cuadra" if r["arranques"] == len(ses) else "**no cuadra**"))
        if r["ultima_pila"]:
            a("")
            a("Esta compilación llevaba la sonda que anota la pila de Ruby, "
              "que no viaja en el paquete y por eso casi nunca aparece. La "
              "última que dejó escrita:")
            a("")
            a("```")
            a(r["ultima_pila"][:600])
            a("```")
        elif r["tiras"]:
            a("")
            a("Lo único que varía de una sesión a otra en el registro de Ruby "
              "son los contadores de la memoria de tiras, que cuentan cuántos "
              "Pokémon distintos se llegaron a dibujar: el mayor de esta "
              "partida es `%s`. No dice dónde estaba el jugador; dice cuánto "
              "juego le dio tiempo a ver." % max(r["tiras"], key=len))
    a("")
    if datos["errorlog"]:
        a("### Excepción de Ruby (`errorlog.txt`)")
        a("")
        for b in datos["errorlog"][-3:]:
            a("```")
            a(b["cabecera"])
            for l in b["cuerpo"][:25]:
                a(l)
            a("```")
            a("")
    else:
        a("**No hay `errorlog.txt`**, o está vacío: Essentials no llegó a "
          "atrapar ninguna excepción. Si el juego se cerró, se cerró por "
          "debajo de Ruby.")
        a("")
    a("### Dónde estaba el jugador")
    a("")
    a("**Ninguna línea de los tres registros lo dice.** No es que se haya "
      "perdido: no se escribe. `mkxp-debug.log` sólo trae la docena de líneas "
      "de arranque, `mkxp-ruby.log` es la misma plantilla en todas las "
      "sesiones, y `mkxp-boot.log` habla de memoria, hilos y fotogramas, "
      "nunca del juego. Así que del sitio de la caída sólo se sabe lo que "
      "cuente el jugador, y el relato es parte del caso.")
    a("")
    if datos["eventos"]:
        a("Lo más cerca que se llega es `[me]`, la fanfarria que suena al "
          "capturar, al encontrar un objeto o al subir de nivel: %d en toda la "
          "partida. No dice dónde, pero dice que estaba jugando y no parado en "
          "un menú." % len(datos["eventos"]))
        a("")
    a("Lo que haría falta para no volver a estar así está especificado en "
      "`docs/consola/20260906-dos-jugadores.md`: una línea `[donde]` que el "
      "motor escriba en cada cambio de mapa, con mapa, coordenadas y momento. "
      "Es una línea por puerta cruzada —decenas en una partida entera, no "
      "miles—, y con ella el registro de la próxima caída diría en qué "
      "habitación ocurrió.")
    a("")

    # --- 7. casos parecidos ----------------------------------------------
    a("## Casos ya archivados")
    a("")
    if datos["coincidencias"]:
        for c, comunes, misma_comp, sellos in datos["coincidencias"]:
            a("* **%s** (`docs/consola/%s/`) — %s: mismo desplazamiento `+%s`.%s"
              % (c["titulo"] or c["nombre"], c["nombre"],
                 " y ".join(sellos) if sellos else "compilación desconocida",
                 "`, `+".join(comunes),
                 "" if misma_comp else
                 " **Ojo**: es otra compilación, y los desplazamientos de dos "
                 "compilaciones distintas no son comparables; la coincidencia "
                 "puede ser casualidad."))
        a("")
        iguales = [c for c, _, misma, _s in datos["coincidencias"] if misma]
        if iguales:
            a("Con la misma compilación y el mismo desplazamiento, **es el "
              "mismo fallo** que %s." % ", ".join(c["titulo"] or c["nombre"]
                                                  for c in iguales))
            a("")
    else:
        a("Ninguno de los %d casos archivados en `docs/consola/` tiene un "
          "volcado en el mismo sitio. Es la primera vez que se ve."
          % datos["n_archivados"])
        a("")

    # --- 8. veredicto -----------------------------------------------------
    a("## Veredicto")
    a("")
    for l in datos["veredicto"]:
        a(l)
        a("")
    a("## Qué procede")
    a("")
    for i, acc in enumerate(datos["acciones"]):
        a("%d. %s" % (i + 1, acc))
    a("")
    return bloque(p) + "\n"

# --------------------------------------------------------------------- main

def triaje(carpeta, etiqueta, fecha, relato, destino, nombre, archivar):
    ficheros, descartados = busca_registros(carpeta)
    if "mkxp-boot.log" not in ficheros:
        raise SystemExit("no hay mkxp-boot.log en %s ni en sus subcarpetas; sin "
                         "ese fichero no hay nada que triar" % carpeta)
    for sobrante in descartados:
        sys.stderr.write("aviso: %s esta fuera de la carpeta del "
                         "mkxp-boot.log y NO entra en el triaje; si es de otro "
                         "jugador, tiene su propio caso\n" % sobrante)

    sesiones = analiza_boot(lee(ficheros["mkxp-boot.log"]))
    debug = analiza_debug(lee(ficheros["mkxp-debug.log"])) \
        if "mkxp-debug.log" in ficheros else None
    ruby = analiza_ruby(lee(ficheros["mkxp-ruby.log"])) \
        if "mkxp-ruby.log" in ficheros else None
    errorlog = analiza_errorlog(lee(ficheros["errorlog.txt"])) \
        if "errorlog.txt" in ficheros else None

    # La compilacion que se ensena arriba es la de la ULTIMA sesion, no la de
    # la primera.
    #
    # mkxp-boot.log no se trunca: crece durante toda la vida de la instalacion,
    # y en el registro del 6 de septiembre de 2026 habia veintitres sesiones de
    # seis compilaciones distintas, la mas vieja de tres dias antes. Quedarse
    # con el primer [build] hacia que el informe encabezara con una compilacion
    # que el jugador ya no usa y respondiera "NO lleva el arreglo" sobre ella.
    # La que importa es la ultima: es la que se estaba jugando.
    con_build = [s.compilacion for s in sesiones if s.compilacion]
    comp = con_build[-1] if con_build else None

    # Y se dice cuantas hay, porque cambia como se lee todo lo demas: los rangos
    # de fondo y monton de un registro con seis compilaciones no describen
    # ninguna de ellas.
    distintas = []
    for c in con_build:
        clave = (c["version"], c["b"])
        if clave not in [(d["version"], d["b"]) for d in distintas]:
            distintas.append(c)

    grupos = agrupa_volcados(sesiones)

    # El numero que decide si la memoria de video toco el techo no es el minimo
    # ni la media de toda la partida: es cuanto ocupaba el fondo en la ultima
    # medida ANTES de cada caida. Un rango «57 a 511 MB» mezcla la rampa del
    # arranque con el instante del fallo y no dice nada; esto si.
    fondo_al_caer = []
    for i, s in enumerate(sesiones):
        maximo = max([f[1] for f in s.fondo]) if s.fondo else None
        for v in s.volcados:
            previas = [f[1] for f in s.fondo if f[0] <= v["ms"]]
            fondo_al_caer.append({
                "sesion": i + 1, "ms": v["ms"], "rel": v["rel"],
                "ultimo": previas[-1] if previas else None, "max": maximo,
            })

    fondo_vals = [f[1] for s in sesiones for f in s.fondo]
    tex = [f[2] for s in sesiones for f in s.fondo if f[2] is not None]
    picos = [p[1] for s in sesiones for p in s.picos]
    libres = [p[2] for s in sesiones for p in s.picos]
    tirones = [t for s in sesiones for t in s.tirones]
    susp = [t for t in tirones if es_suspension(t)]
    reales = sorted([t for t in tirones if not es_suspension(t)],
                    key=lambda t: -t["marco"])

    # Los desplazamientos que la herramienta de simbolos tendria que resolver.
    desplazamientos = []
    for g in grupos:
        if g["rel"] not in desplazamientos:
            desplazamientos.append(g["rel"])
        for _, off in g["volcados"][0]["pila"]:
            if off not in desplazamientos:
                desplazamientos.append(off)
    simbolos, simbolos_modo = (resolver_simbolos(comp, desplazamientos)
                               if desplazamientos else (None, None))

    # Ni la carpeta que se esta triando ni la de salida cuentan como «otro
    # caso»: un informe que dice que un caso coincide consigo mismo no informa.
    archivados = indice_del_archivo(excluir=(os.path.abspath(destino),
                                             os.path.abspath(carpeta)))
    coincidencias = []
    mios = set(g["rel"] for g in grupos)
    mio_sello = "%s b%d" % (comp["version"], comp["b"]) if comp else None
    for c in archivados:
        comunes = sorted(set(r for r, _, _ in c["volcados"]) & mios)
        if comunes:
            # La compilacion que cuenta es la de los volcados que coinciden, no
            # la primera del fichero.
            sellos = sorted(set("%s b%d" % (k["version"], k["b"])
                                for r, _, k in c["volcados"]
                                if r in comunes and k))
            misma = bool(mio_sello and mio_sello in sellos)
            coincidencias.append((c, comunes, misma, sellos))

    total_ms = sum(s.ultimo_ms for s in sesiones)
    datos = {
        "fecha": fecha, "sesiones": sesiones, "compilacion": comp,
        "compilaciones": distintas,
        "memoria": next((s.memoria for s in sesiones if s.memoria), None),
        "reloj": next((s.reloj for s in sesiones if s.reloj), None),
        "debug": debug, "ruby": ruby, "errorlog": errorlog,
        "arreglos": estado_de_arreglos(comp),
        "grupos": grupos, "simbolos": simbolos, "simbolos_modo": simbolos_modo,
        "serie_fondo": serie(fondo_vals), "serie_monton": serie(picos),
        # El arranque llena el fondo desde cero, y esa rampa ensucia el
        # minimo: lo que dice si el fondo esta desbocado es el tramo de
        # regimen, con el juego ya en marcha.
        "fondo_regimen": serie(fondo_vals[len(fondo_vals) // 2:]),
        "fondo_al_caer": fondo_al_caer,
        "eventos": [e for s in sesiones for e in s.eventos],
        # El monton se mira por sesion: entre una sesion y la siguiente el
        # proceso muere y vuelve a empezar, asi que la bajada de en medio no
        # cuenta. Que suba dentro de cada sesion es la senal de la fuga.
        "monton_por_sesion": [serie([p[1] for p in s.picos]) for s in sesiones],
        "fondo_texturas": ("de %d a %d" % (min(tex), max(tex))) if tex else None,
        "libre_min": min(libres) if libres else 0,
        "libre_max": max(libres) if libres else 0,
        "suspensiones": susp, "tirones_reales": reales,
        "sesiones_con_exc": sum(1 for s in sesiones if s.termino_en_exc),
        "duracion_total": duracion(total_ms - sum(t["marco"] for t in susp)),
        "coincidencias": coincidencias, "n_archivados": len(archivados),
        "descartados": descartados,
        "sellos_del_registro": sorted(set(
            "%s b%d" % (s.compilacion["version"], s.compilacion["b"])
            for s in sesiones if s.compilacion)),
        "etiqueta_carpeta": os.path.basename(destino.rstrip("\\/")),
    }
    datos["veredicto"], datos["acciones"] = veredicto(datos)

    titulo = "Caída de %s, %s" % (etiqueta, fecha_es(fecha))
    if coincidencias and coincidencias[0][2]:
        titulo = "%s — la misma firma que %s" % (titulo, coincidencias[0][0]["nombre"])
    informe = escribe_informe(datos, titulo, relato)

    if not os.path.isdir(destino):
        os.makedirs(destino)
    if archivar:
        for clave, origen in sorted(ficheros.items()):
            copia = os.path.join(destino, os.path.basename(origen))
            if os.path.abspath(origen) != os.path.abspath(copia):
                shutil.copy2(origen, copia)
    camino = os.path.join(destino, nombre)
    with open(camino, "w", encoding="utf-8", newline="\n") as f:
        f.write(informe)
    return camino, datos


def resumen_en_pantalla(camino, datos):
    comp = datos["compilacion"]
    print("informe: %s" % camino)
    if comp:
        otras = len(datos.get("compilaciones") or []) - 1
        print("compilacion: %s b%d (%s)%s"
              % (comp["version"], comp["b"], fecha_es(comp["fecha"]),
                 "  [la ultima; el registro trae %d mas]" % otras if otras > 0 else ""))
    for arr, estado, _p in datos["arreglos"]:
        print("  %-50s %s" % (arr["nombre"], estado))
    print("sesiones: %d | volcados: %d en %d sitio(s)"
          % (len(datos["sesiones"]),
             sum(g["n"] for g in datos["grupos"]), len(datos["grupos"])))
    for g in datos["grupos"]:
        if g["mismo_camino"]:
            camino = "misma pila"
        elif g["marcos_comunes"]:
            camino = "%d marcos comunes, luego se separan" % g["marcos_comunes"]
        else:
            camino = "pilas distintas desde el marco 0"
        de = ", ".join(g.get("sellos") or []) or "compilacion desconocida"
        aviso = ""
        if comp and g.get("sellos"):
            mio = "%s b%d" % (comp["version"], comp["b"])
            if mio not in g["sellos"]:
                aviso = "  <- NO es de la compilacion de arriba"
        print("  +%s x%d far=%s (%s) en %s%s"
              % (g["rel"], g["n"], g["volcados"][0]["far"], camino, de, aviso))
    f, m = datos["serie_fondo"], datos["serie_monton"]
    if f:
        print("fondo: %d-%d MB%s" % (f["min"], f["max"],
                                     " (monotono)" if f["monotona"] else ""))
    if m:
        print("monton: %d-%d MB%s" % (m["min"], m["max"],
                                      " (monotono)" if m["monotona"] else ""))
    print("tirones: %d reales, %d suspensiones"
          % (len(datos["tirones_reales"]), len(datos["suspensiones"])))

    # Lo que la 1.1.1 mide y antes no existia. Se ensena solo de la ultima
    # sesion: mezclar sesiones aqui seria mezclar compilaciones.
    ult = next((x for x in reversed(datos["sesiones"]) if x.compilacion), None)
    if ult is not None:
        if ult.nro:
            print("lanzado desde: %s" % ult.nro)
        if ult.montaje and ult.interprete_ms:
            # En milisegundos y no en segundos: aqui la diferencia entre 568 ms
            # y 55 s es el asunto entero, y redondear a "2 s" lo borra.
            print("arranque: %s montado a los %d ms, interprete a los %d ms"
                  % (ult.montaje[1], ult.montaje[0], ult.interprete_ms))
        if ult.texturas:
            mb = [t[1] for t in ult.texturas]
            print("texturas vivas: %d-%d MB (pico %d MB en %d texturas)"
                  % (min(mb), max(mb), ult.texturas[-1][3], ult.texturas[-1][4]))
        if ult.censo:
            c = ult.censo
            print("fallos del fondo: %d | redondeando a 16 serian aciertos el "
                  "%d%%, a potencia de 2 el %d%%"
                  % (c["fallos"], c["p16"], c["pp2"]))
        if ult.lentos:
            peor = sorted(ult.lentos, key=lambda x: -x[1])[:3]
            print("ficheros lentos: %d por encima de 40 ms; los peores:"
                  % len(ult.lentos))
            for _ms, coste, fich in peor:
                print("  %4d ms  %s" % (coste, fich))
        r = resume_ritmo(ult.ritmo)
        if r:
            print("ritmo: %d ventanas de 15 s | fps mediana %d, peor %d (%d bajo 58) | "
                  "cpu mediana %.1f ms, max %.1f | comp %.1f | lote %s"
                  % (r["n"], r["fps_med"], r["fps_min"], r["bajo_58"],
                     r["cpu_med"] or 0, r["cpu_max"] or 0, r["comp_med"] or 0,
                     "%d con, %d sin" % (r["con_lote"], r["sin_lote"])
                     if r["con_lote"] and r["sin_lote"] else
                     ("si" if r["con_lote"] else ("apagado" if r["sin_lote"] else "-"))))
        if ult.donde:
            print("ultimo sitio: mapa %d %s en (%d,%d)"
                  % (ult.donde[-1][1], ult.donde[-1][2] or "?",
                     ult.donde[-1][3], ult.donde[-1][4]))
    if datos["descartados"]:
        print("OJO: %d fichero(s) de otra carpeta fuera del triaje (otro "
              "jugador):" % len(datos["descartados"]))
        for c in datos["descartados"]:
            print("  %s" % c)
    for c, comunes, misma, sellos in datos["coincidencias"]:
        print("coincide con %s (%s) en +%s%s"
              % (c["nombre"], " y ".join(sellos) or "?", ", +".join(comunes),
                 "" if misma else " (otra compilacion)"))


def main():
    # La consola de Windows no siempre sabe escribir «guardian» con tilde ni el
    # signo de seccion; que un caracter no entre en la pagina de codigos no es
    # razon para no dar el resumen.
    for flujo in (sys.stdout, sys.stderr):
        try:
            flujo.reconfigure(errors="replace")
        except Exception:
            pass

    ap = argparse.ArgumentParser(
        description="Triaje de los registros que manda un jugador.")
    ap.add_argument("carpeta", help="la carpeta que mando el jugador")
    ap.add_argument("--etiqueta", help="palabra corta para el caso "
                    "(pidgey, nuzlocke...); por defecto, el nombre de la carpeta")
    ap.add_argument("--fecha", help="AAAAMMDD del caso; por defecto, hoy")
    ap.add_argument("--relato", help="lo que conto el jugador, en una frase")
    ap.add_argument("--destino", help="carpeta de salida; por defecto "
                    "docs/consola/AAAAMMDD-<etiqueta>")
    ap.add_argument("--nombre", default="analisis.md",
                    help="nombre del informe (por defecto analisis.md)")
    ap.add_argument("--sin-archivar", action="store_true",
                    help="no copiar los registros crudos al destino")
    args = ap.parse_args()

    carpeta = os.path.abspath(args.carpeta)
    if not os.path.isdir(carpeta):
        raise SystemExit("no existe la carpeta %s" % carpeta)
    etiqueta = args.etiqueta or re.sub(r"[^a-z0-9]+", "-",
                                       os.path.basename(carpeta).lower()).strip("-")
    if args.fecha:
        fecha = datetime.datetime.strptime(args.fecha, "%Y%m%d").date()
    else:
        fecha = datetime.date.today()
    destino = args.destino or os.path.join(ARCHIVO, "%s-%s"
                                           % (fecha.strftime("%Y%m%d"), etiqueta))
    destino = os.path.abspath(destino)

    # Nunca pisar un analisis escrito a mano: si ya hay uno, el automatico se
    # deja al lado para poder compararlos.
    nombre = args.nombre
    if nombre == "analisis.md" and os.path.isfile(os.path.join(destino, nombre)):
        nombre = "analisis-automatico.md"
        sys.stderr.write("ya hay un analisis.md en el destino; el informe se "
                         "escribe como %s\n" % nombre)

    camino, datos = triaje(carpeta, etiqueta, fecha, args.relato, destino,
                           nombre, not args.sin_archivar)
    resumen_en_pantalla(camino, datos)


if __name__ == "__main__":
    main()
