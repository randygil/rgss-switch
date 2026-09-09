# nx-uranium-audio.rb — el audio de Pokemon Uranium sin FmodEx.
#
# Uranium es el unico juego del censo que no es mkxp-z: es el reproductor
# original de RPG Maker XP (Uranium.exe de 110 KB + RGSS102E.dll, Ruby 1.8.1),
# y su clase Audio NO es la de RGSS. Son dos secciones de Scripts.rxdata:
#
#   0249 "RGSS Linker"        carga "RGSS Linker.dll" con Win32API y hace
#                             `raise LoadError` si la DLL no contesta 1.
#   0250 "F-mod main script"  hace Kernel.load_module("RGSS FmodEx.dll",
#                             "Init_FmodEx"), llama a ::FmodEx.init(64) y
#                             reescribe entero el module Audio sobre FmodEx.
#
# En Horizon no hay ninguna de las dos DLL, y el Win32API postizo de
# runtime/lib/nx-ruby18.rb devuelve 0 a todo. Con eso:
#
#   - 0249 linea 12: `raise LoadError, "Failed to load RGSS Linker."` porque
#     `@RGSS_Linker[:core].call(lib_name)` da 0 y no 1. El juego se para AHI,
#     en la seccion 249 de 260, antes de la pantalla de titulo.
#   - 0250 linea 28: `::FmodEx.init(64)` -> NameError, constante FmodEx.
#
# O sea que no basta con callar el Win32API: hay que poner otra cosa en su
# lugar. Eso es este fichero. La estrategia es NO DEJAR QUE ESAS DOS SECCIONES
# SE EVALUEN: se envuelve NXFuente.transforma —el gancho que el motor llama con
# (nombre, codigo) antes de evaluar cada seccion— y para esos dos nombres se
# devuelve, en su lugar, la implementacion de aqui abajo, escrita contra la
# clase Audio nativa de mkxp-z.
#
# ---------------------------------------------------------------------------
# QUE PIDE EL JUEGO DE VERDAD (recuento sobre las 260 secciones)
# ---------------------------------------------------------------------------
#
#   Audio.bgm_play      4    Audio.bgs_play   6    Audio.se_play   4
#   Audio.bgm_stop      3    Audio.bgs_stop   4    Audio.se_stop   3
#   Audio.bgm_fade      2    Audio.bgs_fade   3
#   Audio.me_play       2    Audio.bgm_position 1
#   Audio.me_stop       3
#   Audio.me_fade       2
#
# Y una cosa que se ve leyendo el script de FmodEx y no el recuento: sus
# bgs_play, bgs_fade, bgs_stop, se_play y se_stop llevan la condicion
# `if(@library != ::FmodEx)` COMENTADA (el autor puso "#JV" al lado), asi que
# esas cinco ya llamaban al Audio de RGSS y no a FmodEx. Solo bgm_* y me_*
# pasaban por FmodEx de verdad. Lo que se pierde al quitar FmodEx, por tanto,
# es menos de lo que las 31 referencias a fmod sugieren.
#
# Audio.sine, doubleSine, square, triangle, saw, noise, playTone y beep (39
# usos) NO son de FmodEx: los define 0050 "AudioUtilities v17" generando la
# onda a mano y sacandola por winmm (waveOutOpen/waveOutWrite). Con el Win32API
# postizo esas llamadas devuelven 0 y no suenan; son los tonos del telefono y
# los pitidos, y no tumban nada. No se tocan aqui.
#
# 0048 "Audio" define OTRA clase Audio entera sobre "audio.dll", pero el bloque
# va dentro de `if safeExists?("audio.dll")` y esa DLL no viaja a la tarjeta
# (§2 de CONVENCIONES.md no copia *.dll), asi que ese camino no existe en la
# consola. De ahi sale tambien `Audio.bgm_position`, que por eso el juego llama
# con `rescue 0` (0019 "Game_System v17" linea 87): en el original de Windows
# con FmodEx ese metodo NO EXISTIA y la posicion del BGM se perdia siempre.
# Aqui si se implementa, sobre Audio.bgm_pos.

module NXUranioAudio
  # --- la Audio nativa, guardada ANTES de que nadie la redefina -------------
  #
  # Se captura al cargar el preload, que es antes de la primera seccion de
  # Scripts.rxdata. Son objetos Method: siguen apuntando a la funcion C aunque
  # despues se redefina Audio.bgm_play, que es exactamente lo que va a pasar
  # cuando se evalue la seccion sustituida. Es el mismo truco que usaba el
  # script de FmodEx (`@bgm_play = method(:bgm_play)`), por el mismo motivo.
  #
  # La lista sale de src/mkxp-z/binding/audio-binding.cpp:
  #   bgm_play(nombre, vol, pitch, pos, pista)  bgm_stop  bgm_fade  bgm_pos
  #   bgm_volume  bgm_set_volume
  #   bgs_play(nombre, vol, pitch, pos)  bgs_stop  bgs_fade  bgs_pos
  #   me_play(nombre, vol, pitch)  me_stop  me_fade
  #   se_play(nombre, vol, pitch)  se_stop
  #   setup_midi  __reset__
  # No hay se_fade, y el script de FmodEx tampoco lo tenia: no falta nada.
  NATIVO = {}

  PEDIDOS = %w[bgm_play bgm_stop bgm_fade bgm_pos bgm_volume bgm_set_volume
               bgs_play bgs_stop bgs_fade bgs_pos
               me_play me_stop me_fade
               se_play se_stop].freeze

  def self.captura
    faltan = []
    PEDIDOS.each do |m|
      if defined?(Audio) && Audio.respond_to?(m)
        NATIVO[m.to_sym] = Audio.method(m)
      else
        faltan << m
      end
    end
    if faltan.empty?
      NX.log("[uranio] Audio nativa capturada: #{NATIVO.size} metodos")
    else
      NX.log("[uranio] Audio nativa capturada: #{NATIVO.size} metodos; FALTAN #{faltan.join(' ')}")
    end
  end

  @avisos = {}

  # Llamar a la nativa sin que un fallo suyo tumbe el juego. Un sonido que no
  # suena es un defecto; una excepcion en mitad de un combate es una partida
  # perdida. Se avisa UNA vez por metodo y se sigue.
  def self.nativo(clave, *args)
    m = NATIVO[clave]
    if m.nil?
      unless @avisos[clave]
        @avisos[clave] = true
        NX.log("[uranio] Audio.#{clave} no existe en este motor: llamada ignorada")
      end
      return nil
    end
    m.call(*args)
  rescue Exception => e
    unless @avisos[["fallo", clave]]
      @avisos[["fallo", clave]] = true
      NX.log("[uranio] Audio.#{clave}#{args.inspect}: #{e.class}: #{e.message}")
    end
    nil
  end

  # --- volumenes ------------------------------------------------------------
  #
  # Se copia LA ARITMETICA DEL SCRIPT DE FMODEX, no una parecida, para que el
  # juego suene igual de fuerte que en Windows:
  #
  #   volume = volume * @master_volume / 100          # 0250 lineas 60 y 96
  #   volume *= ($PokemonSystem.bgmvolume/100.0) if $PokemonSystem
  #   volume = volume.to_i
  #
  # y con @sfx_volume y $PokemonSystem.sevolume para bgs y se (lineas 78 y 112).
  # @master_volume y @sfx_volume valen 100 los dos y nadie los cambia en las 260
  # secciones, asi que son constantes; se dejan escritos igual porque el dia que
  # alguien anada un ajuste de volumen maestro, este es el sitio.
  MAESTRO = 100
  EFECTOS = 100

  def self.volumen(v, base, ajuste)
    v = v.to_i * base / 100
    if $PokemonSystem && $PokemonSystem.respond_to?(ajuste)
      p = $PokemonSystem.send(ajuste)
      v = v * (p.to_f / 100.0) if p
    end
    v = v.to_i
    v = 0 if v < 0
    v = 100 if v > 100
    v
  rescue StandardError
    v.to_i
  end

  def self.vol_musica(v);  volumen(v, MAESTRO, :bgmvolume); end
  def self.vol_efectos(v); volumen(v, EFECTOS, :sevolume);  end

  # El pitch de RGSS va de 50 a 150 y 100 es "normal". Un 0 o un nil llegando a
  # la nativa seria un sonido a velocidad cero; se normaliza aqui y no en cada
  # metodo.
  def self.tono(p)
    p = p.to_i
    p = 100 if p <= 0
    p
  end

  # La posicion llega del propio juego (0019 "Game_System v17" guarda
  # @bgm_position y se lo devuelve a bgm_play al reanudar) y puede ser nil, 0 o
  # lo que devolvio bgm_pos. La nativa espera un Float en segundos: un negativo
  # o un NaN ahi es un salto a ninguna parte, asi que se recorta a 0.
  def self.segundos(v)
    p = v.to_f
    return 0.0 if p.nan? || p.infinite? || p < 0.0
    p
  rescue StandardError
    0.0
  end

  # --- la API que el juego llama -------------------------------------------

  # El cuarto argumento es la novedad respecto al original. 0019 "Game_System
  # v17" linea 59 llama `Audio.bgm_play(name,vol,pitch,position)` y envuelve la
  # llamada en `rescue ArgumentError` para reintentar con tres: el bgm_play de
  # FmodEx solo aceptaba tres, asi que en el juego de Windows la posicion SE
  # PERDIA SIEMPRE y volver de un combate reiniciaba la musica. La nativa de
  # mkxp-z si tiene ese parametro (audio.h: `float pos`, en segundos de
  # reproduccion), y bgm_pos devuelve lo mismo en las mismas unidades, asi que
  # aqui el par pausar/reanudar cierra de verdad.
  def self.bgm_play(nombre, volumen = 100, pitch = 100, posicion = nil)
    nativo(:bgm_play, nombre.to_s, vol_musica(volumen), tono(pitch), segundos(posicion))
  end

  def self.bgm_fade(ms); nativo(:bgm_fade, ms.to_i); end
  def self.bgm_stop;     nativo(:bgm_stop);          end

  # Audio.bgm_position: 0019 linea 87, dentro de bgm_pause. La nativa devuelve
  # un Float en segundos; el juego solo lo guarda para devolverselo a bgm_play,
  # asi que las unidades dan igual mientras las dos puntas sean las mismas.
  def self.bgm_position; nativo(:bgm_pos).to_f; end

  def self.me_play(nombre, volumen = 100, pitch = 100)
    nativo(:me_play, nombre.to_s, vol_musica(volumen), tono(pitch))
  end

  def self.me_fade(ms); nativo(:me_fade, ms.to_i); end
  def self.me_stop;     nativo(:me_stop);          end

  # bgs y se van con el volumen de EFECTOS ($PokemonSystem.sevolume), que es lo
  # que hacia el script de FmodEx aunque despues llamara al Audio de RGSS.
  def self.bgs_play(nombre, volumen = 100, pitch = 100, posicion = nil)
    nativo(:bgs_play, nombre.to_s, vol_efectos(volumen), tono(pitch), segundos(posicion))
  end

  def self.bgs_fade(ms); nativo(:bgs_fade, ms.to_i); end
  def self.bgs_stop;     nativo(:bgs_stop);          end
  def self.bgs_position; nativo(:bgs_pos).to_f;      end

  def self.se_play(nombre, volumen = 100, pitch = 100)
    nativo(:se_play, nombre.to_s, vol_efectos(volumen), tono(pitch))
  end

  def self.se_stop; nativo(:se_stop); end

  # check_file del script de FmodEx (0250 linea 122) probaba once extensiones
  # con File.exist? porque FmodEx exigia el nombre completo. La Audio de mkxp-z
  # resuelve la extension ella sola por PhysFS —y ademas por el indice de rutas
  # en minusculas (pathCache), que es lo que hace que "Audio/BGM/TITULO" case
  # con "Titulo.ogg" dentro de datos.zip—, asi que aqui no hay nada que probar:
  # se devuelve el nombre tal cual. Se conserva el metodo porque es publico y
  # cualquier parche del juego podria llamarlo.
  def self.check_file(nombre)
    nombre
  end

  # loop_audio + LOOP_TABLE eran la extension de FmodEx para puntos de bucle
  # manuales ([fichero, principio, final]). LOOP_TABLE viene VACIA en Uranium
  # 1.3.2 (0250 lineas 12-19: solo el comentario "Add here"), asi que no se
  # pierde ni un bucle. mkxp-z respeta los puntos LOOPSTART/LOOPLENGTH que
  # traigan los propios .ogg, que es como estan hechos los de este juego.
  def self.loop_audio(_sonido, _nombre)
    nil
  end
end

# ---------------------------------------------------------------------------
# El codigo que sustituye a cada seccion
# ---------------------------------------------------------------------------
#
# Se devuelven como cadenas y no se evaluan aqui a proposito: asi se evaluan en
# EL MISMO SITIO Y EN EL MISMO ORDEN que el original, con lo que todo lo que
# venga despues (secciones 251 a 260) se encuentra exactamente lo que esperaba.
module NXUranioSecciones
  # 0249 "RGSS Linker" (Nuri Yuri, 2015). Lo unico que deja detras y que otro
  # script pueda usar es Kernel.load_module; en las 260 secciones se llama UNA
  # vez, desde el propio script de FmodEx, pero se define igual porque el
  # contrato del script es ese y un mod podria pedirlo.
  LINKER = <<~'RUBY'
    module Kernel
      unless @RGSS_Linker
        @RGSS_Linker = { :core => nil }
        module_function
        def load_module(nombre, funcion)
          NX.log("[uranio] Kernel.load_module(#{nombre.inspect}, #{funcion.inspect}) ignorado: en Horizon no hay DLL")
          nil
        end
      end
    end
  RUBY

  # 0250 "F-mod main script". Se conserva la forma: module Audio con
  # module_function, las constantes publicas (LOOP_TABLE, EXT) y los mismos
  # nombres de metodo, para que cualquier cosa que las mire las encuentre.
  # El cuerpo delega en NXUranioAudio, que es quien habla con la nativa.
  FMOD = <<~'RUBY'
    $channelcount = 0 if !$channelcount

    # FmodEx postizo. Nada de las 260 secciones lo nombra fuera de este script
    # -se comprobo con grep-, pero el original dejaba la constante puesta y
    # algun parche de la comunidad la mira para saber si hay audio "bueno".
    # Que exista y delegue es mas barato que un NameError.
    module FmodEx
      def self.init(*_); true; end
      def self.bgm_play(n, v = 100, p = 100); NXUranioAudio.bgm_play(n, v, p); nil; end
      def self.bgm_fade(t);                   NXUranioAudio.bgm_fade(t); end
      def self.bgm_stop;                      NXUranioAudio.bgm_stop; end
      def self.bgs_play(n, v = 100, p = 100); NXUranioAudio.bgs_play(n, v, p); nil; end
      def self.bgs_fade(t);                   NXUranioAudio.bgs_fade(t); end
      def self.bgs_stop;                      NXUranioAudio.bgs_stop; end
      def self.me_play(n, v = 100, p = 100);  NXUranioAudio.me_play(n, v, p); end
      def self.me_fade(t);                    NXUranioAudio.me_fade(t); end
      def self.me_stop;                       NXUranioAudio.me_stop; end
      def self.se_play(n, v = 100, p = 100);  NXUranioAudio.se_play(n, v, p); end
      def self.se_stop;                       NXUranioAudio.se_stop; end
    end

    module Audio
      LOOP_TABLE = [] unless const_defined?(:LOOP_TABLE)
      EXT = ['.ogg', '.mp3', '.wav', '.mid', '.aac', '.wma',
             '.it', '.xm', '.mod', '.s3m', '.midi'] unless const_defined?(:EXT)

      unless @nx_uranio
        @nx_uranio = true
        module_function

        def bgm_play(file_name, volume = 100, pitch = 100, position = nil)
          NXUranioAudio.bgm_play(file_name, volume, pitch, position)
        end
        def bgm_fade(time);  NXUranioAudio.bgm_fade(time); end
        def bgm_stop;        NXUranioAudio.bgm_stop; end
        def bgm_position;    NXUranioAudio.bgm_position; end

        def bgs_play(file_name, volume = 100, pitch = 100, position = nil)
          NXUranioAudio.bgs_play(file_name, volume, pitch, position)
        end
        def bgs_fade(time);  NXUranioAudio.bgs_fade(time); end
        def bgs_stop;        NXUranioAudio.bgs_stop; end

        def me_play(file_name, volume = 100, pitch = 100)
          NXUranioAudio.me_play(file_name, volume, pitch)
        end
        def me_fade(time);   NXUranioAudio.me_fade(time); end
        def me_stop;         NXUranioAudio.me_stop; end

        def se_play(file_name, volume = 100, pitch = 100)
          NXUranioAudio.se_play(file_name, volume, pitch)
        end
        def se_stop;         NXUranioAudio.se_stop; end

        def check_file(file_name);      NXUranioAudio.check_file(file_name); end
        def loop_audio(sound, name);    NXUranioAudio.loop_audio(sound, name); end
      end
    end
  RUBY

  # Se compara por nombre NORMALIZADO —minusculas y sin nada que no sea letra o
  # numero— porque el nombre llega tal cual lo escribio RPG Maker XP dentro de
  # Scripts.rxdata: "RGSS Linker" y "F-mod main script" hoy, pero un espacio de
  # mas o un guion de menos en otra version no puede costar el arranque.
  TABLA = {
    "rgsslinker"     => LINKER,
    "fmodmainscript" => FMOD,
    "fmodmain"       => FMOD
  }.freeze

  def self.normaliza(nombre)
    n = nombre.to_s.dup.force_encoding("UTF-8")
    n = n.scrub("") unless n.valid_encoding?
    n.downcase.gsub(/[^a-z0-9]/, "")
  rescue StandardError
    ""
  end

  def self.sustituto(nombre)
    TABLA[normaliza(nombre)]
  end
end

# ---------------------------------------------------------------------------
# El enganche: NXFuente.transforma
# ---------------------------------------------------------------------------
#
# El motor llama a NXFuente.transforma(nombre, codigo) antes de evaluar cada
# seccion y evalua lo que devuelva (runtime/lib/nx-ruby18.rb, apartado 1). Se
# envuelve con alias_method sobre el singleton en vez de tocar nx-ruby18.rb:
# ese fichero es de la FAMILIA entera (Opalo, Iberia, Titan, Z tambien lo
# cargan) y esto es de un juego solo.
#
# Se comprueba que NXFuente exista: si el empaquetador no puso nx-ruby18.rb
# —avisa cuando falta— este shim no puede hacer nada, y mas vale decirlo en el
# registro que quedarse callado.
if defined?(NXFuente) && NXFuente.respond_to?(:transforma)
  module NXFuente
    class << self
      alias_method :nx_transforma_sin_uranio, :transforma

      def transforma(nombre, codigo)
        sust = NXUranioSecciones.sustituto(nombre)
        if sust
          NX.log("[uranio] seccion #{nombre.inspect} SUSTITUIDA " \
                 "(#{codigo.to_s.lines.size} lineas de FmodEx -> #{sust.lines.size} de la capa nativa)")
          return sust
        end
        nx_transforma_sin_uranio(nombre, codigo)
      end
    end
  end
  NX.log("[uranio] NXFuente.transforma envuelto: se sustituyen \"RGSS Linker\" y \"F-mod main script\"")
else
  NX.log("[uranio] AVISO: no hay NXFuente; el juego evaluara el FmodEx original y morira con LoadError")
end

NXUranioAudio.captura

# ---------------------------------------------------------------------------
# Lo que esta capa NO cubre, y hay que mirar en la consola
# ---------------------------------------------------------------------------
#
#   Los tonos generados (Audio.sine y compania, 39 usos en 0050
#   "AudioUtilities v17"). Se sintetizan a mano y salen por winmm, que el
#   Win32API postizo contesta con 0: no suenan. Son el timbre del telefono, el
#   pitido de retroceso y la llamada en espera. No se cae nada.
#
#   El volumen maestro y el de efectos son 100 fijos, como en el original. Si
#   se anade un ajuste, va en NXUranioAudio::MAESTRO / EFECTOS.
#
#   Los cuatro .mid de Audio/ (713 ficheros: 378 ogg, 272 wav, 55 mp3, 4 mid).
#   mkxp-z los toca con fluidsynth y un soundfont, y este juego no trae
#   ninguno; con midiSoundFont sin fijar sonaran a nada. Es lo mismo que le
#   pasa a Iberia y a Titan.
#
#   Audio.bgm_volume / bgm_set_volume de la nativa no los llama nadie en las
#   260 secciones: el juego cambia el volumen volviendo a llamar a bgm_play.
#   Estan capturados por si hicieran falta.
