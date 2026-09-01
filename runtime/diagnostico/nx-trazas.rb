# nx-trazas.rb — sondas temporales de nivel Ruby.
#
# El registro se corta siempre en el mismo sitio (el aviso de version de
# Essentials) y a partir de ahi el juego no dice nada mas: ni error ni
# fotograma. Hacen falta dos datos que ningun registro de C puede dar, porque
# ocurren dentro del interprete:
#
#   1. Si Thread.new devuelve. Era el muro de §5.41 y ahora que hay pipe()
#      deberia volver, pero "deberia" no es una medida.
#   2. Si se llega a Graphics.update, que es el latido del bucle principal.
#      Mientras no aparezca, la pantalla negra es porque nadie dibuja.
#
# Se carga como preload despues de nx-compat.rb y se quita cuando arranque.

module NXT
  @hilos = 0
  @frames = 0

  @reloj = nil

  class << self
    attr_accessor :hilos, :frames, :reloj
  end
end

class << Thread
  alias_method :nx_new_sin_traza, :new

  def new(*args, &bloque)
    NXT.hilos += 1
    n = NXT.hilos
    origen = caller(1, 1)
    origen = origen ? origen.first : "?"
    NX.log("[traza] Thread.new ##{n} desde #{origen}")
    hilo = nx_new_sin_traza(*args) do |*a|
      begin
        bloque.call(*a)
      rescue Exception => e
        NX.log("[traza] hilo ##{n} murio: #{e.class}: #{e.message}")
        raise
      end
    end
    NX.log("[traza] Thread.new ##{n} devuelto -> #{hilo.class}")
    hilo
  end
end

# Graphics.update es un metodo de modulo definido en C++ por mkxp-z; se puede
# alias igual que cualquier otro. Solo se anotan los primeros y luego uno cada
# 300 (cinco segundos a 60 Hz) para no convertir el registro en el cuello de
# botella.
module Graphics
  class << self
    alias_method :nx_update_sin_traza, :update

    def update
      NXT.frames += 1
      n = NXT.frames
      if n == 1
        NXT.reloj = Time.now
      elsif n % 300 == 0
        ahora = Time.now
        seg = ahora - NXT.reloj
        NX.log(format("[traza] fotograma %d | %.1f fps en los ultimos 300",
                      n, seg > 0 ? 300.0 / seg : 0.0))
        NXT.reloj = ahora
      end
      nx_update_sin_traza
    end
  end
end

NX.log("[traza] sondas de Ruby instaladas")
