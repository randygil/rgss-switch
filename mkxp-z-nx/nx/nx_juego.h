/*
 * nx_juego.h — la carpeta del juego, y los nombres que todos comparten.
 *
 * El porteo nacio para un solo juego y llevaba su carpeta escrita en siete
 * ficheros distintos: nx_boot.c, nx_fsprobe.c, nx_medir.c, nx_aviso.c,
 * debugwriter.h, main.cpp y sharedstate.cpp. Mientras hubo un solo juego eso
 * funcionaba; en cuanto el mismo binario tiene que correr cualquier juego de
 * RPG Maker XP, cada una de esas siete copias es un sitio donde el motor
 * escribe en la carpeta de OTRO juego.
 *
 * Aqui hay una sola respuesta a "¿donde esta el juego?", y quien la necesite
 * la pide. La contesta main.cpp -nxSetupWorkdir- en cuanto la decide, por el
 * orden de CONVENCIONES §3: el directorio del .nro, romfs:/juego.txt, y si no,
 * nada. Hasta ese momento nx_carpeta_juego() devuelve NULL, y eso NO es un
 * caso raro: los 45 constructores estaticos corren antes que main() y ya
 * quieren escribir en el registro. Por eso nx_boot.c acumula en memoria.
 */
#ifndef NX_JUEGO_H
#define NX_JUEGO_H

#include <stddef.h>

/* El contenedor de recursos y su llave (CONVENCIONES §1 y §2).
 *
 * Un solo fichero en vez de veintidos mil: lo que hace que copiar un juego a
 * la tarjeta sea cuestion de minutos y no de una hora. La llave son ocho bytes
 * (RGSSAD\0\1) y no lleva datos: existe porque Essentials pregunta
 * FileTest.exist?("./Game.rgssad") para decidir si busca sus ficheros por
 * load_data -que va por PhysFS y ve dentro del contenedor- o por el sistema de
 * ficheros -que no-. Sin ella el juego arranca y muere a los veinte segundos.
 *
 * Estan aqui, y no en cada fichero que los nombra, porque el dia que cambien
 * tienen que cambiar a la vez en el motor, en el aviso de pantalla y en el
 * empaquetador. */
#define NX_CONTENEDOR "datos.zip"
#define NX_LLAVE      "Game.rgssad"

/* El registro de arranque cuando no llega a saberse cual es la carpeta. */
#define NX_LOG_HUERFANO "sdmc:/rgss-switch.log"

#ifdef __cplusplus
extern "C" {
#endif

/* La carpeta del juego una vez decidida (p.ej. "sdmc:/switch/pokemon-anil"),
 * sin barra final, o NULL si todavia no se sabe. */
const char *nx_carpeta_juego(void);

/* La fija main.cpp cuando encuentra el juego. Vuelca al fichero definitivo lo
 * que el registro de arranque llevaba acumulado en memoria. */
void nx_carpeta_juego_fija(const char *ruta);

/* Se llama cuando ya no va a haber carpeta: lo acumulado se vuelca a
 * NX_LOG_HUERFANO para que la pantalla de aviso no sea el unico testigo. */
void nx_carpeta_juego_rendirse(void);

/* Una ruta dentro de la carpeta del juego, en el buffer que se le pase.
 * Devuelve el buffer, o NULL si la carpeta no se sabe todavia. */
char *nx_ruta_juego(char *buf, size_t tam, const char *nombre);

/* El titulo del juego para la pantalla de aviso: lo que fije el motor cuando
 * lea la configuracion (windowTitle), o el Title= de Game.ini, o
 * "rgss-switch". Nunca devuelve NULL. */
const char *nx_titulo_juego(void);
void nx_titulo_juego_fija(const char *titulo);

/* Lo que se probo buscando el juego, para poder ensenarlo en pantalla cuando
 * no se encuentra: "argv[0] = ...", "romfs:/juego.txt = ...". Sin esto, el
 * aviso solo puede decir "no lo encuentro", que es justo lo que ya se ve. */
void        nx_intento(const char *linea);
int         nx_intentos_n(void);
const char *nx_intento_lee(int i);

/* Modo diagnostico. Enciende las autopruebas del arranque (ficheros, hilos,
 * tuberias, sincronizacion) y el registro linea a linea, que cuesta unos 40 ms
 * por linea en la tarjeta.
 *
 * Dos interruptores, y basta con uno: <carpeta>/diagnostico.txt para un juego
 * concreto, y sdmc:/switch/diagnostico.txt como interruptor global. El global
 * existe porque las autopruebas mas tempranas corren en los constructores
 * estaticos, cuando todavia no se sabe que carpeta es: sin el, lo unico que se
 * puede depurar es lo que pasa despues de encontrar el juego. */
int nx_diagnostico(void);

#ifdef __cplusplus
}
#endif

#endif /* NX_JUEGO_H */
