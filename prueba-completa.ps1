#Requires -Version 5.1
# Prueba de punta a punta (como administrador): crea un usuario de prueba con perfil,
# le pone archivos, una tarea, una regla de firewall y una clave de registro, lo borra
# con borrar-perfil.ps1 y comprueba que no quedo nada. No toca a ningun usuario real.
$ErrorActionPreference = 'Stop'
$U = 'zzPruebaBorrado'
$script = Join-Path $PSScriptRoot 'borrar-perfil.ps1'
$res = @()
function Check($nombre, [bool]$ok) { $script:res += [pscustomobject]@{ Prueba = $nombre; Resultado = $(if ($ok) { 'PASA' } else { 'FALLA' }) } }

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Correr como administrador (Probar.bat).' }

Add-Type -Namespace W -Name U -MemberDefinition @'
[DllImport("userenv.dll", CharSet = CharSet.Unicode)]
public static extern int CreateProfile(string sid, string name, System.Text.StringBuilder path, uint len);
'@

# 1) Usuario y perfil de prueba
$pwd = ConvertTo-SecureString ('Pz!' + [guid]::NewGuid().ToString('N')) -AsPlainText -Force
if (Get-LocalUser $U -ErrorAction SilentlyContinue) { Remove-LocalUser $U }
$u = New-LocalUser -Name $U -Password $pwd -Description 'Prueba de borrar-perfil (se borra sola)'
$sid = $u.SID.Value
$sb = New-Object Text.StringBuilder 260
$hr = [W.U]::CreateProfile($sid, $U, $sb, 260)
$ruta = $sb.ToString()
Check 'Crear perfil de prueba' ($hr -eq 0 -and (Test-Path $ruta))

# 2) Cosas que el usuario "deja"
foreach ($c in 'Documents', 'Downloads', 'Desktop') {
  New-Item -ItemType Directory (Join-Path $ruta $c) -Force | Out-Null
  Set-Content (Join-Path $ruta "$c\prueba.txt") 'hola'
}
$app = Join-Path $ruta 'AppData\Local\Prueba\app.exe'
New-Item -ItemType Directory (Split-Path $app) -Force | Out-Null; Set-Content $app 'x'
New-NetFirewallRule -DisplayName 'zzPruebaBorrado app' -Program $app -Action Allow | Out-Null
$accion = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c echo hola'
Register-ScheduledTask -TaskName 'zzPruebaBorrado-tarea' -Action $accion -User $U -Password ([Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pwd))) | Out-Null
New-Item "HKLM:\SOFTWARE\zzPruebaBorrado\$sid" -Force | Out-Null
# Junction hacia afuera del perfil: el borrado NO debe tocar lo de afuera
$afuera = Join-Path $env:TEMP 'zzPruebaBorrado-afuera'
New-Item -ItemType Directory $afuera -Force | Out-Null; Set-Content "$afuera\no-borrar.txt" 'debe quedar'
cmd /c "mklink /J `"$ruta\Documents\enlace-afuera`" `"$afuera`"" | Out-Null

# 3) Escanear
& $script -Usuario $U -Modo Escanear -Informes (Join-Path $PSScriptRoot 'informes\prueba') | Out-Host
Check 'Escaneo termina bien' ($LASTEXITCODE -eq 0)

# 4) Borrar todo
& $script -Usuario $U -Modo Borrar -BorrarCuenta -SinConfirmar -Informes (Join-Path $PSScriptRoot 'informes\prueba') | Out-Host
Check 'Borrado sin restos (exit 0)' ($LASTEXITCODE -eq 0)

# 5) Comprobar a mano
Check 'Carpeta del perfil borrada' (-not (Test-Path $ruta))
Check 'Clave ProfileList borrada' (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"))
Check 'Clave de prueba con SID borrada' (-not (Test-Path "HKLM:\SOFTWARE\zzPruebaBorrado\$sid"))
Check 'Cuenta borrada' (-not (Get-LocalUser $U -ErrorAction SilentlyContinue))
Check 'Tarea borrada' (-not (Get-ScheduledTask -TaskName 'zzPruebaBorrado-tarea' -ErrorAction SilentlyContinue))
Check 'Regla de firewall borrada' (-not (Get-NetFirewallRule -DisplayName 'zzPruebaBorrado app' -ErrorAction SilentlyContinue))
Check 'Lo de AFUERA del perfil sigue intacto' (Test-Path "$afuera\no-borrar.txt")

# Limpieza de la prueba
Remove-Item 'HKLM:\SOFTWARE\zzPruebaBorrado' -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $afuera -Recurse -Force -ErrorAction SilentlyContinue

$res | Format-Table -AutoSize | Out-Host
if ($res.Resultado -contains 'FALLA') { Write-Host 'HAY PRUEBAS QUE FALLAN' -ForegroundColor Red; exit 1 }
Write-Host 'TODAS LAS PRUEBAS PASAN' -ForegroundColor Green
