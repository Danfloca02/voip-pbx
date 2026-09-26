# Análisis de captura — `llamadas_troncal_mismaLAN_test.pcapng`

> Documento de insumo para la documentación del entregable.
> Generado a partir del análisis del `.pcapng` con Scapy 2.7.0.
> **No versionar dentro del repo de Asterisk** — destino: ZIP de entrega.

---

## 1. Metadatos de la captura

| Campo | Valor |
|---|---|
| Archivo | `llamadas_troncal_mismaLAN_test.pcapng` |
| Tamaño | 2 261 716 bytes |
| Paquetes totales | 7 417 |
| Ventana temporal | 213,06 s |
| Inicio (UTC) | 2026-09-26 01:35:53.947 |
| Host de captura | `192.168.0.10` |
| Versión de Asterisk | `Asterisk PBX GIT-22-f2d810e` |
| Softphone | `MicroSIP/3.22.12` (extensión 1001, display `HP1001`) |

### Composición del tráfico

| Protocolo | Paquetes | Observación |
|---|---:|---|
| TCP sobre `127.0.0.1` | 6 601 | Tráfico local ajeno a la telefonía (herramientas de desarrollo). **Ruido** — no forma parte del escenario. |
| UDP sobre `192.168.0.10` | 786 | Telefonía real: 45 SIP + 741 RTP/RTCP |

**Nota metodológica:** el 89 % de la captura es ruido de loopback. Para futuras capturas conviene acotar con filtro BPF:

```bash
sudo tcpdump -i any -n -s 0 -w captura.pcap \
  'udp port 5060 or udp portrange 10000-10050'
```

---

## 2. Hallazgo crítico — el bridge de Docker sigue activo

La dirección `172.17.0.1` aparece de forma sistemática en la señalización:

```
Via: SIP/2.0/UDP 192.168.0.10:57084;rport=44234;received=172.17.0.1;...
BYE sip:1001@172.17.0.1:44234;ob SIP/2.0
From: <sip:trunk_sip@172.17.0.2>
```

### Interpretación

| Evidencia | Significado |
|---|---|
| `received=172.17.0.1` | Asterisk vio la IP de origen reescrita al gateway del bridge `docker0`, no la IP real del cliente |
| `rport=44234` ≠ `57084` (puerto del Via) | El puerto de origen también fue traducido |
| Contact almacenado: `sip:1001@172.17.0.1:44234` | `rewrite_contact=yes` funcionó, pero grabó la IP del NAT de Docker |
| `From: trunk_sip@172.17.0.2` | La PBX remota se identificó con una IP de la subred del bridge |

**Conclusión:** esta captura corresponde al despliegue en modo `bridge` con `ports:` publicados, **no** al despliegue final con `network_mode: host`.

### Implicación para la documentación

Esto es material de valor didáctico, no un defecto a ocultar. Sirve como **evidencia empírica de la justificación de `network_mode: host`**:

1. Con bridge, la IP de origen se pierde → `type=identify` (autenticación de troncal por IP) es inviable.
2. Obliga a usar la variante con `identify_by=username` como workaround.
3. Con host networking desaparece la reescritura y la variante por IP vuelve a ser utilizable.

**Recomendación:** repetir la captura con `network_mode: host` y presentar ambas lado a lado. El contraste entre `received=172.17.0.1` y `received=<IP real>` es la demostración más limpia del punto.

---

## 3. Inventario de llamadas

Se identifican **tres intentos de llamada** y un ciclo de registro.

### 3.1 Llamada A — `1001 → 22001` — FALLIDA (404)

| t (s) | Dirección | Mensaje |
|---:|---|---|
| 107,449 | 1001 → PBX | `INVITE sip:22001@192.168.0.10` |
| 107,460 | PBX → 1001 | `401 Unauthorized` (reto digest, comportamiento normal RFC 3261) |
| 107,461 | 1001 → PBX | `ACK` + `INVITE` con `Authorization: Digest` |
| 107,577 | PBX → 1001 | **`404 Not Found`** |
| 107,577 | 1001 → PBX | `ACK` |

**Diagnóstico:** la autenticación fue correcta — el 404 llega *después* del INVITE autenticado. El fallo es de **dialplan**: no existe patrón de extensión que case con `22001` en el contexto `llamadas_internas`.

**Causa probable:** el número marcado tiene 5 dígitos (`22001`), lo que sugiere que se intentó componer prefijo troncal `2` + extensión `2001`. El dialplan no contempla ese patrón. La llamada B demuestra que el prefijo configurado es `8`, no `2`.

**Latencia de rechazo:** 116 ms desde el INVITE autenticado. Respuesta rápida y limpia.

### 3.2 Llamada B — `1001 → 82001` vía troncal — EXITOSA

| t (s) | Dirección | Mensaje |
|---:|---|---|
| 176,086 | 1001 → PBX | `INVITE sip:82001@192.168.0.10` |
| 176,088 | PBX → 1001 | `401 Unauthorized` |
| 176,089 | 1001 → PBX | `ACK` + `INVITE` autenticado |
| 176,095 | PBX → 1001 | `100 Trying` |
| 177,285 | PBX → 1001 | `180 Ringing` |
| 184,467 | PBX → 1001 | `200 OK` (SDP: puerto 10030, PCMU) |
| 184,481 | 1001 → PBX | `ACK` |
| 184,483 | 1001 → PBX | `UPDATE` (session timer) |
| 184,496 | PBX → 1001 | `200 OK` |
| 188,923 | PBX → 1001 | `BYE` — `Reason: Q.850;cause=16` |
| 188,924 | 1001 → PBX | `200 OK` |

**Métricas de sesión:**

| Indicador | Valor |
|---|---|
| Post-Dial Delay (INVITE → 180 Ringing) | 1 196 ms |
| Tiempo de timbrado (180 → 200 OK) | 7 182 ms |
| Duración de la conversación | 4 442 ms |
| Causa de terminación | Q.850 cause 16 — *Normal Clearing* |
| Iniciador del BYE | La PBX |

**Nota sobre el PDD de 1,2 s:** el retardo entre `100 Trying` y `180 Ringing` corresponde al tiempo que tarda la PBX local en enviar el INVITE por la troncal y recibir el timbrado del extremo remoto. Es el coste de la salida troncal — en una llamada puramente interna sería de decenas de ms.

**Nota sobre el BYE:** lo emite Asterisk, no el softphone. Es coherente con que el otro extremo colgó primero y la PBX propagó la terminación.

### 3.3 Llamada C — entrante desde troncal → `1001` — EXITOSA

Precedida por un ciclo de registro:

| t (s) | Mensaje |
|---:|---|
| 196,900 | `REGISTER` (Expires: 300) |
| 196,905 | `401 Unauthorized` |
| 196,905 | `REGISTER` autenticado |
| 196,912 | `200 OK` — registro completado en **12 ms** |

Llamada entrante:

| t (s) | Dirección | Mensaje |
|---:|---|---|
| 197,524 | PBX → 1001 | `INVITE sip:1001@172.17.0.1:44234` — `From: <sip:trunk_sip@172.17.0.2>` |
| 197,551 | 1001 → PBX | `100 Trying` |
| 197,552 | 1001 → PBX | `180 Ringing` |
| 201,193 | 1001 → PBX | `200 OK` (SDP: puerto 4006, PCMU) |
| 201,197 | PBX → 1001 | `ACK` |
| 204,726 | PBX → 1001 | `BYE` — Q.850 cause 16 |
| 204,727 | 1001 → PBX | `200 OK` |

**Métricas:**

| Indicador | Valor |
|---|---|
| Tiempo de registro | 12 ms |
| PDD (INVITE → 180) | 28 ms |
| Tiempo de timbrado | 3 641 ms |
| Duración de la conversación | 3 529 ms |
| Terminación | Normal Clearing |

**Relevancia:** esta llamada demuestra la **bidireccionalidad de la troncal**. B valida el sentido saliente, C el entrante. Ambos sentidos operativos es requisito del escenario troncal.

### 3.4 Keepalives

Se observan 13 paquetes UDP vacíos (CRLF) de `1001` hacia la PBX, con intervalo de 12–14 s. Es el mecanismo de mantenimiento de binding NAT de PJSIP en MicroSIP. Comportamiento esperado; confirma que el cliente mantiene el pinhole abierto.

---

## 4. Análisis de calidad de audio (RTP)

Cuatro flujos RTP, uno por sentido en cada llamada establecida.

| Flujo | Puertos | SSRC | Códec | Paquetes | Duración | Pérdida | Jitter | Δ máx |
|---|---|---:|---|---:|---:|---:|---:|---:|
| Teléfono → PBX (llamada B) | 4004 → 10030 | 2127116129 | PCMU | 223 | 4,44 s | **0,00 %** | 0,06 ms | 20,6 ms |
| PBX → Teléfono (llamada B) | 10030 → 4004 | 966437328 | PCMU | 194 | 3,70 s | **0,00 %** | 6,50 ms | 277,0 ms |
| Teléfono → PBX (llamada C) | 4006 → 10034 | 64830352 | PCMU | 176 | 3,50 s | **0,00 %** | 0,08 ms | 20,3 ms |
| PBX → Teléfono (llamada C) | 10034 → 4006 | 1642198610 | PCMU | 136 | 2,64 s | **0,00 %** | 6,95 ms | 278,1 ms |

Jitter calculado según RFC 3550 §6.4.1, reloj de 8 000 Hz.

### 4.1 Pérdida de paquetes: 0 %

Ninguna secuencia RTP presenta huecos ni duplicados en los cuatro flujos. En una LAN es el resultado esperado y confirma que no hay saturación ni descarte en la ruta.

### 4.2 Asimetría de jitter — hallazgo relevante

Existe una diferencia de **dos órdenes de magnitud** entre sentidos:

- Teléfono → PBX: 0,06–0,08 ms (prácticamente perfecto)
- PBX → Teléfono: 6,50–6,95 ms

El análisis de los intervalos entre paquetes en el sentido PBX → teléfono revela **entrega a ráfagas** en lugar del cadenciado uniforme de 20 ms:

```
gap  94,9 ms  en t=185,046
gap  50,7 ms  en t=185,157
gap 141,0 ms  en t=185,366
gap  99,7 ms  en t=185,486
gap 277,0 ms  en t=185,764
gap  72,9 ms  en t=185,878
```

**Interpretación:** Asterisk emite RTP cada 20 ms; la ráfaga se introduce en el camino. El único elemento asimétrico entre ambos sentidos es el NAT del bridge de Docker, que procesa el tráfico saliente del contenedor por una ruta distinta a la del entrante. El relay de Docker acumula y libera en bloques.

**Consecuencia audible:** con un jitter buffer estándar (~60 ms) el efecto se absorbe. Las ráfagas de 277 ms lo exceden, lo que puede producir micro-cortes.

**Verificación propuesta:** repetir la medición con `network_mode: host`. Si el jitter en el sentido PBX → teléfono baja al rango de 0,1 ms, queda probado que el bridge era la causa. Esa comparación cuantificada es un resultado fuerte para el informe.

### 4.3 Negociación de códec

| Etapa | Contenido |
|---|---|
| Oferta del teléfono | PCMA (8), PCMU (0), telephone-event (101) — PCMA como preferencia |
| Respuesta de Asterisk (llamada B) | PCMU (0), PCMA (8), telephone-event (101) |
| Oferta de Asterisk (llamada C) | PCMU (0), PCMA (8), **G722 (9)**, telephone-event (101) |
| Códec finalmente usado | **PCMU en los cuatro flujos** |

Asterisk impone su propio orden de preferencia, que es el comportamiento por defecto de PJSIP. La plantilla `[codec-troncal]` declara `ulaw` antes que `alaw`, y eso es lo que prevalece.

La presencia de G722 en la oferta de la llamada C indica que esa ruta tomó la plantilla `[codec-interno]` (que sí incluye G722) y no `[codec-troncal]`. Merece verificación en la configuración: una llamada que entra por troncal debería heredar el perfil troncal.

Se observa además `payload type 13` (Comfort Noise, RFC 3389) en un paquete por flujo, al inicio de cada stream saliente de Asterisk.

### 4.4 Estimación de MOS

Con 0 % de pérdida, jitter máximo de 6,95 ms y PCMU (Ie = 0 en el modelo E), el factor R se mantiene próximo al máximo teórico de G.711.

**MOS estimado: 4,3–4,4** (excelente) para ambas llamadas, considerando únicamente los parámetros de red observados.

Salvedad: la estimación no contempla las ráfagas de 277 ms. Si el jitter buffer del cliente no las absorbe, la calidad percibida sería inferior a la medida. Para una medición definitiva conviene usar `CHANNEL(rtpqos)` en un hangup handler, que reporta las métricas desde el propio motor RTP de Asterisk.

---

## 5. Validación del comportamiento SIP

| Aspecto | Estado | Evidencia |
|---|---|---|
| Autenticación digest MD5 | Correcto | Reto 401 + reintento con `qop=auth`, `nc=00000001` |
| `force_rport` | Activo | `rport=44234` presente en todas las respuestas |
| `rewrite_contact` | Activo | Contact reescrito a la IP observada |
| `direct_media=no` | Confirmado | Todo el RTP pasa por los puertos 10030/10034 de la PBX |
| Rango RTP | Correcto | Puertos dentro de 10000–10050, coherente con `rtp.conf` |
| Session timers | Operativos | `UPDATE` a los 2 ms del ACK, `Session-Expires: 1800`, `refresher=uac` |
| Terminación de sesión | Limpia | `Q.850 cause=16` y `200 OK` en ambas llamadas |
| Registro | Correcto | `Expires: 300`, ciclo completo en 12 ms |
| Troncal bidireccional | Demostrada | Llamada B saliente, llamada C entrante |

No se observan retransmisiones, timeouts, respuestas 5xx ni mensajes malformados.

---

## 6. Puntos a desarrollar en la documentación final

### 6.1 Corregir o justificar el 404 de `22001`

Es el único fallo de la captura y queda sin explicación en el registro. Dos opciones:

- **Corregir el dialplan** y volver a capturar, presentando solo llamadas exitosas.
- **Documentarlo como caso de prueba negativo**: demuestra que el dialplan rechaza correctamente los destinos no enrutables en lugar de reenviarlos ciegamente. Esto es una propiedad de seguridad (prevención de fraude telefónico) y vale más que ocultarlo.

La segunda opción es preferible: un informe con un caso negativo documentado es más creíble que uno con solo casos felices.

### 6.2 Repetir la captura con `network_mode: host`

Es la acción de mayor valor. Permite:

- Eliminar `172.17.0.1` de toda la señalización.
- Habilitar `type=identify` por IP en la troncal (variante A).
- Cuantificar la mejora de jitter en el sentido PBX → teléfono.

La comparación **antes/después** convierte una decisión de arquitectura en un resultado medido.

### 6.3 Revisar el perfil de códec de la llamada entrante

La oferta con G722 en la llamada C sugiere que el endpoint que la originó no heredó `[codec-troncal]`. Verificar con:

```
pjsip show endpoint trunk_sip
```

### 6.4 Acotar el filtro de captura

El 89 % de ruido de loopback diluye la evidencia. Aplicar el filtro BPF indicado en §1.

### 6.5 Incorporar métricas nativas de Asterisk

El análisis de pcap mide la red. `CHANNEL(rtpqos,audio,all)` mide lo que el motor RTP realmente experimentó, y persiste en CDR para análisis agregado. Las dos fuentes juntas son más sólidas que cualquiera por separado.

---

## 7. Resumen ejecutivo

Se validaron **dos llamadas completas a través de troncal SIP, una en cada sentido**, con establecimiento correcto, audio bidireccional y terminación limpia.

La calidad de red fue **excelente**: 0 % de pérdida en los cuatro flujos RTP y jitter inferior a 7 ms. MOS estimado de 4,3–4,4.

Se detectaron dos observaciones:

1. **Ráfagas de hasta 277 ms** en el sentido PBX → teléfono, atribuibles al NAT del bridge de Docker presente en este despliegue. No causaron pérdida, pero pueden afectar la calidad percibida.
2. **Un intento fallido** (`22001`, 404 Not Found) por ausencia de patrón en el dialplan. La autenticación fue correcta; el fallo es de enrutamiento.

La captura corresponde al despliegue en modo `bridge`. La migración a `network_mode: host` debería eliminar ambas observaciones de infraestructura y habilitar la autenticación de troncal por IP.

---

## Anexo — Reproducción del análisis

```python
from scapy.all import rdpcap, IP, UDP

pkts = rdpcap('llamadas_troncal_mismaLAN_test.pcapng')

# Señalización SIP
for p in pkts:
    if UDP in p and 5060 in (p[UDP].sport, p[UDP].dport):
        payload = bytes(p[UDP].payload).decode('utf8', 'replace')
        if payload.strip():
            print(payload.split('\r\n')[0])

# Jitter RFC 3550 sobre un flujo RTP
J = 0.0
prev = None
for p in pkts:
    if UDP in p and p[UDP].sport == 10030:
        d = bytes(p[UDP].payload)
        if len(d) < 12 or (d[0] >> 6) != 2:
            continue
        ts = int.from_bytes(d[4:8], 'big')
        t = float(p.time)
        if prev:
            D = abs((t - prev[0]) * 8000 - (ts - prev[1]))
            J += (D - J) / 16.0
        prev = (t, ts)
print("Jitter: %.2f ms" % (J / 8.0))
```

Entorno: Python 3 + Scapy 2.7.0. No requiere tshark.
