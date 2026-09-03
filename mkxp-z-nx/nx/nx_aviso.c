/*
 * nx_aviso.c — la pantalla que dice que ha pasado.
 *
 * Hasta aqui, todo fallo de arranque se veia igual: la consola vuelve al menu
 * homebrew sin decir nada. Y son tres cosas muy distintas las que producen ese
 * mismo sintoma:
 *
 *   1. Los datos del juego no estan donde el .nro los busca (o la copia a la
 *      tarjeta se corto a medias).
 *   2. El .nro se lanzo como applet de biblioteca, con 448 MB, y el juego
 *      necesita unos 700.
 *   3. Un fallo de verdad del motor (GL, PhysFS, Ruby).
 *
 * mkxp-z ya distingue los tres, pero los cuenta por SDL_ShowSimpleMessageBox,
 * que en el SDL de Horizon no esta implementado: devuelve -1 y nadie se entera.
 * De ahi que este fichero exista. Pinta el mismo informe que ya iba al registro
 * —mkxp-boot.log— pero en la pantalla, que es donde mira quien acaba de pulsar
 * el icono y no tiene el PC delante.
 *
 * Se dibuja con la consola de libnx (framebufferCreate sobre la ventana por
 * defecto), no con SDL: para el caso 1 todavia no hay SDL, y para el caso 3 SDL
 * ya se ha ido. Las dos no pueden tener la ventana a la vez, y por eso
 * nx_aviso_mostrar() se llama antes de SDL_Init o despues de SDL_Quit, nunca
 * en medio.
 *
 * Todo el texto es ASCII a proposito: la fuente de la consola de libnx no lleva
 * las vocales acentuadas y "diagnóstico" saldria con un hueco en medio. Es la
 * misma decision que en el resto de los shims del port.
 */

#include <switch.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

void nx_boot_trace(const char *msg);
const char *nx_build(void);

int  nx_revision_arranque(void);
void nx_aviso_registra(const char *msg);
int  nx_aviso_pendiente(void);
void nx_aviso_mostrar(void);

/* El contenedor de datos que monta sharedstate.cpp cuando existe. Un solo
 * fichero en vez de 22.148: lo que hace que copiar el juego a la tarjeta sea
 * cuestion de minutos y no de una hora. */
#define NX_PAQUETE "anil-datos.zip"

/* ---------------------------------------------------------------- inventario */

#define NX_MAX_LINEAS 24

static char  lineas[NX_MAX_LINEAS][96];
static int   n_lineas;
static char  motivo[256];        /* el titular: que ha fallado */
static char  pendiente[1024];    /* mensaje de error del motor, si hubo */
static int   hay_pendiente;

static void anota(const char *linea)
{
    if (n_lineas < NX_MAX_LINEAS) {
        snprintf(lineas[n_lineas], sizeof(lineas[0]), "%s", linea);
        n_lineas++;
    }
    nx_boot_trace(linea);
}

/* "0 MB" en un fichero de 900 KB parece un fallo del programa y no lo es, asi
 * que por debajo del mega se cuenta en kilos. Devuelve un buffer estatico: se
 * usa de uno en uno, dentro de un snprintf. */
static const char *tamano(u64 bytes)
{
    static char t[24];

    if (bytes >= 1024 * 1024)
        snprintf(t, sizeof(t), "%llu MB", (unsigned long long)(bytes / (1024 * 1024)));
    else
        snprintf(t, sizeof(t), "%llu KB", (unsigned long long)(bytes / 1024));
    return t;
}

static int existe(const char *ruta, int *es_dir, u64 *tam)
{
    struct stat st;

    if (es_dir) *es_dir = 0;
    if (tam)    *tam = 0;
    if (stat(ruta, &st) != 0)
        return 0;
    if (es_dir) *es_dir = S_ISDIR(st.st_mode) ? 1 : 0;
    if (tam)    *tam = (u64)st.st_size;
    return 1;
}

/* Revision del contenedor.
 *
 * No basta con que el fichero este: la forma mas comun de que un juego de 700 MB
 * llegue mal a una tarjeta es que la copia se corte por la mitad, y entonces el
 * fichero existe, pesa mucho y no sirve. Un zip termina en su registro final
 * (End Of Central Directory, firma 50 4b 05 06), asi que si esos cuatro bytes
 * no estan al final, la copia esta incompleta y se puede decir exactamente eso
 * en vez de "pantalla negra".
 *
 * De paso, el mismo registro trae la cuenta de entradas, que es la respuesta a
 * "¿este fichero lleva de verdad el juego dentro?" sin abrir nada mas.
 *
 * Devuelve  1 = bien,  0 = no existe,  -1 = incompleto o no es un zip. */
static int revisa_paquete(u64 *tam, unsigned *entradas)
{
    unsigned char eocd[22];
    int fd, ok = -1;
    off_t fin;

    *tam = 0;
    *entradas = 0;
    if (!existe(NX_PAQUETE, 0, tam))
        return 0;

    fd = open(NX_PAQUETE, O_RDONLY);
    if (fd < 0)
        return -1;

    fin = lseek(fd, 0, SEEK_END);
    if (fin >= 22 && lseek(fd, fin - 22, SEEK_SET) == fin - 22
        && read(fd, eocd, 22) == 22
        && eocd[0] == 0x50 && eocd[1] == 0x4b && eocd[2] == 0x05 && eocd[3] == 0x06) {
        *entradas = (unsigned)eocd[10] | ((unsigned)eocd[11] << 8);
        ok = 1;
    } else if (fin >= 22) {
        /* El registro final admite un comentario detras, asi que puede no ser
         * lo ultimo del fichero. Se busca hacia atras en los ultimos 64 KiB,
         * que es el maximo que ese comentario puede medir. */
        static unsigned char cola[64 * 1024 + 22];
        off_t desde = fin > (off_t)sizeof(cola) ? fin - (off_t)sizeof(cola) : 0;
        ssize_t n;

        if (lseek(fd, desde, SEEK_SET) == desde && (n = read(fd, cola, sizeof(cola))) > 22) {
            for (ssize_t i = n - 22; i >= 0; i--) {
                if (cola[i] == 0x50 && cola[i+1] == 0x4b
                    && cola[i+2] == 0x05 && cola[i+3] == 0x06) {
                    *entradas = (unsigned)cola[i+10] | ((unsigned)cola[i+11] << 8);
                    ok = 1;
                    break;
                }
            }
        }
    }

    close(fd);
    return ok;
}

/* Como se ha lanzado, que es lo que decide el presupuesto de memoria. Repite el
 * criterio de nx_memoria.c a proposito: alli se anota en el registro y aqui hay
 * que decidir si se avisa en pantalla, y son dos usos que no comparten estado. */
extern char *fake_heap_start;
extern char *fake_heap_end;

static u64 monton_mb(void)
{
    return (u64)(fake_heap_end - fake_heap_start) / (1024 * 1024);
}

static int memoria_de_applet(void)
{
    if (envIsNso())
        return 0;                                   /* NSP instalado: aplicacion */
    if (appletGetAppletType() == AppletType_LibraryApplet)
        return 1;
    /* El tipo de applet lo contesta el sistema y el emulador miente; el monton
     * que libnx consiguio de verdad, no. Con menos de 1 GB no cabe el juego. */
    return monton_mb() < 1024;
}

/* --------------------------------------------------------------- la pantalla */

static void pinta_cabecera(void)
{
    printf(CONSOLE_CYAN "  Pokemon Anil 4.0 para Nintendo Switch" CONSOLE_RESET
           "                  %s\n\n", nx_build());
}

static void pinta_pie(const char *teclas)
{
    printf("\n  El registro completo queda en:\n"
           "    SD:/switch/pokemon-anil/mkxp-boot.log\n\n"
           CONSOLE_YELLOW "  %s" CONSOLE_RESET "\n", teclas);
}

static void espera(int admite_seguir, int *seguir)
{
    PadState pad;

    *seguir = 0;
    padConfigureInput(1, HidNpadStyleSet_NpadStandard);
    padInitializeDefault(&pad);

    while (appletMainLoop()) {
        padUpdate(&pad);
        u64 pulsado = padGetButtonsDown(&pad);
        if (pulsado & HidNpadButton_Plus)
            return;
        if (admite_seguir && (pulsado & HidNpadButton_A)) {
            *seguir = 1;
            return;
        }
        consoleUpdate(NULL);
    }
}

/* Devuelve 1 si el jugador ha elegido seguir de todas formas. */
static int muestra(const char *que_hacer[], int admite_seguir)
{
    int i, seguir = 0;

    consoleInit(NULL);
    pinta_cabecera();
    printf(CONSOLE_RED "  %s" CONSOLE_RESET "\n\n", motivo);

    for (i = 0; i < n_lineas; i++)
        printf("  %s\n", lineas[i]);

    if (que_hacer) {
        printf("\n" CONSOLE_GREEN "  Que hacer:" CONSOLE_RESET "\n");
        for (i = 0; que_hacer[i]; i++)
            printf("    %s\n", que_hacer[i]);
    }

    pinta_pie(admite_seguir ? "Pulsa A para intentarlo igualmente, + para salir."
                            : "Pulsa + para salir.");
    consoleUpdate(NULL);
    espera(admite_seguir, &seguir);
    consoleExit(NULL);
    return seguir;
}

/* ------------------------------------------------------------ la revision */

/* Lo que tiene que estar para que el arranque tenga alguna posibilidad. El
 * motor no comprueba nada de esto: intenta usarlo y muere donde le toca, que
 * suele ser lejos de la causa. */
struct exigencia {
    const char *ruta;
    int         dir;          /* 1 si tiene que ser un directorio */
    int         fatal;
    int         solo_sueltos; /* 1 si con contenedor va DENTRO y aqui no toca */
    const char *para_que;
};

static const struct exigencia exigencias[] = {
    { "mkxp.json",        0, 1, 0, "configuracion del motor" },
    { "lib",              1, 1, 0, "biblioteca de Ruby" },
    { "lib/nx-compat.rb", 0, 1, 0, "shims del port" },
    { "lib/socket.rb",    0, 1, 0, "el plugin Cable Club lo pide al arrancar" },
    { "preload.rb",       0, 0, 0, "compatibilidad de Ruby 3.x" },
    { "Game.ini",         0, 0, 0, "titulo y version de RGSS" },
    { "Fonts",            1, 0, 1, "fuentes del juego" },
};

int nx_revision_arranque(void)
{
    char linea[96], cwd[256];
    int faltan_fatales = 0, hay_sueltos, hay_scripts, dir;
    unsigned entradas = 0;
    u64 tam = 0, ignora;
    int paquete;
    size_t i;

    n_lineas = 0;
    motivo[0] = 0;

    if (!getcwd(cwd, sizeof(cwd)))
        snprintf(cwd, sizeof(cwd), "(desconocido)");
    snprintf(linea, sizeof(linea), "Busco el juego en: %.70s", cwd);
    anota(linea);
    anota("");

    /* 1. Los datos: o el contenedor de un fichero, o las carpetas sueltas. */
    paquete = revisa_paquete(&tam, &entradas);
    hay_scripts = existe("Data/Scripts.rxdata", 0, &ignora);
    hay_sueltos = hay_scripts && existe("Graphics", &dir, &ignora) && dir
                  && existe("Audio", &dir, &ignora) && dir;

    if (paquete == 1) {
        snprintf(linea, sizeof(linea), "[ OK  ] %s (%s, %u entradas)",
                 NX_PAQUETE, tamano(tam), entradas);
        anota(linea);
        /* Un contenedor con cuatro entradas es un contenedor de otra cosa: el
         * juego tiene 22.000 y ningun recorte razonable baja de mil. */
        if (entradas < 1000 && !hay_sueltos) {
            snprintf(motivo, sizeof(motivo),
                     "EL PAQUETE DE DATOS ESTA CASI VACIO (%u entradas).", entradas);
            faltan_fatales = 1;
        }
    } else if (paquete == -1) {
        snprintf(linea, sizeof(linea), "[ MAL ] %s (%s, sin registro final)",
                 NX_PAQUETE, tamano(tam));
        anota(linea);
        if (!hay_sueltos) {
            snprintf(motivo, sizeof(motivo),
                     "EL PAQUETE DE DATOS ESTA INCOMPLETO: LA COPIA SE CORTO.");
            faltan_fatales = 1;
        }
    }

    if (hay_sueltos) {
        anota("[ OK  ] Data/, Graphics/ y Audio/ sueltos");
        /* Tener las dos cosas funciona, pero no como espera quien acaba de
         * dejar un grafico suelto para probar: el contenedor se monta primero
         * y gana. Mejor decirlo que dejar que lo deduzca. */
        if (paquete == 1)
            anota("       (estan los dos; MANDA el contenedor y las carpetas solo ocupan sitio)");
    } else if (paquete != 1) {
        anota(hay_scripts ? "[FALTA] Graphics/ y/o Audio/ sueltos"
                          : "[FALTA] Data/Scripts.rxdata suelto");
        /* Si el contenedor esta pero roto, ya se ha dicho arriba: repetir
         * "[FALTA] anil-datos.zip" mandaria a buscar un fichero que si esta. */
        if (paquete == 0) {
            snprintf(linea, sizeof(linea), "[FALTA] %s", NX_PAQUETE);
            anota(linea);
        }
        if (!motivo[0])
            snprintf(motivo, sizeof(motivo), "NO ENCUENTRO LOS DATOS DEL JUEGO.");
        faltan_fatales = 1;
    }

    /* 2. Las piezas del port. Estan en la entrega, asi que si falta una es que
     *    se descomprimio a medias o se actualizo solo el .nro. */
    for (i = 0; i < sizeof(exigencias) / sizeof(exigencias[0]); i++) {
        const struct exigencia *e = &exigencias[i];
        int es_dir = 0;
        int esta;

        /* Lo que viaja dentro del contenedor no se busca en la tarjeta: si esta
         * en el zip, preguntar por la carpeta solo produce un falso aviso. */
        if (e->solo_sueltos && paquete == 1)
            continue;
        esta = existe(e->ruta, &es_dir, &ignora) && (!e->dir || es_dir);

        if (esta && !e->fatal)
            continue;                  /* lo opcional solo se nombra si falta */
        if (esta)
            snprintf(linea, sizeof(linea), "[ OK  ] %s", e->ruta);
        else
            snprintf(linea, sizeof(linea), "[%s] %-16s %s",
                     e->fatal ? "FALTA" : "  ?  ", e->ruta, e->para_que);
        anota(linea);
        if (!esta && e->fatal) {
            faltan_fatales = 1;
            if (!motivo[0])
                snprintf(motivo, sizeof(motivo),
                         "FALTAN PIEZAS DEL PORT EN LA CARPETA DEL JUEGO.");
        }
    }

    if (faltan_fatales) {
        static const char *que_hacer[] = {
            "1. En el PC, ejecuta Empaquetar.cmd de la entrega del port y",
            "   elige la carpeta de tu Pokemon Anil 4.0 para PC.",
            "2. Copia la carpeta 'switch' que sale de ahi a la raiz de la",
            "   tarjeta SD, y comprueba que la copia termina sin errores.",
            "   Tiene que quedar SD:/switch/pokemon-anil/pokemon-anil.nro",
            "3. Vuelve a lanzarlo desde el menu homebrew.",
            0
        };
        muestra(que_hacer, 0);
        return 1;
    }

    /* 3. La memoria. Los datos estan, pero con 448 MB el juego muere igual y el
     *    sintoma es el mismo; que se distinga aqui ahorra el viaje al registro. */
    if (memoria_de_applet()) {
        static const char *que_hacer[] = {
            "- Abre el Album MANTENIENDO PULSADO R sobre cualquier juego: asi",
            "  el menu homebrew corre como aplicacion y hereda su memoria.",
            "- O instala pokemon-anil.nsp (Awoo Installer, DBI o Goldleaf) y",
            "  lanzalo desde el menu HOME.",
            0
        };
        n_lineas = 0;
        snprintf(linea, sizeof(linea), "El monton que me han dado: %llu MB.",
                 (unsigned long long)monton_mb());
        anota(linea);
        anota("El juego necesita unos 700 MB de recursos, mas el interprete.");
        snprintf(motivo, sizeof(motivo), "ARRANCADO CON MEMORIA DE APPLET: NO VA A CABER.");
        if (!muestra(que_hacer, 1))
            return 1;
        nx_boot_trace("[aviso] memoria de applet: el jugador eligio seguir");
    }

    return 0;
}

/* ------------------------------------------------- fallos del motor, ya tarde */

void nx_aviso_registra(const char *msg)
{
    if (!msg || !*msg)
        return;
    /* Se guarda el PRIMERO: en una cascada de fallos el primero es la causa y
     * los siguientes son consecuencias. */
    if (!hay_pendiente) {
        snprintf(pendiente, sizeof(pendiente), "%s", msg);
        hay_pendiente = 1;
    }
    nx_boot_trace(msg);
}

int nx_aviso_pendiente(void)
{
    return hay_pendiente;
}

void nx_aviso_mostrar(void)
{
    if (!hay_pendiente)
        return;

    n_lineas = 0;
    snprintf(motivo, sizeof(motivo), "EL MOTOR NO HA PODIDO ARRANCAR.");

    /* El mensaje viene del motor, en ingles y de una sola linea que puede pasar
     * de los 80 caracteres de la consola: se parte por donde se pueda. */
    {
        const char *p = pendiente;
        while (*p && n_lineas < NX_MAX_LINEAS) {
            char trozo[80];
            size_t n = strlen(p);
            if (n > 74) {
                n = 74;
                while (n > 40 && p[n] != ' ')
                    n--;
            }
            snprintf(trozo, sizeof(trozo), "%.*s", (int)n, p);
            anota(trozo);
            p += n;
            while (*p == ' ')
                p++;
        }
    }

    {
        static const char *que_hacer[] = {
            "- Adjunta mkxp-boot.log y mkxp-ruby.log al reportarlo; la primera",
            "  linea del registro dice que compilacion arranco.",
            "- Si acabas de actualizar, sustituye tambien mkxp.json y lib/:",
            "  un .nro nuevo con la lib/ vieja falla justo aqui.",
            0
        };
        muestra(que_hacer, 0);
    }
}
