# nx-rutas.rb — memoria para el resolutor de rutas de Essentials.
#
# Medido en la consola: cada cambio de pestana en la pantalla de datos cuesta
# ~800 ms, y siempre los mismos. 784, 760, 838, 849, 867... El coste no baja al
# repetir, y eso es la firma de que no se guarda nada.
#
# Lo que pasa por debajo, por cada imagen que aparece en pantalla:
#
#   pbResolveBitmap(x)
#     x.gsub(/\.(bmp|png|gif|jpg|jpeg)$/, "")        una regex
#     RTP.eachPathFor(noext)                          dos regex mas
#       RTP.eachPath -> ".".gsub().gsub()             dos gsub sobre una constante
#         pbTryString(path + ".png")
#           pbGetFileChar
#             FileTest.exist?("./Game.rgssad")        LLAMADA AL SISTEMA
#             FileTest.exist?(canon_file)             LLAMADA AL SISTEMA
#             File.open(...) { |f| f.read(1) }        ABRIR + LEER + CERRAR
#
# Cinco llamadas al sistema y seis operaciones de cadena para averiguar algo que
# no cambia nunca: donde esta un fichero que se instalo con el juego. En un PC
# eso son microsegundos y nadie lo nota. En Horizon cada llamada al sistema de
# ficheros es un IPC —§5.48— y medido aqui salen ~2 ms cada una: una pantalla de
# trece imagenes gasta 65 llamadas.
#
# La cache es segura porque los graficos del juego no cambian mientras corre: el
# arbol se monta al arrancar y nadie escribe en Graphics/. Se memoriza tambien
# el nil, porque "esta imagen no existe" es una respuesta igual de estable y es
# la que mas cuesta (agota todos los candidatos).
#
# Como mkxp-z solo tiene preloadScript y no postloadScript, esto se carga antes
# de que el juego defina pbResolveBitmap. Por eso la instalacion es perezosa: se
# intenta en cada Graphics.update hasta que el metodo existe, que es en la
# primera vuelta del bucle principal.

module NXRutas
  BITMAP = {}

  @instalado = false
  @llamadas = 0
  @nuevas = 0
  @seg = 0.0

  class << self
    attr_reader :instalado

    def anota(nueva, t0)
      @llamadas += 1
      @nuevas += 1 if nueva
      @seg += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    end

    # Para el informe de nx-perfil.rb: cuantas resoluciones, cuantas fueron
    # nuevas de verdad y cuanto costaron.
    def cobra
      r = [@llamadas, @nuevas, @seg]
      @llamadas = 0
      @nuevas = 0
      @seg = 0.0
      r
    end

    def instala
      return true if @instalado
      return false unless Object.private_method_defined?(:pbResolveBitmap)
      @instalado = true

      Object.class_eval do
        alias_method :nx_pbResolveBitmap_sin_cache, :pbResolveBitmap

        def pbResolveBitmap(x)
          return nil if !x
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          cache = NXRutas::BITMAP
          if cache.key?(x)
            NXRutas.anota(false, t0)
            return cache[x]
          end
          r = nx_pbResolveBitmap_sin_cache(x)
          cache[x] = r
          NXRutas.anota(true, t0)
          r
        end
        private :pbResolveBitmap
      end

      # "./Game.rgssad" se consulta antes de CADA comprobacion de fichero, en
      # pbGetFileChar, pbRgssExists?, pbRgssOpen y pbGetFileString. Si no habia
      # un archivo cifrado al arrancar, no va a aparecer uno a mitad de partida.
      NXRutas.const_set(:HAY_RGSSAD, FileTest.exist?("./Game.rgssad"))
      class << FileTest
        alias_method :nx_exist_sin_rgssad, :exist?
        def exist?(x)
          return NXRutas::HAY_RGSSAD if x == "./Game.rgssad"
          nx_exist_sin_rgssad(x)
        end
      end

      NX.log("[rutas] resolutor memoizado (Game.rgssad: #{NXRutas::HAY_RGSSAD})")
      true
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_rutas, :update

    def update
      NXRutas.instala unless NXRutas.instalado
      nx_update_sin_rutas
    end
  end
end

NX.log("[rutas] a la espera de que el juego defina pbResolveBitmap")
