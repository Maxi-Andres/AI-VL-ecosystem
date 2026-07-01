# AI-VL — launchers de Windows

Scripts para instalar y levantar el sistema en Windows. El flujo es:

```
frontend (celular) → backend (:8000/:8443) → iacore (:8001) → Ollama (:11434, modelo)
```

Los tres repos (`AI-VL-core`, `AI-VL-backend`, `AI-VL-frontend`) van en la carpeta
padre de esta (`win/`). Los scripts detectan solos la raíz del repo, así que
podés dejar `win/` como subcarpeta o mover los `.bat` a la raíz — funcionan igual.

## Uso

1. **`install.bat`** — una sola vez (o al cambiar de PC). Instala Python/Bun/Ollama
   si faltan, crea los venvs, hace `bun install` y baja el modelo de Ollama.
   Se auto-eleva a administrador (winget lo necesita).

2. **`run.bat`** — prende todo en **modo celular (HTTPS)** para usar el teléfono
   como cámara. Compila el frontend y levanta iacore + backend por HTTPS.
   Después, desde el celular (misma red/WiFi):

   ```
   https://<IP-de-tu-PC>:8443
   ```

   El celu avisa que el certificado no es de confianza (es autofirmado) →
   *Configuración avanzada → Continuar* (Android) / *Mostrar detalles → visitar
   el sitio* (iPhone). Después dale permiso de cámara.

## Certificado y cambio de IP

La cámara del navegador exige HTTPS cuando se entra por IP de LAN. Por eso
`run.bat` genera un **certificado autofirmado** en `../certs/` cuyo SAN incluye la
IP de tu PC.

- **Cambio de IP automático:** en cada corrida, `run.ps1` detecta la IP de la
  placa de red que tiene gateway (ignora los adaptadores virtuales de VMware/WSL)
  y la compara con `../certs/ip.txt`. Si cambió, **regenera el certificado solo**.
  No tenés que hacer nada al moverte de red.

- **Forzar una IP a mano:** si la detección elige la placa equivocada (por ejemplo
  tenés varias placas físicas), creá el archivo:

  ```
  ../certs/ip.override.txt
  ```

  con una sola línea que sea la IP que querés usar, p. ej. `192.168.0.7`.
  `run.bat` va a usar esa IP (y regenerar el cert para ella). Borralo para volver
  a la detección automática.

Para ver tu IP: `ipconfig` (campo *Dirección IPv4* de tu adaptador de red).

## Puertos

| Servicio | Puerto | Notas |
|----------|--------|-------|
| iacore   | 8001   | HTTP local (detección YOLO/VLM) |
| backend  | 8443   | HTTPS (modo celular); sirve el frontend en un solo origen |
| Ollama   | 11434  | modelo `qwen3-vl:4b-instruct` |

## Apagar

Cerrá las 2 ventanas que abre `run.bat` (iacore y backend).

## Si el celular no conecta

- Que la PC y el celu estén en la **misma red/WiFi**.
- La regla de Firewall para el `:8443` la crea `run.bat` (por eso pide admin).
- Verificá la IP: si cambió y el cert es viejo, volvé a correr `run.bat` (regenera).
