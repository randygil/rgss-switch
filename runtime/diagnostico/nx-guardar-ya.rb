# nx-guardar-ya.rb — sonda: guarda la partida en cuanto exista una.
#
# Llegar a un punto de guardado guionizando el mando es largo, y lo que hay que
# comprobar no es el menu de pausa —eso es codigo del juego, igual en cualquier
# plataforma— sino que la partida se escriba de verdad en la SD con el estado
# real: el Marshal entero, con el jugador, el mapa y la mochila.
#
# Se llama a SaveData.save_to_file DIRECTAMENTE ademas de a Game.save, por un
# motivo: Game.save envuelve la escritura en un `rescue IOError, SystemCallError`
# que devuelve false y se traga el error. Para el jugador esta bien; para
# averiguar por que ha fallado, no sirve de nada.
#
# Y hay que darle la ranura. (Escrita para Anil, el primer juego: el plugin
# Multi Save es suyo. En otro juego habra que mirar si redefine Game.save.)
# El plugin Multi Save de Anil redefine Game.save con
# la firma (slot, auto, safe:) y empieza con `slot = $player.save_slot` seguido
# de `return false if slot.nil?`: en una partida recien empezada, que todavia no
# se ha guardado nunca, save_slot es nil y Game.save devuelve false sin intentar
# nada. Los nombres de fichero tambien cambian: "Partida 1.rxdata", con espacio.
#
# No se carga en produccion.

module NXGuardarYa
  @hecho = false
  @estable = 0
  class << self
    attr_accessor :hecho
  end

  def self.revisar
    return unless defined?($player) && $player
    return unless defined?($game_map) && $game_map && $game_map.map_id != 0
    return unless defined?(SaveData)
    return unless defined?($scene) && $scene.class.to_s == "Scene_Map"
    return if defined?($game_temp) && $game_temp && $game_temp.message_window_showing
    return if respond_to?(:pbMapInterpreterRunning?) && pbMapInterpreterRunning?

    # Que el jugador tenga el control de verdad, no un hueco entre dos mensajes
    # de la introduccion: 180 fotogramas seguidos sin evento ni ventana.
    @estable += 1
    return if @estable < 180

    @hecho = true
    ranura = SaveData.respond_to?(:get_new_manual_slot) ? SaveData.get_new_manual_slot : nil
    ruta = ranura ? SaveData.get_full_path(ranura) : SaveData::FILE_PATH
    NX.log("[guardar] ranura #{ranura.inspect}")
    NX.log("[guardar] mapa #{$game_map.map_id}, jugador #{$player.name.inspect}")
    NX.log("[guardar] data_directory #{System.data_directory.inspect} dir=#{File.directory?(System.data_directory)}")
    NX.log("[guardar] ruta #{ruta.inspect}")

    # 1. Escritura pelada al mismo sitio, para separar "no se puede escribir
    #    ahi" de "algo falla al componer la partida".
    begin
      File.open(ruta + ".prueba", "wb") { |f| f.write("nx") }
      NX.log("[guardar] escritura pelada OK (#{File.size(ruta + '.prueba')} B)")
      File.delete(ruta + ".prueba")
    rescue Exception => e
      NX.log("[guardar] escritura pelada FALLO #{e.class}: #{e.message}")
    end

    # 2. La de verdad, sin red.
    t0 = Time.now
    SaveData.save_to_file(ruta)
    ms = ((Time.now - t0) * 1000).round
    NX.log("[guardar] save_to_file OK en #{ms} ms, #{File.size(ruta)} B")

    # 3. Releer con el mismo camino que usa el juego al cargar.
    datos = SaveData.read_from_file(ruta)
    NX.log("[guardar] releido: #{datos.class} con #{datos.size} claves")
    NX.log("[guardar] jugador releido: #{(datos[:player].name rescue '(no)')}")

    # 4. Y ahora por el camino de verdad, el mismo que el menu de pausa.
    ok = Game.save(ranura)
    NX.log("[guardar] Game.save(#{ranura.inspect}) -> #{ok}, #{File.size(ruta)} B")
    NX.log("[guardar] ficheros .rxdata en la carpeta: " +
           Dir.entries(SaveData::SAVE_DIR).select { |f| f.end_with?(".rxdata") }.inspect)
    NX.log("[guardar] OK")
  rescue Exception => e
    @hecho = true
    NX.log("[guardar] FALLO #{e.class}: #{e.message}")
    (e.backtrace || []).first(6).each { |l| NX.log("[guardar]   #{l}") }
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_guardar, :update

    def update
      NXGuardarYa.revisar unless NXGuardarYa.hecho
      nx_update_sin_guardar
    end
  end
end

NX.log("[guardar] sonda instalada")
