# nx-guardado.rb — sonda del camino de guardado. No se carga en produccion.
#
# Guardar la partida es lo ultimo del bucle principal que quedaba sin
# comprobar, y no se puede dar por bueno por analogia: los registros del port
# se escriben con open()/write() de C, mientras que Pokemon Essentials guarda
# con File.open(ruta, "wb") de Ruby y Marshal.dump, y luego rota copias con
# File.rename y File.delete. Son cuatro operaciones distintas sobre la SD.
#
# La sonda hace exactamente lo mismo que SaveData.save_to_file, sobre un
# fichero de prueba y en el mismo directorio, y lo vuelve a leer.

module NXG
  def self.probar
    dir = System.data_directory
    NX.log("[guardar] System.data_directory -> #{dir.inspect}")
    NX.log("[guardar] directorio existe: #{File.directory?(dir)}")

    ruta = File.join(dir, "nx-prueba-guardado.rxdata")
    datos = { :entrenador => "LINA", :insignias => 8, :equipo => [1, 4, 7],
              :hora => Time.now.to_i }

    # 1. escribir como escribe el juego
    File.open(ruta, "wb") { |f| Marshal.dump(datos, f) }
    NX.log("[guardar] escrito #{File.size(ruta)} B en #{ruta}")

    # 2. releer y comparar
    vuelta = File.open(ruta, "rb") { |f| Marshal.load(f) }
    NX.log("[guardar] releido: #{vuelta == datos ? 'IDENTICO' : "DISTINTO #{vuelta.inspect}"}")

    # 3. rotacion de copia de seguridad (SaveData usa .bak)
    File.rename(ruta, ruta + ".bak")
    NX.log("[guardar] rename -> existe .bak: #{File.file?(ruta + '.bak')}, original: #{File.file?(ruta)}")

    # 4. borrado
    File.delete(ruta + ".bak")
    NX.log("[guardar] delete -> queda algo: #{File.file?(ruta + '.bak')}")

    NX.log("[guardar] OK")
  rescue Exception => e
    NX.log("[guardar] FALLO #{e.class}: #{e.message}")
    NX.log("[guardar] #{e.backtrace ? e.backtrace.first(4).join(' | ') : '(sin traza)'}")
  end
end

NXG.probar
