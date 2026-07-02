# AI-VL — ecosystem

Repo **wrapper**: agrupa los launchers (`win/`, `linux/`) y la documentación para
instalar y correr el sistema completo. **No contiene el código de las apps** — los
tres repos de las apps son independientes (cada uno su propio `.git`) y están
git-ignorados acá (ver `.gitignore`); hay que clonarlos dentro de esta carpeta.

## Arquitectura

Tres apps independientes que se comunican **por red (puerto), nunca por ruta de
archivo** (cada una puede correr en otra máquina):

```
frontend (celular)  →  backend (:8443 HTTPS)  →  iacore (:8001)  →  Ollama (:11434, modelo)
   UI en el navegador     gateway / API+WS         YOLO + VLM         qwen3-vl:4b-instruct
```

- **iacore** (`AI-VL-core`) — núcleo de inferencia: YOLO + VLM y las deps pesadas
  (torch/ultralytics). Expone `service:app` en `:8001`.
- **backend** (`AI-VL-backend`) — gateway al que se conecta el navegador (WS para el
  stream de video). Relaya los frames a iacore. Sin deps de modelo. `app:app`.
- **frontend** (`AI-VL-frontend`) — UI minimalista en el navegador. Solo habla con el
  backend. React + Vite, se compila con `bun`.

## Estructura

```
AI-VL-ecosystem/
├── README.md            ← este archivo
├── .gitignore
├── win/                 ← launchers de Windows  (install.bat/.ps1, run.bat/.ps1)
├── linux/               ← launchers de Linux    (install.sh, run.sh)
├── AI-VL-core/          ← repo independiente (clonar)   · iacore
├── AI-VL-backend/       ← repo independiente (clonar)   · gateway
├── AI-VL-frontend/      ← repo independiente (clonar)   · UI
└── certs/               ← certificado TLS autogenerado por run (git-ignorado)
```

## Repos a clonar

Cloná los tres **dentro de esta carpeta** (respetá los nombres de carpeta):

```bash
git clone https://github.com/Maxi-Andres/AI-VL-core.git      AI-VL-core
git clone https://github.com/Maxi-Andres/AI-VL-backend.git   AI-VL-backend
git clone https://github.com/Maxi-Andres/AI-VL-frontend.git  AI-VL-frontend
```

| Repo | URL | Rol |
|------|-----|-----|
| `AI-VL-core`     | https://github.com/Maxi-Andres/AI-VL-core.git     | iacore — YOLO + VLM (`:8001`) |
| `AI-VL-backend`  | https://github.com/Maxi-Andres/AI-VL-backend.git  | gateway — API + WS (`:8443`) |
| `AI-VL-frontend` | https://github.com/Maxi-Andres/AI-VL-frontend.git | UI del navegador |

## Puertos

| Servicio | Puerto | Notas |
|----------|--------|-------|
| iacore   | 8001   | HTTP local (detección YOLO/VLM) |
| backend  | 8443   | HTTPS (modo celular); sirve el frontend en un solo origen |
| Ollama   | 11434  | modelo `qwen3-vl:4b-instruct` |

## Arranque rápido

1. Cloná los tres repos acá dentro (ver arriba).
2. Según tu sistema operativo, usá los launchers (detectan solos la raíz, así que
   sirven desde la subcarpeta o movidos a la raíz):
   - **Windows** → [`win/`](win/README.md): `install.bat` (una vez) y `run.bat`.
   - **Linux** → [`linux/`](linux/README.md): `./install.sh` (una vez) y `./run.sh`.

Ambos instalan lo que falte (Python, Bun, Ollama), arman los venvs, compilan el
frontend y levantan todo en **modo celular (HTTPS)** para usar el teléfono como
cámara. Los launchers **no tocan git**: respetan la rama/commit de cada repo.
