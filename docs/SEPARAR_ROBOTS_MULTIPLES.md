# Separar varios robots: elegir en el header y mandar solo a ese

Objetivo: tener el Go2 y el G1 conectados a la vez, elegir en el **header** cuál
querés usar, y que **los comandos (y el video) vayan solo a ese robot**.

## El problema de fondo (DDS)

Los robots Unitree usan **los mismos nombres de topic** (`/api/sport/request`,
`/api/videohub/request`, `/api/arm/request`, `/api/voice/request`, …) y **no llevan
un ID de robot** en el mensaje. Si los dos están en el **mismo dominio DDS**, no hay
forma de direccionar a uno solo: **los dos reciben el request y los dos responden**.

Esto se ve como:
- Video intercalado (frames de un robot y del otro).
- **Peligroso:** un comando de movimiento le llega a los dos → los dos se mueven.

Cambiar el selector del header **no alcanza** por sí solo: hay que separarlos a
nivel **DDS**, y recién ahí el selector elige a cuál hablarle.

Hay dos formas de separarlos. Elegí una.

---

## Opción A — Un dominio DDS por robot (recomendada si el robot lo permite)

Cada robot en un **`ROS_DOMAIN_ID` distinto**. Propuesta: **G1 = 0** (default),
**Go2 = 1**.

### Del lado del robot (lo hacés vos)
El dominio lo fija la **computadora de a bordo del robot**, no AI-VL. Hay que
entrar por SSH a la PC de a bordo del Go2 y hacer que sus servicios arranquen con
`ROS_DOMAIN_ID=1` (o el dominio de CycloneDDS correspondiente), y reiniciarlos.

> ⚠️ Salvedad: en muchos Go2/G1 el dominio viene **fijo en 0** de fábrica y cambiarlo
> no está bien soportado (depende del firmware). Si tu Go2 no lo permite, usá la
> **Opción B** (interfaz), que no toca el robot.

### Del lado de AI-VL (lo hago yo)
Un proceso puede hablar con varios dominios usando **un `Context` de rclpy por
dominio** (`rclpy.init(context=ctx, domain_id=N)` — ya verificado que el rclpy del
contenedor lo soporta). El plan:

- **Executor** (`robot_executor/`): cada transport (Go2/G1) crea su propio `Context`
  en el dominio del robot. Como el executor solo *publica* (no spinnea), es directo:
  el transport del G1 vive en dominio 0 y el del Go2 en dominio 1, **en simultáneo**,
  sin colisión. Mapa robot→dominio configurable por env
  (`G1_DOMAIN_ID=0`, `GO2_DOMAIN_ID=1`).
- **Bridge de cámara** (`robot_camera_bridge/`): ve un robot a la vez (el elegido).
  Al cambiar de robot en el header, **rearma su contexto/nodo en el dominio nuevo**
  y vuelve a spinnear. Ya tiene el switch de fuente en caliente; se le agrega el
  cambio de dominio.
- **Frontend:** ya existe el selector de robot en el header (`RobotContext`) que al
  cambiar empuja `{robot}` al bridge; solo hay que hacer que también dispare el
  cambio de dominio del executor/bridge (o que cada uno derive el dominio del robot).

Resultado: elegís el robot en el header → executor y bridge hablan **solo** en el
dominio de ese robot → comandos y video van únicamente a ese robot.

---

## Opción B — Aislar por interfaz de red (no toca el robot)

Si no se puede cambiar el dominio del robot, se separan por **interfaz/subred**.
Cada robot en su propia NIC/VLAN, y el DDS de cada robot **atado a esa interfaz** vía
`CYCLONEDDS_URI` (`<NetworkInterface name="...">`). Así "dominio 0 en la interfaz A"
ve solo al robot A, y "dominio 0 en la interfaz B" ve solo al robot B.

### Del lado de la red (lo hacés vos)
- Cada robot en una interfaz/subred distinta del host (tenés VLANs).
- Anotar qué interfaz corresponde a cada robot (ej. Go2 → `enp4s0`, G1 → `enp3s0`,
  o las VLANs que uses).

### Del lado de AI-VL (lo hago yo)
- Mapa robot→interfaz configurable por env (`GO2_DDS_IFACE`, `G1_DDS_IFACE`).
- El executor/bridge setean el `CYCLONEDDS_URI` con la interfaz del robot elegido
  antes de inicializar su contexto DDS (mismo esquema por-robot que la Opción A,
  pero cambiando la interfaz en vez del dominio).

> Nota: DDS por defecto usa multicast para descubrir; entre VLANs/subredes ruteadas
> puede requerir configurar *peers* unicast en `CYCLONEDDS_URI`. Si el descubrimiento
> no cruza la VLAN, se agrega `<Peers>` con la IP del robot.

---

## Comparación rápida

| | Opción A (dominio) | Opción B (interfaz) |
|---|---|---|
| Toca el robot | Sí (SSH, cambiar dominio) | No |
| Toca la red | No | Sí (VLAN/NIC por robot) |
| Riesgo | Firmware puede no permitirlo | Descubrimiento entre subredes |
| Recomendado si | El robot deja cambiar el dominio | El robot está fijo en dominio 0 |

## Mientras tanto (sin separar)

Usar **un robot a la vez**: conectar solo el que vas a usar. Con uno solo no hay
colisión, el selector del header elige la fuente y todo va a ese robot. Es lo más
simple hasta decidir A o B.

## Qué falta para implementarlo

Cuando definas A o B (y, en A, confirmes que el Go2 deja cambiar el dominio), del
lado de AI-VL queda:
1. Mapa robot→dominio (A) o robot→interfaz (B), por env.
2. Executor: un `Context` DDS por robot con su dominio/interfaz.
3. Bridge: rearmar su contexto en el dominio/interfaz del robot al cambiar en el header.
4. Verificar: con los dos conectados, elegir A y confirmar que solo A recibe;
   luego B. (La fuente `test` sirve para validar el switch sin robots.)
