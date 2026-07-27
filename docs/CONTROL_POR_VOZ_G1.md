# Control por voz del Unitree G1 con AI-VL — cómo se hace

> Narrativa en español (fuera de los repos AI-VL). La versión in-repo y en inglés,
> que es la fuente de verdad para trabajar el código, está en
> `~/Desktop/AI-VL-ecosystem/ROBOT_CONTROL.md`. Si movés este archivo dentro de un
> repo AI-VL, traducilo a inglés.
>
> **Roadmap extendido y cómo crear skills:** `~/Desktop/G1_FASES_Y_CREAR_SKILLS.md`
> (fases 0–10, multi-robot G1+Go2). **Arquitectura de referencia del sistema completo:**
> `~/Desktop/ARQUITECTURA_ROBOT_G1_PROPUESTA.md` (capas Nav2/GR00T/SONIC/orquestador).

## Objetivo

Hablarle al robot y que actúe:
- *"andá para acá"* / *"pará"* / *"sentate"* / *"saludá"* → se mueve.
- *"agarrá la lata roja"* → la ve, calcula a dónde/cómo mover el brazo, va y la agarra.
- Feedback por voz (*"ok, yendo"*).

**La idea central:** hay que separar **dos capas** que es fácil confundir.

---

## Objetivo a futuro — una biblioteca de skills de manipulación

El movimiento ya está resuelto por el SDK. El **objetivo a futuro** es la
**manipulación por voz** de objetos y cosas del entorno, por ejemplo (tus propios casos):

- *"levantá la caja y subila al escritorio"* — agarrar algo y ponerlo en otro lado.
- *"prendé la tecla de luz"* — interacción chica, precisa, con contacto/fuerza.
- otras tareas chicas del día a día, elegidas por voz.

Esto **no está en el SDK** y es lo que hay que construir. Aviso de alcance para que el
plan sea honesto:

- "Decirle cualquier cosa y que la haga" en general es **frontera de la robótica**
  (modelos VLA que aprenden). Lo realista es una **biblioteca de skills concretos** que
  vas haciendo crecer — cada skill es semi-a-medida.
- No todas las tareas son igual de difíciles. Escalera sensata:
  1. **Agarrar un objeto gordo y ponerlo en un lugar fijo** — lo más accesible; un
     objeto grande perdona errores de centímetros. **Empezar acá.**
  2. **"Caja → escritorio"** — tarea completa de **robot móvil**: caminar hasta la caja +
     agarrarla + caminar hasta el escritorio + ubicar la superficie + soltarla. Varios
     skills encadenados + navegación.
  3. **"Tecla de luz"** — el más difícil de los tres aunque suene trivial: precisión de
     milímetros sobre un target diminuto, y es un *toque con fuerza controlada*, no un agarre.
- Las poses de brazo built-in del SDK (`g1_arm_action_example`) son **coreografías fijas**
  — no se adaptan a que el objeto esté en otra posición. Esa adaptabilidad es justo el
  hueco que llenamos con percepción-3D + IK.

O sea: las tareas de arriba son la **estrella polar**, pero se implementan como una
biblioteca que crece, arrancando por el agarrar-y-poner fácil y escalando.

---

## Las dos capas (esto es lo importante de entender)

1. **Transporte** — *cómo* le hablás al robot real. Elegís **UNO**: el **SDK de Unitree**
   (`unitree_sdk2`) o **`unitree_ros2`**. Los dos son oficiales y hablan DDS con el robot.
2. **Comportamiento** — *qué* hace el robot. Dos sub-casos:
   - **Locomoción y gestos** (caminar, parar, sentarse, saludar, remoto) → **ya vienen
     hechos en el SDK.** No hay que programar el andar ni el equilibrio.
   - **Agarre visual** (agarrar la lata roja específica que ve la cámara) → esto sí es
     custom, y es lo único donde *opcionalmente* se reusa LuckyEngine.

> **LuckyEngine NO es un transporte y no toca el robot real** — es un simulador +
> policies entrenadas. No es una alternativa al SDK. Solo aporta (si hace falta) para
> el agarre avanzado o como banco de pruebas.

---

## Qué está instalado en esta máquina

| Stack | Ruta | Qué es | Para qué |
|---|---|---|---|
| **unitree_sdk2** | `~/Desktop/unitree_sdk2` | SDK oficial de Unitree (C++; binding Python = `unitree_sdk2_python`). Trae **loco client de alto nivel**, control de brazo/mano, audio y gamepad. | **Transporte recomendado.** Locomoción y gestos listos; brazo y mano para el agarre. |
| **unitree_ros2** | `~/Desktop/unitree_ros2` | Interfaz ROS2 al mismo robot (transporte alternativo). | Solo si querés el ecosistema ROS2. Si no, el SDK Python es más prolijo para AI-VL (que es Python). |
| **LuckyEngine** | `~/Documents/LuckyEngine` | Simulador MuJoCo del G1 (motor cerrado "Hazel"). No se deploya tal cual. | **Opcional:** blueprint de la secuencia de agarre, offsets calibrados, policies RL (si algún día superás el andar built-in), banco de pruebas. |

---

## La buena noticia: caminar y remoto ya vienen

El `unitree_sdk2` incluye el **loco client** del G1
(`include/unitree/robot/g1/loco/g1_loco_client.hpp`,
ejemplo `example/g1/high_level/g1_loco_client_example.cpp`) con el controlador de
marcha/equilibrio **adentro**. Comandos listos:

- **`Move(vx, vy, vyaw)`** → caminar con una velocidad. Esto es *"andá para acá"*.
- `StopMove()`, `StandUp()`, `Sit()`, `Squat()`, `BalanceStand()`, `HighStand()`/`LowStand()`
- Gestos: `WaveHand()` (saludar), `ShakeHand()`
- Brazo: `g1_arm7_sdk_dds_example.cpp`; mano Dex3: `g1_dex3_example.cpp`
- **Control remoto:** el G1 trae el joystick físico de fábrica (los ejemplos incluyen
  `gamepad.hpp`). No hay que construirlo.

**Para mover el robot por voz NO necesitás LuckyEngine.** Es STT → interpretar el
comando → un llamado al SDK.

---

## Qué YA tenés hecho en AI-VL (oídos, boca, ojos)

| Capacidad | Endpoint |
|---|---|
| **Voz → texto (STT)** — faster-whisper | `iacore /transcribe` · backend `POST /api/transcribe` |
| **Texto → voz (TTS)** — Piper/Kokoro | backend `POST /api/speak` |
| **VLM** — qwen3-vl (open-vocabulary) | `iacore /vlm` · backend `POST /api/vlm` |
| **Detección YOLO** — cajas normalizadas 0..1 | `iacore /detect` · backend `WS /ws/detect` |

O sea: micrófono → Whisper → texto → VLM → texto → parlante **ya funciona**.

---

## Qué falta construir (el cerebro motor)

1. **Intérprete de comando** — un prompt sobre el VLM que ya tenés: convierte el texto
   en un *skill* JSON. Ej: *"andá para adelante"* → `{"skill":"walk","direction":"forward"}`;
   *"agarrá la lata roja"* → `{"skill":"grab","target":"lata roja"}`. Open-vocabulary,
   sin lista fija de objetos.
2. **Ejecutor de skills** — capa delgada que traduce el JSON a llamadas del SDK:
   - locomoción/gestos → **directo al loco client built-in** (`Move`, `StandUp`, …).
   - `grab` → movimiento custom (ver punto 4) con los clientes de brazo/mano del SDK.
3. **Percepción 3D** (solo para agarrar) — de la caja 2D de YOLO a una **pose 3D en el
   marco del robot**: centro de la caja + **profundidad** de la cámara del G1 +
   intrínsecos + calibración mano-ojo. *(Depende de qué cámara trae el G1 — prerequisito.)*
4. **Planificador del brazo** (solo para agarrar) — pose de agarre = objeto + offset;
   distancia = contra la mano actual; **perfil de velocidad** con tope cartesiano; **IK**
   del brazo de 7-DOF (librería aparte: pinocchio/PyRoki/etc., porque el IK de la sim
   vive dentro del DLL cerrado). Reusás los offsets/velocidades calibrados de LuckyEngine.

---

## Cómo se hace, paso a paso (roadmap)

**Fase 0 — Prerequisito.** Compilar `unitree_sdk2` (o instalar `unitree_sdk2_python`) y
correr el `g1_loco_client_example` para confirmar que conecta y mueve el robot con seguridad.

**Fase 1 — Voz → intención.** Endpoint `POST /command` en iacore (reusa el VLM):
texto → skill JSON. Loop: `/api/transcribe` → `/command` → `/api/speak`. Ya "entiende y
responde" sin mover nada.

**Fase 2 — Locomoción por voz (el primer logro fácil, sin LuckyEngine).** Conectar
`walk`/`turn`/`stop`/`sit`/`wave` a los comandos built-in del SDK. *"Vení / pará /
saludá"* funcionando punta a punta.

**Fase 3 — Percepción 3D.** Módulo bbox + profundidad + intrínsecos + mano-ojo → pose en
marco pelvis. Verificar contra una medición con cinta métrica.

**Fase 4 — Skill `grab` (lo difícil).** IK + perfil de velocidad con los clientes de
brazo/mano del SDK. Probar primero en MuJoCo standalone (`g1_29dof.xml`), después en el
robot asegurado. Blueprint = la FSM de agarre de LuckyEngine.

**Fase 5 — Integración total.** Encadenar todo con manejo de errores hablado
(*"no veo la lata"*, *"no llego"*). A mediano plazo, migrar el agarre fino a aprendizaje
(LeRobot/ACT, pipeline en `Piper Pattern Stacking/tools/`).

---

## Cómo verificar cada etapa

- **Voz→intención**: 20 frases variadas → ¿el skill/target del JSON es correcto? (sin robot).
- **Locomoción**: pasos cortos con el robot asegurado; *"pará"* corta al instante.
- **Percepción 3D**: error de pose < ~2 cm contra medición manual, en 5 posiciones.
- **Grab**: lata/botella en 5 posiciones dentro del alcance; tasa de éxito.
- **Seguridad**: forzar "sin pose"/"IK no converge" → el brazo va a reposo, no a pose inválida.

---

## Riesgos / notas

- Para **caminar por voz** el único requisito es el SDK andando — no depende de la cámara.
- La **profundidad de la cámara** solo hace falta para agarrar; es el punto más frágil.
  Si no da profundidad métrica confiable, el agarre por **aprendizaje (LeRobot/ACT)** gana
  peso porque no depende de deproyección precisa.
- El G1 se cae: siempre tené una **postura de reposo** segura disponible.
- Convenciones AI-VL: código/docs en inglés dentro de los repos; **nunca** commitear
  automáticamente (lo hacés vos).

---

## TL;DR

Ya tenés oídos, boca y ojos (STT + TTS + VLM/YOLO). El **transporte** limpio es el
**SDK de Unitree** (binding Python). **Caminar, parar y el control remoto ya vienen en el
SDK** — para eso no toca LuckyEngine. Falta: (1) un prompt que convierta la voz en un
*skill* JSON, y (2) para el agarre visual, la percepción 3D + un planificador de brazo con
IK propio. LuckyEngine queda como blueprint del agarre y banco de pruebas, no como pieza
obligatoria.
