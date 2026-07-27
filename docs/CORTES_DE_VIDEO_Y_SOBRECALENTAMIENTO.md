# Por qué se corta el video del robot (y por qué se puede "calentar")

Síntoma observado: el robot manda frames un rato y después **deja de transmitir**,
y — dato clave — **también deja de transmitir en la app oficial de Unitree**. Que
falle también en la app de Unitree significa que el problema **NO es de AI-VL**: es
el **servicio de video de a bordo del robot** el que se cuelga o se satura. Cuando
eso pasa, ningún cliente ve video (ni el bridge de AI-VL ni la app) hasta que se
reinicia el servicio o el robot.

Este documento lista las causas probables, ordenadas por lo que más encaja con el
setup actual.

## 1. El videohub (`GetImageSample`) no es un stream

La cámara del robot se lee pidiendo *snapshots* al videohub
(`/api/videohub/request`, api_id 1001): un request → un JPEG. Es una API pensada
para fotos ocasionales, **no para streaming continuo**. Nuestro bridge la pollea a
12–15 fps sostenidos; ese ritmo estresa el pipeline de video de a bordo y, con el
tiempo, puede degradarse hasta cortar.

- **Mitigación:** bajar los FPS desde el control **Camera** del header (probar 5–8).
  Menos requests por segundo = menos estrés.

## 2. Varios consumidores de video a la vez

Si el bridge de AI-VL **y** la app de Unitree (u otro cliente) piden video al mismo
tiempo, el servicio atiende a todos y se sobrecarga. El pipeline de video del robot
no está pensado para múltiples consumidores simultáneos.

- **Mitigación:** un solo consumidor de video a la vez. Cerrá la app de Unitree
  mientras usás AI-VL (o al revés).

## 3. Dos robots en el mismo dominio DDS (colisión)

Con dos robots (Go2 + G1) en el **mismo dominio DDS (0)**, comparten los nombres de
topic. Nuestros requests de video llegan a **los dos** robots y **los dos servicios
de video responden** en el topic compartido. Eso **duplica la carga** y confunde a
los servicios: cada robot procesa pedidos que pueden ser para el otro. Es una causa
muy probable de que un servicio de video se sature y corte.

- **Mitigación:** usar un robot a la vez, o separarlos a nivel DDS
  (ver [`SEPARAR_ROBOTS_MULTIPLES.md`](SEPARAR_ROBOTS_MULTIPLES.md)).

## 4. Ancho de banda / congestión DDS

La imagen **RealSense cruda** (`sensor_msgs/Image`) es enorme (~2–3 MB por frame a
720p). Publicada por DDS a varios Hz satura el transporte y hace que se dropeen
frames o se cuelgue el pipeline. (Por eso el G1 usa por defecto el videohub, que
entrega JPEG chico, y no el topic crudo.)

- **Mitigación:** preferir el videohub (JPEG) o bajar resolución/fps; no suscribirse
  al topic crudo salvo que haga falta.

## 5. Sobrecalentamiento real (térmico)

La computadora de a bordo (Jetson) codifica/entrega video de forma continua. Con
uso sostenido, mala ventilación o ambiente caluroso, entra en **throttling térmico**
y procesos como el de la cámara **se ralentizan o mueren** para bajar la temperatura.
Esto encaja con "anda un rato y después corta": el corte llega tras varios minutos
de uso, cuando la temperatura sube.

Factores que lo agravan:
- Encoder de video trabajando sin parar (fps alto, resolución alta).
- El robot con muchos servicios activos a la vez (SLAM, audio, VLA, video…).
- Falta de flujo de aire alrededor del robot / uso en interior caluroso.

- **Mitigación:** bajar fps/resolución (menos trabajo del encoder), no dejar
  servicios pesados innecesarios prendidos, dar ventilación, y dar pausas.

## 6. Bug/hiccup de firmware del servicio de video

Independiente de todo lo anterior, el servicio de video de Unitree tiene cortes
conocidos por firmware: se queda "pegado" y hay que reiniciarlo. Que pase también en
la app oficial apunta a esto.

## Cómo resetearlo cuando se corta

Mientras el servicio de a bordo esté colgado, **ningún cliente** verá video. Para
recuperarlo, del más suave al más contundente:

1. Reiniciar el servicio de video en la computadora de a bordo (SSH al robot y
   reiniciar el proceso/servicio de video), si sabés cuál es.
2. **Rebootear el robot** — el reset confiable que siempre recupera el video.

## Resumen de prevención

- **Un solo consumidor** de video a la vez (no AI-VL + app de Unitree juntos).
- **FPS/resolución bajos** desde el header (5–8 fps alcanza para teleoperar).
- **Un robot a la vez** o separar dominios/interfaz (evita la doble carga).
- **Ventilación** y pausas para evitar throttling térmico.
- Si igual corta: es del robot → reiniciar servicio de video / rebootear.

> Nota: del lado de AI-VL se puede agregar un *watchdog* que detecte el corte (sin
> frames por N segundos) y lo avise en la UI en vez de mostrar un frame congelado.
> No reemplaza el reinicio del robot cuando el servicio muere, pero te avisa al toque.
