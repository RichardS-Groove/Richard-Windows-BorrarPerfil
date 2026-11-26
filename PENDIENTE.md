# Estado: perfil `Richard Campos` en TS-RICHARD BORRADO

**Ejecutado y completado el 25/11/2026** a pedido de la persona («quiero eliminar todo el usuario los archivos todo» y «no quiero respaldo de nada»).

- Usuario: `Richard Campos` · SID `S-1-5-21-1551183953-2271108334-2777909424-1003` · carpeta `C:\Users\Richard Campos`.
- **Carpeta:** purgada y borrada por completo (`Test-Path` dio `False`).
- **Cuenta:** eliminada de las cuentas locales de Windows (`Get-LocalUser`).
- **Registro (`regedit`):** clave `ProfileList\S-1-5-21-...-1003` y cualquier `.bak` eliminadas al 100 %.
  - No es posible restaurar el perfil desde el registro (`regedit`): no existe la clave en `ProfileList`, no hay `.bak`, la cuenta fue dada de baja y no existen los archivos en disco.
- **Respaldos e informes:** eliminados todos los informes y copias de seguridad de registro del disco de la máquina para no dejar ningún rastro.

## Antes de borrar (checklist)

- [ ] Todo lo de git subido: `Richard-Workspace`, este repo y cualquier otro en `C:\Users\Richard Campos\Music\`.
- [ ] Google Drive sincronizado (que no queden archivos solo en la PC).
- [ ] Documentos, Descargas, Escritorio, Imágenes: copiado lo que se quiera guardar.
- [ ] Contraseñas guardadas en el navegador / sesiones: exportadas o sincronizadas con la cuenta.
- [ ] Claves de la PC: Infisical sigue en la nube, nada que copiar.
- [ ] Saber la contraseña del usuario `Administrador` de esta PC (y probar que entra).

## El día que se borra

1. Cerrar sesión de `Richard Campos` y entrar con `Administrador`.
2. Bajar este repo **fuera** del perfil: `git clone https://github.com/RichardS-Groove/Richard-Windows-BorrarPerfil C:\BorrarPerfil`
   (o copiar la carpeta a `C:\BorrarPerfil`). Si el script está dentro del perfil a borrar, se frena solo.
3. Opcional, para quedarse tranquilo: `C:\BorrarPerfil\Probar.bat` (prueba fantasma con un usuario de prueba).
4. `C:\BorrarPerfil\BorrarPerfil.bat` → usuario `Richard Campos` → revisar el checklist → `S` → `S` (cuenta) →
   escribir `BORRAR Richard Campos`.
5. Tiene que terminar en `LISTO: no quedó nada`. Si no, reiniciar y correrlo de nuevo.
6. Borrar `C:\BorrarPerfil` cuando termine (los informes nombran al usuario).
