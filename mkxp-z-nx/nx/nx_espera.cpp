/*
 * nx_espera.cpp — la pantalla de "CARGANDO".
 *
 * El arranque tarda. Con las carpetas sueltas son unos veinte segundos (§5.48)
 * y con el contenedor trece y medio mas (§5.58), y en todo ese rato la consola
 * ensena UNA PANTALLA NEGRA. Quien lo prueba por primera vez no distingue eso
 * de un cuelgue: apaga y vuelve a intentarlo, que es exactamente lo que no hay
 * que hacer. El registro decia desde el principio que el arranque iba bien; el
 * problema es que el jugador no lee registros.
 *
 * Asi que se dibuja algo. El logo del juego, la palabra CARGANDO y una barra
 * que avanza en cada hito del arranque:
 *
 *   0,15  contexto GL creado (aqui empieza a haber donde dibujar)
 *   0,25  shaders compilados
 *   0,55  contenedor montado          <- el tramo largo, 8,4 s
 *   0,60  directorio del juego montado
 *   0,85  indice de rutas construido  <- el otro, 5,6 s
 *   0,90  fuentes indexadas
 *   1,00  arrancando el interprete Ruby
 *
 * La barra da SALTOS y no avanza sola, y es a proposito: entre un hito y el
 * siguiente el hilo esta dentro de PhysFS y no hay a quien pedirle un fotograma.
 * Preferir un salto honesto a una animacion que finge progreso, que es lo que
 * hace todo el mundo y lo que convierte una barra en un adorno.
 *
 * POR QUE A MANO Y NO CON EL MOTOR. Todo esto pasa DENTRO del constructor de
 * SharedState: el Graphics de mkxp-z, sus shaders y su cache de estado se estan
 * construyendo justo ahora y no hay un shState al que pedirle nada. De ahi que
 * haya aqui un programa GLES minimo, un cuadrado y dos texturas. Se usa la
 * tabla de funciones de mkxp-z (gl-fun.h), no los prototipos del sistema, para
 * no tener dos formas distintas de llegar al driver.
 *
 * Y POR QUE HAY QUE LIMPIAR DESPUES. GLState de mkxp-z es una CACHE: recuerda
 * que programa, color de fondo y modo de mezcla dejo puestos, y se salta la
 * llamada si le piden lo que ya cree tener. Si esta pantalla cambia el estado a
 * su espalda, la primera escena del juego sale con el programa equivocado. El
 * arreglo no es adivinar lo que habia, es volver a poner la cache y el driver de
 * acuerdo: nx_espera_cierra() deja el estado como recien inicializado y
 * sharedstate.cpp reinicia las propiedades cacheadas justo despues.
 */

#include <SDL.h>
#include <SDL_image.h>
#include <SDL_surface.h>

#include "gl-fun.h"

#include <string.h>

/* Generado por el Makefile con `xxd -i nx/espera.png`. */
#include "espera.png.xxd"

extern "C" {
void nx_boot_trace(const char *msg);
void nx_espera_abre(SDL_Window *ventana);
void nx_espera_paso(float fraccion);
void nx_espera_cierra(void);
}

namespace {

const char *VERTICE =
    "#version 100\n"
    "attribute vec2 pos;\n"
    "attribute vec2 uv;\n"
    "uniform vec2 pantalla;\n"
    "varying vec2 vuv;\n"
    "void main() {\n"
    "  vec2 n = (pos / pantalla) * 2.0 - 1.0;\n"
    "  gl_Position = vec4(n.x, -n.y, 0.0, 1.0);\n"
    "  vuv = uv;\n"
    "}\n";

const char *FRAGMENTO =
    "#version 100\n"
    "precision mediump float;\n"
    "varying vec2 vuv;\n"
    "uniform sampler2D tex;\n"
    "uniform vec4 color;\n"
    "uniform float conTextura;\n"
    "void main() {\n"
    "  vec4 c = color;\n"
    "  if (conTextura > 0.5)\n"
    "    c *= texture2D(tex, vuv);\n"
    "  gl_FragColor = c;\n"
    "}\n";

SDL_Window *ventana;
GLuint programa, vbo, ibo, vao, texLogo, texBlanco;
GLint uPantalla, uColor, uConTextura, uTex;
int logoW, logoH;
int pantallaW = 1280, pantallaH = 720;
bool viva;

GLuint compila(GLenum tipo, const char *fuente)
{
    GLuint s = gl.CreateShader(tipo);
    GLint len = (GLint)strlen(fuente), ok = 0;

    gl.ShaderSource(s, 1, &fuente, &len);
    gl.CompileShader(s);
    gl.GetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char registro[512] = {0};
        GLsizei n = 0;
        gl.GetShaderInfoLog(s, sizeof(registro) - 1, &n, registro);
        nx_boot_trace("[espera] no compila el shader:");
        nx_boot_trace(registro);
        gl.DeleteShader(s);
        return 0;
    }
    return s;
}

/* Cuatro vertices en pixeles de pantalla, con sus coordenadas de textura. */
void cuadro(float x, float y, float w, float h)
{
    const float v[16] = {
        x,     y,     0.0f, 0.0f,
        x + w, y,     1.0f, 0.0f,
        x + w, y + h, 1.0f, 1.0f,
        x,     y + h, 0.0f, 1.0f,
    };

    gl.BufferSubData(GL_ARRAY_BUFFER, 0, sizeof(v), v);
    gl.DrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, 0);
}

void pinta(GLuint textura, float x, float y, float w, float h,
           float r, float g_, float b, float a)
{
    gl.Uniform4f(uColor, r, g_, b, a);
    gl.Uniform1f(uConTextura, textura == texBlanco ? 0.0f : 1.0f);
    gl.ActiveTexture(GL_TEXTURE0);
    gl.BindTexture(GL_TEXTURE_2D, textura);
    cuadro(x, y, w, h);
}

GLuint sube(SDL_Surface *sup)
{
    GLuint t = 0;

    gl.GenTextures(1, &t);
    gl.BindTexture(GL_TEXTURE_2D, t);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    gl.PixelStorei(GL_UNPACK_ALIGNMENT, 4);
    gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, sup->w, sup->h, 0,
                  GL_RGBA, GL_UNSIGNED_BYTE, sup->pixels);
    return t;
}

}  /* namespace */

void nx_espera_abre(SDL_Window *v)
{
    GLint vp[4] = {0, 0, 0, 0};
    GLuint vs, fs;
    static const GLushort indices[6] = {0, 1, 2, 2, 3, 0};

    ventana = v;

    /* El tamano de la superficie EGL, que es el unico dato fiable: SDL y
     * nwindow contestan 1920x1080 aunque la imagen salga a otra medida
     * (misma leccion que la sonda de main.cpp). */
    gl.GetIntegerv(GL_VIEWPORT, vp);
    if (vp[2] > 0 && vp[3] > 0) {
        pantallaW = vp[2];
        pantallaH = vp[3];
    }

    vs = compila(GL_VERTEX_SHADER, VERTICE);
    fs = compila(GL_FRAGMENT_SHADER, FRAGMENTO);
    if (!vs || !fs)
        return;

    programa = gl.CreateProgram();
    gl.AttachShader(programa, vs);
    gl.AttachShader(programa, fs);
    gl.BindAttribLocation(programa, 0, "pos");
    gl.BindAttribLocation(programa, 1, "uv");
    gl.LinkProgram(programa);
    {
        GLint ok = 0;
        gl.GetProgramiv(programa, GL_LINK_STATUS, &ok);
        if (!ok) {
            nx_boot_trace("[espera] el programa no enlaza; sin pantalla de carga");
            return;
        }
    }
    gl.DeleteShader(vs);
    gl.DeleteShader(fs);

    uPantalla   = gl.GetUniformLocation(programa, "pantalla");
    uColor      = gl.GetUniformLocation(programa, "color");
    uConTextura = gl.GetUniformLocation(programa, "conTextura");
    uTex        = gl.GetUniformLocation(programa, "tex");

    /* Un VAO propio: en un contexto GLES3 el 0 no siempre vale, y el de mkxp-z
     * todavia no existe. */
    gl.GenVertexArrays(1, &vao);
    gl.BindVertexArray(vao);

    gl.GenBuffers(1, &vbo);
    gl.BindBuffer(GL_ARRAY_BUFFER, vbo);
    gl.BufferData(GL_ARRAY_BUFFER, 16 * sizeof(float), 0, GL_DYNAMIC_DRAW);
    gl.GenBuffers(1, &ibo);
    gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    gl.BufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);

    gl.EnableVertexAttribArray(0);
    gl.VertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), 0);
    gl.EnableVertexAttribArray(1);
    gl.VertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float),
                           (const void *)(2 * sizeof(float)));

    /* El logo. Va empotrado en el binario porque esto se dibuja ANTES de que
     * PhysFS monte nada: en ese momento no se puede leer un fichero del juego. */
    {
        SDL_RWops *rw = SDL_RWFromConstMem(nx_espera_png, (int)nx_espera_png_len);
        SDL_Surface *bruta = rw ? IMG_Load_RW(rw, 1) : 0;
        SDL_Surface *rgba = bruta ? SDL_ConvertSurfaceFormat(bruta, SDL_PIXELFORMAT_ABGR8888, 0) : 0;

        if (!rgba) {
            nx_boot_trace("[espera] no pude decodificar espera.png");
            return;
        }
        logoW = rgba->w;
        logoH = rgba->h;
        texLogo = sube(rgba);
        SDL_FreeSurface(rgba);
        SDL_FreeSurface(bruta);
    }

    /* Un pixel blanco para las barras: mismo programa, sin textura de verdad. */
    {
        const unsigned char blanco[4] = {255, 255, 255, 255};
        gl.GenTextures(1, &texBlanco);
        gl.BindTexture(GL_TEXTURE_2D, texBlanco);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 1, 1, 0, GL_RGBA,
                      GL_UNSIGNED_BYTE, blanco);
    }

    viva = true;
    nx_boot_trace("[espera] pantalla de carga lista");
    /* Dos veces el primer fotograma, y no por gusto: la superficie de Horizon
     * tiene mas de un bufer, y un solo intercambio deja el otro con lo que
     * hubiera antes -negro-. Si el compositor ensena ese, el jugador ve negro
     * hasta el siguiente hito, que puede ser ocho segundos despues. Dos
     * intercambios cuestan 32 ms y quitan la duda. */
    nx_espera_paso(0.15f);
    nx_espera_paso(0.15f);
}

void nx_espera_paso(float fraccion)
{
    GLint fboAntes = 0;
    float alto, ancho, x, y, barraW, barraH, barraX, barraY;

    if (!viva)
        return;

    if (fraccion < 0.0f) fraccion = 0.0f;
    if (fraccion > 1.0f) fraccion = 1.0f;

    /* A la pantalla, no a lo que estuviera enganchado: en medio de la
     * construccion de SharedState puede haber un FBO puesto, y dibujar ahi
     * seria pintar dentro de una textura que nadie ensena. */
    gl.GetIntegerv(GL_FRAMEBUFFER_BINDING, &fboAntes);
    gl.BindFramebuffer(GL_FRAMEBUFFER, 0);

    gl.Viewport(0, 0, pantallaW, pantallaH);
    gl.Disable(GL_SCISSOR_TEST);
    gl.Disable(GL_DEPTH_TEST);
    gl.Enable(GL_BLEND);
    gl.BlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    /* Azul muy oscuro, no negro: el negro puro es indistinguible de una consola
     * que no ha arrancado, que es justo la duda que hay que quitar. */
    gl.ClearColor(0.043f, 0.063f, 0.125f, 1.0f);
    gl.Clear(GL_COLOR_BUFFER_BIT);

    gl.UseProgram(programa);
    gl.BindVertexArray(vao);
    gl.BindBuffer(GL_ARRAY_BUFFER, vbo);
    gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    gl.Uniform2f(uPantalla, (float)pantallaW, (float)pantallaH);
    gl.Uniform1i(uTex, 0);

    /* El logo ocupa el 62% del alto, centrado y un poco por encima del medio
     * para dejar sitio a la barra. */
    alto = pantallaH * 0.62f;
    ancho = alto * ((float)logoW / (float)logoH);
    x = (pantallaW - ancho) / 2.0f;
    y = (pantallaH - alto) / 2.0f - pantallaH * 0.04f;
    pinta(texLogo, x, y, ancho, alto, 1.0f, 1.0f, 1.0f, 1.0f);

    barraW = pantallaW * 0.46f;
    barraH = pantallaH * 0.018f;
    barraX = (pantallaW - barraW) / 2.0f;
    barraY = y + alto + pantallaH * 0.05f;
    pinta(texBlanco, barraX, barraY, barraW, barraH, 1.0f, 1.0f, 1.0f, 0.16f);
    pinta(texBlanco, barraX, barraY, barraW * fraccion, barraH,
          0.36f, 0.75f, 1.0f, 1.0f);

    SDL_GL_SwapWindow(ventana);

    gl.BindFramebuffer(GL_FRAMEBUFFER, fboAntes);
}

void nx_espera_cierra(void)
{
    if (!viva)
        return;

    gl.DisableVertexAttribArray(0);
    gl.DisableVertexAttribArray(1);
    gl.BindVertexArray(0);
    gl.BindBuffer(GL_ARRAY_BUFFER, 0);
    gl.BindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
    gl.BindTexture(GL_TEXTURE_2D, 0);
    gl.UseProgram(0);

    gl.DeleteTextures(1, &texLogo);
    gl.DeleteTextures(1, &texBlanco);
    gl.DeleteBuffers(1, &vbo);
    gl.DeleteBuffers(1, &ibo);
    gl.DeleteVertexArrays(1, &vao);
    gl.DeleteProgram(programa);

    viva = false;
    nx_boot_trace("[espera] pantalla de carga retirada");
}
