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
#include <malloc.h>

void nx_boot_trace(const char *msg);
int  nx_diagnostico(void);

/* texpool.cpp: cuantas texturas hay de verdad guardadas en la cola. */
unsigned nx_pool_reales(void);
unsigned nx_texturas_informe(unsigned *n_vivas, unsigned *pico_mb,
                             unsigned *n_pico, unsigned *n_perdidas);

static void nx_pool_informe(unsigned bytes, unsigned objetos);

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
    nx_pool_informe(bytes, objetos);
}

/* Informe periodico del fondo, SOLO en modo diagnostico.
 *
 * La linea [tiron] lleva el tamano y el numero de texturas, pero solo se
 * escribe cuando hay un tiron, y el desbordamiento del contador no da ninguno:
 * el juego sigue fluido hasta que el driver dice que no y el proceso muere. Con
 * este informe el numero se ve subir, que es lo que hacia falta para verlo
 * venir. Una linea cada 4.096 peticiones no le cuesta nada al fotograma.
 *
 * Cuenta ADEMAS cuantas texturas hay de verdad en la cola de prioridad: si ese
 * numero y el contador dejan de coincidir, el contador se ha dado la vuelta y
 * el desalojo de release() ya no desaloja. Ese desajuste es el fallo entero,
 * dicho en dos numeros. */
static void nx_pool_informe(unsigned bytes, unsigned objetos)
{
    static u32 veces;
    char linea[160];

    if (!nx_diagnostico())
        return;
    if ((veces++ & 0xFFu) != 0)
        return;

    snprintf(linea, sizeof(linea),
             "[fondo] %u peticiones | %u KB | %u texturas contadas | %u en cola",
             (unsigned)veces, bytes / 1024u, objetos, nx_pool_reales());
    nx_boot_trace(linea);
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

/* --------------------------------------------------------------------------
 * Desglose del monton.
 *
 * nx_memoria.c ya anota la marca de agua: mallinfo().uordblks cada vez que
 * sube un escalon de 32 MB. En los registros de un jugador ese numero sube
 * solo, sin bajar nunca, y pasa del gigabyte en diez minutos de partida. Pero
 * un numero suelto no dice de quien es la memoria, y "el monton crece" tiene
 * cuatro explicaciones que piden arreglos distintos y hasta opuestos:
 *
 *   a) Los alijos, haciendo su trabajo. El fondo de texturas tiene 512 MB de
 *      presupuesto en la consola -veinticinco veces el de escritorio-, el
 *      alijo de imagenes 192 y el de cadenas 32: 736 MB que por definicion se
 *      llenan y no se vacian. Un alijo que crece hasta su techo no es una
 *      fuga, es un alijo.
 *   b) Texturas VIVAS. Las que el juego tiene en uso no las cuenta nadie: el
 *      fondo solo sabe de las que le han devuelto. En Horizon una textura es
 *      memoria del proceso -nvmap mapea el monton, no reserva aparte-, asi que
 *      un Bitmap que nadie suelta son megas de monton que no salen en ningun
 *      contador.
 *   c) El monton de objetos de Ruby, que es otra cosa: son los slots del
 *      recolector, y se miden con GC.stat.
 *   d) Fragmentacion del asignador. newlib no devuelve paginas al sistema, asi
 *      que un monton troceado se ve grande aunque por dentro no haya casi nada
 *      vivo.
 *
 * Las cuatro se separan con numeros que ya estan a mano o que cuestan
 * microsegundos:
 *
 *   - mallinfo().arena es lo que malloc lleva pedido al sistema; .uordblks lo
 *     que tiene repartido; .fordblks lo que le queda libre por dentro. Si
 *     arena sube y uordblks no, es (d) y solo (d). Si van pegados, la
 *     fragmentacion no tiene nada que ver y sobra hablar de ella.
 *   - fondo + img + cad son los tres alijos, que este fichero ya cuenta para
 *     la linea [tiron]. Lo que queda al restarlos es (b) mas el motor.
 *   - GC.stat da (c) directamente, y de propina malloc_increase_bytes, que es
 *     el unico contador que hace correr al recolector por presion de memoria.
 *     Si ese numero es pequeno mientras el monton crece, el recolector no se
 *     esta enterando de lo que gasta el juego: un Bitmap es un objeto de
 *     cuarenta bytes para Ruby y varios megas para la consola, porque el
 *     descriptor de tipo de las clases del motor declara dsize = 0.
 *
 * VA EN PRODUCCION, no en modo diagnostico, y a proposito. Lo que hay que
 * explicar pasa en la consola de un jugador que juega media hora, y nadie va a
 * dejar puesto diagnostico.txt para eso. El coste es un mallinfo, una llamada
 * al sistema y cuatro consultas a GC.stat cada treinta segundos -unas veinte
 * lineas en una sesion de diez minutos- contra un fotograma de 16,7 ms.
 * nx_pool_informe si esta gobernado por el modo diagnostico, y no es
 * incoherente: aquel salta una vez cada 256 peticiones al fondo, que en un
 * fotograma malo son varias por segundo. Es otra clase de coste.
 *
 * El periodo es fijo y NO hay disparo por escalon. Mirar mallinfo en cada
 * fotograma significa recorrer las 128 listas de huecos del asignador dentro
 * del mismo cronometro que este fichero existe para no perturbar. La escalera
 * fina ya la da nx_memoria.c una vez por segundo; lo que falta aqui es el
 * reparto, no la resolucion.
 *
 * Ruby se declara con simbolos DEBILES. Asi la sonda sigue compilando y
 * enlazando en un binario sin interprete -las autopruebas de arranque lo son- y
 * se limita a callar esa linea en vez de romper el enlace. Y solo se pregunta
 * desde dentro de nx_marco, al que unicamente se llega por Graphics::update y
 * Graphics::wait: los dos salen del guion del juego, o sea del hilo de Ruby y
 * con el interprete montado desde hace rato.
 */
typedef unsigned long nx_VALUE;
typedef unsigned long nx_ID;

extern nx_ID    rb_intern(const char *) __attribute__((weak));
extern nx_VALUE rb_id2sym(nx_ID)        __attribute__((weak));
extern size_t   rb_gc_stat(nx_VALUE)    __attribute__((weak));

/* Un slot del recolector de Ruby son 40 bytes en 64 bits (sizeof(RVALUE)).
 * GC.stat cuenta slots, no bytes; la conversion va aqui para que la linea del
 * registro se pueda comparar con las demas sin sacar la calculadora. */
#define NX_SLOT_RUBY 40u

#define NX_MB(b) ((unsigned long long)((b) / (1024ull * 1024ull)))

static size_t nx_gc(const char *clave)
{
    if (!&rb_gc_stat || !&rb_intern || !&rb_id2sym)
        return 0;
    return rb_gc_stat(rb_id2sym(rb_intern(clave)));
}

static void nx_monton_informe(void)
{
    struct mallinfo mi = mallinfo();
    u64 total = 0, usado = 0;
    size_t alijos, resto;
    char linea[256];

    svcGetInfo(&total, InfoType_TotalMemorySize, CUR_PROCESS_HANDLE, 0);
    svcGetInfo(&usado, InfoType_UsedMemorySize,  CUR_PROCESS_HANDLE, 0);

    snprintf(linea, sizeof(linea),
             "[monton] malloc %llu MB en uso | %llu libres dentro"
             " | %llu pedidos al sistema | el sistema dice %llu de %llu MB",
             NX_MB(mi.uordblks), NX_MB(mi.fordblks), NX_MB(mi.arena),
             (unsigned long long)(usado / (1024 * 1024)),
             (unsigned long long)(total / (1024 * 1024)));
    nx_boot_trace(linea);

    /* Los tres alijos llegan aqui ya en megas, redondeados hacia abajo por
     * quien los anota. Se vuelven a pasar a bytes para restarlos del monton: el
     * numero que interesa es lo que sobra, y ahi el redondeo se nota. */
    alijos = ((size_t)pool_mb + img_mb + txt_mb) * 1024u * 1024u;
    resto  = (mi.uordblks > alijos) ? (size_t)mi.uordblks - alijos : (size_t)0;

    snprintf(linea, sizeof(linea),
             "[monton] reparto: fondo %u | img %u | cad %u"
             " | resto %llu MB (texturas vivas + motor + ruby)",
             (unsigned)pool_mb, (unsigned)img_mb, (unsigned)txt_mb,
             NX_MB(resto));
    nx_boot_trace(linea);

    /* Y dentro de ese "resto", el trozo que hasta hoy no contaba nadie.
     *
     * El fondo de texturas solo ve las que se reaprovechan. Estas son las que
     * el juego tiene ABIERTAS ahora mismo, y en los registros del 6 de
     * septiembre eran entre 557 y 752 MB: el termino que manda y el que
     * explica que la GPU diga que no con el fondo en 259 MB. El pico va al
     * lado del valor de ahora porque cuando llega una caida lo que importa no
     * es lo que hay, es lo que llego a haber. */
    {
        unsigned n = 0, pico = 0, n_pico = 0, sin_contar = 0;
        unsigned mb = nx_texturas_informe(&n, &pico, &n_pico, &sin_contar);

        if (sin_contar)
            snprintf(linea, sizeof(linea),
                     "[monton] texturas vivas: %u MB en %u | pico %u MB en %u"
                     " | %u sin contar (la tabla no crecio)",
                     mb, n, pico, n_pico, sin_contar);
        else
            snprintf(linea, sizeof(linea),
                     "[monton] texturas vivas: %u MB en %u | pico %u MB en %u",
                     mb, n, pico, n_pico);
        nx_boot_trace(linea);
    }

    if (&rb_gc_stat) {
        size_t vivos  = nx_gc("heap_live_slots");
        size_t viejos = nx_gc("old_objects");
        size_t inc    = nx_gc("malloc_increase_bytes");
        size_t veces  = nx_gc("count");

        snprintf(linea, sizeof(linea),
                 "[monton] ruby: %u recogidas | %u slots vivos (%llu MB)"
                 " | %u viejos | inc malloc %llu KB",
                 (unsigned)veces, (unsigned)vivos,
                 NX_MB((unsigned long long)vivos * NX_SLOT_RUBY),
                 (unsigned)viejos,
                 (unsigned long long)(inc / 1024u));
        nx_boot_trace(linea);
    }
}

/* Treinta segundos. Bastante espaciado para no pesar y bastante frecuente para
 * que una sesion de cinco minutos deje diez muestras, que es lo que hace falta
 * para ver si el resto crece al ritmo de los alijos o por su cuenta. */
#define NX_PERIODO_MONTON 30ull


void nx_marco(void)
{
    u64 ahora = armGetSystemTick();
    u64 cpu_ahora = ticks_de_este_hilo();
    u64 transcurrido, cpu_gastado;

    {
        static u64 monton_previo;
        if (monton_previo == 0 ||
            ahora - monton_previo >=
                armNsToTicks(NX_PERIODO_MONTON * 1000000000ull)) {
            monton_previo = ahora;
            nx_monton_informe();
        }
    }

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
