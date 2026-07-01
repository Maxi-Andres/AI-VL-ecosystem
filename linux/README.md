# AI-VL — launchers de Linux

Equivalentes de Linux a los scripts de `../win/` (install / run modo celular).

> **Pendiente de portar.** Hoy están los de Windows (`../win/`). La versión Linux
> usaría `python3 -m venv`, `bun`, `ollama` y `openssl` (todos multiplataforma) con
> los mismos puertos y el mismo flujo:
>
> ```
> frontend (celular) → backend (:8443 HTTPS) → iacore (:8001) → Ollama (:11434)
> ```
>
> El certificado autofirmado con la IP de LAN en el SAN se genera igual con
> `openssl` (en Linux no hace falta `MSYS_NO_PATHCONV`). El puerto :8443 se abre
> con `firewalld`/`ufw` según la distro.

Cuando se instale en otro sistema, agregar acá `install.sh` y `run.sh`.
