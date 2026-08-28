# Unitree G1 por voz — cómo funciona, las fases, y cómo crear skills nuevas

> **Este documento es un how-to, no un backlog.** Su valor son las secciones 4 y 5: cómo
> **agregar comandos nuevos fáciles** (los que son puro SDK) y cómo se **crean skills de
> manipulación** de verdad ("levantá la pelota / la caja"), evaluando **NVIDIA Isaac** y si
> **con el SDK alcanza**.
>
> - Qué hacer y en qué orden, con el estado verificado de cada fase →
>   **`~/Desktop/.claude/ROADMAP.md`** §6. La §2 de acá quedó como contexto histórico; si
>   difieren, gana ROADMAP.md.
> - Diseño técnico y fórmulas → `~/Desktop/AI-VL-ecosystem/ROBOT_CONTROL.md`.
> - El puntero a `~/Desktop/CONTROL_POR_VOZ_G1.md` que había acá quedó muerto en el renombre
>   del 27-08 y ese archivo se borró el 28-08 por duplicar a `ROBOT_CONTROL.md`.
>
> Fecha: 2026-07-20, punteros corregidos el 2026-08-28. Ojo: la parte de
> Isaac/GR00T/LeRobot se mueve muy rápido; abajo pongo versiones y links para re-chequear.

---

## 1. Cómo funciona hoy

### 1.1 Las tres apps + el robot

```
📱 frontend (browser)  ──HTTP/WS──▶  backend (gateway :8443)  ──HTTP──▶  iacore (:8001)  ──▶ Ollama (VLM/qwen3-vl)
   AI-VL-frontend                     AI-VL-backend                       AI-VL-core
                                                                              │
                                            (Fase 2, a construir)             ▼
                                         EJECUTOR + unitree_sdk2  ──DDS──▶  🤖 Unitree G1
```

- **iacore** = el cerebro (percepción + lenguaje): STT (Whisper), TTS (Piper), VLM
  (qwen3-vl), YOLO, y ahora el **intérprete de comandos**.
- **backend** = gateway fino; el browser solo le habla a él.
- **frontend** = UI en el navegador (cámara del teléfono, botones, paneles).
- **El robot NO lo toca el browser.** Lo toca un **ejecutor** que tiene el
  `unitree_sdk2` y habla **DDS** por la red (Fase 2).

### 1.2 El pipeline de voz

```
🎤 voz → /transcribe (texto) → /command (skill JSON) → [ejecutor → SDK → robot] → /speak (feedback)
```

### 1.3 Las dos capas (no confundir)

1. **Transporte** = *cómo* le hablás al robot real → **`unitree_sdk2`** (binding
   Python) o `unitree_ros2`. Elegís uno. Recomendado: el SDK.
2. **Comportamiento** = *qué* hace:
   - **Locomoción + gestos + poses de brazo** → **ya vienen en el SDK**.
   - **Manipulación adaptativa** (agarrar un objeto donde esté) → **hay que
     construirla** (esto es la sección 5).

### 1.4 Lo que ya construimos (Fase 1 — hecho ✅)

- **`AI-VL-core/src/command_common.py`** — el **intérprete**: convierte el texto en
  un **skill JSON** `{skill, params, say}`. Adentro está el **catálogo `SKILLS`**
  (única fuente de verdad) y las constantes para el ejecutor (`SPEED_PRESETS`,
  `ARM_ACTION_IDS`). Valida la salida contra el catálogo (nada inválido llega al robot).
- **`AI-VL-core/service.py`** — endpoints `POST /command` y `GET /skills`.
- **`AI-VL-backend/app.py`** — proxies `POST /api/command` y `GET /api/skills`.
- **`AI-VL-frontend`** — el panel **"Robot command (interpreter)"** en la página
  Live: escribís o dictás un comando y te muestra el **skill elegido** + el **JSON
  exacto** que recibiría el robot (para verificar que elige bien, antes de mover nada).

El intérprete cubre **toda la superficie documentada del SDK**: `walk`, `turn`, `stop`,
`stand_up`, `balance_stand`, `sit`, `squat`, `high_stand`, `low_stand`, `damp`,
`zero_torque`, `start`, `wave_hand`, `shake_hand`, `arm_action` (16 poses), `unknown`.
Los gestos y `arm_action` **sólo corren en fsm id {500, 501, 801}** (o sea, después de
`start` / "Preparation"); si no, el robot los rechaza con 7404 / 7303.

**Secuencia real de arranque** (el G1 no camina si no pasás por los tres):

```
damp (FSM 1)  ->  stand_up / "Preparation" (FSM 4)  ->  start (500) | run (801) | walk_waist (501)
```

Procedencia de cada id: **`[robot]`** = lo publicó el robot (leído con
`g1_fsm_watch.py`), **`[sdk]`** = está en los headers de esta máquina, **`[web]`** =
documentado afuera del SDK y **sin** confirmar contra el robot.

| Modo de la app | Skill | FSM id | Procedencia |
|---|---|---|---|
| Zero torque | `zero_torque` | 0 | `[sdk]` |
| Damping | `damp` | 1 | `[sdk]` `[robot]` |
| Squat | `squat` | 2 | `[sdk]` `[robot]` (completó 2 → 4) |
| Seating | `sit` | 3 | `[sdk]` |
| Preparation (y "squat up") | `stand_up` | 4 | `[sdk]` `[robot]` |
| **Lie up** | `lie_up` | **702** | `[robot]` |
| Main operation / walk, cintura 1-DoF | `start` | 500 | `[sdk]` `[web]` |
| **Walk**, cintura 3-DoF | `walk_waist` | **501** | `[robot]` |
| Run, cintura 1-DoF | `run` | 801 | `[web]` |
| **Run**, cintura 3-DoF | `run_waist` | **802** | `[robot]` |
| **Climb** | `climb` | **812** | `[robot]` |

Los pares 500/501 y 801/802 son el **mismo** controlador para las dos variantes de
cintura (1-DoF / 3-DoF): no es "walk + control de cintura", es el walk de cada robot, y
el que no corresponde a la variante se rechaza con error 7302. **Nuestro robot contesta
501/802, o sea es el de cintura 3-DoF.**

Secuencia de arranque: `damp (1) → stand_up/Preparation (4) → walk (501) | run (802) | climb (812)`.

Observado y **no** expuesto como skill: **706**, un estado de tránsito de ~6-7 s que el
robot ocupa mientras se mueve entre una postura baja y parado (lo vimos en los dos
sentidos, incluso en un squat de la app que se cayó y terminó en damping). No es una
postura que se elija. En firmware viejo el "start locomotion" aparece como **200** en
vez de 500; si 500 rebota, probá 200 con el skill crudo `set_fsm_id`.

**Welcome no existe** en este firmware: `GetActionList` devuelve el subsistema del brazo
**completo** (23 acciones numeradas + 4 rutinas por nombre) y ahí no está.

Para descubrir un id nuevo, en el devcontainer:

```
bash /workspace/robot_executor/run_fsm_watch.sh --all
```

Es read-only (sólo publica api_ids `Get*`, no puede mover nada, ni siquiera al salir).
Tocá cada opción en la app: cada estado nuevo se imprime y el que salga marcado
`<-- NEW` es un id que todavía no tenemos. `--all` además imprime la lista de acciones
de brazo que el robot declara. Ojo con dos cosas: sólo imprime **cambios** (si ya estás
en ese modo, no sale nada) y el robot dice **en cuál** estado está, nunca cuáles tiene —
la locomoción no tiene api de catálogo, a diferencia del brazo.

---

## 2. Las fases (estado)

| Fase | Qué es | Estado |
|---|---|---|
| **0** | Prereq: compilar/instalar el SDK y probar `g1_loco_client_example` (que conecte y mueva seguro) | ⬜ pendiente (necesita el robot) |
| **1** | **Voz → intención**: `/command` (texto → skill JSON) + panel de verificación | ✅ **hecho** |
| **2** | **Locomoción/gestos por voz**: el **ejecutor** que traduce el JSON a llamadas del SDK | ⬜ siguiente |
| **3** | **Percepción-3D**: bbox de YOLO + profundidad + intrínsecos + mano-ojo → pose 3D en marco pelvis | ⬜ (solo para agarrar) |
| **4** | **Skill `grab`** (manipulación): IK + perfil de velocidad, con brazo/mano del SDK | ⬜ (lo difícil) |
| **5** | **Integración total**: encadenar, manejo de errores hablado, y a mediano plazo migrar el agarre fino a aprendizaje | ⬜ |

**Fases del norte (proyecto completo)** — se construyen de a poco, después de las 0–5:

| Fase | Qué es | Estado |
|---|---|---|
| **6** | **Planificador de comandos compuestos** (orquestador): `/command` pasa de 1 skill a descomponer la instrucción en una **secuencia ordenada** (plan JSON) + máquina de estados/behavior tree. Ej: *"agarrá la caja y llevala a la cocina"* → `[locate, navigate, grab, navigate, place]` | ⬜ norte |
| **7** | **Navegación (Nav2 + SLAM)**: mapear el entorno, localizar, planificar ruta, evitar obstáculos; destinos semánticos ("cocina") → pose. Usa el transporte **ROS2** | ⬜ norte |
| **8** | **Manipulación aprendida (Isaac GR00T + LeRobot)**: teleop VR → demos → fine-tune → deploy (PolicyServer); valida en `unitree_sim_isaaclab`/MuJoCo. Reemplazo escalable del `grab` a mano (Fase 4) | ⬜ norte |
| **9** | **Control whole-body (SONIC)** [opcional/avanzado]: GEAR-SONIC para coordinar locomoción+manipulación de cuerpo completo. Ojo: sobrecalentamiento tobillo/cadera reportado | ⬜ norte |
| **10** | **Integración mobile-manipulation + arbitraje**: encadenar planificador ↔ Nav2 ↔ GR00T con **exclusión mutua** nav/manipulación + feedback hablado. La tarea canónica punta a punta | ⬜ norte |

> Las fases 6–10 son la pista **G1**. El **Go2** crece en paralelo con sus propios skills
> del `SportClient` + su navegación, compartiendo el intérprete/orquestador y el
> transporte abstracto, pero **sin** SONIC/GR00T (son embodiment G1).

### Arquitectura de referencia (norte) y decisiones

El panorama completo está en [`ARQUITECTURA_ROBOT_G1_PROPUESTA.md`](ARQUITECTURA_ROBOT_G1_PROPUESTA.md)
(capas 0–5). Cómo mapean sus capas a nuestras fases:

| Capa de la propuesta | Nuestra(s) fase(s) |
|---|---|
| 0 — Comms (`unitree_sdk2` / `unitree_ros2`) | 0 + decisión de transporte abstracto |
| 1 — Percepción | 3 (percepción-3D) + 7 (SLAM) |
| 2 — Nav2 (navegación) | 7 |
| 3 — SONIC (whole-body) | 9 |
| 4 — GR00T (VLA manipulación) | 8 (alternativa clásica en 4) |
| 5 — Orquestador LLM | 1 (semilla) → 6 (planificador) → 10 (arbitraje) |

Dos decisiones fijadas:

- **Ejecutor con transporte abstracto:** el ejecutor habla con el robot por una interfaz
  fina (`RobotTransport`) con dos implementaciones — `unitree_sdk2` (Python, ahora) y
  `unitree_ros2` (cuando entre Nav2, que es nativo ROS2). Ni el intérprete ni el ejecutor
  dependen de un transporte concreto. Vale para **G1 y Go2**.
- **`/command` = semilla del orquestador:** hoy mapea a **un** skill; en la Fase 6 crece a
  descomponer instrucciones compuestas + arbitrar controladores. La Fase 2 se construye
  con esa evolución en mente.

---

## 3. Cómo se ejecuta un comando (Fase 2 — el ejecutor + SDK)

El intérprete **solo decide**. El **ejecutor** es el que mueve. Arranca una vez con
`ChannelFactoryInitialize(0, <interfaz_de_red>)`, crea un `LocoClient` y un
`G1ArmActionClient`, y mapea el JSON a llamadas del SDK:

| skill JSON | Llamada del SDK |
|---|---|
| `walk` {direction, speed, continuous, duration_s} | `SPEED_PRESETS[speed]` → `loco.Move(vx, vy, vyaw)`; si no es continuo, `Move` por `duration_s` (o `DEFAULT_STEP_S`) y luego `StopMove()` |
| `turn` {direction, speed} | `loco.Move(0, 0, ±vyaw)` |
| `stop` | `loco.StopMove()` |
| `stand_up`/`sit`/`squat`/`damp`/`zero_torque`/`start`/`balance_stand`/`high_stand`/`low_stand` | los métodos FSM del loco client (`StandUp()`, `Sit()`, …) |
| `wave_hand` {turn} | `loco.WaveHand(turn)` |
| `shake_hand` {on} | `loco.ShakeHand()` — **dos etapas**: `on=true` ofrece la mano (task 2), `on=false` la termina y baja el brazo (task 3) |
| `arm_action` {action} | `arm.ExecuteAction(ARM_ACTION_IDS[action])` |

**Dónde corre:** en una máquina en la **misma red DDS** que el robot (la onboard del
G1 — un Jetson — o esta PC conectada al robot). Recibe el JSON de `/command` (o lo
pide él mismo).

**Seguridad (obligatorio):** watchdog, **postura de reposo** siempre alcanzable, y
que **`stop` corte todo** al instante. El equilibrio/marcha ya vienen adentro del
loco client, pero el ejecutor tiene que ser defensivo igual.

---

## 4. Cómo agregar un COMMAND nuevo (los fáciles = puro SDK)

Estos son los que **no requieren simulador ni entrenamiento**: cualquier cosa que
sea una **llamada del SDK o una secuencia fija** de ellas. Ejemplos: una pose de
brazo que no estaba, un "baile" (secuencia de gestos), "date vuelta 180°", etc.

**Receta (3 pasos):**

1. **Agregar el skill al catálogo** en `AI-VL-core/src/command_common.py` → `SKILLS`:
   ```python
   "spin_around": {
       "desc": "Turn 180 degrees in place.",
       "params": {"direction": {"values": ["left", "right"], "default": "left"}},
       "examples": ["turn around", "date vuelta", "giá 180"],
   },
   ```
   Con solo esto, el **prompt y la validación ya lo reconocen** (el catálogo es la
   única fuente de verdad). Podés probarlo **ya** desde el panel del front.

2. **Enseñarle al ejecutor a ejecutarlo** (Fase 2): agregar el caso en el mapeo
   skill→SDK. Para `spin_around` sería un `Move(0,0,±vyaw)` por el tiempo que da
   media vuelta, o encadenar acciones del `arm_action_client`.

3. **(Opcional) exponer parámetros/números** en las constantes del módulo
   (`SPEED_PRESETS`, un nuevo `ARM_ACTION_IDS`, etc.) para que el ejecutor los lea.

> **Regla de oro:** si la tarea se puede escribir como "llamá a estos métodos del SDK
> en este orden", es un **command fácil** → esta sección alcanza, sin Isaac ni datos.
> Si la tarea depende de **dónde está un objeto** o de **tocar con fuerza fina**, NO
> es esto → pasás a la sección 5.

---

## 5. Cómo crear SKILLS DE MANIPULACIÓN nuevas ("levantá la pelota / la caja")

Acá está la pregunta de fondo: para que el robot **agarre cosas que ve**, ¿alcanza
con el SDK? ¿sirve LuckyRobots? ¿NVIDIA Isaac?

### 5.1 ¿Alcanza solo con el SDK? — Respuesta matizada

El SDK te da la **capa de actuación completa** y es imprescindible:
- Control del brazo de 7-DOF (`g1_arm7_sdk_dds_example`, interfaz `rt/arm_sdk`),
  incluso a **bajo nivel** (targets de posición articular).
- Mano **Dex3** (7-DOF, force-controlled, con tacto opcional).
- Locomoción/equilibrio built-in.

Pero el SDK **NO** trae la **inteligencia** de la manipulación:
- **percepción** (¿dónde está la pelota en 3D?),
- **IK a un target cartesiano** (¿qué ángulos de brazo llevan la mano ahí?),
- **planificación del agarre** (aproximación, orientación de la palma, fuerza de cierre).

> **Conclusión:** el SDK es **necesario pero no suficiente**. Es el "músculo".
> El "cerebro-motor" (percibir → decidir pose → planear movimiento) lo ponés vos
> encima, por una de las tres rutas de abajo. Las poses built-in del SDK
> (`arm_action`) son **coreografías fijas** — no se adaptan a dónde está el objeto.

### 5.2 ¿Y LuckyRobots / LuckyEngine? — No como fábrica de skills

Sirve **solo como blueprint**: motor cerrado (DLL "Hazel"), **sin código fuente**,
**sin bridge al hardware** (no hay CAN/serial/ROS2) y **sin percepción** (lee la
posición del objeto como ground-truth de la escena). Te da offsets calibrados, la
FSM de agarre y el modelo MJCF (`g1_29dof.xml`) como banco de pruebas. **No es** un
camino para *crear y desplegar* skills nuevas en el robot real.

### 5.3 Las tres rutas modernas para crear una skill de manipulación

#### Ruta A — Clásica: percepción-3D + IK (determinística)
- **Cómo:** YOLO (ya lo tenés) da la caja 2D → sumás **profundidad** + intrínsecos +
  calibración mano-ojo → **pose 3D**. Después **IK** (p. ej. `cuRobo` de NVIDIA, o
  `pinocchio`/`PyRoki`) para llevar la mano a esa pose, con perfil de velocidad, y
  cerrás la Dex3.
- **Banco de pruebas:** MuJoCo con `g1_29dof.xml` (el de LuckyEngine) antes del robot.
- **Buena para:** el **primer** agarre — objeto **gordo** (caja, pelota grande) en un
  lugar más o menos conocido. Tolera errores de centímetros.
- **Límite:** frágil si la profundidad no es confiable; cada skill es semi-a-medida.
- **Isaac que aplica:** `cuRobo`/`cuMotion` (IK y motion planning en GPU), Isaac ROS
  (percepción acelerada en el Jetson).

#### Ruta B — Imitation Learning con LeRobot (enseñar por demostración) ⭐ práctica
- **Cómo:** **teleoperás** el G1 (Apple Vision Pro / Quest 3 / PICO 4 con
  `xr_teleoperate`) haciendo la tarea varias veces → grabás **demos** → entrenás una
  policy (**ACT / Diffusion Policy / Pi0 / Pi05**) → la desplegás en el **Jetson Orin
  NX** onboard (corre a ~50 Hz).
- **Estado:** el **G1 (29/23-DoF) con Dex3 está soportado oficialmente en LeRobot**
  (v0.5, marzo 2026). Unitree tiene un fork (`unitree_IL_lerobot`) para
  imitation dual-arm y **datasets públicos** (ej. `G1_Dex3_ToastedBread_Dataset`).
- **Buena para:** skills contact-rich reales ("levantá la caja y ponela en el
  escritorio") sin depender de deproyección de profundidad perfecta. Es el camino
  **más accesible hoy** para skills nuevas que "se aprenden mostrando".
- **Costo:** juntar demos (teleop) + una GPU para entrenar.

#### Ruta C — Foundation model VLA con NVIDIA Isaac GR00T ("decile cualquier cosa") ⭐ norte
- **Qué es:** **Isaac GR00T** (N1.5 → N1.6/N1.7) es un **modelo fundacional
  Vision-Language-Action** open para humanoides: entra imagen + lenguaje, sale acción.
- **G1:** se **post-entrena (fine-tune) sobre demos del Unitree G1**; hay scripts
  oficiales (repo `NVIDIA/Isaac-GR00T`) y proyectos comunitarios de pick-and-place en
  G1. GR00T N1.5 mejora bastante a N1 en objetos vistos **y no vistos**.
- **Buena para:** la **estrella polar** — "levantá lo que sea que te diga",
  generalizando a objetos nuevos, condicionado por lenguaje. Reemplaza el
  "programar cada skill a mano" por "fine-tunear un generalista".
- **Costo:** el más pesado (datos + GPU grande + integración de deploy), pero es la
  dirección que escala.

#### El sustrato: Isaac Sim / Isaac Lab (el simulador y el entrenamiento)
- **Isaac Lab** (sobre Isaac Sim) = framework GPU para **RL + imitation + sim-to-real**.
  El **G1 está soportado** (`unitreerobotics/unitree_sim_isaaclab`), con tareas de
  **grasp/dexterous hand-arm** y contact-rich. Es rapidísimo (1 s de sim ≈ 27 min de
  experiencia real en una RTX 4090) y trae workflow **teacher-student** para sim-to-real.
- **Rol:** es el **reemplazo abierto y desplegable de LuckyEngine** — entrenás y
  validás acá (locomoción RL, y policies de manipulación B/C) y después bajás al robot.

### 5.4 NVIDIA Isaac — mapa de piezas

| Pieza | Qué hace | Cuándo la usás |
|---|---|---|
| **Isaac Sim** | Simulador foto-realista (USD/PhysX) | Base de Isaac Lab; generar datos sintéticos |
| **Isaac Lab** | RL / imitation / sim-to-real a escala; **G1 soportado** | Entrenar y validar policies (loco + manip) |
| **Isaac GR00T** | Modelo fundacional **VLA** para humanoides; **fine-tune en G1** | Ruta C: manipulación generalista por lenguaje |
| **cuRobo / cuMotion** | IK + motion planning en GPU | Ruta A: llevar la mano a una pose |
| **Isaac ROS** | Percepción acelerada (Jetson) | Percepción-3D en el robot |

---

## 6. Recomendación práctica (por dónde ir)

**Escalera sensata** (de menos a más esfuerzo), alineada con las fases:

1. **Terminar Fase 2** — el ejecutor de comandos SDK (locomoción/gestos/poses). Sin
   Isaac, sin datos. Es "hablarle y que se mueva". → sección 4.
2. **Primer agarre por Ruta A (clásica)** — caja/pelota gorda, con percepción-3D + IK
   (`cuRobo`) y MuJoCo como banco. Es la Fase 3-4. Objeto grande = perdona errores.
3. **Skills que se enseñan → Ruta B (LeRobot)** — teleoperás, grabás, entrenás
   ACT/Diffusion, deploy en el Jetson. El camino práctico para crecer la biblioteca.
4. **Generalización "decile cualquier cosa" → Ruta C (Isaac GR00T)** — cuando quieras
   que generalice a objetos nuevos por lenguaje. El norte a mediano plazo.

**Resumen de una línea:** el **SDK** mueve el robot y hace gestos/poses fijas (sección
4 alcanza). Para **agarrar cosas que ve**, el SDK es solo el músculo: el cerebro lo
ponés con **percepción-3D + IK** (rápido de arrancar) o con **aprendizaje** —
**LeRobot** (práctico) y **NVIDIA Isaac Lab + GR00T** (escalable). **LuckyEngine
queda como blueprint**, Isaac es el ecosistema real para esto.

---

## 7. Referencias

- Isaac GR00T (repo oficial, fine-tune en G1): https://github.com/NVIDIA/Isaac-GR00T
- GR00T N1.5 (explicación): https://learnopencv.com/gr00t-n1_5-explained/
- GR00T N1.5 (NVIDIA GEAR): https://research.nvidia.com/labs/gear/gr00t-n1_5/
- Fine-tuning GR00T N1.5 en Unitree G1 (issue): https://github.com/NVIDIA/Isaac-GR00T/issues/296
- Isaac Lab (sim-to-real): https://isaac-sim.github.io/IsaacLab/main/source/experimental-features/newton-physics-integration/sim-to-real.html
- Unitree × Isaac Lab (entorno oficial G1): https://github.com/unitreerobotics/unitree_sim_isaaclab
- LeRobot — Unitree G1: https://huggingface.co/docs/lerobot/v0.5.1/unitree_g1
- Unitree (GitHub, SDK + IL fork + datasets): https://github.com/unitreerobotics
- Guía imitation learning (ACT/Diffusion/VLA, 2026): https://www.roboticscenter.ai/learn/imitation-learning
