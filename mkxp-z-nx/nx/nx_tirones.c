/*
 * nx_tirones.c — cronometro de tirones, para saber de quien es la culpa.
 *
 * El sintoma en consola es "se congela dos o tres segundos al elegir algunas
 * opciones". Eso admite dos explicaciones que piden arreglos opuestos:
 *
 *   a) La tarjeta. Abrir y leer los PNG de un menu sobre una SD que da 3,4 MB/s
 *      es lento, y mientras se lee no se dibuja.
 *   b) La CPU. Descomprimir esos PNG en un A57 a 1 GHz es lento, y la SD no
 *      tiene nada que ver.
 *
 * Adivinar cual de las dos es exactamente lo que no hay que hacer, asi que se
 * miden las dos por separado. La primera version de este fichero cronometraba
 * solo las lecturas y contesto la pregunta: con el bufer puesto, un fotograma
 * de 1013 ms gasta 17 ms leyendo. No es la tarjeta. Pero "no es la tarjeta"
 * todavia no dice que es, y hay un fotograma en el registro de consola —1160 ms
 * con CERO lecturas y CERO ficheros abiertos— que descarta tambien la carga.
 *
 * Asi que ahora se reparte el fotograma entre los cinco embudos por los que
 * puede irse el tiempo, mas el sobrante:
 *
 *   io    lecturas de fichero            SDL_RWopsRead
 *   dec   PNG -> pixeles                 IMG_LoadTyped_RW
 *   sub   pixeles -> textura de la GPU   TEX::uploadImage
 *   pix   textura -> pixeles             glReadPixels, que SINCRONIZA
 *   txt   dibujar una cadena             Bitmap::drawText
 *   blt   pegar un trozo de bitmap       Bitmap::stretchBlt
 *   comp  dibujar la escena entera       Graphics::redrawScreen
 *   esp   dormir hasta el siguiente      FrameLimiter::delay
 *   swap  entregar el fotograma          SDL_GL_SwapWindow
 *   exi   preguntar si un fichero esta   FileSystem::exists
 *   abr   abrir un fichero               FileSystem::openRead
 *   pool  reservar textura + framebuffer  TexPool::request, cuando falla
 *   mid   medir una cadena               Bitmap::textSize
 *   fis   abrir el fichero de verdad     PHYSFS_openRead, dentro de abr
 *   fnt   dar con la fuente              Font::getSdlFont, dentro de txt y mid
 *   resto todo lo demas, que aqui quiere decir el interprete de Ruby
 *
 * Las tres ultimas se anadieron despues, y por un motivo concreto: el
 * muestreador de Ruby (lib/nx-perfil.rb) dijo que durante los tirones la pila
 * del juego estaba parada DENTRO de Graphics.update, o sea en C++ y no en el
 * interprete. "esp" y "swap" van separadas a proposito: dormir de mas es un
 * ajuste del limitador, y bloquearse entregando el fotograma es la GPU. No se
 * arreglan igual.
 *
 * Los embudos se anidan: descodificar lee del fichero, dibujar texto sube una
 * textura. Si se sumaran tal cual, el total pasaria del fotograma. Por eso hay
 * una hondura por hilo y solo el ambito mas exterior suma a "cubierto": cada
 * embudo informa de su tiempo INCLUSIVO —util para "cuanto cuesta el texto en
 * total"— pero el reparto marco = cubierto + resto no cuenta nada dos veces.
 *
 * La hondura es __thread porque el hilo de la musica tambien lee ficheros y
 * anidaria en un contador que no es suyo. El resto de contadores los tocan
 * varios hilos sin cerrojo: son u64 alineados, que en aarch64 se leen y
 * escriben enteros, y esto es un instrumento de diagnostico. Un contaje perdido
 * de vez en cuando no cambia ninguna conclusion; un cerrojo por lectura si
 * cambiaria la medida.
 *
 * Solo se anotan los fotogramas que pasan del umbral, que a 60 Hz son 16,7 ms:
 * 250 es un tiron que se ve a simple vista y no hay duda de que lo es. Y se
 * corta a los 60 avisos, porque si el juego entero va a tirones el registro no
 * debe crecer sin limite sobre la misma tarjeta que estamos midiendo.
 */
#include <switch.h>
#include <stdio.h>

void nx_boot_trace(const char *msg);

u64  nx_entra(void);
void nx_sale(int cual, u64 t0);
void nx_io_abre(void);
void nx_marco(void);

/* Mismo orden que las etiquetas de abajo. Lo comparte bitmap.cpp por su cuenta,
 * declarandolo extern "C": no hay cabecera compartida en todo el port y no
 * merece la pena inventarla para seis constantes. */
enum {
    NX_G_IO = 0,
    NX_G_DECODE,
    NX_G_SUBIR,
    NX_G_LEERPIX,
    NX_G_TEXTO,
    NX_G_BLIT,
    NX_G_COMP,
    NX_G_ESPERA,
    NX_G_SWAP,
    NX_G_EXISTE,
    NX_G_ABRIR,
    NX_G_POOL,
    NX_G_MEDIR,
    NX_G_FISICO,
    NX_G_FUENTE,
    NX_G_NUEVA,
    NX_G_LIMPIA,
    NX_G_TIRA,
    NX_G_PEGA,
    NX_G_N
};

static const char *etiqueta[NX_G_N] = {
    "io", "dec", "sub", "pix", "txt", "blt", "comp", "esp", "swap", "exi",
    "abr", "pool", "mid", "fis", "fnt",
    /* Las cuatro de abajo se anadieron cuando quitar 150 ms medidos de un
     * fotograma no lo acorto ni un milisegundo: se fueron enteros a "resto".
     * Un reparto donde el trozo que manda se llama "todo lo demas" no es un
     * reparto, y "resto = el interprete de Ruby" era una suposicion, no una
     * medida. Estas cubren lo que quedaba sin sonda del lado de C++:
     *
     *   nue   crear un Bitmap: pedir textura al fondo y borrarla
     *   lim   pintar un rectangulo: clear, fill_rect, gradient_fill_rect
     *   tira  soltar un Bitmap y devolver su textura al fondo
     *   peg   la mitad de drawText que habla con la GPU, aparte de rasterizar
     *
     * "nue" y "peg" salen de dos numeros que llevaban en el registro desde el
     * principio y que no habia sabido leer: "fondo 250 aciertos" son 250
     * bitmaps creados en UN fotograma, y "cad 236/312" dice que el texto se
     * reaprovecha y aun asi cuesta lo mismo, o sea que lo caro no era
     * rasterizarlo. */
    "nue", "lim", "tira", "peg"
};

#define NX_UMBRAL_MS   250
#define NX_MAX_AVISOS  60

static u64 gasto[NX_G_N];       /* tiempo inclusivo por embudo */
static u32 cuenta[NX_G_N];      /* cuantas veces se entro en cada uno */
static u64 cubierto;            /* tiempo bajo alguna sonda, sin solapes */
static u32 io_abiertos;         /* cuantos ficheros se abrieron */
static u64 marco_previo;
static u32 avisos;

/* --------------------------------------------------------------------------
 * Reloj de pared contra tiempo de CPU, que es la pregunta que queda.
 *
 * "resto" —lo que no cae bajo ninguna sonda— eran 300 a 580 ms de cada
 * fotograma malo, y la explicacion que dabamos por buena era "el interprete de
 * Ruby". Suponerlo no lo demuestra. Esto si: el nucleo
 * lleva la cuenta de los ticks que ha consumido cada hilo, y restarla entre dos
 * fotogramas dice cuanto de esos 580 ms estuvo el hilo trabajando y cuanto
 * estuvo parado esperando a algo. Si "cpu" sale parecido a "marco", es Ruby y
 * hay que quitarle trabajo. Si sale mucho menor, el hilo esta bloqueado y
 * buscar en Ruby es perder el tiempo.
 *
 * No es una estimacion ni un muestreo: es la contabilidad del planificador. Es
 * justo lo que le faltaba al muestreador de Ruby que hubo que tirar. */
static u64 cpu_previo;

static u64 ticks_de_este_hilo(void)
{
    u64 t = 0;
    svcGetInfo(&t, InfoType_ThreadTickCount, CUR_THREAD_HANDLE, (u64)-1);
    return t;
}

static __thread u32 hondura;

#define MS(t) ((unsigned long long)(armTicksToNs(t) / 1000000))

u64 nx_entra(void)
{
    hondura++;
    return armGetSystemTick();
}

void nx_sale(int cual, u64 t0)
{
    u64 ticks = armGetSystemTick() - t0;

    if (cual >= 0 && cual < NX_G_N) {
        gasto[cual] += ticks;
        cuenta[cual]++;
    }
    if (hondura > 0 && --hondura == 0)
        cubierto += ticks;
}

void nx_io_abre(void)
{
    io_abiertos++;
}

/* El fondo de texturas de mkxp-z recicla las que se liberan, pero solo hasta un
 * presupuesto. Cuando no le cabe una, la borra; y cuando luego se la vuelven a
 * pedir tiene que crearla de cero contra el driver. Un sprite animado de
 * Pokemon son decenas de fotogramas, y seis en el equipo desbordan cualquier
 * presupuesto pequeno: de ahi que abrir la misma pantalla cueste siempre lo
 * mismo, porque el fondo esta siempre vacio para ese tamano.
 *
 * Se cuentan los aciertos aparte de los fallos porque el numero que decide es
 * la PROPORCION: mil fallos y cero aciertos es un fondo pequeno; mil fallos y
 * mil aciertos es un juego que pide texturas de mil tamanos distintos y
 * entonces el presupuesto no arregla nada. */
static u32 pool_aciertos;
static u32 pool_mb;
/* Cuantas texturas hay guardadas, no solo cuantos megas. El contador de
 * objetos del fondo era de 16 bits y 512 MB en cajas de texto de 64x32 son
 * exactamente 65.536: con el numero a la vista se ve venir el desbordamiento en
 * vez de descubrirlo por un volcado de pila. */
static u32 pool_tex;

void nx_pool_acierto(void)
{
    pool_aciertos++;
}

void nx_pool_tamano(unsigned bytes, unsigned objetos)
{
    pool_mb = bytes / (1024u * 1024u);
    pool_tex = objetos;
}

/* El fondo de texturas recicla el hueco en la GPU, pero no el trabajo de
 * llenarlo: abrir el PNG, descomprimirlo y rasterizar la cadena de texto se
 * repiten enteros cada vez. Esos dos alijos guardan el resultado ya cocinado.
 *
 * Se cuentan aciertos Y fallos, no solo aciertos, porque un alijo se juzga por
 * la proporcion. Cero fallos con dos aciertos no dice nada; y muchos fallos
 * con el alijo lleno significa que el presupuesto se queda corto y esta
 * echando fuera cosas que va a volver a pedir, que es peor que no tenerlo. */
static u32 img_ac, img_fa, img_mb;
static u32 txt_ac, txt_fa, txt_mb;

void nx_cache_imagen(int acierto, unsigned bytes)
{
    if (acierto) img_ac++; else img_fa++;
    img_mb = bytes / (1024u * 1024u);
}

void nx_cache_texto(int acierto, unsigned bytes)
{
    if (acierto) txt_ac++; else txt_fa++;
    txt_mb = bytes / (1024u * 1024u);
}

static void limpia(void)
{
    int i;
    for (i = 0; i < NX_G_N; i++) {
        gasto[i] = 0;
        cuenta[i] = 0;
    }
    cubierto = 0;
    io_abiertos = 0;
    pool_aciertos = 0;
    img_ac = img_fa = 0;
    txt_ac = txt_fa = 0;
}

/* Una lectura de pixeles no es como los demas embudos: es UNA llamada que
 * sincroniza la GPU entera, y lo que cuesta depende del tamano de la textura.
 * Saber que se fue medio segundo en "pix" no sirve de nada si no se sabe en
 * que bitmap, asi que las caras se anotan con sus medidas. */
void nx_pixeles(int ancho, int alto, u64 ticks)
{
    static u32 dichas;
    char linea[128];

    if (MS(ticks) < 50 || dichas >= 12)
        return;
    dichas++;
    snprintf(linea, sizeof(linea),
             "[pix] lectura de %dx%d (%d KB) -> %llu ms%s",
             ancho, alto, (ancho * alto * 4) / 1024, MS(ticks),
             (dichas == 12) ? " [ultimo aviso]" : "");
    nx_boot_trace(linea);
}

void nx_marco(void)
{
    u64 ahora = armGetSystemTick();
    u64 cpu_ahora = ticks_de_este_hilo();
    u64 transcurrido, cpu_gastado;

    if (marco_previo == 0) {
        marco_previo = ahora;
        cpu_previo = cpu_ahora;
        limpia();
        return;
    }

    transcurrido = ahora - marco_previo;
    marco_previo = ahora;
    cpu_gastado = cpu_ahora - cpu_previo;
    cpu_previo = cpu_ahora;

    if (MS(transcurrido) >= NX_UMBRAL_MS && avisos < NX_MAX_AVISOS) {
        char linea[448];
        int n, i;

        avisos++;
        n = snprintf(linea, sizeof(linea), "[tiron] marco %llu ms | cpu %llu ms |",
                     MS(transcurrido), MS(cpu_gastado));

        /* Solo los embudos que han hecho algo: un menu que no dibuja texto no
         * tiene por que gastar sitio diciendolo. */
        for (i = 0; i < NX_G_N && n > 0 && n < (int)sizeof(linea); i++)
            if (cuenta[i])
                n += snprintf(linea + n, sizeof(linea) - n, " %s %ux %llu ms |",
                              etiqueta[i], (unsigned)cuenta[i], MS(gasto[i]));

        if (n > 0 && n < (int)sizeof(linea))
            snprintf(linea + n, sizeof(linea) - n,
                     " %u ficheros | fondo %u aciertos %u MB %u tex"
                     " | img %u/%u %u MB | cad %u/%u %u MB | resto %llu ms",
                     (unsigned)io_abiertos,
                     (unsigned)pool_aciertos, (unsigned)pool_mb,
                     (unsigned)pool_tex,
                     (unsigned)img_ac, (unsigned)(img_ac + img_fa), (unsigned)img_mb,
                     (unsigned)txt_ac, (unsigned)(txt_ac + txt_fa), (unsigned)txt_mb,
                     MS(transcurrido > cubierto ? transcurrido - cubierto : 0));

        if (avisos == NX_MAX_AVISOS) {
            size_t l = 0;
            while (linea[l]) l++;
            snprintf(linea + l, sizeof(linea) - l, " [ultimo aviso]");
        }
        nx_boot_trace(linea);
    }

    limpia();
}
