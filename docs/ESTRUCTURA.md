# Contexto y estructura del proyecto

Qué es este repo, qué ficheros se usan de verdad y qué hace cada contexto del
dialplan. Para desplegar y probar, ver [DESPLIEGUE.md](DESPLIEGUE.md).

---

## 1. Alcance

PBX multisede con Asterisk 22 en Docker. Cada sede corre su propia instancia y
se enlazan por una troncal SIP directa entre ellas.

**Lo que el proyecto hace:**

- Extensiones SIP internas por sede, con softphones (MicroSIP, Zoiper).
- Troncal SIP entre sedes, en la misma LAN o por internet.
- Buzón de voz, desvío de llamadas, conferencia, transferencia, hold.
- Señalización TLS y voz SRTP como opción por extensión.

**Lo que el proyecto NO hace, y no está previsto:**

- **No hay proveedor SIP comercial ni mayorista.** No se sale a la telefonía
  tradicional (PSTN), no hay DIDs y no hay numeración pública.
- No hay colas, IVR, grabación ni CRM.

Esa exclusión importa para leer el resto: cuando la documentación dice
**"por internet"** se refiere a dos PBX de este proyecto comunicándose entre
IPs públicas. Nunca a una troncal con un operador.

---

## 2. Árbol de ficheros

```
voip-pbx/
├── compose.yaml                  red 'host'  -> servidor Linux
├── compose.override.yaml         red 'bridge' -> laptop Windows   [NO versionado]
├── compose.override.yaml.example plantilla del anterior
├── Dockerfile                    compila Asterisk 22 + PJSIP + SRTP
├── Makefile                      atajos de operacion
├── .gitattributes                fuerza LF: sin esto, editar en Windows
│                                 reescribe el repo entero a CRLF
├── .gitignore
├── config/etc/asterisk/          se monta como volumen en /etc/asterisk
│   ├── pjsip.conf                extensiones y troncales   (igual en todas)
│   ├── pjsip_local.conf          transporte + IPs propias  [NO versionado]
│   ├── pjsip_local.conf.example  plantilla del anterior
│   ├── extensions.conf           dialplan
│   ├── voicemail.conf            buzones
│   ├── confbridge.conf           perfiles de conferencia
│   ├── features.conf             codigos DTMF en llamada
│   ├── rtp.conf                  rango de puertos de audio
│   └── keys/                     certificado TLS            [NO versionado]
├── logs/var/log/asterisk/        logs y CDR                 [NO versionado]
└── docs/
    ├── ESTRUCTURA.md             este fichero
    ├── DESPLIEGUE.md             instructivo de despliegue y pruebas
    └── TRONCALES.md              detalle conceptual de troncales
```

### Los tres ficheros que NO se versionan

Es el patrón central del repo: **lo que cambia entre máquinas vive fuera de
git**, así que el resto es idéntico en todas y no hay nada que revertir antes
de desplegar.

| Fichero | Por qué | Se crea con |
|---|---|---|
| `pjsip_local.conf` | Transporte y, si hay NAT, la IP de la máquina | `cp` del `.example` |
| `compose.override.yaml` | Sólo existe en Windows | `cp` del `.example` |
| `config/etc/asterisk/keys/` | Certificado y clave privada | `openssl` (§5) |

**En el escenario de entrega** —Linux, `network_mode: host`, IP pública en la
NIC— `pjsip_local.conf` no lleva **ninguna IP**: sólo los dos transportes.
Asterisk elige la dirección a anunciar según el destino de cada llamada. Las
únicas IPs del proyecto son el `contact=` y el `match=` de la otra sede.
Detalle en [DESPLIEGUE.md](DESPLIEGUE.md) §6.

---

## 3. Ficheros de Asterisk: 13 de unos 130

La imagen trae `make samples`, que deja ~130 ficheros `.conf` de ejemplo. De
esos, el proyecto sólo toca **13**. Los demás están con sus valores por defecto
y no hay que mirarlos.

| Fichero | Líneas efectivas | Qué define |
|---|---|---|
| `pjsip.conf` | 79 | Extensiones 1001/1002, plantillas, troncal |
| `pjsip_local.conf` | 15 | Transportes UDP 5060 y TLS 5061, IPs propias |
| `extensions.conf` | 50 | Dialplan completo |
| `confbridge.conf` | 42 | `default_bridge` (máx. 10), `default_user` |
| `voicemail.conf` | 22 | Buzones 1001 y 1002 en el contexto `default` |
| `asterisk.conf` | 15 | Rutas y opciones del demonio |
| `features.conf` | 10 | `#1` transferencia ciega, `#2` consultada, `#9` colgar |
| `logger.conf` | 10 | Canales de log |
| `cdr.conf` | 9 | Registro de llamadas activado |
| `modules.conf` | 8 | Carga de módulos |
| `musiconhold.conf` | 4 | Clase por defecto (sin audio: hold en silencio) |
| `rtp.conf` | 3 | `rtpstart=10000`, `rtpend=10020` |
| `cdr_custom.conf` | 2 | Segundo backend de CDR |

### Ruido heredado de la instalación por defecto

```
Contextos cargados:            29
De ellos, de ejemplo (ael/lua): 23
```

`extensions.ael` y `extensions.lua` son ficheros de muestra que `pbx_ael` y
`pbx_lua` compilan al arrancar, y meten 23 contextos (`ael-dundi-e164-*`,
`ael-trunkint`, …) que nadie usa. No rompen nada, pero ensucian
`dialplan show`. Para quitarlos, en `modules.conf`:

```ini
noload => pbx_ael.so
noload => pbx_lua.so
```

También hay **dos backends de CDR** escribiendo lo mismo en carpetas distintas
(`cdr-csv/Master.csv` y `cdr-custom/Master.csv`). Con uno basta:

```ini
noload => cdr_custom.so
```

---

## 4. Dialplan: contextos y qué hace cada uno

```
[llamadas_internas]            <- donde entran las extensiones
    include => salientes_troncal_sip
[salientes_troncal_sip]        <- prefijo 8: salida hacia la otra sede
[entrantes_troncal_sip]        <- donde entran las llamadas de la otra sede
[qos-handler]                  <- subrutina de calidad (ver aviso abajo)
```

Sólo cuatro. Antes existían `salientes_redpublica` y `entrantes_redpublica`
para una troncal con proveedor; se eliminaron porque no hay proveedor en el
alcance, y con ellos el prefijo `9` quedó libre.

### `[llamadas_internas]`

Contexto de las extensiones. Todo lo que marca un softphone entra aquí.

| Se marca | Qué ocurre |
|---|---|
| `1XXX`–`5XXX` | Llama a la extensión. Aplica desvío y cae al buzón si no contesta |
| `800` | Entra a la sala de conferencia |
| `*72<ext>` | Activa desvío hacia esa extensión |
| `*73` | Desactiva el desvío |
| `*97` | Entra a tu propio buzón |
| `*98` | Pregunta qué buzón |
| `*98<ext>` | Entra al buzón de esa extensión |
| `8<ext>` | Sale por la troncal hacia la otra sede |

Dos detalles no obvios:

- **`800` gana sobre `_8X.`** porque Asterisk prioriza las coincidencias
  exactas del contexto propio sobre los patrones de contextos incluidos. Es
  correcto pero frágil: si cambias el prefijo de troncal, revisa esto.
- **El `GotoIf` sobre `${DIALSTATUS}` no es decorativo.** Sin él, cuando la
  llamada se contesta y el destino cuelga primero, `Dial()` retorna y el que
  llamó acaba escuchando el buzón de voz.

### `[salientes_troncal_sip]`

Patrón `_8X.`. Quita el `8` con `${EXTEN:1}` y manda el resto por `trunk_sip`.
Marcar `82001` envía `2001`.

### `[entrantes_troncal_sip]`

Donde caen las llamadas que llegan por la troncal. Acepta extensiones
`1XXX`–`5XXX` y la sala `800`; cualquier otra cosa cuelga.

**Entre sedes se envía la extensión completa, sin prefijo.** Aquí no se usa
`${EXTEN:1}`: el otro extremo espera `2001`, no `001`.

Este contexto **no incluye ningún contexto de salida**, y es deliberado. Un
`include` a un contexto de salida en un contexto de entrada es la vía clásica
del fraude telefónico: quien entre por la troncal podría sacar llamadas.

### `[qos-handler]`

> **Aviso: definido pero no invocado.** Esta subrutina escribe la calidad RTP
> en `CDR(userfield)`, pero nada la llama, así que ese campo sale vacío en
> `Master.csv`. Para activarla hay que engancharla como *hangup handler* —
> tiene que ejecutarse al colgar, porque antes las estadísticas RTP no existen:
>
> ```ini
> same => n,Set(CHANNEL(hangup_handler_push)=qos-handler,s,1)
> ```
>
> colocado antes del `Dial()`. Pendiente de decidir si se activa.

---

## 5. Objetos PJSIP

```
pjsip_local.conf          pjsip.conf
──────────────────        ─────────────────────────────────
[transport-udp] :5060     [codec-interno]  g722, ulaw, alaw
[transport-tls] :5061     [codec-troncal]  ulaw, alaw
                          [endpoint-interno]      <- plantilla base
                          [endpoint-interno-tls]  <- variante cifrada
                          [1001] [1002]           <- extensiones
                          [endpoint-troncal]
                          [aor-troncal-lan | externa | dinamica]
                          [trunk_sip]             <- comentado hasta elegir
```

### Añadir una extensión

Copiar los tres bloques de `1001` y cambiar el número. Para que sea cifrada,
usar `(endpoint-interno-tls)` en lugar de `(endpoint-interno)`; requiere el
5061 abierto y el softphone con Transport = TLS.

### Cifrado

| | Qué cifra | Puerto |
|---|---|---|
| TLS | La señalización SIP | 5061/tcp |
| SRTP (SDES) | El audio | el rango RTP |

Se usa **SDES y no DTLS**: MicroSIP y Zoiper de escritorio no hablan
DTLS-SRTP, que es lo de WebRTC. El certificado es autofirmado y se genera por
máquina:

```bash
openssl req -x509 -newkey rsa:4096 -nodes -days 730 \
  -keyout config/etc/asterisk/keys/asterisk.key \
  -out   config/etc/asterisk/keys/asterisk.crt \
  -subj "/CN=asterisk.novalink.local" \
  -addext "subjectAltName=DNS:asterisk.novalink.local,IP:TU_IP"
```

Nunca se versiona: `keys/` está en `.gitignore`.

---

## 6. Plan de numeración

| Rango | Sede |
|---|---|
| `1XXX` | Caracas (principal) |
| `2XXX` | Maracaibo |
| `3XXX` | Valencia |
| `4XXX` | Barinas |
| `5XXX` | Puerto La Cruz |

Prefijos: `8` = otra sede por troncal. `9` libre. `800` = conferencia.
`*` = códigos de servicio.

**Cada sede debe usar su propio rango.** Dos sedes con `1001` hacen ambiguo el
enrutamiento y la troncal no sirve de nada.

---

## 7. Operación

```bash
make build      # compila la imagen
make up         # arranca (crea los directorios de CDR)
make cli        # consola de Asterisk
make logs       # seguir el log
make check      # estado del contenedor
make net        # puertos e IPs
make trunk      # estado de la troncal
make trace      # traza SIP en vivo
make down
make rebuild
```

`make up` ejecuta además `logdirs`, que crea `cdr-csv/` y `cdr-custom/` dentro
del contenedor. Son necesarios: el volumen de logs tapa los que venían en la
imagen, Asterisk no los crea, y sin ellos el CDR falla con *No such file or
directory* al terminar cada llamada.

La configuración está montada como volumen, así que **no hace falta
reconstruir** para cambiarla:

```
pjsip reload            tras tocar pjsip.conf o pjsip_local.conf
dialplan reload         tras tocar extensions.conf
module reload app_voicemail.so
core reload             todo
```

Excepción: los **transportes no son recargables**. Cambiar `bind`, el protocolo
o el certificado exige `make down && make up`.

---

## 8. Estado

| Función | Estado |
|---|---|
| Extensiones internas, llamadas y audio | Probado |
| Buzón de voz (`*97`, `*98`) | Probado |
| Desvío (`*72`, `*73`) | Probado |
| Conferencia (`800`) | Probado |
| Transferencia (`#1`, `#2`, botón del softphone) | Probado |
| CDR en `Master.csv` | Probado |
| Transporte TLS en 5061 | Carga y negocia handshake |
| Troncal entre sedes | Registro y autenticación OK; **negociación SDP pendiente** |
| `[qos-handler]` | Definido, sin invocar |
| Despliegue en servidor Linux | Sin probar |

El punto abierto de la troncal es una negociación de audio fallida
(`Couldn't negotiate stream ... (nothing)`), probablemente porque un extremo
ofrece SRTP y el otro sólo acepta RTP en claro. Se confirma mirando la línea
`m=audio` de la oferta: `RTP/SAVP` es cifrado, `RTP/AVP` no.
