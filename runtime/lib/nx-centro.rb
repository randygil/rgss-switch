# nx-centro.rb — findCenter sin cuarenta mil viajes de Ruby a C.
#
# El plugin [MUI] Pokemon UI centra el sprite del Pokemon con findCenter, que
# busca el primer pixel opaco desde cada borde llamando a get_pixel una vez por
# pixel. Se ejecuta en cada drawPage de la vista de datos, a traves de
# pbSetDisplay, y medido en la consola:
#
#   Sum#drawPage 1x/657ms/421.461obj   Bmp#get_pixel 41.430x/289ms/290.011obj
#
# Es decir: de los 657 ms de un cambio de pestana, casi 300 son esto, y de los
# 420.000 objetos, 290.000 son los Color que devuelve get_pixel. Y esta en
# TODAS las paginas, no solo en la de estadisticas, que es lo que cuadra con lo
# que se nota jugando.
#
# El barrido ahora lo hace Bitmap#nx_opaque_bounds en C++ (ver bitmap.cpp), en
# una pasada por la copia en RAM y una unica llamada. Aqui solo se rehace la
# aritmetica del original, con sus mismas rarezas (empieza a buscar en la
# columna 1 y la fila 1), para que el Pokemon quede pintado exactamente donde
# estaba.
#
# findCenter es una funcion global que define el plugin despues del preload,
# asi que se sustituye tarde, la primera vez que existe. Si el binario no trae
# nx_opaque_bounds —un .nro viejo con este lib nuevo— se deja el original.

module NXCentro
  @instalado = false

  class << self
    attr_reader :instalado

    def instala
      return true if @instalado
      return false unless Object.private_method_defined?(:findCenter) ||
                          Object.method_defined?(:findCenter)
      @instalado = true

      unless Bitmap.method_defined?(:nx_opaque_bounds)
        NX.log("[centro] este .nro no trae nx_opaque_bounds; findCenter se queda como estaba")
        return true
      end

      Object.class_eval do
        alias_method :nx_findCenter_pixel_a_pixel, :findCenter

        def findCenter(bitmap)
          return [0, 0] if !bitmap
          return nx_findCenter_pixel_a_pixel(bitmap) unless bitmap.respond_to?(:nx_opaque_bounds)
          width = bitmap.width
          height = bitmap.height
          left, right, top, bottom = bitmap.nx_opaque_bounds
          return [0, 0] if left < 0 || right < 0 || top < 0 || bottom < 0
          # Mismas cuatro coordenadas que el original: [izq, ancho-der-1, arriba, alto-abajo-1]
          coords = [left, width - right - 1, top, height - bottom - 1]
          offsetX = ((coords[1] - coords[0]) / 2).ceil
          offsetY = ((coords[3] - coords[2]) / 2).ceil
          return [offsetX, offsetY]
        end
      end

      NX.log("[centro] findCenter pasa por nx_opaque_bounds")

      # findTop, de [Deluxe Utilities] Deluxe Battle Rules, es el mismo barrido
      # pero solo por arriba, y se ejecuta al aparecer cada Pokemon en combate
      # (y al colocar el icono de megaevolucion). El original recorre las filas
      # (1..alto) y devuelve la primera con un pixel opaco, o 0 si no hay; el
      # "top" de nx_opaque_bounds se calcula con esa misma regla.
      if Object.private_method_defined?(:findTop) || Object.method_defined?(:findTop)
        Object.class_eval do
          alias_method :nx_findTop_pixel_a_pixel, :findTop

          def findTop(bitmap)
            return 0 if !bitmap
            return nx_findTop_pixel_a_pixel(bitmap) unless bitmap.respond_to?(:nx_opaque_bounds)
            top = bitmap.nx_opaque_bounds[2]
            return (top < 0) ? 0 : top
          end
        end
        NX.log("[centro] findTop pasa por nx_opaque_bounds")
      end
      true
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_centro, :update

    def update
      NXCentro.instala unless NXCentro.instalado
      nx_update_sin_centro
    end
  end
end

NX.log("[centro] a la espera de findCenter")
