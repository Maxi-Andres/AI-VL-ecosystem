# Cómo usar: voz → robot (Go2) — quickstart

Loop completo: **hablás/escribís → el intérprete elige un skill → botón → el robot lo hace.**

```
🎤 → /command (skill JSON) → botón "Execute on robot" → backend /api/execute → ejecutor (ROS2) → 🤖 Go2
```

## Opción rápida — todo de una
Con el Go2 conectado (ver paso 1), desde `~/Desktop/AI-VL-ecosystem` un solo comando
levanta el devcontainer + el `robot_executor` + AI-VL:
```bash
! ./linux/run-with-robot.sh
```
Ctrl+C corta todo. Para probar sin mover el robot: `DRY_RUN=true ./linux/run-with-robot.sh`.
Si el `unitree_ros2` no está en `~/Desktop`, pasá `UNITREE_ROS2_DIR=/ruta ./linux/run-with-robot.sh`.

Si preferís hacerlo a mano (o entender cada pieza), seguí los pasos de abajo.

## 1) Conectar el Go2
- Cable ethernet perro ↔ PC. En `enp4s0`: IP fija `192.168.123.99`, máscara `255.255.255.0`.
- Verificá que esté conectado:
  ```bash
  ! ip -brief link show enp4s0        # debe decir UP (no NO-CARRIER)
  ! ping -c2 192.168.123.161          # el perro responde
  ```

## 2) Levantar AI-VL (oídos/ojos/boca + intérprete)
Desde `~/Desktop/AI-VL-ecosystem`:
```bash
! ./linux/run.sh
```
Levanta iacore + backend (HTTPS) + monitor. El backend habla con el ejecutor en `localhost:8090`.

## 3) Levantar el ejecutor (mueve el robot) — en el devcontainer
Abrí el devcontainer de `unitree_ros2` (VSCode → *Reopen in Container*) y en una terminal:
```bash
cp /workspace/robot_executor/.env.example /workspace/robot_executor/.env   # solo la 1ª vez
source /workspace/setup.sh
python3 /workspace/robot_executor/robot_executor_service.py
```
Queda escuchando en `:8090`. Por default: **SAFE_MODE=on** (bloquea acrobacias) y **DRY_RUN=off** (mueve de verdad).

## 4) Usar
En el navegador (página **Live** o **Monitor**), en el panel **"Robot command"**:
1. Elegí robot **Go2**.
2. Escribí o dictá (🎤) un comando: *"sentate"*, *"saludá"*, *"andá para adelante"*, *"pará"*.
3. **Interpret** → mirá el skill + JSON que eligió.
4. **Execute on robot** → el perro lo hace.

> Primer test: `sentate` o `saludá`, con el perro en un espacio despejado.

## Seguridad
- **SAFE_MODE**: bloquea flips / handstand / walk_upright. Para habilitarlos: `SAFE_MODE=false` en el `.env`.
- **Probar sin mover**: arrancá el ejecutor con `DRY_RUN=true` (loguea el comando, no lo manda).
- **Parar**: comando *"pará"* → `StopMove` inmediato. Los `walk`/`turn` acotados se frenan solos.

## Si algo no anda
- **"robot executor unreachable"** en la UI → el ejecutor (paso 3) no está corriendo.
- **`enp4s0 does not match an available interface`** → el Go2 no está conectado (enp4s0 DOWN); revisá el paso 1.
- **`no transport implemented for 'g1'`** → por ahora solo está cableado el Go2.
