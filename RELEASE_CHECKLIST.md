# Checklist de release y pruebas

Usa esta lista antes de publicar una nueva versión en un repo privado de producción.

## Antes de crear la release

- Ejecuta `bash release_check.sh`.
- Verifica que `git status` esté limpio.
- Confirma que `master` apunta al último commit estable.
- Revisa que el cambio corresponda a un feature, bugfix o hotfix correcto.
- Valida que `main.py`, `templates/index.html` y `static/js/app.js` no tengan errores.
- Comprueba que `.env` no contiene secretos que no deban salir de la máquina.
- Asegúrate de que `users.json`, `panel.log` y otros archivos runtime siguen ignorados.

## Crear la release

- Empuja los cambios a `origin/master`.
- Crea el tag de versión, por ejemplo `v1.1.1` o `v1.2.0` según el alcance.
- Publica la GitHub Release desde el tag.
- Resume el cambio en las notas de release con qué cambió, cómo probarlo y si hay riesgos.

## Probar en entorno privado

- Clona el repo en una máquina limpia o VM de Ubuntu.
- Ejecuta `bash setup_ubuntu.sh`.
- Copia `.env.example` a `.env` y ajusta valores locales.
- Inicia el panel con el método elegido: manual o `systemd`.
- Verifica acceso web, login básico, carga de logs y control de servicio.
- Prueba el flujo de actualización con `bash update_ubuntu.sh`.

## Criterios mínimos de aceptación

- La UI carga sin errores y el backend responde en `http://localhost:8080`.
- `update_ubuntu.sh` termina sin fallos y no rompe `.env`.
- El servicio `senderman-ftp-admin` arranca y reinicia correctamente.
- Los archivos de release están limitados a código, docs y scripts necesarios.

## Recomendación para producción

- Mantén el repo privado.
- Usa una cuenta o token con permisos mínimos.
- Prueba primero en staging antes de usar una máquina productiva real.
- Conserva una versión anterior para rollback rápido.