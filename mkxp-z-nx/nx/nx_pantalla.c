/*
 * nx_pantalla.c — la resolucion de verdad de la pantalla.
 *
 * Hay dos fuentes y no siempre dicen lo mismo:
 *
 *   nwindowGetDimensions       la superficie donde Mesa dibuja de verdad
 *   appletGetDefaultDisplayResolution   la salida de video del sistema
 *
 * Manda la primera, porque es la que fija el tamano del bufer; la segunda
 * describe a donde va ese bufer despues. Cuando la consola sale de la base la
 * salida cambia de 1920x1080 a 1280x720, y la pregunta —que no se puede
 * contestar sin medirla— es si la superficie cambia con ella o si Horizon se
 * limita a escalar. De ahi que se consulten y se anoten las DOS aunque solo se
 * use una: sin las dos en el registro no hay manera de saberlo.
 *
 * La respuesta se cachea, porque esto se consulta en el camino de cada
 * fotograma y cada consulta es un IPC al servicio applet.
 */
#include <switch.h>

void nx_boot_trace(const char *msg);

void nx_resolucion_pantalla(int *ancho, int *alto);
int  nx_pantalla_cambio(int *ancho, int *alto);

static int w_cache, h_cache;
static Event ev_cambio;
static int   ev_estado;          /* 0 sin intentar, 1 abierto, -1 no disponible */

/* Nada de printf en el camino de arranque: se formatea a mano. */
static char *pon(char *q, const char *s)
{
    while (*s) *q++ = *s++;
    return q;
}

static char *pon_num(char *q, unsigned v)
{
    char t[12];
    int i = 0;

    if (!v) t[i++] = '0';
    while (v) { t[i++] = (char)('0' + v % 10); v /= 10; }
    while (i) *q++ = t[--i];
    return q;
}

static char *pon_wh(char *q, unsigned w, unsigned h)
{
    q = pon_num(q, w);
    *q++ = 'x';
    return pon_num(q, h);
}

/* Consulta las dos fuentes, anota ambas y devuelve la que manda. */
static void medir(int *w, int *h, const char *cuando)
{
    u32 nw = 0, nh = 0;
    s32 aw = 0, ah = 0;
    int hay_nw, hay_ap;
    char msg[192], *q = msg;

    hay_nw = R_SUCCEEDED(nwindowGetDimensions(nwindowGetDefault(), &nw, &nh))
             && nw > 0 && nh > 0;
    hay_ap = R_SUCCEEDED(appletGetDefaultDisplayResolution(&aw, &ah))
             && aw > 0 && ah > 0;

    q = pon(q, "[gfx] ");
    q = pon(q, cuando);
    q = pon(q, ": nwindow ");
    if (hay_nw) q = pon_wh(q, nw, nh); else q = pon(q, "?");
    q = pon(q, " | applet ");
    if (hay_ap) q = pon_wh(q, (unsigned)aw, (unsigned)ah); else q = pon(q, "?");
    q = pon(q, " | modo ");
    q = pon(q, appletGetOperationMode() == AppletOperationMode_Handheld
                   ? "portatil" : "sobremesa");
    *q = 0;
    nx_boot_trace(msg);

    if (hay_nw) {
        *w = (int)nw;
        *h = (int)nh;
    } else if (hay_ap) {
        *w = (int)aw;
        *h = (int)ah;
    } else {
        /* Sin applet (arrancado como applet en vez de como aplicacion) lo mas
         * seguro es suponer la pantalla pequena: dibujar de menos se ve mal,
         * dibujar de mas se sale. */
        *w = 1280;
        *h = 720;
        nx_boot_trace("[gfx] nadie contesta; se asume 1280x720");
    }
}

void nx_resolucion_pantalla(int *ancho, int *alto)
{
    if (w_cache <= 0)
        medir(&w_cache, &h_cache, "inicial");
    *ancho = w_cache;
    *alto  = h_cache;
}

/* Devuelve 1 —y la medida nueva— cuando la consola ha entrado o salido de la
 * base Y eso ha cambiado la superficie. Si solo cambia la salida de video pero
 * la superficie sigue igual, no hay nada que hacer y devuelve 0.
 *
 * El evento no se cierra nunca: vive lo que el proceso. */
int nx_pantalla_cambio(int *ancho, int *alto)
{
    int w = w_cache, h = h_cache;

    if (ev_estado == 0) {
        ev_estado = R_SUCCEEDED(appletGetDefaultDisplayResolutionChangeEvent(&ev_cambio))
                        ? 1 : -1;
        nx_boot_trace(ev_estado == 1
                          ? "[gfx] suscrito al cambio de resolucion"
                          : "[gfx] sin evento de cambio de resolucion");
    }
    if (ev_estado != 1)
        return 0;

    /* timeout 0: mirar, no esperar. Esto se llama desde el hilo de dibujo. */
    if (R_FAILED(eventWait(&ev_cambio, 0)))
        return 0;
    eventClear(&ev_cambio);

    appletUpdateDefaultDisplayResolution();
    medir(&w, &h, "tras el cambio");

    if (w == w_cache && h == h_cache)
        return 0;

    w_cache = w;
    h_cache = h;
    *ancho = w;
    *alto  = h;
    return 1;
}
