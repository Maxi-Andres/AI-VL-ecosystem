# AI-VL — Linux launchers

Scripts to install and run the system on Linux (equivalents of `../win/`). The flow is:

```
frontend (phone) → backend (:8443 HTTPS) → iacore (:8001) → Ollama (:11434, model)
```

The three repos (`AI-VL-core`, `AI-VL-backend`, `AI-VL-frontend`) go in this folder's
parent (the ecosystem root). The scripts auto-detect the repo root, so you can keep
`linux/` as a subfolder or move the `.sh` files to the root — either way works.

## Usage

The first time, make them executable:

```bash
chmod +x linux/install.sh linux/run.sh
```

1. **`./linux/install.sh`** — once (or when switching machines). Installs Python 3 /
   Bun / Ollama if missing, creates the venvs, runs `bun install` and pulls the Ollama
   model. It does NOT auto-elevate: it installs into your home and only asks for `sudo`
   when the installer needs it (distro packages, or Ollama's official script).

2. **`./linux/run.sh`** — brings everything up in **phone mode (HTTPS)** so you can use
   the phone as a camera. It builds the frontend and starts iacore + backend over
   HTTPS. Then, from the phone (same network/WiFi):

   ```
   https://<YOUR-PC-IP>:8443
   ```

   The phone will warn that the certificate is not trusted (it's self-signed) →
   *Advanced → Continue* (Android) / *Show details → visit the website* (iPhone).
   Then grant camera permission.

## Live logs

`run.sh` keeps running in the foreground and streams **both services' logs live** to
the terminal — every request uvicorn handles (GET/POST, who connects, WebSocket
upgrades, status codes), prefixed with `[iacore]` and `[backend]` so you can tell them
apart. This is the Linux equivalent of the two console windows on Windows. Press
`Ctrl+C` to shut both down cleanly.

## Certificate and IP changes

The browser camera requires HTTPS when you connect by LAN IP. That's why `run.sh`
generates a **self-signed certificate** in `../certs/` whose SAN includes your PC's IP.

- **Automatic IP change:** on each run, `run.sh` detects the IP of the interface with
  the default gateway (`ip route get 1.1.1.1`) and compares it against `../certs/ip.txt`.
  If it changed, it **regenerates the certificate on its own**. You don't have to do
  anything when you move between networks.

- **Force an IP manually:** if detection picks the wrong interface, create
  `../certs/ip.override.txt` with a single line holding the IP you want to use
  (e.g. `192.168.0.7`). Delete it to go back to automatic detection.

To see your IP: `ip addr` or `hostname -I`.

## Firewall

`run.sh` tries to open port `:8443` with `ufw` or `firewalld` (depending on the
distro), which may ask for `sudo`. If you have neither, it warns and continues: in that
case allow `8443/tcp` manually if the phone can't connect.

## Ports

| Service | Port | Notes |
|---------|------|-------|
| iacore  | 8001  | Local HTTP (YOLO/VLM detection) |
| backend | 8443  | HTTPS (phone mode); serves the frontend on a single origin |
| Ollama  | 11434 | model `qwen3-vl:4b-instruct` |

## Shutting down

`Ctrl+C` in the terminal running `run.sh` shuts iacore and backend down together.

## If the phone won't connect

- Make sure the PC and the phone are on the **same network/WiFi**.
- Make sure port `:8443` is open in the firewall (see above).
- Check the IP: if it changed and the cert is stale, run `run.sh` again (it regenerates).
