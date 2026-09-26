<div align="center">

<img src="img/logo_ucv.png" alt="Universidad Central de Venezuela" height="120">
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
<img src="img/logo_ciencias.png" alt="Facultad de Ciencias UCV" height="120">

<br>

**UNIVERSIDAD CENTRAL DE VENEZUELA**<br>
**FACULTAD DE CIENCIAS**<br>
Comunicación de Datos

<br><br><br>

# PBX IP multisede con Asterisk en Docker

### Documentación técnica, instructivo de despliegue y validación

<br><br><br>

Daniel Flores — C.I. 28.314.837<br>
Mauricio Marquina — C.I. 31.155.347

<br><br><br>

Caracas, septiembre de 2026

</div>

<div style="page-break-after: always;"></div>

**_Resumen_—Se diseñó e implementó una central telefónica IP (PBX) basada en Asterisk 22, compilada y ejecutada dentro de un contenedor Docker. Cada sede opera su propia instancia y las sedes se interconectan mediante una troncal SIP directa, sin proveedor externo ni salida a la red telefónica pública. El sistema ofrece extensiones SIP, buzón de voz, desvío, transferencia, llamada en espera y conferencia, con señalización TLS y voz SRTP opcionales. Se documentan el plan de numeración, los escenarios de red soportados, el despliegue en un servidor Linux con IP pública, el análisis de dos capturas de tráfico real (llamadas por troncal y buzón de voz) y la solución del escenario de llamada en espera (Hold) con su corte automático por inactividad RTP.**

**_Palabras clave_—Asterisk, Docker, PJSIP, RTP, SIP, SRTP, TLS, troncal SIP, VoIP.**

## I. INTRODUCCIÓN

El proyecto consiste en un programa basado en Asterisk [1], compilado y gestionado dentro de un contenedor Docker [2], que cumple la función de PBX. El alcance excluye proveedores SIP comerciales y la PSTN: cuando este documento menciona la red pública se refiere a dos PBX del proyecto comunicándose entre direcciones IP públicas.

Los requisitos del desarrollo fueron:

1. Llamadas entre extensiones de una misma PBX y hacia extensiones de otra PBX a través de una troncal.
2. Un plan de numeración documentado, definido en `extensions.conf`.
3. Monitoreo del envío de paquetes y de la calidad de servicio (QoS).
4. Transferencia, llamada en espera, desvío y conferencia.

El código fuente y la documentación extendida se encuentran en el repositorio del proyecto [3].

## II. TECNOLOGÍAS Y PROTOCOLOS

### A. Pila tecnológica

**TABLA I.** Pila tecnológica por entorno

| Entorno | Componentes |
|---|---|
| Desarrollo | Windows con WSL2, Docker Desktop, Git/GitHub, Make, firewall de Windows, tcpdump y Wireshark, softphones MicroSIP y Zoiper |
| Producción | Servidor Linux con Docker Engine (sin Docker Desktop), red `host`, ufw y Make |

En producción basta con clonar el repositorio, generar el certificado TLS, ajustar las direcciones de la troncal y ejecutar los comandos de Make (Sección VI).

### B. Protocolos

**TABLA II.** Protocolos utilizados

| Protocolo | Función en el sistema | Puerto |
|---|---|---|
| SIP [4] | Señalización: registro, autenticación, inicio y cierre de sesiones (`REGISTER`, `INVITE`, `ACK`, `BYE`; respuestas `100 Trying`, `180 Ringing`, `200 OK`, `401 Unauthorized`) | 5060/UDP |
| SDP [5] | Viaja dentro de SIP y **describe** la sesión: IP y puerto del audio y códecs ofrecidos. No codifica ni comprime; eso lo hacen los códecs (G.711 [6], G.722) | — |
| RTP/RTCP [7] | RTP transporta el audio sobre UDP, sin retransmisiones: un paquete de voz tardío ya no sirve. Cada extremo emite su propio flujo. RTCP reporta pérdida y jitter | 10000–10050/UDP |
| PJSIP | Pila SIP de Asterisk (`res_pjsip`, `chan_pjsip`): extensiones, autenticación y troncales | — |
| TLS [8] | Cifra la **señalización** SIP | 5061/TCP |
| SRTP [9] | Cifra el **audio**. Las claves viajan en el SDP (SDES [10]), por lo que solo es seguro sobre TLS | Rango RTP |

El buzón de voz y la conferencia no dependen de PJSIP: los proveen los módulos `app_voicemail` y `app_confbridge`. En la conferencia, Asterisk mezcla el audio de todos los participantes en un puente.

### C. Arquitectura

**TABLA III.** Archivos principales

| Archivo | Contenido | Versionado |
|---|---|---|
| `compose.yaml` | Contenedor con `network_mode: host` (producción) | Sí |
| `compose.override.yaml` | Modo bridge para Docker Desktop (solo desarrollo) | No |
| `pjsip.conf` | Extensiones, plantillas y troncal | Sí |
| `pjsip_local.conf` | Transportes UDP 5060 y TLS 5061; IP propias solo si hay NAT | No |
| `extensions.conf` | Plan de marcado | Sí |
| `voicemail.conf`, `confbridge.conf`, `features.conf` | Buzones, conferencia y códigos DTMF | Sí |
| `rtp.conf` | Rango RTP 10000–10050 | Sí |
| `keys/` | Certificado y clave privada TLS | No |

Lo que cambia entre máquinas no se versiona y se crea a partir de su archivo `.example`; el resto es idéntico en todas las sedes.

## III. PLAN DE NUMERACIÓN Y FUNCIONALIDADES

**TABLA IV.** Plan de numeración por sede

| Rango | Sede |
|---|---|
| `1XXX` | Caracas (principal) |
| `2XXX` | Maracaibo |
| `3XXX` | Valencia |
| `4XXX` | Barinas |
| `5XXX` | Puerto La Cruz |

Cada sede usa su propio rango; dos sedes con la misma extensión harían ambiguo el enrutamiento.

**TABLA V.** Códigos de marcación

| Se marca | Efecto |
|---|---|
| `1XXX`–`5XXX` | Llamada a extensión local; aplica el desvío y, sin respuesta en 20 s, pasa al buzón de voz |
| `8` + extensión | Salida por la troncal: `82001` envía `2001` a la otra sede |
| `800` | Sala de conferencia (máximo 10 participantes) |
| `*72` + ext. / `*73` | Activa / desactiva el desvío (se guarda en AstDB) |
| `*97` | Buzón propio |
| `*98` / `*98` + ext. | Buzón preguntando el número / de una extensión concreta |
| `#1` / `#2` / `#9` | Durante la llamada: transferencia ciega / consultada / colgar |

El plan de marcado tiene cuatro contextos: `llamadas_internas`, donde entran las extensiones; `salientes_troncal_sip`, incluido en el anterior, que retira el prefijo `8`; `entrantes_troncal_sip`, que recibe las llamadas de la otra sede y por seguridad no incluye ninguna ruta de salida; y `qos-handler` (Sección IV).

La llamada en espera la inicia el softphone con un re-INVITE y Asterisk reproduce música en espera (clase `default`) al interlocutor; la Sección X detalla su funcionamiento y el corte automático a los 15 minutos. La transferencia funciona con el botón del softphone (SIP REFER) y con los códigos DTMF, que requieren las opciones `tT` de `Dial()`, ya incluidas.

## IV. MONITOREO Y CALIDAD DE SERVICIO

**TABLA VI.** Comandos de monitoreo (consola: `make cli`)

| Comando | Uso |
|---|---|
| `pjsip set logger on` | Traza SIP completa en vivo |
| `rtcp set stats on` | Estadísticas de cada informe RTCP: pérdida y jitter |
| `rtcp set debug on` | Detalle de cada paquete RTCP |
| `pjsip show channelstats` | Resumen de QoS de las llamadas en curso |

Los registros persisten en el volumen `logs/var/log/asterisk/`:

- `full.log` y `messages.log` (`logger.conf`) se escriben de forma continua. El sufijo del nombre es el hostname del contenedor (`appendhostname=yes`), por lo que cada recreación del contenedor inicia un archivo nuevo.
- Al terminar cada llamada, `cdr.conf` y `cdr_custom.conf` añaden un registro a `cdr-csv/Master.csv` y `cdr-custom/Master.csv`. `make up` crea esos directorios, sin los cuales el registro falla.
- `make logs` solo sigue en vivo la salida del contenedor; no genera los archivos.

La columna `userfield` del CDR está reservada para las métricas RTP de la subrutina `qos-handler`, que aún no se invoca. Para activarla basta registrarla como *hangup handler* antes del `Dial()`:

```ini
same => n,Set(CHANNEL(hangup_handler_push)=qos-handler,s,1)
```

## V. ESCENARIOS DE LLAMADA

### A. Regla de direccionamiento

Asterisk escribe su propia dirección en el SDP y en la cabecera `Contact`. Cuando hay NAT, dos parámetros de `pjsip_local.conf` la corrigen: `external_*` indica qué dirección anunciar y `local_net` a qué redes no anunciarla. Actúan en pareja:

**TABLA VII.** Combinaciones de `external_*` y `local_net`

| Configuración | Teléfono en la LAN | Otra sede por internet |
|---|---|---|
| Ninguno de los dos | IP privada ✓ | IP pública ✓ |
| `external_*` sin `local_net` | IP pública ✗ | IP pública ✓ |
| `external_*` con `local_net` | IP privada ✓ | IP pública ✓ |

Con Linux, red `host` y la IP pública asignada a la interfaz del servidor no se configura ninguno: Asterisk elige la dirección de origen según la tabla de rutas del sistema operativo. Solo con NAT delante (Docker en modo bridge, router doméstico o nube con IP pública traducida) se declara `external_*` y, si hay extensiones en la LAN, `local_net` con la dirección de **red** (p. ej. `192.168.0.0/24`), no la de la puerta de enlace. En modo bridge `local_net` se deja comentado: el contenedor se ve a sí mismo como `172.17.0.x` y anunciaría esa dirección.

### B. Escenario 1: una PBX y softphones en la misma red

- Linux con red `host`: `pjsip_local.conf` sin cambios, solo los transportes.
- Docker Desktop en modo bridge: `external_media_address` y `external_signaling_address` con la IP LAN de la máquina en ambos transportes, y `local_net` comentado.

Cada softphone se registra contra la IP LAN de la PBX con el usuario y la clave de su extensión.

### C. Escenario 2: dos PBX en la misma red

Valida la troncal en un entorno controlado. En Linux con red `host` la IP de origen llega intacta y la troncal se autentica por IP (variante A de `pjsip.conf`). En cada PBX, apuntando a la otra:

```ini
[trunk_sip](endpoint-troncal)
context=entrantes_troncal_sip
aors=trunk_sip

[trunk_sip](aor-troncal-lan)
contact=sip:<IP_PRIVADA_OTRA_PBX>:5060   ; el contact pertenece al AOR

[trunk_sip]
type=identify
endpoint=trunk_sip
match=<IP_PRIVADA_OTRA_PBX>
```

Con Docker Desktop la IP de origen llega reescrita como `172.17.0.1` e `identify` nunca coincide. En ese caso se usa la variante B, con usuario, clave y registro de una PBX contra la otra, documentada en `pjsip.conf`. La captura de la Sección VIII corresponde a este caso.

### D. Escenario 3: PBX con IP pública, softphones en otras redes o en la LAN

La condición es que la IP pública esté asignada a la interfaz del servidor, lo que se comprueba con `ip -br -4 addr`. No basta con la ausencia de CGNAT: detrás de un router con reenvío de puertos, o en nubes que traducen la IP pública (AWS EC2, GCP), hace falta `external_*`.

`pjsip_local.conf` contiene solo los transportes en `0.0.0.0:5060` y `0.0.0.0:5061`. La troncal es la del escenario 2 con las IP públicas y la plantilla `aor-troncal-externa`, cuyo `qualify_timeout` tolera la latencia de internet. El plan de marcado no cambia entre LAN e internet: decide a qué extensión o troncal llamar, no qué dirección anunciar.

Los softphones se registran contra la IP pública de su PBX, o contra la privada si están en su LAN. Desde internet conviene usar TLS (Sección VII).

```
  1001 ── PBX Caracas (IP_A) ◄─── trunk_sip ───► PBX Maracaibo (IP_B) ── 2001
          red host, sin NAT        5060/UDP        red host, sin NAT
```

**Fig. 1.** Topología del escenario de entrega.

## VI. INSTRUCTIVO DE DESPLIEGUE

Servidor Linux con la IP pública en la interfaz. Se repite en cada sede.

**1. Instalar Docker Engine.**

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER      # cerrar sesión y volver a entrar
```

**2. Clonar el repositorio.**

```bash
git clone https://github.com/Danfloca02/voip-pbx.git && cd voip-pbx
```

**3. Verificar las direcciones.**

```bash
curl -4 ifconfig.me      # IP pública vista desde internet
ip -br -4 addr           # IP asignadas a las interfaces
```

Si la IP pública aparece en la segunda salida no hay NAT y no se configura `external_*`. Si no aparece, se aplica la Tabla VII.

**4. Crear el transporte y el certificado TLS**, que no se versionan. Sin `keys/` el transporte TLS no carga.

```bash
cp config/etc/asterisk/pjsip_local.conf.example config/etc/asterisk/pjsip_local.conf
mkdir -p config/etc/asterisk/keys
openssl req -x509 -newkey rsa:4096 -nodes -days 730 \
  -keyout config/etc/asterisk/keys/asterisk.key \
  -out config/etc/asterisk/keys/asterisk.crt \
  -subj "/CN=<NOMBRE_SEDE>" -addext "subjectAltName=IP:<IP_PUBLICA>"
```

**5. Configurar `pjsip.conf`:** descomentar la variante A de `trunk_sip` con la IP pública de la otra sede y cambiar las claves de las extensiones, que por defecto coinciden con su número.

**6. Confirmar la red del contenedor.** `compose.yaml` debe usar `network_mode: host` sin bloque `ports:`, y no debe existir `compose.override.yaml`, que solo se usa con Docker Desktop.

```bash
docker compose config | grep network_mode     # debe mostrar: host
```

**7. Configurar el firewall.** El rango RTP debe coincidir con `rtp.conf`.

```bash
sudo ufw allow OpenSSH                                          # antes de habilitar
sudo ufw allow from <IP_OTRA_PBX> to any port 5060 proto udp    # troncal
sudo ufw allow 5061/tcp                                          # softphones por TLS
sudo ufw allow 10000:10050/udp                                   # audio RTP
sudo ufw enable && sudo ufw status numbered
```

Si hay softphones que se registran por UDP desde internet se abre `5060/udp` a cualquier origen, lo que exige claves robustas. En la nube se abren los mismos puertos en el grupo de seguridad.

**8. Construir e iniciar.** `make up` crea además los directorios del CDR.

```bash
make build && make up
```

**9. Verificar** desde `make cli`:

```
pjsip show transports     ; udp 5060 y tls 5061
pjsip show endpoints      ; trunk_sip en estado Avail
pjsip show contacts       ; extensiones registradas
```

**10. Probar:** registrar los softphones, activar `pjsip set logger on` y recorrer los códigos de la Tabla V.

## VII. PRUEBA DE TLS Y SRTP

El transporte TLS carga y completa el handshake (verificado con TLS 1.2 y el cifrado ECDHE-RSA-AES256-GCM-SHA384), pero la llamada cifrada de extremo a extremo queda pendiente de validar antes del despliegue final. El procedimiento es:

1. Comprobar el handshake desde otra máquina:

   ```bash
   openssl s_client -connect <IP_PBX>:5061 -tls1_2 </dev/null
   ```

2. Asignar a la extensión la plantilla cifrada y recargar con `pjsip reload`:

   ```ini
   [1001](endpoint-interno-tls)    ; antes: (endpoint-interno)
   ```

3. Configurar el softphone con transporte TLS, puerto 5061 y SRTP obligatorio. Si valida el certificado, aceptar la excepción, ya que es autofirmado.

4. Llamar con `pjsip set logger on` activo. La consola muestra el SIP ya descifrado.

**TABLA VIII.** Resultados esperados de la prueba TLS/SRTP

| Verificación | Resultado esperado | Si falla |
|---|---|---|
| `openssl s_client` | `TLSv1.2` y `Verify return code: 18` (autofirmado) | 5061/TCP cerrado o falta `keys/` |
| `pjsip show contacts` | Contacto con `transport=TLS` | El softphone sigue en UDP |
| SDP en la traza | `m=audio … RTP/SAVP` y una línea `a=crypto` | `488 Not Acceptable Here`: el softphone no ofrece SRTP |
| Wireshark, puerto 5061 | Solo *TLS Application Data*; SIP ilegible | TLS inactivo |
| Wireshark, *RTP → Play Streams* | Ruido en lugar de voz | SRTP inactivo |

## VIII. ANÁLISIS DE LA CAPTURA DE PAQUETES

### A. Contexto

La captura `llamadas_troncal_mismaLAN_test.pcapng` (7 417 paquetes, unos 3,5 min) se tomó en el escenario 2 con Docker Desktop en modo bridge y la troncal en variante B, sobre el adaptador de loopback del equipo `192.168.0.10`. Por eso registra la pata entre el softphone (MicroSIP, extensión 1001, en la misma máquina) y la PBX local, pero no los paquetes entre las dos PBX. El 89 % del tráfico es TCP de loopback ajeno a la telefonía; lo relevante son 45 mensajes SIP y 731 paquetes RTP.

### B. Llamadas

**TABLA IX.** Llamadas registradas

| Llamada | Destino | Resultado | PDD | Duración |
|---|---|---|---|---|
| A | `22001` | `404 Not Found` | — | — |
| B | `82001`, saliente por troncal | Completada | 1 196 ms | 4,4 s |
| C | `1001`, entrante por troncal | Completada | 28 ms | 3,5 s |

En A la autenticación fue correcta y el rechazo provino del plan de marcado: `22001` no coincide con ningún patrón, porque el prefijo de troncal es `8`. El sistema descarta así los destinos no enrutables en lugar de reenviarlos. B y C demuestran la troncal en ambos sentidos; el PDD de B incluye el recorrido hasta la otra PBX. Ambas terminaron con `BYE` y causa Q.850 16 (*normal clearing*), sin retransmisiones ni errores 5xx.

### C. Calidad del audio

**TABLA X.** Flujos RTP (PCMU; jitter según RFC 3550 [7])

| Flujo | Paquetes | Pérdida | Jitter | Δ máx. |
|---|---|---|---|---|
| Teléfono → PBX (B) | 223 | 0 % | 0,06 ms | 20,6 ms |
| PBX → teléfono (B) | 195 | 0 % | 6,50 ms | 277,0 ms |
| Teléfono → PBX (C) | 176 | 0 % | 0,08 ms | 20,3 ms |
| PBX → teléfono (C) | 137 | 0 % | 6,95 ms | 278,1 ms |

Sin pérdida y con jitter inferior a 7 ms, el modelo E [11] da un MOS estimado cercano a 4,4, el máximo práctico de G.711.

### D. Hallazgos

1. **Reescritura de la IP de origen.** Todas las respuestas de la PBX llevan `received=172.17.0.1` y el contacto de 1001 quedó registrado como `sip:1001@172.17.0.1:44234`: Asterisk no ve la IP real del cliente. Es la evidencia empírica de por qué `identify` no funciona con Docker Desktop y de la elección de la red `host` en producción [2].
2. **Jitter asimétrico.** En el sentido PBX → teléfono el audio llega a ráfagas, con huecos de hasta 277 ms, aunque Asterisk emite cada 20 ms. La hipótesis es que el proxy de puertos de Docker Desktop acumula los paquetes; se confirmará si el efecto desaparece con red `host`. No causó pérdidas, pero supera un búfer de jitter típico de 60 ms.
3. **Códecs.** Se usó PCMU en los cuatro flujos. La oferta hacia 1001 en la llamada C incluye G.722 porque esa pata usa el perfil de la extensión (`codec-interno`) y no el de la troncal; PCMU encabeza la oferta por ser el códec ya negociado en la troncal, lo que evita transcodificar.
4. **Identidad del llamante.** La llamada C llega con `From: <sip:trunk_sip@172.17.0.2>`, así que el teléfono muestra `trunk_sip` en lugar de la extensión que llama: es un efecto del `from_user` de la variante B. `172.17.0.2` es la dirección del propio contenedor local. La variante A no usa `from_user` y conserva el número.

La captura debe repetirse en producción con red `host`, en la interfaz física para registrar también la troncal, y con un filtro que excluya el ruido:

```bash
sudo tcpdump -i any -n -w entrega.pcap \
  'udp port 5060 or tcp port 5061 or udp portrange 10000-10050'
```

## IX. PRUEBA DEL BUZÓN DE VOZ

### A. Contexto

La captura `test_voicemail.pcapng` (5 397 paquetes, 93,8 s) se tomó en el mismo equipo, despliegue (bridge, variante B) y adaptador que la de la Sección VIII. Se cruzó con `full.log` de la PBX; los relojes del equipo y del contenedor difieren en alrededor de 1 s.

### B. Eventos

**TABLA XI.** Eventos de la prueba

| Evento | Señalización en la captura | Resultado |
|---|---|---|
| 1. Llamada entrante por troncal a 1001 | `INVITE` → `100 Trying` → `180 Ringing` → `486 Busy Here` (6,8 s) → `ACK` | El usuario rechaza; la llamada pasa al buzón |
| 2. Consulta del buzón (`*97`) | `INVITE` → `401` → `INVITE` con credenciales → `200 OK` (67 ms, sin `180`) → `UPDATE` → `BYE` a los 39,5 s | Mensaje escuchado y borrado |

En el evento 1 el `486` llega 6,8 s después del timbrado: es un rechazo manual, no un vencimiento de los 20 s. La captura no muestra el buzón porque este no ocurre en la pata del teléfono: el log confirma que la propia PBX ejecuta `VoiceMail()` sobre el canal de la troncal, cuyo audio viaja hacia la otra PBX y no pasa por el adaptador capturado.

```
02:11:46.048 app_dial.c: Everyone is busy/congested at this time (1:1/0/0)
02:11:46.159 Executing [1001@entrantes_troncal_sip:4] VoiceMail("PJSIP/trunk_sip-00000008", "1001@default,u")
02:11:59.941 app_voicemail.c: Recording the message
02:12:02.893 app.c: User hung up
```

En el evento 2 la respuesta es inmediata y sin `180 Ringing` porque no hay un teléfono que alertar: Asterisk contesta y ejecuta `VoiceMailMain()`. La captura registra 72 paquetes `telephone-event` (RFC 4733), que corresponden a los seis dígitos que el log recibe: la clave `1001`, `1` para escuchar y `7` para borrar.

```
02:12:28.533 Playing 'vm-youhave.gsm' ... 'digits/1.gsm' ... 'vm-INBOX.gsm'
02:12:41.545 Playing '/var/spool/asterisk/voicemail/default/1001/INBOX/msg0000.slin'
02:12:56.161 DTMF end '7' received on PJSIP/1001-0000000a, duration 200 ms
02:12:56.170 Playing 'vm-deleted.gsm'
```

La prueba valida el ciclo completo del buzón: desvío por ocupado, grabación, aviso de mensaje nuevo, reproducción y borrado.

### C. Calidad del audio

**TABLA XII.** Flujos RTP de la consulta al buzón (PCMU)

| Flujo | Paquetes | Pérdida | Jitter |
|---|---|---|---|
| Teléfono → PBX | 1 976 (1 904 de voz y 72 DTMF) | 0 % | 0,09 ms |
| PBX → teléfono | 1 755 | 0 % | 2,01 ms |

La voz y los DTMF comparten SSRC y numeración de secuencia; contados juntos no hay huecos. Los silencios del sentido PBX → teléfono, de hasta 7,3 s, tampoco son pérdidas: la numeración es continua y corresponden a los momentos en que Asterisk espera un dígito y no tiene audio que enviar.

### D. Hallazgos

1. **Puerto de medios distinto al anunciado.** Asterisk anunció `m=audio 10044`, pero el audio llegó al teléfono desde el puerto 52418. Es el proxy de Docker Desktop reescribiendo el puerto de origen, la misma familia de efectos que `received=172.17.0.1`. En modo bridge el rango de `rtp.conf` no describe lo que viaja por el cable; con red `host` ambos coinciden y el firewall de la Sección VI es exacto.
2. **Jitter.** 2 ms frente a los 6,5 ms de la Sección VIII. Son escenarios distintos (audio generado por la PBX frente a audio puenteado desde la troncal), por lo que no se extrae una conclusión de la diferencia.
3. **Saludo de ocupado.** Con el rechazo (`DIALSTATUS=BUSY`) el buzón reproduce el saludo de «no disponible» porque el plan de marcado siempre usa la opción `u`. Se puede elegir según el estado con `VoiceMail(${EXTEN}@default,${IF($["${DIALSTATUS}"="BUSY"]?b:u)})`.

## X. ESCENARIO DE LLAMADA EN ESPERA (HOLD)

### A. Planteamiento

Una llamada puesta en espera debe mantenerse mientras el usuario lo decida, pero no indefinidamente si el extremo retenido desaparece (cierre del softphone, pérdida de red o de batería). En ese caso no llega ningún `BYE` y, sin un mecanismo adicional, la llamada queda abierta: ocupa un canal, deja el CDR sin cerrar y retiene puertos del rango RTP, que con 10000–10050 admite pocas sesiones simultáneas. El requisito es cortarla automáticamente a los 15 minutos sin audio.

Existe además el problema inverso: la troncal tiene `rtp_timeout=60` para detectar llamadas activas muertas. Si ese valor se aplicara también en espera, una llamada retenida legítimamente se cortaría al minuto, porque el extremo retenido deja de enviar audio.

### B. Fundamento teórico

SIP no transporta el audio ni verifica que siga fluyendo: una vez establecida la sesión, el audio viaja por RTP sobre UDP, sin conexión. La espera se negocia con el modelo oferta/respuesta de SDP [12]: el teléfono que retiene envía un re-INVITE (o `UPDATE`) cuyo SDP lleva `a=sendonly` o `a=inactive` —o, en implementaciones antiguas, `c=0.0.0.0`— y el otro extremo responde `a=recvonly` o `a=inactive`. A partir de ahí el flujo hacia el teléfono se detiene y el del teléfono puede detenerse también. Al reanudar, un nuevo re-INVITE restablece `a=sendrecv`.

Como UDP no tiene conexión, la única forma de saber que un extremo sigue vivo es que sigan llegando sus paquetes. Asterisk 22 lo implementa en `res_pjsip_sdp_rtp.c`:

1. Al recibir un SDP con `sendonly`, `inactive` o dirección nula, marca la pata como retenida (`remotely_held`), pide música en espera para el otro extremo (`ast_queue_hold`, clase `moh_suggest=default`) y deja de enviarle audio.
2. Elige el temporizador de la pata: `rtp_timeout` si está activa y `rtp_timeout_hold` si está en espera. Un valor 0 lo desactiva.
3. La función `rtp_check_timeout` compara el instante actual con el del último paquete RTP **recibido** de esa pata. Mientras la diferencia sea menor que el límite, se reprograma para el tiempo restante.
4. Si el límite se alcanza, registra `Disconnecting channel '…' for lack of audio RTP activity in … seconds`, fija la causa `AST_CAUSE_REQUESTED_CHAN_UNAVAIL` (Q.850 44) y cuelga el canal. El puente se deshace y Asterisk envía `BYE` al otro extremo.

En consecuencia, con `rtp_timeout_hold=900`, si durante la espera pasan 15 minutos sin que Asterisk reciba paquetes de audio del extremo retenido, se da por perdido ese flujo, se corta la comunicación RTP y se cuelga la llamada. Si el teléfono sigue enviando paquetes durante la espera —`sendonly` lo permite—, el temporizador se reinicia con cada uno y la llamada no se corta, que es lo correcto: el extremo sigue vivo. `rtp_keepalive=15` no interfiere, porque actúa sobre los paquetes que Asterisk **envía** para mantener abiertas las traducciones NAT, no sobre los que recibe.

### C. Solución

**TABLA XIII.** Temporizadores RTP por plantilla (`pjsip.conf`)

| Plantilla | `rtp_timeout` (activa) | `rtp_timeout_hold` (espera) | `rtp_keepalive` |
|---|---|---|---|
| `endpoint-interno` y `endpoint-interno-tls` | 0 (desactivado) | 900 s | 15 s |
| `endpoint-troncal` | 60 s | 900 s | — |

```ini
[endpoint-interno](!,codec-interno)
rtp_keepalive=15
rtp_timeout_hold=900     ; 15 min en espera sin RTP recibido: se cuelga

[endpoint-troncal](!,codec-troncal)
rtp_timeout=60           ; llamada activa sin RTP durante 60 s: se cuelga
rtp_timeout_hold=900     ; en espera se tolera hasta 15 min
```

Al definirse en las plantillas, toda extensión o troncal nueva hereda los valores. `rtp_timeout_hold` también está en la troncal porque la espera puede iniciarla un teléfono de la otra sede, cuyo re-INVITE `sendonly` llega por la troncal. La configuración cargada se comprueba en la consola:

```
*CLI> pjsip show endpoint 1001
 rtp_keepalive                      : 15
 rtp_timeout                        : 0
 rtp_timeout_hold                   : 900
 moh_suggest                        : default
*CLI> pjsip show endpoint trunk_sip
 rtp_timeout                        : 60
 rtp_timeout_hold                   : 900
```

### D. Evidencia en los logs

Durante una llamada entrante por troncal hacia 1001, el softphone puso la llamada en espera. El log muestra que Asterisk detectó la retención y reprodujo música al interlocutor de la otra sede, y que la llamada terminó a los 19 s, todavía en espera, por un cuelgue normal:

```
02:09:19.078 app_dial.c: PJSIP/1001-00000007 answered PJSIP/trunk_sip-00000006
02:09:19.125 bridge_channel.c: Channel PJSIP/trunk_sip-00000006 joined 'simple_bridge'
02:10:37.860 res_musiconhold.c: Started music on hold, class 'default', on channel 'PJSIP/trunk_sip-00000006'
02:10:56.876 res_musiconhold.c: Stopped music on hold on PJSIP/trunk_sip-00000006
02:10:56.886 bridge_channel.c: Channel PJSIP/trunk_sip-00000006 left 'simple_bridge'
02:10:56.912 pbx.c: Spawn extension (entrantes_troncal_sip, 1001, 2) exited non-zero on 'PJSIP/trunk_sip-00000006'
```

Este extracto sustenta el diagnóstico en dos puntos: la espera se negocia y reconoce —la música arranca en la pata opuesta a la que retiene, `PJSIP/1001`, que desde ese momento queda sujeta a `rtp_timeout_hold`— y no aparece ningún `Disconnecting channel … for lack of audio RTP activity`, que es lo esperado al durar la espera 19 s, muy por debajo de 900 s.

El corte a los 15 minutos no se ha registrado aún en una prueba. Para verificarlo sin esperar el tiempo completo se reduce temporalmente el valor, se recarga y se retiene una llamada con un softphone que deje de enviar audio en espera (o se le bloquea la red):

```ini
rtp_timeout_hold=30      ; solo para la prueba; restaurar 900 después
```

```bash
make cli       # pjsip reload; pjsip set logger on
grep "lack of audio RTP activity" logs/var/log/asterisk/full.log.*
```

El resultado esperado es la línea `NOTICE … Disconnecting channel 'PJSIP/1001-…' for lack of audio RTP activity in 30 seconds`, seguida del `BYE` de Asterisk a ambos extremos y de un registro en `cdr-csv/Master.csv`.

## XI. CONCLUSIONES

La PBX cumple los requisitos planteados: llamadas internas, llamadas entre sedes por troncal en ambos sentidos —confirmadas en la captura—, plan de numeración documentado, monitoreo de QoS desde la consola y el CDR, y los servicios de transferencia, espera, desvío y conferencia. El buzón de voz quedó validado de extremo a extremo, y la llamada en espera se corta automáticamente tras 15 minutos sin audio del extremo retenido, sin afectar a las esperas legítimas.

Separar la configuración propia de cada máquina (`pjsip_local.conf`, `compose.override.yaml` y `keys/`) de la versionada permite usar el mismo repositorio en desarrollo y en producción sin editar archivos del control de versiones.

El principal hallazgo técnico es el efecto del modo bridge de Docker Desktop: reescribe la IP de origen, lo que impide autenticar la troncal por IP, e introduce ráfagas de jitter. En producción se usa la red `host`, donde Asterisk ve la red real y no necesita `external_*` ni `local_net`.

Quedan pendientes antes del despliegue final la validación de TLS y SRTP de extremo a extremo, la activación de `qos-handler` para registrar la QoS en el CDR, la prueba del corte por inactividad en espera (Sección X-D) y la repetición de las capturas en producción.

## REFERENCIAS

[1] Sangoma Technologies, "Asterisk Documentation." [En línea]. Disponible: https://docs.asterisk.org/

[2] Docker Inc., "Host network driver," *Docker Docs*. [En línea]. Disponible: https://docs.docker.com/engine/network/drivers/host/

[3] D. Flores y M. Marquina, "voip-pbx," repositorio GitHub, 2026. [En línea]. Disponible: https://github.com/Danfloca02/voip-pbx

[4] J. Rosenberg *et al.*, "SIP: Session Initiation Protocol," IETF, RFC 3261, jun. 2002.

[5] A. Begen, P. Kyzivat, C. Perkins y M. Handley, "SDP: Session Description Protocol," IETF, RFC 8866, ene. 2021.

[6] *Pulse Code Modulation (PCM) of Voice Frequencies*, Rec. ITU-T G.711, nov. 1988.

[7] H. Schulzrinne, S. Casner, R. Frederick y V. Jacobson, "RTP: A Transport Protocol for Real-Time Applications," IETF, RFC 3550, jul. 2003.

[8] T. Dierks y E. Rescorla, "The Transport Layer Security (TLS) Protocol Version 1.2," IETF, RFC 5246, ago. 2008.

[9] M. Baugher, D. McGrew, M. Naslund, E. Carrara y K. Norrman, "The Secure Real-time Transport Protocol (SRTP)," IETF, RFC 3711, mar. 2004.

[10] F. Andreasen, M. Baugher y D. Wing, "Session Description Protocol (SDP) Security Descriptions for Media Streams," IETF, RFC 4568, jul. 2006.

[11] *The E-model: a Computational Model for Use in Transmission Planning*, Rec. ITU-T G.107, jun. 2015.

[12] J. Rosenberg y H. Schulzrinne, "An Offer/Answer Model with the Session Description Protocol (SDP)," IETF, RFC 3264, jun. 2002.
