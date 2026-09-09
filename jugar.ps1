# Arranca el juego y lo CONDUCE: manda pulsaciones al emulador y toma capturas.
#
# Es el paso siguiente a captura.ps1. Aquella responde a "¿se dibuja algo?";
# esta responde a "¿responde a los mandos?", que es la unica manera de saber si
# el juego se puede jugar de verdad y no solo mirar.
#
# Ryujinx traduce teclado a mando de Switch. Con la configuracion de esta
# maquina: A=Z, B=X, X=C, Y=V, cruceta=flechas, +=Plus, -=Minus.
# mkxp-z, a su vez, mapea el boton A del mando a Input::C, que es el "aceptar"
# de RPG Maker. Asi que "Z" es el ENTER que pide la pantalla de titulo.
#
# Las pulsaciones van con keybd_event y NO con SendKeys: SendKeys suelta la
# tecla en el mismo instante, y un juego que lee el mando una vez por fotograma
# se pierde la mitad. Aqui se mantiene pulsada un tiempo medible.
#
# Guion: lista de acciones, cada una "tecla:Z", "esperar:1500" o "foto:nombre".
#
#   .\jugar.ps1 -Juego pokemon-anil
#
# El slug es obligatorio y de el sale la ruta del .nro; -Ruta sigue estando
# para apuntar a un .nsp o a un binario de prueba, que Ryujinx arranca igual
# desde la linea de ordenes.
param(
    [Parameter(Mandatory=$true)][string]$Juego,
    [string]$Ruta = "",
    [int]$Espera = 150,
    [string[]]$Guion = @("foto:titulo", "tecla:Z", "esperar:3000", "foto:tras-enter"),
    [string]$Etiqueta = "juego"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

Add-Type -Name Nativo -Namespace Win32 -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(System.IntPtr h, out int pid);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
public struct RECT { public int Left, Top, Right, Bottom; }
"@
[Win32.Nativo]::SetProcessDPIAware() | Out-Null

$VK = @{
    "Z" = 0x5A; "X" = 0x58; "C" = 0x43; "V" = 0x56
    "W" = 0x57; "A" = 0x41; "S" = 0x53; "D" = 0x44
    "ARRIBA" = 0x26; "ABAJO" = 0x28; "IZQUIERDA" = 0x25; "DERECHA" = 0x27
    "MAS" = 0xBB; "MENOS" = 0xBD; "ENTER" = 0x0D; "ESC" = 0x1B
}
if (-not $Ruta) { $Ruta = "$env:APPDATA\Ryujinx\sdcard\switch\$Juego\$Juego.nro" }
if (-not (Test-Path $Ruta)) { throw "no esta $Ruta" }
$dir = Join-Path $PSScriptRoot "docs\capturas"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

# -Ruta acepta tanto el .nro (menu homebrew) como el .nsp (aplicacion instalada):
# Ryujinx arranca los dos igual desde la linea de ordenes.
$p = Start-Process -FilePath "C:\Games\publish\Ryujinx.exe" `
        -ArgumentList "--fullscreen", "`"$Ruta`"" -PassThru
Write-Output "Ryujinx PID $($p.Id); esperando $Espera s a que arranque el juego"
Start-Sleep -Seconds $Espera

function Enfocar {
    $p.Refresh()
    if ($p.MainWindowHandle -ne [System.IntPtr]::Zero) {
        [Win32.Nativo]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
    }
    Start-Sleep -Milliseconds 250
}

# La foto solo se guarda SI EL EMULADOR ESTA DELANTE.
#
# Copiar la pantalla entera parecia inofensivo y no lo es: esta maquina la usa
# alguien mientras la prueba corre, asi que en cuanto otra ventana se pone
# encima -o el emulador se muere a mitad de guion- lo que queda guardado en
# docs/capturas es el escritorio con lo que hubiera abierto. Paso de verdad: una
# tanda entera de capturas de Opalo y de Z eran WhatsApp y el editor, y hubo que
# borrarlas.
#
# Se probo antes PrintWindow sobre la ventana del emulador, que tendria la
# ventaja de no necesitar el foco; no vale: en pantalla completa lo que dibuja
# OpenGL no esta en el cliente de la ventana principal y lo unico que sale es la
# barra de menu. Asi que se comprueba de quien es la ventana de primer plano y,
# si no es del emulador, no se guarda nada: "no hay foto" es mejor dato que una
# foto de otra cosa.
function Foto([string]$nombre) {
    $ruta = Join-Path $dir "$Juego-$Etiqueta-$nombre.png"
    $p.Refresh()
    if ($p.HasExited) {
        Write-Output "  foto $nombre OMITIDA: el emulador ya habia terminado"
        return
    }
    Enfocar
    $h = $p.MainWindowHandle
    $pid_frente = 0
    [Win32.Nativo]::GetWindowThreadProcessId([Win32.Nativo]::GetForegroundWindow(), [ref]$pid_frente) | Out-Null
    if ($pid_frente -ne $p.Id) {
        Write-Output "  foto $nombre OMITIDA: delante hay otra ventana (pid $pid_frente)"
        return
    }
    # Y solo el rectangulo de SU ventana, no la pantalla: en ventana -no en
    # pantalla completa- detras esta el escritorio de quien usa la maquina.
    $w = New-Object Win32.Nativo+RECT
    [Win32.Nativo]::GetWindowRect($h, [ref]$w) | Out-Null
    $ancho = $w.Right - $w.Left
    $alto  = $w.Bottom - $w.Top
    if ($ancho -le 0 -or $alto -le 0) {
        Write-Output "  foto $nombre OMITIDA: la ventana mide ${ancho}x${alto}"
        return
    }
    $bmp = New-Object System.Drawing.Bitmap $ancho, $alto
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen((New-Object System.Drawing.Point $w.Left, $w.Top), [System.Drawing.Point]::Empty, (New-Object System.Drawing.Size $ancho, $alto))
    $bmp.Save($ruta, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Output "  foto -> $ruta"
}

Enfocar
foreach ($accion in $Guion) {
    if ($p.HasExited) { Write-Output "el emulador ya habia terminado"; break }
    $partes = $accion.Split(":", 2)
    switch ($partes[0]) {
        "tecla" {
            $nombre = $partes[1].ToUpper()
            if (-not $VK.ContainsKey($nombre)) { throw "tecla desconocida: $nombre" }
            Enfocar
            $codigo = [byte]$VK[$nombre]
            [Win32.Nativo]::keybd_event($codigo, 0, 0, [System.UIntPtr]::Zero)
            Start-Sleep -Milliseconds 150
            [Win32.Nativo]::keybd_event($codigo, 0, 2, [System.UIntPtr]::Zero)
            Write-Output "  tecla $nombre"
            Start-Sleep -Milliseconds 400
        }
        "esperar" { Start-Sleep -Milliseconds ([int]$partes[1]) }
        "foto"    { Foto $partes[1] }
        default   { throw "accion desconocida: $accion" }
    }
}

if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
Write-Output "cerrado"
