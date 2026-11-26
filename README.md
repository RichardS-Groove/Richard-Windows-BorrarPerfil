# Borrar un perfil de Windows por completo

Borra un usuario de Windows como si nunca hubiera existido: sus archivos (Documentos, Descargas, Escritorio,
AppData…), su rastro en el registro, sus tareas programadas, sus reglas de firewall, su papelera y, si querés,
la cuenta. Primero **escanea sin tocar nada** y arma un checklist; recién después, y si confirmás, borra.

## Cómo se usa (paso a paso)

1. Entrá a Windows con **otro** usuario administrador (por ejemplo `Administrador`). El usuario que vas a borrar
   tiene que tener la sesión **cerrada**; si dudás, reiniciá la PC.
2. Doble clic en **`BorrarPerfil.bat`**. Windows pide permiso de administrador: aceptá.
3. Muestra los perfiles de la PC. Escribí el nombre del que querés borrar.
4. **Paso 1 — Escaneo** (no toca nada). Recorre 8 lugares y los muestra en pantalla:
   1. La cuenta de usuario y sus grupos.
   2. El perfil registrado en Windows.
   3. La carpeta `C:\Users\<usuario>` con el tamaño de Documentos, Descargas, Escritorio, Imágenes, Videos,
      Música, OneDrive y AppData; y carpetas viejas del mismo usuario (`<usuario>.000`, etc.).
   4. Su papelera de reciclaje en cada disco.
   5. Tareas programadas que corren como ese usuario, y servicios (estos solo se avisan).
   6. Reglas del firewall de programas instalados dentro del perfil.
   7. Todo el registro (`HKLM\SOFTWARE` y `HKLM\SYSTEM`, ~500 mil claves, 1–2 minutos): claves con su SID en el
      nombre, ProfileList, ProfileGuid, la pantalla de inicio (último usuario), etc.
   8. Lo que no se toca a propósito (ver abajo).
5. Abre el **checklist** en el Bloc de notas. Revisalo.
6. Pregunta si querés borrar (S/N) y si querés borrar **también la cuenta** (S/N).
7. Para confirmar hay que escribir exactamente `BORRAR <usuario>`. Cualquier otra cosa cancela.
8. **Paso 2 — Borrado**, en este orden: cierra sus programas abiertos → tareas → firewall → perfil (método oficial
   de Windows) → restos de carpetas → registro → cuenta.
9. **Verificación**: vuelve a escanear y dice `LISTO: no quedó nada` o qué quedó. Si quedó algo, casi siempre
   alcanza con reiniciar y volver a correrlo.

Todo queda en `informes\<fecha>_<usuario>\`: `checklist.md` (marcado `[x]` borrado / `[!]` falló),
`verificacion.md` y `respaldo-registro\` (copia de las claves borradas, por las dudas; se puede borrar).

## Frenos de seguridad (no borra si…)

- Es el usuario con el que estás conectado, o tiene una sesión abierta / el perfil está en uso.
- Es el `Administrador` incorporado, `Default`, `Public` o una cuenta del sistema.
- No se abrió como administrador.
- No escribiste la confirmación exacta.

Los **enlaces** (junctions) dentro del perfil se quitan primero, así nunca se borra nada que esté **fuera** del perfil.

## Lo que NO se toca (a propósito)

| Qué | Por qué |
| --- | --- |
| Windows Hello (PIN/huella) | Es de SYSTEM; Windows lo limpia al borrar la cuenta. |
| Visor de eventos | Menciona el SID, pero borrarlo borra el historial de toda la PC. |
| Base de apps (StateRepository) | La maneja Windows; tocarla a mano rompe la Tienda. |
| Servicios que corren como el usuario | Se avisan: cambiarles la cuenta o desinstalarlos a mano. |

Una cuenta de Microsoft (correo) o de la empresa (Azure/Entra) sigue existiendo en la nube: esto borra solo lo de la PC.

## Probarlo sin riesgo

- **Simulación** (cualquier usuario, no toca nada): `powershell -ExecutionPolicy Bypass -File borrar-perfil.ps1 -Usuario <usuario>`
- **Prueba completa** (`Probar.bat`, como administrador): crea un usuario de prueba `zzPruebaBorrado` con perfil,
  archivos, una tarea, una regla de firewall, una clave de registro y un enlace hacia afuera; lo borra y comprueba
  10 puntos (incluido que lo de afuera del enlace siga intacto). No toca usuarios reales.

## Uso directo (sin el .bat)

```powershell
.\borrar-perfil.ps1 -Usuario <usuario>                              # escanear
.\borrar-perfil.ps1 -Usuario <usuario> -Modo Borrar                 # borrar archivos y registro
.\borrar-perfil.ps1 -Usuario <usuario> -Modo Borrar -BorrarCuenta   # y además la cuenta
```

Salidas: 0 bien · 2 quedaron restos · 3 no existe · 4 hay frenos · 5 sin administrador · 6 cancelado.

## De dónde sale (investigación)

- El método oficial es `Win32_UserProfile` + `Remove-CimInstance`: borra la carpeta y la clave ProfileList.
  Borrar solo la carpeta deja la clave huérfana y Windows después crea perfiles temporales.
  - [Microsoft Learn: scripts para limpiar perfiles](https://learn.microsoft.com/en-us/troubleshoot/windows-server/support-tools/scripts-to-cleanup-profile-folder-information-and-prevent-temp-user-profiles-from-being-created)
  - [Helge Klein: borrar un perfil local no es tan fácil](https://helgeklein.com/blog/deleting-a-local-user-profile-not-as-easy-as-one-might-assume/)
  - [Action1: borrar perfiles con PowerShell](https://www.action1.com/blog/how-to-delete-user-profiles-remotely-via-powershell-script/)
- Lo que el método oficial deja (ProfileGuid, Credential Providers, CapabilityAccessManager, Windows Search, etc.)
  no está documentado en una lista oficial: por eso el script **busca el SID en todo el registro** en vez de usar
  una lista fija. En la simulación del 25/11/2026 en TS-RICHARD (usuario `ts-in`) encontró 10 cosas para borrar.

## Versiones

- **1.1.0** (25/11/2026): menú interactivo numerado en `BorrarPerfil.bat` (sin tener que tipear nombres con espacios a mano); corrección de inicialización de `$Informes` en PowerShell 5.1; validación de eliminación completa en `regedit` (`ProfileList` sin `.bak` para evitar cualquier intento de restauración de perfil).
- **1.0.0** (25/11/2026): escáner + checklist + borrado + verificación + prueba completa.
