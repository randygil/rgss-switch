# nx-sonido.rb — por que el juego se queda mudo, si es que se queda.
#
# Con los datos en un contenedor los efectos de sonido no sonaban, y el juego no
# se quejaba: Essentials resuelve el audio con RTP.exists?, que pregunta por
# FileTest.exist?, y si eso contesta que no, pbResolveAudioSE devuelve nil y
# nadie pide el sonido. Un fallo mudo, en el sentido literal y en el otro.
#
# Esta sonda contesta las tres preguntas por separado, que es lo que hace falta
# para no confundir "no se encuentra" con "no se oye":
#
#   1. FileTest.exist? sobre un fichero que solo esta dentro del contenedor.
#   2. Que devuelve pbResolveAudioSE con un nombre de efecto de verdad.
#   3. Cuantas veces pide el juego un efecto mientras se juega, y cual.
#
# Si 1 y 2 salen bien y 3 cuenta llamadas, lo que quede es cosa del audio, no
# del sistema de ficheros; si 1 falla, esta pasando lo de arriba.
#
# Va en la lista de precarga del perfil de diagnostico. La instalacion de la
# cuenta es perezosa —el juego define Audio y $game_system despues— y se apoya en
# Graphics.update, igual que nx-rutas.rb.

module NXSonido
  EFECTO = "Battle ball drop"          # de Anil, el primer juego; cambialo por uno del tuyo
  DENTRO = "Audio/SE/#{EFECTO}.ogg"

  @instalado = false
  @pedidos = 0
  @ultimo = nil

  class << self
    def revisa
      NX.log("[sonido] FileTest.exist?(#{DENTRO.inspect}) = #{FileTest.exist?(DENTRO)}")
      NX.log("[sonido] File.exist? idem = #{File.exist?(DENTRO)}")
      if defined?(RTP)
        NX.log("[sonido] RTP.exists? = #{RTP.exists?("Audio/SE/" + EFECTO, ["", ".wav", ".ogg"])}")
      end
      if respond_to?(:pbResolveAudioSE, true) || Object.private_method_defined?(:pbResolveAudioSE)
        NX.log("[sonido] pbResolveAudioSE(#{EFECTO.inspect}) = #{pbResolveAudioSE(EFECTO).inspect}")
      end
    rescue Exception => e
      NX.log("[sonido] la revision fallo: #{e.class}: #{e.message}")
    end

    # Cuenta lo que el juego PIDE, que es distinto de lo que se oye: si aqui
    # entran llamadas y no hay sonido, el problema esta despues de esta linea.
    def instala
      return true if @instalado
      return false unless defined?(Audio) && Audio.respond_to?(:se_play)
      sonda = self
      Audio.singleton_class.send(:alias_method, :nx_se_play, :se_play)
      Audio.singleton_class.send(:define_method, :se_play) do |*args|
        sonda.anota(args[0])
        nx_se_play(*args)
      end
      @instalado = true
      NX.log("[sonido] contador de efectos puesto")
      revisa
      true
    end

    def anota(nombre)
      @pedidos += 1
      @ultimo = nombre
      NX.log("[sonido] efectos pedidos: #{@pedidos} | ultimo #{nombre.inspect}") if @pedidos <= 5 || @pedidos % 25 == 0
    end
  end
end

# Perezoso: Audio existe desde el principio, pero pbResolveAudioSE y RTP los
# define el juego, y eso pasa despues de los scripts de precarga.
module Graphics
  class << self
    unless method_defined?(:nx_sonido_update)
      alias_method :nx_sonido_update, :update
      def update(*args)
        NXSonido.instala unless NXSonido.instance_variable_get(:@instalado)
        nx_sonido_update(*args)
      end
    end
  end
end
