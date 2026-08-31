/*
 * nx_audio.c — testigo del relevo entre la fanfarria y la musica de fondo.
 *
 * En RPG Maker un ME (Music Effect: la fanfarria de coger un objeto, de subir
 * de nivel, de ganar un combate) no se mezcla con la musica de fondo: la
 * silencia, suena solo, y al acabar la devuelve. Ese relevo lo lleva una
 * maquina de estados en un hilo aparte —meWatchFun, en audio.cpp— y tiene
 * cuatro estados con dos transiciones cada uno.
 *
 * Es justo la clase de codigo donde un fallo no se ve leyendo: hay que saber
 * por que rama se fue. Y era una rama, no la SD: el estado que devuelve el
 * volumen a 1 se estaba pisando, asi que la musica volvia muda (§5.57).
 *
 * Una linea por relevo, y como mucho doce: interesa ver los primeros —el del
 * primer objeto es el que delato el fallo— y no llenar el registro en una
 * partida larga, que en esta consola se escribe sobre la misma tarjeta que
 * estamos midiendo.
 */
#include <switch.h>
#include <stdio.h>

void nx_boot_trace(const char *msg);

void nx_traza_me(int hayQueSubir);

#define NX_MAX_ME 12

void nx_traza_me(int hayQueSubir)
{
    static unsigned veces;
    char linea[160];

    if (veces >= NX_MAX_ME)
        return;
    veces++;

    snprintf(linea, sizeof(linea),
             "[me] fanfarria terminada -> %s%s",
             hayQueSubir ? "BgmFadingIn (se devuelve el volumen)"
                         : "MeNotPlaying (la musica ya estaba parada)",
             (veces == NX_MAX_ME) ? " [ultimo aviso]" : "");
    nx_boot_trace(linea);
}
