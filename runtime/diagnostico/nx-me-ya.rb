# nx-me-ya.rb — sonda: reproduce una fanfarria encima de la musica de fondo.
#
# Es lo que pasa al coger un objeto, y era justo lo que ninguna prueba guionizada
# habia hecho nunca: se llego al combate, al guardado y al nombre, pero jamas se
# recogio nada. Por eso el fallo del relevo ME->BGM (§5.57) sobrevivio a todas
# las ejecuciones del emulador y aparecio en la primera partida de verdad.
#
# Se hace dos veces seguidas, porque el estado es una maquina y el segundo paso
# es el que dice si quedo bien colocada tras el primero.
#
# No se carga en produccion.

module NXMe
  @hecho = false
  class << self; attr_accessor :hecho; end

  def self.revisar
    return unless defined?($scene) && $scene.class.to_s == "Scene_Map"
    return if defined?($game_temp) && $game_temp && $game_temp.message_window_showing
    @hecho = true

    2.times do |i|
      NX.log("[me] --- prueba #{i + 1} ---")
      NX.log("[me] bgm_play")
      Audio.bgm_play("Audio/BGM/AltoMando.ogg", 100, 100) rescue
        NX.log("[me] no se pudo poner esa BGM: #{$!.class}")
      60.times { Graphics.update }
      NX.log("[me] me_play (la fanfarria de objeto)")
      Audio.me_play("Audio/ME/Item get.wav", 100, 100) rescue
        NX.log("[me] no se pudo poner ese ME: #{$!.class}")
      240.times { Graphics.update }
      NX.log("[me] fin de la prueba #{i + 1}")
    end
  rescue Exception => e
    @hecho = true
    NX.log("[me] FALLO #{e.class}: #{e.message}")
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_me, :update
    def update
      NXMe.revisar unless NXMe.hecho
      nx_update_sin_me
    end
  end
end

NX.log("[me] sonda instalada")
