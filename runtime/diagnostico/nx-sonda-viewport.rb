# encoding: utf-8
#
# nx-sonda-viewport.rb — por que la imagen sale en un rincon de la pantalla.
#
# Randy: "no esta nada centrado el viewport, se ve super curseado" (Opalo en la
# consola y en el emulador). La captura de Z en Ryujinx mide el area del juego
# en 960x720 dentro de los 1200x895 que ocupa la ventana del emulador: 0,8
# justo, que es 512/640 y 384/480. O sea que la pantalla logica del motor se
# quedo en 640x480 -el valor por omision de mkxp-z para RGSS1- y Essentials
# clasico dibuja sus 512x384 en la esquina de arriba a la izquierda.
#
# Esta sonda contesta a "quien no hizo el cambio de tamano": si el juego no lo
# pidio (Graphics.haveresizescreen false) o si lo pidio y el motor no lo aplico.
#
# Se carga DESPUES de nx-ruby18.rb y ANTES de los scripts del juego, asi que
# aqui Graphics todavia es el del motor: se guarda su width/height de verdad
# con otro nombre, porque Sprite_Resizer los va a pisar con los suyos
# (@@width=DEFAULTSCREENWIDTH) y despues ya no hay forma de preguntarselo.

module Graphics
  class << self
    alias nx_ancho_real width
    alias nx_alto_real height
    alias nx_resize_real resize_screen

    # El juego llama a esto desde pbSetResizeFactor2 DENTRO de un begin/rescue
    # pelado: si lanza, no se entera nadie. Aqui se cuenta lo que paso.
    def resize_screen(w, h)
      NX.log("[viewport] el juego pide resize_screen(#{w.inspect}, #{h.inspect})")
      nx_resize_real(w, h)
      NX.log("[viewport] tras resize_screen: motor #{nx_ancho_real}x#{nx_alto_real}")
    rescue Exception => e
      NX.log("[viewport] resize_screen LANZA #{e.class}: #{e.message}")
      raise
    end
  end
end

module NXSondaViewport
  @@dicho = 0

  def self.linea(cuando)
    real_w = (Graphics.nx_ancho_real rescue "?")
    real_h = (Graphics.nx_alto_real rescue "?")
    juego_w = (Graphics.width rescue "?")
    juego_h = (Graphics.height rescue "?")
    tiene = (Graphics.haveresizescreen rescue "sin-metodo")
    NX.log("[viewport] #{cuando}: motor #{real_w}x#{real_h} | " \
           "juego #{juego_w}x#{juego_h} | haveresizescreen #{tiene.inspect} | " \
           "factor #{$ResizeFactor.inspect} offset #{$ResizeOffsetX.inspect}," \
           "#{$ResizeOffsetY.inspect} | " \
           "screensize #{($PokemonSystem.screensize rescue 'sin-PokemonSystem').inspect} " \
           "border #{($PokemonSystem.border rescue '?').inspect} | " \
           "Graphics.fullscreen #{(Graphics.fullscreen rescue '?').inspect}")
  end

  # Se dice en el primer Graphics.update (el juego ya ha cargado sus scripts y
  # ha llamado a pbSetResizeFactor) y otra vez a los 600 fotogramas, que es
  # despues del titulo.
  def self.late
    @@dicho += 1
    linea("update #{@@dicho}") if @@dicho == 1 || @@dicho == 600
    if @@dicho == 150
      # Quien es pbSetResizeFactor a estas alturas: el de Sprite_Resizer o el
      # sello vacio que 0170_PSystem_System.rb:28 le pone encima.
      begin
        NX.log("[viewport] arity de pbSetResizeFactor = "                "#{Object.instance_method(:pbSetResizeFactor).arity} "                "(el de Sprite_Resizer es -1; el sello de 0170, 1)")
      rescue Exception => e
        NX.log("[viewport] pbSetResizeFactor: #{e.class}: #{e.message}")
      end
    end
    if @@dicho == 300
      # Prueba de control: lo pide la sonda, no el juego, y sin rescue de por
      # medio. Si aqui la pantalla logica SI cambia, el motor sabe hacerlo y el
      # que se quedo corto fue el camino del juego.
      begin
        Graphics.nx_resize_real(512, 384)
        NX.log("[viewport] la sonda pidio 512x384: motor "                "#{Graphics.nx_ancho_real}x#{Graphics.nx_alto_real}")
      rescue Exception => e
        NX.log("[viewport] la sonda no pudo: #{e.class}: #{e.message}")
      end
    end
  end
end

module Graphics
  class << self
    alias nx_update_sonda update
    def update
      NXSondaViewport.late
      nx_update_sonda
    end
  end
end

NX.log("[viewport] sonda puesta; motor arranca en " \
       "#{Graphics.nx_ancho_real}x#{Graphics.nx_alto_real}")
