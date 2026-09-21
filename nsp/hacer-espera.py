# Genera mkxp-z-nx/nx/espera.png: la insignia del motor y el rotulo CARGANDO.
#
#     python nsp/hacer-espera.py      (pide Pillow; el Makefile NO lo llama)
#
# El PNG esta en el repositorio ya hecho y el Makefile solo lo convierte a
# generated/espera.png.xxd para empotrarlo en el binario. Esto existe para que
# la imagen se pueda REHACER: si manana cambia la marca, se toca aqui y no se
# retoca un PNG a mano sin saber de donde salieron sus medidas.
#
# La geometria es la MISMA que la del PNG anterior -el de Anil-, para no tocar
# nx_espera.cpp, y sale de medir aquel fichero, no de inventarla:
#
#   lienzo 640x400 RGBA, fondo transparente (el azul lo pone glClearColor)
#   insignia 256x256 en (192,8), esquinas redondeadas de radio 24
#   CARGANDO en blanco con halo al 47%, caja de 227 px de ancho, arriba en y=312
#
# La insignia se DIBUJA, no se pega desde nsp/icono.jpg: el icono lleva su marco
# cuadrado y al recortarle las esquinas quedaba el resto del trazo en ellas. Los
# colores y las medidas de dentro se muestrearon de ese icono para que las dos
# caras del motor -la del menu de la consola y la de la pantalla de carga- sean
# la misma.

import os

from PIL import Image, ImageDraw, ImageFont

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SALIDA = os.path.join(RAIZ, "mkxp-z-nx", "nx", "espera.png")

W, H = 640, 400
BADGE_X, BADGE_Y, BADGE, RADIO = 192, 8, 256, 24

FONDO = (25, 34, 49, 255)      # el fondo del icono
MARCO = (52, 70, 86, 255)      # su linea, 3 px a 6 px del borde
CLARO = (240, 245, 252, 255)   # RGSS
AZUL = (110, 175, 225, 255)    # switch

# Medido en nsp/icono.jpg, en coordenadas de la insignia de 256:
RGSS_ALTO, RGSS_ANCHO, RGSS_Y = 57, 207, 84
SW_ALTO, SW_ANCHO, SW_Y = 22, 81, 166

TEXTO, TEXTO_Y, TEXTO_ALTO, TEXTO_ANCHO = "CARGANDO", 312, 32, 227
HALO = 120  # alpha del contorno, medido en el PNG anterior

NEGRITA = "C:/Windows/Fonts/arialbd.ttf"
NORMAL = "C:/Windows/Fonts/arial.ttf"


def cuerpo_para(ruta, muestra, alto):
    """El cuerpo de fuente que da exactamente ese alto de caja para `muestra`."""
    c = alto
    while True:
        f = ImageFont.truetype(ruta, c)
        izq, arr, der, aba = f.getbbox(muestra)
        if aba - arr >= alto:
            return f
        c += 1


def escribe(pincel, ruta, texto, alto, ancho, cx, y, color):
    """Centra `texto` en cx con ese alto de caja, estirando el espaciado hasta
    `ancho`. Devuelve nada: dibuja letra a letra porque el ancho manda."""
    f = cuerpo_para(ruta, texto, alto)
    anchos = [f.getlength(c) for c in texto]
    paso = (ancho - sum(anchos)) / max(len(texto) - 1, 1)
    x = cx - ancho / 2.0
    arr = f.getbbox(texto)[1]
    for i, c in enumerate(texto):
        pincel.text((x, y - arr), c, font=f, fill=color, anchor="la")
        x += anchos[i] + paso


lienzo = Image.new("RGBA", (W, H), (0, 0, 0, 0))

# --- la insignia --------------------------------------------------------
ins = Image.new("RGBA", (BADGE, BADGE), (0, 0, 0, 0))
p = ImageDraw.Draw(ins)
p.rounded_rectangle([0, 0, BADGE - 1, BADGE - 1], radius=RADIO, fill=FONDO)
p.rounded_rectangle([6, 6, BADGE - 7, BADGE - 7], radius=RADIO - 6,
                    outline=MARCO, width=3)
escribe(p, NEGRITA, "RGSS", RGSS_ALTO, RGSS_ANCHO, BADGE / 2.0, RGSS_Y, CLARO)
escribe(p, NORMAL, "switch", SW_ALTO, SW_ANCHO, BADGE / 2.0, SW_Y, AZUL)
lienzo.paste(ins, (BADGE_X, BADGE_Y), ins)

# --- el rotulo ----------------------------------------------------------
# En su propia capa para poder colocarlo por su caja exacta: el contorno se
# sale de las metricas de la fuente y desplazaria el centro.
capa = Image.new("RGBA", (TEXTO_ANCHO + 40, TEXTO_ALTO + 40), (0, 0, 0, 0))
p = ImageDraw.Draw(capa)
f = cuerpo_para(NORMAL, TEXTO, TEXTO_ALTO)
anchos = [f.getlength(c) for c in TEXTO]
paso = (TEXTO_ANCHO - sum(anchos)) / (len(TEXTO) - 1)
x = 20.0
for i, c in enumerate(TEXTO):
    p.text((x, 20), c, font=f, fill=(255, 255, 255, 255), anchor="lt",
           stroke_width=2, stroke_fill=(255, 255, 255, HALO))
    x += anchos[i] + (paso if i < len(TEXTO) - 1 else 0)

caja = capa.split()[3].getbbox()
capa = capa.crop(caja)
lienzo.paste(capa, ((W - capa.width) // 2, TEXTO_Y), capa)

lienzo.save(SALIDA)
print(SALIDA, lienzo.size, "rotulo", capa.size)
