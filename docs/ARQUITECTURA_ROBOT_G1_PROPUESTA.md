# Arquitectura propuesta: Unitree G1 ejecutando instrucciones complejas en lenguaje natural

> **Propósito de este documento:** este README resume una arquitectura de referencia discutida para un robot Unitree G1 físico que debe ejecutar instrucciones compuestas en lenguaje natural (ejemplo guía: *"agarra esa caja y llévala a la cocina"*). Está pensado para que otra instancia de Claude lo use como punto de comparación frente a un diseño o código ya existente del usuario, y señale coincidencias, huecos o contradicciones.

---

## 1. Contexto y objetivo

- **Robot:** Unitree G1 (humanoide, 29 DOF, con variantes de mano: gripper de 2 dedos, Dex3, Inspire).
- **Objetivo funcional:** el usuario da una instrucción compuesta en lenguaje natural que implica (a) entender/descomponer la tarea, (b) navegar por un edificio, y (c) manipular objetos — y el robot la ejecuta de punta a punta.
- **Ejemplo canónico de tarea:** "agarra esa caja y llévala a la cocina" → implica reconocer el objeto, desplazarse hasta él, agarrarlo, navegar a otra ubicación con nombre semántico ("cocina"), y soltarlo ahí.
- **Restricción de diseño importante:** ningún componente individual del stack resuelve el problema completo. Se requiere composición de varias piezas maduras (algunas ya entrenadas/publicadas por NVIDIA/Unitree) más una capa de orquestación construida por el usuario.

---

## 2. Los tres sub-problemas que esconde la instrucción

Toda instrucción tipo "haz X con el objeto Y en el lugar Z" se descompone en:

1. **Comprensión de lenguaje / planificación de tarea** — traducir "esa caja" y "la cocina" en referencias concretas (posición 3D del objeto, pose de destino con nombre semántico) y en una secuencia ordenada de subtareas.
2. **Navegación** — desplazar el robot desde su posición actual hasta una ubicación objetivo, evitando obstáculos, usando un mapa del entorno.
3. **Manipulación** — ejecutar el agarre/soltado físico del objeto con el brazo/mano, con la fuerza y trayectoria adecuadas.

Ninguno de los repos/herramientas evaluados cubre los tres a la vez. La arquitectura propuesta es, en esencia, una composición de módulos especializados en cada uno, más un orquestador que decide cuál manda en cada momento.

---

## 3. Inventario de repositorios/tecnologías evaluadas y su rol

| Repositorio / Tecnología | Rol en el stack | Qué resuelve | Qué NO resuelve |
|---|---|---|---|
| [`unitreerobotics/unitree_sdk2`](https://github.com/unitreerobotics/unitree_sdk2) | Capa 0 — comunicación con hardware (C++) | SDK oficial en C++ sobre CycloneDDS para leer estados (IMU, motores, batería) y enviar comandos de bajo nivel directamente al robot real. Autocontenido, sin dependencias de ROS2. | No incluye IA, ni navegación, ni manipulación de alto nivel; es solo el canal de comunicación. |
| [`unitreerobotics/unitree_ros2`](https://github.com/unitreerobotics/unitree_ros2) | Capa 0 (alternativa) — comunicación con hardware vía ROS2 | Expone el mismo protocolo DDS del SDK2 como topics/mensajes nativos de ROS2 (`unitree_go`, `unitree_api`), sin envolver la interfaz del SDK. Permite usar RViz2, `ros2 bag`, y en general todo el tooling de ROS2. | Igual que el SDK2, no resuelve navegación ni manipulación por sí solo; es el puente de comunicación. |
| [`unitreerobotics/unitree_sim_isaaclab`](https://github.com/unitreerobotics/unitree_sim_isaaclab) | Capa de simulación / recolección de datos | Simulador construido sobre Isaac Lab para probar tareas de manipulación (pick-place, stacking, wholebody) en G1/H1-2 sin arriesgar el hardware real. Usa el mismo protocolo DDS que el robot físico. Se integra con `xr_teleoperate` para grabar demostraciones de teleoperación. Permite replay y generación de datos aumentados (variando luces/cámaras). | No es un modelo de IA ni un controlador; es el entorno donde se prueban/entrenan otras piezas. |
| [`NVIDIA/Isaac-GR00T`](https://github.com/NVIDIA/Isaac-GR00T) | Capa 4 — manipulación vía IA (VLA) | Modelo fundacional de visión-lenguaje-acción (VLA), N1.7. Toma imagen(es) + instrucción en lenguaje y predice acciones continuas (vía cabeza de difusión sobre backbone VLM Cosmos-Reason2-2B / Qwen3-VL). Cross-embodiment mediante "embodiment tags". Viene con checkpoints ya fine-tuneados para benchmarks específicos (LIBERO/Panda, DROID, SimplerEnv Bridge/WidowX, SimplerEnv Fractal/Google Robot) — **ninguno para G1**. Requiere fine-tuning propio (`launch_finetune.py`) con datos del robot/tarea real del usuario, en formato LeRobot. | No hace navegación de largo alcance por un edificio por sí solo (ver `UNITREE_G1_SONIC` abajo, que es whole-body, no navegación global con mapa). No trae un checkpoint listo para "cualquier caja en cualquier cocina" sin fine-tuning propio. |
| [`NVlabs/GR00T-WholeBodyControl`](https://github.com/NVlabs/GR00T-WholeBodyControl) (SONIC / GEAR-SONIC) | Capa 3 — locomoción de bajo nivel / control de cuerpo completo | Modelo de comportamiento humanoide (SONIC) entrenado sobre datos de captura de movimiento a gran escala (Bones-SEED, 142K+ movimientos, ~288h, retargeteados a G1). Da al robot habilidades motoras base: caminar, equilibrio, coordinación de cuerpo completo. Incluye un planificador cinemático que **se dirige externamente** (teclado/gamepad, o programáticamente). El embodiment tag `UNITREE_G1_SONIC` permite que GR00T (VLA) prediga tokens de acción latente que SONIC decodifica en comandos de articulaciones de todo el cuerpo (piernas + brazos + manos), combinando locomoción y manipulación en una sola política end-to-end. Existe un workflow documentado completo: **collect (teleop VR) → fine-tune (Isaac-GR00T N1.7) → deploy (PolicyServer + decoder SONIC)**. | SONIC **no tiene mapa del entorno ni hace planificación de ruta global**; "sabe caminar" pero no "sabe ir a la cocina" — necesita que algo externo le diga la dirección/velocidad (rol que hoy cumple un humano con gamepad, y que Nav2 podría cumplir programáticamente). |
| **ROS2 Nav2** | Capa 2 — navegación global | Stack maduro de navegación móvil: SLAM (mapeo), localización, planificación global de ruta, evitación de obstáculos dinámicos vía LIDAR/cámaras. Recibe un objetivo (coordenada o waypoint con nombre semántico) y genera comandos de velocidad (`cmd_vel`) o waypoints. | No hace manipulación. No entiende lenguaje natural per se (necesita que el objetivo ya venga traducido a una pose). |
| **MoveIt** (mencionado como alternativa a GR00T para manipulación) | Capa 4 (alternativa/complemento) — manipulación geométrica clásica | Dado la pose 3D exacta de un objeto (de un sistema de visión externo), calcula cinemática inversa y trayectoria del brazo evitando colisiones. Robusto y predecible cuando el objeto/posición está bien definido. | No generaliza bien a objetos no vistos/desordenados ni "entiende" qué es una caja — depende de que la percepción externa le dé una pose exacta. |
| **LLM orquestador** (Claude/GPT/VLM, a construir por el usuario) | Capa 5 — comprensión de lenguaje y arbitraje | Interpreta la instrucción compuesta, la descompone en subtareas ordenadas, y decide qué controlador tiene el mando en cada momento (Nav2 vs. GR00T/SONIC), gestionando la transición sin conflicto (usualmente vía máquina de estados o behavior tree — Nav2 ya usa behavior trees internamente, lo cual facilita extenderlo). | Esta capa **no existe como producto**; es responsabilidad de integración del usuario. |

---

## 4. Diagrama de capas (de arriba hacia abajo = de la decisión a la ejecución física)

```
┌─────────────────────────────────────────────────────┐
│ CAPA 5 — Orquestador (LLM)                            │
│ Interpreta lenguaje, descompone en subtareas,         │
│ arbitra entre Nav2 y GR00T (máquina de estados /      │
│ behavior tree). NO EXISTE COMO PRODUCTO — la arma      │
│ el usuario.                                            │
└─────────────────────────────────────────────────────┘
              ↓ activa                    ↓ activa
┌───────────────────────┐      ┌───────────────────────┐
│ CAPA 2 — Nav2          │      │ CAPA 4 — Isaac-GR00T   │
│ (navegación global,    │      │ (VLA: visión+lenguaje  │
│  SLAM, evitación de    │      │  → acción; manipula-   │
│  obstáculos)           │      │  ción; embodiment tag  │
│                        │      │  UNITREE_G1_SONIC)     │
└───────────────────────┘      └───────────────────────┘
              ↓ cmd_vel / waypoints        ↓ tokens de acción latente
              └──────────────┬─────────────┘
                              ↓
              ┌───────────────────────────────┐
              │ CAPA 3 — SONIC (GEAR-SONIC)    │
              │ Decodifica en comandos de      │
              │ articulaciones de cuerpo        │
              │ completo (piernas+brazos+manos)│
              └───────────────────────────────┘
                              ↓
              ┌───────────────────────────────┐
              │ CAPA 1 — Percepción             │
              │ SLAM (mapa+localización) +      │
              │ detección/segmentación de       │
              │ objetos (visión clásica o VLM)  │
              └───────────────────────────────┘
                              ↓
              ┌───────────────────────────────┐
              │ CAPA 0 — Comunicación hardware  │
              │ unitree_ros2 (recomendado si se │
              │ integra con Nav2/ROS2) o        │
              │ unitree_sdk2 (C++ standalone)   │
              └───────────────────────────────┘
                              ↓
                    Robot Unitree G1 físico
```

---

## 5. Qué viene resuelto "de fábrica" vs. qué requiere trabajo del usuario

**Ya maduro / publicado, usable con poco o ningún desarrollo propio:**
- Capa 0: `unitree_ros2` (o `unitree_sdk2`) — SDKs oficiales, estables.
- Capa 2: Nav2 — stack de navegación estándar de la industria/academia, muy probado.
- Capa 3: SONIC — checkpoints ya liberados en Hugging Face por NVIDIA (releases para G1), listos para usar o fine-tunear.
- Capa 4 (parcialmente): el modelo base `nvidia/GR00T-N1.7-3B` viene pre-entrenado con conocimiento general de manipulación (bimanual, semi-humanoide, dataset humanoide extenso + 20K horas de video humano EgoScale). Hay checkpoints fine-tuneados públicos, pero **ninguno específico para G1 + tareas caseras del usuario**.

**Requiere trabajo real de integración/entrenamiento del usuario:**
- Capa 1: SLAM es una herramienta madura, pero mapear el edificio específico del usuario es tarea suya. La detección de objetos puede requerir ajuste fino para reconocer "esa caja" en particular.
- Capa 4 (fine-tuning específico): recolectar demostraciones de teleoperación del G1 real del usuario (vía el stack de teleop de `GR00T-WholeBodyControl` / `xr_teleoperate`), limpiarlas, y correr `launch_finetune.py` con `--embodiment-tag UNITREE_G1_SONIC` sobre esos datos.
- Capa 5: la orquestación/arbitraje Nav2 ↔ GR00T no existe como producto — es responsabilidad de integración de sistemas: decidir cuándo un controlador "suelta" el mando y el otro lo "toma", sin que ambos manden comandos contradictorios al mismo tiempo (ej. Nav2 pidiendo caminar mientras GR00T pide postura fija de brazo).

---

## 6. Puntos de fricción / riesgos técnicos identificados en la conversación

- **Conflicto de control simultáneo:** si Nav2 y GR00T-VLA intentan controlar el cuerpo al mismo tiempo (uno pidiendo locomoción, otro pidiendo manipulación estática), puede haber comandos contradictorios sobre las mismas articulaciones. Se necesita un mecanismo explícito de arbitraje (máquina de estados/behavior tree) que garantice exclusión mutua clara entre "modo navegación" y "modo manipulación".
- **Fine-tuning no trivial:** ni el modelo base de GR00T ni los checkpoints públicos cubren G1 + objetos/tareas específicas del usuario; se requiere recolección de datos reales (teleoperación VR) y cómputo de fine-tuning (GPUs de 40GB+ VRAM recomendadas, ideal H100/L40).
- **"Saber caminar" ≠ "saber navegar":** confusión común a evitar — SONIC ya sabe ejecutar la locomoción físicamente (equilibrio, coordinación), pero no tiene mapa ni planificación de ruta; eso es exclusivamente rol de Nav2 + SLAM.
- **Requisitos de hardware de cómputo:** inferencia de GR00T necesita GPU con 16GB+ VRAM (RTX 4090, L40, H100, o Jetson AGX Thor/Orin, DGX Spark); esto normalmente corre en un servidor externo (arquitectura server-client vía ZMQ/PolicyServer), no necesariamente embebido en el propio G1.
- **Problemas de hardware reportados en la comunidad:** hay reportes de sobrecalentamiento en motores de tobillo/cadera del G1 corriendo GEAR-SONIC (issues abiertos en el repo `GR00T-WholeBodyControl`), a tener en cuenta para pruebas prolongadas.

---

## 7. Preguntas abiertas para comparar contra el diseño/código existente del usuario

Al comparar este documento contra la idea/código ya armado, conviene verificar explícitamente:

1. ¿El diseño existente usa `unitree_sdk2` o `unitree_ros2` como capa de comunicación? ¿Es coherente con si se planea integrar Nav2 (que es nativo ROS2)?
2. ¿Existe ya una capa de SLAM/mapeo del entorno específico, o se asume que ya hay un mapa?
3. ¿El código existente contempla el uso de SONIC/GEAR-SONIC para locomoción, o usa el controlador de marcha estándar de Unitree (stock)?
4. ¿Hay ya un dataset propio de teleoperación recolectado para fine-tuning de GR00T, o se planea usar el modelo base zero-shot?
5. ¿Existe una capa de orquestación/arbitraje diseñada (máquina de estados, behavior tree, u otro mecanismo), o el diseño actual asume que Nav2 y GR00T nunca competirían por el control al mismo tiempo?
6. ¿El hardware de cómputo disponible (GPU local vs. servidor remoto) es coherente con los requisitos de inferencia/fine-tuning de GR00T descritos arriba?
7. ¿El diseño existente contempla explícitamente los tres sub-problemas (lenguaje, navegación, manipulación) como capas separadas, o los mezcla de alguna forma distinta que valga la pena contrastar?

---

## 8. Fuentes primarias consultadas

- https://github.com/unitreerobotics/unitree_sdk2
- https://github.com/unitreerobotics/unitree_ros2
- https://github.com/unitreerobotics/unitree_sim_isaaclab
- https://github.com/NVIDIA/Isaac-GR00T
- https://github.com/NVlabs/GR00T-WholeBodyControl
- https://nvlabs.github.io/GR00T-WholeBodyControl/ (documentación, incluye tutorial "VLA Workflow: Collect, Fine-tune, Deploy")
