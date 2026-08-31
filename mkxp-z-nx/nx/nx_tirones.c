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
 * miden las dos por separado. Cada lectura de fichero pasa por un unico embudo
 * —SDL_RWopsRead en filesystem.cpp, por donde va todo: mapas, sprites, musica—
 * y ahi se suma el tiempo. Al cerrar el fotograma se compara:
 *
 *   marco 2400 ms con 2310 en lecturas  ->  es la tarjeta
 *   marco 2400 ms con   40 en lecturas  ->  es la CPU
 *
 * Solo se anotan los fotogramas que pasan del umbral, que a 60 Hz son 16,7 ms:
 * 250 es un tiron que se ve a simple vista y no hay duda de que lo es. Y se
 * corta a los 60 avisos, porque si el juego entero va a tirones el registro no
 * debe crecer sin limite sobre la misma tarjeta que estamos midiendo.
 *
 * Los contadores los tocan el hilo de RGSS y el de la musica sin cerrojo. Son
 * u64 alineados, que en aarch64 se leen y escriben enteros, y esto es un
 * instrumento de diagnostico: un contaje perdido de vez en cuando no cambia
 * ninguna conclusion, y un cerrojo por lectura si cambiaria la medida.
 */
#include <switch.h>
#include <stdio.h>

void nx_boot_trace(const char *msg);

void nx_io_suma(u64 ticks);
void nx_io_abre(void);
void nx_marco(void);

#define NX_UMBRAL_MS   250
#define NX_MAX_AVISOS  60

static u64 io_ticks;          /* tiempo dentro de lecturas en este fotograma */
static u64 io_peor;           /* la peor lectura suelta del fotograma */
static u32 io_cuenta;         /* cuantas lecturas */
static u32 io_abiertos;       /* cuantos ficheros se abrieron */
static u64 marco_previo;
static u32 avisos;

void nx_io_suma(u64 ticks)
{
    io_ticks += ticks;
    io_cuenta++;
    if (ticks > io_peor)
        io_peor = ticks;
}

void nx_io_abre(void)
{
    io_abiertos++;
}

void nx_marco(void)
{
    u64 ahora = armGetSystemTick();
    u64 transcurrido;

    if (marco_previo == 0) {
        marco_previo = ahora;
        io_ticks = io_peor = 0;
        io_cuenta = io_abiertos = 0;
        return;
    }

    transcurrido = ahora - marco_previo;
    marco_previo = ahora;

    if (armTicksToNs(transcurrido) / 1000000 >= NX_UMBRAL_MS && avisos < NX_MAX_AVISOS) {
        char linea[224];
        avisos++;
        snprintf(linea, sizeof(linea),
                 "[tiron] marco %llu ms | %llu ms en %u lecturas"
                 " sobre %u ficheros | la peor %llu ms%s",
                 (unsigned long long)(armTicksToNs(transcurrido) / 1000000),
                 (unsigned long long)(armTicksToNs(io_ticks) / 1000000),
                 (unsigned)io_cuenta, (unsigned)io_abiertos,
                 (unsigned long long)(armTicksToNs(io_peor) / 1000000),
                 (avisos == NX_MAX_AVISOS) ? " [ultimo aviso]" : "");
        nx_boot_trace(linea);
    }

    io_ticks = io_peor = 0;
    io_cuenta = io_abiertos = 0;
}
