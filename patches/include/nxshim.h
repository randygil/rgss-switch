/*
 * nxshim.h - Declaraciones forzadas via -include para el port a Switch.
 * newlib declara ciertas macros pero omite las funciones asociadas; GCC 14+
 * trata la declaracion implicita como error, asi que hay que declararlas.
 */
#ifndef _NXSHIM_H
#define _NXSHIM_H
#ifdef __cplusplus
extern "C" {
#endif
int setmode(int fd, int mode);   /* implementada en nxcompat.c */
#ifdef __cplusplus
}
#endif
#endif
