# nx-rutas-windows.rb - contrabarras, Dir.chdir y %TEMP% para la familia ruby31.
#
# Arregla: un script que abre "Graphics\\Pictures\\algo.png" o que hace
# Dir.chdir(ENV["TEMP"]). En Windows la contrabarra es un separador y el entorno
# trae TEMP; en Horizon la contrabarra es parte del nombre del fichero y el
# entorno esta vacio (Dir.chdir(nil) -> "no implicit conversion of nil").
# Visto en la familia ruby18 (Opalo, seccion 043, GifLibrary), donde lo tapa
# lib/nx-ruby18.rb; esto es lo mismo para los juegos de ruby31, que no cargan
# aquel fichero. De donde sale: idea de scripts/preload/windows_fs.rb de
# mkxp-z-apple-mobile (Empo, GPLv2+), REESCRITO aqui en corto; sin probar en
# consola todavia (2026-09-11): ningun perfil lo enciende.

module NXRutasWindows
  # Solo se toca una ruta que traiga contrabarra: si no la trae, se devuelve el
  # mismo objeto y no se paga ni un gsub. La mayoria de las rutas de estos
  # juegos ya vienen con barra normal.
  def self.arregla(ruta)
    return ruta unless ruta.is_a?(String)
    return ruta unless ruta.include?("\\")
    ruta.tr("\\", "/")
  end

  # El motor ya hizo chdir a la carpeta del juego antes de que Ruby arranque, y
  # ahi es donde tiene sentido escribir. Un TEMP que apunte a otro sitio no
  # existe en esta consola.
  def self.raiz
    @raiz ||= (Dir.pwd rescue ".")
  end
end

# --- Los metodos de clase que reciben rutas ---------------------------------
#
# No se envuelve TODO File: solo lo que estos juegos llaman con una ruta escrita
# a mano. Envolver de mas cuesta una llamada de Ruby por cada acceso a fichero,
# y en esta consola el sistema de ficheros ya es el cuello de botella.
[[File, [:open, :read, :readlines, :exist?, :exists?, :file?, :directory?,
         :size, :delete, :unlink, :rename, :expand_path, :basename, :dirname,
         :extname, :join, :mtime]],
 [FileTest, [:exist?, :exists?, :file?, :directory?]],
 [Dir, [:entries, :foreach, :glob, :mkdir, :chdir, :[]]],
 [IO, [:read, :readlines]]].each do |klass, metodos|
  metodos.each do |m|
    next unless klass.respond_to?(m)
    alias_nombre = "nx_win_#{m}".to_sym
    next if klass.respond_to?(alias_nombre)
    klass.singleton_class.send(:alias_method, alias_nombre, m)
    klass.define_singleton_method(m) do |*args, &blq|
      args = args.map { |a| NXRutasWindows.arregla(a) }
      send(alias_nombre, *args, &blq)
    end
  end
end

# --- Dir.chdir(nil) y el entorno vacio --------------------------------------
#
# Se rellenan las tres variables que estos juegos miran, y con la carpeta del
# juego, que es el unico sitio donde la consola deja escribir.
["TEMP", "TMP", "USERPROFILE", "APPDATA", "SystemRoot"].each do |var|
  next if ENV[var] && !ENV[var].to_s.empty?
  begin
    ENV[var] = NXRutasWindows.raiz
  rescue StandardError
    nil   # ENV es de solo lectura en algunas plataformas; no vale la pena caerse.
  end
end

class << Dir
  alias_method :nx_win_chdir_nil, :chdir unless respond_to?(:nx_win_chdir_nil)
  # Un chdir a nil o a una carpeta que no existe se queda donde esta y sigue.
  # El bloque se ejecuta igual: lo que el juego quiere no es cambiar de carpeta,
  # es ejecutar lo de dentro.
  def chdir(ruta = nil, &blq)
    return nx_win_chdir_nil(ruta, &blq) if ruta && Dir.exist?(ruta.to_s)
    return blq.call(Dir.pwd) if blq
    0
  end
end

NX.log("[nx] rutas de Windows: contrabarras, Dir.chdir y ENV puestos a la carpeta del juego") if defined?(NX)
