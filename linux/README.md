# AI-VL — launchers de Linux

Scripts para instalar y levantar el sistema en Linux (equivalentes de `../win/`).
El flujo es:

```
frontend (celular) → backend (:8443 HTTPS) → iacore (:8001) → Ollama (:11434, modelo)
```

Los tres repos (`AI-VL-core`, `AI-VL-backend`, `AI-VL-frontend`) van en la carpeta
padre de esta (la raíz del ecosystem). Los scripts detectan solos la raíz del repo,
así que podés dejar `linux/` como subcarpeta o mover los `.sh` a la raíz — funcionan
igual.

## Uso

La primera vez, dales permiso de ejecución:

```bash
chmod +x linux/install.sh linux/run.sh
```

1. **`./linux/install.sh`** — una sola vez (o al cambiar de PC). Instala Python 3 /
   Bun / Ollama si faltan, crea los venvs, hace `bun install` y baja el modelo de
   Ollama. No se auto-eleva: instala en tu home y solo pide `sudo` cuando el
   instalador lo necesita (paquetes de la distro, o el script oficial de Ollama).

2. **`./linux/run.sh`** — prende todo en **modo celular (HTTPS)** para usar el
   teléfono como cámara. Compila el frontend y levanta iacore + backend por HTTPS.
   Después, desde el celular (misma red/WiFi):

   ```
   https://<IP-de-tu-PC>:8443
   ```

   El celu avisa que el certificado no es de confianza (es autofirmado) →
   *Configuración avanzada → Continuar* (Android) / *Mostrar detalles → visitar
   el sitio* (iPhone). Después dale permiso de cámara.

## Certificado y cambio de IP

La cámara del navegador exige HTTPS cuando se entra por IP de LAN. Por eso
`run.sh` genera un **certificado autofirmado** en `../certs/` cuyo SAN incluye la
IP de tu PC.

- **Cambio de IP automático:** en cada corrida, `run.sh` detecta la IP de la placa
  con gateway por defecto (`ip route get 1.1.1.1`) y la compara con `../certs/ip.txt`.
  Si cambió, **regenera el certificado solo**. No tenés que hacer nada al moverte de red.

- **Forzar una IP a mano:** si la detección elige la placa equivocada, creá el archivo
  `../certs/ip.override.txt` con una sola línea que sea la IP que querés usar
  (p. ej. `192.168.0.7`). Borralo para volver a la detección automática.

Para ver tu IP: `ip addr` o `hostname -I`.

## Firewall

`run.sh` intenta abrir el puerto `:8443` con `ufw` o `firewalld` (según la distro),
lo cual puede pedir `sudo`. Si no tenés ninguno de los dos, se avisa y se sigue: en
ese caso permití el puerto `8443/tcp` a mano si el celular no conecta.

## Puertos

| Servicio | Puerto | Notas |
|----------|--------|-------|
| iacore   | 8001   | HTTP local (detección YOLO/VLM) |
| backend  | 8443   | HTTPS (modo celular); sirve el frontend en un solo origen |
| Ollama   | 11434  | modelo `qwen3-vl:4b-instruct` |

## Apagar

`Ctrl+C` en la terminal donde corre `run.sh`: apaga iacore y backend juntos.
Los logs quedan en `../.run-iacore.log` y `../.run-backend.log`.

## Si el celular no conecta

- Que la PC y el celu estén en la **misma red/WiFi**.
- Que el puerto `:8443` esté abierto en el firewall (ver arriba).
- Verificá la IP: si cambió y el cert es viejo, volvé a correr `run.sh` (regenera).
