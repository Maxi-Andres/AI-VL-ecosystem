# AI-VL — Windows launchers

Scripts to install and bring the system up on Windows. The flow is:

```
frontend (phone) → backend (:8000/:8443) → iacore (:8001) → Ollama (:11434, model)
```

The three repos (`AI-VL-core`, `AI-VL-backend`, `AI-VL-frontend`) go in this folder's
parent (the ecosystem root). The scripts auto-detect the repo root, so you can keep
`win/` as a subfolder or move the `.bat` files to the root — either way works.

## Usage

1. **`install.bat`** — once (or when switching machines). Installs Python/Bun/Ollama
   if missing, creates the venvs, runs `bun install` and pulls the Ollama model. It
   auto-elevates to administrator (winget needs it).

2. **`run.bat`** — brings everything up in **phone mode (HTTPS)** so you can use the
   phone as a camera. It builds the frontend and starts iacore + backend over HTTPS.
   Then, from the phone (same network/WiFi):

   ```
   https://<YOUR-PC-IP>:8443
   ```

   The phone will warn that the certificate is not trusted (it's self-signed) →
   *Advanced → Continue* (Android) / *Show details → visit the website* (iPhone).
   Then grant camera permission.

## Certificate and IP changes

The browser camera requires HTTPS when you connect by LAN IP. That's why `run.bat`
generates a **self-signed certificate** in `../certs/` whose SAN includes your PC's IP.

- **Automatic IP change:** on each run, `run.ps1` detects the IP of the network
  adapter that has a gateway (it ignores the virtual VMware/WSL adapters) and compares
  it against `../certs/ip.txt`. If it changed, it **regenerates the certificate on its
  own**. You don't have to do anything when you move between networks.

- **Force an IP manually:** if detection picks the wrong adapter (for example you have
  several physical NICs), create the file:

  ```
  ../certs/ip.override.txt
  ```

  with a single line holding the IP you want to use, e.g. `192.168.0.7`. `run.bat` will
  use that IP (and regenerate the cert for it). Delete it to go back to automatic
  detection.

To see your IP: `ipconfig` (the *IPv4 Address* field of your network adapter).

## Ports

| Service | Port | Notes |
|---------|------|-------|
| iacore  | 8001  | Local HTTP (YOLO/VLM detection) |
| backend | 8443  | HTTPS (phone mode); serves the frontend on a single origin |
| Ollama  | 11434 | model `qwen3-vl:4b-instruct` |

## Shutting down

Close the 2 windows that `run.bat` opens (iacore and backend).

## If the phone won't connect

- Make sure the PC and the phone are on the **same network/WiFi**.
- The firewall rule for `:8443` is created by `run.bat` (that's why it needs admin).
- Check the IP: if it changed and the cert is stale, run `run.bat` again (it regenerates).
