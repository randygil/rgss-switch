# Arranca el juego en Ryujinx y toma capturas de la pantalla mientras corre.
# Es la unica verificacion que no admite discusion: o hay imagen o no la hay.
#
#   .\captura.ps1 -Juego pokemon-anil
#
# El slug es obligatorio: de el salen la ruta del .nro y el nombre de las
# capturas. Antes estaba escrito aqui dentro un juego concreto, que con un
# motor generico solo sirve para fotografiar siempre el mismo.
param(
    [Parameter(Mandatory=$true)][string]$Juego,
    [int[]]$Segundos = @(30, 60, 90),
    [string]$Etiqueta = "cap"
)
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# Sin esto, Screen.Bounds devuelve pixeles LOGICOS (con el escalado de Windows
# aplicado) mientras que CopyFromScreen copia pixeles FISICOS. El resultado no
# es una imagen encogida sino RECORTADA por la derecha y por abajo, y se pasa
# un buen rato creyendo que el fallo esta en el juego.
Add-Type -Name Ppp -Namespace Win32 -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
"@
[Win32.Ppp]::SetProcessDPIAware() | Out-Null

$sd  = "$env:APPDATA\Ryujinx\sdcard\switch\$Juego\$Juego.nro"
if (-not (Test-Path $sd)) { throw "no esta $sd" }
$dir = Join-Path $PSScriptRoot "docs\capturas"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$p = Start-Process -FilePath "C:\Games\publish\Ryujinx.exe" `
        -ArgumentList "--fullscreen", "`"$sd`"" -PassThru
Write-Output "Ryujinx PID $($p.Id)"

$anterior = 0
foreach ($s in $Segundos) {
    Start-Sleep -Seconds ($s - $anterior)
    $anterior = $s
    if ($p.HasExited) { Write-Output "el proceso ya habia terminado a los $s s"; break }
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
    $ruta = Join-Path $dir "$Juego-$Etiqueta-$($s)s.png"
    $bmp.Save($ruta, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Output "captura a los $s s -> $ruta"
}
if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; Write-Output "cerrado" }
