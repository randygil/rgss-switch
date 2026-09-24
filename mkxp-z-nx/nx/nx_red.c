/*
 * nx_red.c — la capa de sockets de libnx, encendida antes de main().
 *
 * HTTPLite (binding/http-binding.cpp -> src/net/net.cpp) no podia llegar a la
 * red ni por http:// : nadie llamaba a socketInitialize(). En Horizon los
 * sockets no son del kernel sino del servicio bsd:u, y hasta que alguien abre
 * la sesion con el, socket() devuelve -1 y getaddrinfo() no resuelve nada. El
 * sintoma era una excepcion "Failed to GET" sin mas, que se leia como si el
 * servidor estuviera caido.
 *
 * Se hace en userAppInit, que libnx llama desde __appInit despues de montar el
 * monton y los servicios basicos y antes de los constructores estaticos, y no
 * de forma perezosa en la primera peticion: asi vale tambien para cualquier
 * otra cosa del proceso que quiera un socket, y el coste —unos 2 MB de memoria
 * de transferencia que bsd:u exige por adelantado— se paga una vez y se sabe
 * cuanto es. Ni libcurl ni SDL lo hacen por nosotros: curl-libnx abre ssl y
 * nifm por su cuenta, pero da los sockets por hechos.
 *
 * NO ES FATAL. Un juego que no usa la red tiene que arrancar aunque bsd:u diga
 * que no (sin conexion configurada, modo avion, un emulador sin el servicio).
 * El resultado se guarda y net.cpp lo cita en el mensaje de error de la
 * peticion, que es donde alguien va a mirar.
 *
 * userAppInit no puede escribir en mkxp-boot.log: corre antes que el primer
 * constructor, y el registro de nx_boot.c se apoya en ellos. La traza la deja
 * un constructor de este mismo fichero.
 */
#include <switch.h>
#include <stdio.h>

void nx_boot_trace(const char *msg);

static Result nx_red_rc = (Result)-1;
static int    nx_red_viva;

void userAppInit(void);
void userAppInit(void)
{
    nx_red_rc = socketInitializeDefault();
    nx_red_viva = R_SUCCEEDED(nx_red_rc);
}

void userAppExit(void);
void userAppExit(void)
{
    if (nx_red_viva) {
        socketExit();
        nx_red_viva = 0;
    }
}

/* NULL si los sockets estan; si no, una frase para el mensaje de error. */
const char *nx_red_estado(void);
const char *nx_red_estado(void)
{
    static char txt[96];
    if (nx_red_viva)
        return NULL;
    snprintf(txt, sizeof(txt), "sockets de libnx sin iniciar: socketInitializeDefault = 0x%X",
             (unsigned)nx_red_rc);
    return txt;
}

__attribute__((constructor(104)))
static void nx_red_traza(void)
{
    char linea[128];
    if (nx_red_viva)
        snprintf(linea, sizeof(linea), "[red] sockets de libnx listos (bsd:u)");
    else
        snprintf(linea, sizeof(linea), "[red] SIN sockets: socketInitializeDefault = 0x%X "
                 "(el juego sigue; HTTPLite fallara)", (unsigned)nx_red_rc);
    nx_boot_trace(linea);
}
