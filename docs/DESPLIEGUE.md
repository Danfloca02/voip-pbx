# Despliegue y pruebas

Guía operativa: qué ficheros se crean en cada máquina, dónde va cada IP, cómo
alternar entre `host` y `bridge`, qué abrir en el firewall, y cómo probar los
cuatro escenarios.

Estructura de ficheros y contextos: [ESTRUCTURA.md](ESTRUCTURA.md).
Detalle conceptual de troncales: [TRONCALES.md](TRONCALES.md).

| Sección | Contenido |
|---|---|
| [1](#1-ficheros-que-se-clonan-y-que-se-crean) | Qué se versiona y qué se crea por máquina |
| [2](#2-dónde-va-cada-ip) | La regla de las IPs |
| [3](#3-host-o-bridge) | Alternar modo de red |
| [4](#4-por-sistema-operativo) | Windows / Linux |
| [5](#5-firewall) | Reglas de puertos |
| [6](#6-salir-a-internet-ip-pública-y-nat) | IP pública, NAT, CGNAT |
| [7](#7-el-dialplan-y-los-contextos) | Contextos, códigos y qué cambia de LAN a internet |
| [8](#8-los-cuatro-escenarios) | Pruebas de los 4 escenarios |
| [9](#9-verificación-y-diagnóstico) | Comandos y tabla de síntomas |

---

## 1. Ficheros que se clonan y que se crean

El repo trae todo **menos** lo que cambia de una máquina a otra. Eso se crea
copiando su `.example`.

| Fichero | ¿Viene del repo? | ¿Qué hago con él? |
|---|---|---|
| `compose.yaml` | Sí | No tocar. Trae `network_mode: host` (servidor) |
| `compose.override.yaml` | **No**, ignorado | Crear **sólo en Windows** desde el `.example` |
| `config/etc/asterisk/pjsip.conf` | Sí | Extensiones y troncales. Igual en todas |
| `config/etc/asterisk/pjsip_local.conf` | **No**, ignorado | Crear **siempre** desde el `.example` |
| `config/etc/asterisk/keys/` | **No**, ignorado | Generar sólo si se usa TLS |
| `extensions.conf`, `voicemail.conf`, `confbridge.conf`, `features.conf` | Sí | Iguales en todas |

Primer arranque en cualquier máquina:

```bash
git clone <repo> && cd voip-pbx
cp config/etc/asterisk/pjsip_local.conf.example \
   config/etc/asterisk/pjsip_local.conf
# editar pjsip_local.conf: poner la IP (ver §2)
```

Y **sólo en Windows**, además:

```bash
cp compose.override.yaml.example compose.override.yaml
```

Si Asterisk arranca sin transporte, es que falta `pjsip_local.conf`.

---

## 2. Dónde va cada IP

Es la confusión más habitual. Los dos ficheros guardan cosas distintas:

| Fichero | Qué IP lleva | Pregunta que responde |
|---|---|---|
| `pjsip_local.conf` | **La mía** | ¿Con qué dirección me alcanzan? |
| `pjsip.conf` | **La del otro** | ¿A dónde llamo y de quién acepto? |

**Tu propia IP nunca va en `pjsip.conf`.** Si la pones en un `contact=`, la PBX
se llama a sí misma.

| Parámetro | Fichero | Valor |
|---|---|---|
| `external_media_address` | `pjsip_local.conf` | Mi IP: LAN o pública |
| `external_signaling_address` | `pjsip_local.conf` | La misma |
| `local_net` | `pjsip_local.conf` | Mi red, en formato red/máscara |
| `contact=` | `pjsip.conf` | IP de la otra PBX |
| `match=` | `pjsip.conf` | IP de la otra PBX, de quien acepto |

`bind=0.0.0.0:5060` no se toca nunca: significa "escucha en todas mis
interfaces" y es correcto siempre.

### Cómo obtener cada IP

```powershell
ipconfig                        # Windows: "Dirección IPv4" del Wi-Fi/Ethernet
```
```bash
ip -br -4 addr                  # Linux
curl -4 ifconfig.me             # IP pública real
```

En Windows, ignorar los adaptadores `vEthernet (WSL)`, los de Docker y los de
VPN: no son alcanzables desde fuera. Dentro de WSL, `hostname -I` da una IP
`172.x` que **no sirve** para que otra máquina te alcance.

### `external_*` y `local_net`: los dos juntos o ninguno

Estos dos parámetros son un par. `external_*` dice *qué dirección anuncio* y
`local_net` dice *a quién NO se la anuncio*. **`local_net` no hace nada si
`external_*` no está puesto.**

| Configuración | Teléfono en la LAN | Otra sede por internet |
|---|---|---|
| **Ninguno de los dos** | IP privada de la interfaz ✅ | IP pública ✅ |
| `external_*` **sin** `local_net` | IP pública ❌ hairpin | IP pública ✅ |
| `external_*` **con** `local_net` | IP privada ✅ | IP pública ✅ |

La primera y la tercera funcionan igual. **La rota es la del medio.**

**En el escenario de entrega no se pone ninguno de los dos.** Sin `external_*`,
Asterisk elige la dirección según el destino de cada llamada usando la tabla de
rutas: privada para los teléfonos de la sede, pública para la otra sede. Los dos
casos correctos, sin configurar nada.

Esos parámetros existen para **falsear** la respuesta cuando Asterisk no puede
averiguarla, es decir cuando hay NAT delante. Sin NAT no hacen falta.

Cuándo sí son obligatorios: §6.

---

## 3. Host o bridge

Un solo interruptor: **que exista o no `compose.override.yaml`**.

| | `bridge` (Windows) | `host` (servidor Linux) |
|---|---|---|
| `compose.override.yaml` | existe | **no existe** |
| Puertos | `ports:` explícitos | ninguno, quedan expuestos |
| IP de origen que ve Asterisk | reescrita a `172.17.0.1` | **la real** |
| `type=identify` en troncales | inservible → variante B | funciona |
| `local_net` | comentado | descomentado |
| Rango RTP | el publicado en `ports:` | libre, ampliable gratis |
| Firewall del host | Docker se lo salta | `ufw`/`firewalld` mandan |

### Pasar a bridge

```bash
cp compose.override.yaml.example compose.override.yaml
# comentar local_net en pjsip_local.conf
make down && make up
make check # debe mostrar 0.0.0.0:5060->5060/udp
```

### Pasar a host

```bash
rm compose.override.yaml
# descomentar local_net en pjsip_local.conf
make down && make up
make check     # la columna de puertos VACÍA es lo correcto
sudo ss -ulnp | grep 5060   # esto es lo que confirma que escucha
```

Comprobar qué está aplicando Compose:

```bash
docker compose config | grep -A4 network_mode
```

---

## 4. Por sistema operativo

### Windows con Docker Desktop

`network_mode: host` **no funciona**: el motor corre en la VM
`docker-desktop`, así que "host" es la red de esa VM, ni Windows ni WSL.
Asterisk arranca, escucha, y no lo alcanza nadie. Síntoma: el softphone se
queda en *connecting* para siempre.

```bash
cp compose.override.yaml.example compose.override.yaml
cp config/etc/asterisk/pjsip_local.conf.example config/etc/asterisk/pjsip_local.conf
# pjsip_local.conf: external_* = IP de ipconfig, local_net COMENTADO
make up
```

Tres trampas propias de este entorno:

1. **`networkingMode=mirrored` en `.wslconfig` rompe la publicación.** Docker
   publica el puerto dentro del namespace de WSL y Windows no escucha. Quitar
   esa línea y `wsl --shutdown`.
2. **Las VPN rompen la publicación.** NordVPN, Proton y similares instalan
   filtros que impiden que Docker publique en Windows. Desconectar la VPN
   *y* su kill switch. Comprobar con `netstat`.
3. **La IP de origen se reescribe a `172.17.0.1`**, así que `type=identify` no
   sirve: usar la variante B de `trunk_sip`.

Verificar que Windows publica de verdad:

```powershell
netstat -ano -p UDP | findstr :5060
```

Si sale vacío, nada va a funcionar por más que configures softphones.

### Servidor Linux

Es el destino real y el entorno más simple:

```bash
git clone <repo> && cd voip-pbx
# NO crear compose.override.yaml
cp config/etc/asterisk/pjsip_local.conf.example config/etc/asterisk/pjsip_local.conf
# pjsip_local.conf: external_* = IP pública o LAN, local_net DESCOMENTADO
make build && make up
sudo ss -ulnp | grep 5060
```

Con host networking se puede ampliar el rango RTP sin coste: subir `rtpend` en
`rtp.conf` y abrirlo en el firewall. No hay que replicarlo en ningún sitio.

---

## 5. Firewall

Los puertos son los mismos en todos los sistemas:

| Puerto | Protocolo | Para qué |
|---|---|---|
| 5060 | UDP | Señalización SIP |
| 5061 | TCP | Señalización SIP sobre TLS (sólo si se usa) |
| 10000-10020 | UDP | Audio RTP (el rango de `rtp.conf`) |

El rango RTP debe coincidir en `rtp.conf`, en `ports:` si estás en bridge, y en
el firewall. Si no coinciden, las llamadas conectan y se quedan mudas cuando se
agotan los puertos abiertos.

### Windows

PowerShell **como administrador**:

```powershell
New-NetFirewallRule -DisplayName "Asterisk SIP (UDP 5060)" `
  -Direction Inbound -Protocol UDP -LocalPort 5060 -Action Allow -Profile Private

New-NetFirewallRule -DisplayName "Asterisk RTP (UDP 10000-10020)" `
  -Direction Inbound -Protocol UDP -LocalPort 10000-10020 -Action Allow -Profile Private

# Sólo si usas TLS
New-NetFirewallRule -DisplayName "Asterisk SIP TLS (TCP 5061)" `
  -Direction Inbound -Protocol TCP -LocalPort 5061 -Action Allow -Profile Private
```

El perfil tiene que coincidir con el de tu red, o la regla no aplica:

```powershell
Get-NetConnectionProfile
Set-NetConnectionProfile -InterfaceAlias "Wi-Fi" -NetworkCategory Private
```

No usar `-Profile Any` en una red que no controlas.

> **`127.0.0.1` está exento del firewall, la IP de LAN no.** Si el softphone
> local funciona apuntando a `127.0.0.1` pero no a tu IP de LAN, te falta esta
> regla. Es exactamente el mismo muro que encuentra un móvil en la Wi-Fi.

### Linux (ufw)

```bash
sudo ufw allow OpenSSH          # ANTES de habilitar, o te quedas fuera
sudo ufw allow 5060/udp
sudo ufw allow 10000:10020/udp
sudo ufw enable
sudo ufw status numbered
```

Mejor todavía, restringido al origen conocido:

```bash
sudo ufw allow from 203.0.113.10 to any port 5060 proto udp
sudo ufw allow from 203.0.113.10 to any port 10000:10020 proto udp
```

### Linux (firewalld)

```bash
sudo firewall-cmd --permanent --add-port=5060/udp
sudo firewall-cmd --permanent --add-port=10000-10020/udp
sudo firewall-cmd --reload
```

> **En bridge, Docker se salta `ufw` y `firewalld`.** Inserta su DNAT antes de
> sus cadenas, así que un puerto publicado queda accesible aunque el firewall
> lo tenga denegado. Con `network_mode: host` el tráfico pasa por `INPUT` y el
> firewall recupera el control. Si te quedas en bridge, filtra en `DOCKER-USER`.

---

## 6. Salir a internet (IP pública y NAT)

> Esto es **PBX de este proyecto contra otra PBX de este proyecto** por
> internet. No hay proveedor SIP ni PSTN en el alcance (§7).

### La comprobación que lo decide todo

En cada servidor:

```bash
ip -br -4 addr
```

| Lo que muestra | Qué hacer |
|---|---|
| **La IP pública aparece ahí** | **Nada.** Sin `external_*` ni `local_net` (§2) |
| Sólo `10.x` / `172.x` / `192.168.x` y la pública está fuera | Poner el par (abajo) |

El primer caso es el habitual en servidor dedicado y en VPS tipo Hetzner,
DigitalOcean o Linode. El segundo es el habitual en **AWS EC2 y GCP**: la NIC
lleva una IP privada y el proveedor NATea la pública por fuera, así que Asterisk
no puede conocerla.

### Con IP pública directa en la NIC — escenario de entrega

`pjsip_local.conf` se queda sin una sola IP:

```ini
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

[transport-tls]
type=transport
protocol=tls
bind=0.0.0.0:5061
cert_file=/etc/asterisk/keys/asterisk.crt
priv_key_file=/etc/asterisk/keys/asterisk.key
method=tlsv1_2
```

Las únicas IPs del proyecto pasan a ser el `contact=` y el `match=` de la otra
sede, en `pjsip.conf`.

Requisito: **ninguna VPN en el servidor.** Si algo instala una ruta por defecto,
Asterisk puede elegir la interfaz del túnel y anunciar su dirección.

### Con la pública fuera de la NIC

```ini
; en AMBOS transportes
external_media_address=200.44.x.x
external_signaling_address=200.44.x.x
local_net=192.168.0.0/24        ; sólo si hay extensiones en la LAN
```

### Detrás de NAT (router doméstico)

`ipconfig` da una IP privada; la pública se ve con `curl -4 ifconfig.me`.

1. En `pjsip_local.conf`, `external_*` = la **pública**.
2. `local_net` = la LAN interna.
3. En el router, *Port Forwarding* / *Virtual Server* hacia la IP interna de la
   máquina: `UDP 5060`, `UDP 10000-10020`, y `TCP 5061` si usas TLS.

### CGNAT: no hay salida

Si la pública de `ifconfig.me` no coincide con la WAN del router, o el router
reporta una WAN en `100.64.x.x`–`100.127.x.x`, tu operador te tiene tras
Carrier Grade NAT. Abrir puertos no sirve porque no controlas ese NAT. La
alternativa práctica es una VPN entre las sedes y tratarlo como si fuera LAN.

### Antes de exponer el 5060 a internet

Un 5060 público recibe intentos de registro automatizados en horas.

- **Cambiar las claves de las extensiones.** Vienen iguales al número.
- Restringir por IP de origen siempre que se conozca.
- Usar la variante B de troncal con una clave larga y aleatoria.
- Nunca dejar el contexto de entrada con un `include` a un contexto de salida:
  es la puerta del fraude telefónico.

---

## 7. El dialplan y los contextos

Esta sección responde a la duda más frecuente al pasar de LAN a internet:
**el dialplan no cambia.** Nada de lo que se explica en §6 toca
`extensions.conf`.

### Aviso sobre el vocabulario

En este proyecto **no hay proveedor SIP ni salida a la telefonía tradicional**.
Cuando la documentación dice *"por internet"* se refiere a dos PBX de este
mismo repo hablándose entre IPs públicas.

Existieron los contextos `salientes_redpublica` y `entrantes_redpublica` para
una troncal con operador; se eliminaron por estar fuera de alcance, y el
prefijo `9` quedó libre.

### Los cuatro contextos

```
[llamadas_internas]           <- donde entran las extensiones
    include => salientes_troncal_sip
[salientes_troncal_sip]       <- prefijo 8: salida hacia la otra sede
[entrantes_troncal_sip]       <- entrada de llamadas de la otra sede
[qos-handler]                 <- subrutina de calidad (definida, sin invocar)
```

Lo que se puede marcar desde un softphone:

| Se marca | Qué ocurre |
|---|---|
| `1XXX`–`5XXX` | Llama a la extensión, con desvío y buzón |
| `800` | Sala de conferencia |
| `*72<ext>` / `*73` | Activa / desactiva desvío |
| `*97` | Tu propio buzón |
| `*98` / `*98<ext>` | Buzón preguntando / de una extensión |
| `8<ext>` | Sale por la troncal hacia la otra sede |
| `#1` / `#2` / `#9` | En llamada: transferencia ciega / consultada / colgar |

Detalle completo de cada contexto en [ESTRUCTURA.md](ESTRUCTURA.md) §4.

### Qué cambia de LAN a internet

La troncal es **la misma** en los dos casos. Lo único que cambia son las
direcciones y el camino de red:

| | Misma LAN | Por internet |
|---|---|---|
| `external_*` en `pjsip_local.conf` | IP de LAN | **IP pública** |
| `local_net` en `pjsip_local.conf` | tu LAN | tu LAN (igual) |
| `contact=` en `pjsip.conf` | IP de LAN de la otra PBX | **IP pública de la otra** |
| `match=` en `pjsip.conf` | IP de LAN de la otra PBX | **IP pública de la otra** |
| Plantilla de AOR | `aor-troncal-lan` | `aor-troncal-externa` |
| Prefijo para marcar | `8` | `8`, el mismo |
| `extensions.conf` | — | **sin un solo cambio** |
| Router / firewall | reglas locales (§5) | + port forwarding (§6) |

Una PBX no sabe si el paquete cruzó internet o un switch: sólo ve una IP. Por
eso el escenario público es un problema de direccionamiento y NAT, no de plan
de marcado.

### Una regla de seguridad que no se debe romper

`[entrantes_troncal_sip]` **no incluye ningún contexto de salida**, y es
deliberado. Un `include` a un contexto de salida dentro de un contexto de
entrada permitiría que quien entre por la troncal saque llamadas por ella. Es
la vía clásica del fraude telefónico, y es el error que hay que evitar si algún
día se añade un proveedor.

---

## 8. Los cuatro escenarios

### Escenario 1 — Misma LAN, una PBX

```
  [ PBX 192.168.0.9 ]
      ├── MicroSIP 1001  (misma máquina)
      └── Zoiper   1002  (móvil en la Wi-Fi)
```

**Configuración.** `external_*` = `192.168.0.9`. En bridge, `local_net`
comentado. Nada en `pjsip.conf`: no hay troncal.

**Softphones.** Los dos apuntan a `192.168.0.9`, usuario y clave = el número
de extensión, Transport = UDP.

**Prueba.**

```
pjsip show contacts          ; 1001 y 1002 con su IP real
```

Marcar `1002` desde `1001`. Luego, para el resto de funciones:

| Función | Cómo |
|---|---|
| Buzón | Llamar a 1002, no contestar 20 s, dejar mensaje. `voicemail show users` sube `NewMsg` |
| Escuchar buzón | Desde 1002 marcar `*97`, clave `1002` |
| Desvío | En 1001 marcar `*721002`. Llamar a 1001: suena 1002. `database show CF` |
| Quitar desvío | En 1001 marcar `*73` |
| Hold | Botón Hold del softphone. Sin `musiconhold` se oye silencio: es normal |
| Transferencia | Botón Transfer, o `#1` (ciega) / `#2` (consultada) en llamada |
| Conferencia | Marcar `800` desde los dos. `confbridge list 800` |

Si el móvil no registra pero MicroSIP sí, es el firewall (§5) o aislamiento de
clientes en el router Wi-Fi.

### Escenario 2 — Dos PBX en la misma LAN

```
  [ PBX A 192.168.0.9 ]  ←── trunk_sip ──→  [ PBX B 192.168.0.10 ]
    1001, 1002 (1XXX)                          2001, 2002 (2XXX)
```

**Configuración por lado.** En cada `pjsip_local.conf`, `external_*` = su
propia IP. En cada `pjsip.conf`, descomentar `trunk_sip`:

- **Servidor Linux con host:** variante A. En A, `contact` y `match` =
  `192.168.0.10`. En B, los dos = `192.168.0.9`.
- **Windows con Docker Desktop:** variante A **no funciona**, la IP de origen
  llega como `172.17.0.1`. Usar la variante B: uno hace de servidor con
  `auth=`, el otro añade un `type=registration` apuntando al primero. La clave
  debe ser idéntica en ambos.

**Prueba.**

```
pjsip show endpoints         ; trunk_sip debe pasar a Avail
pjsip show aors              ; confirma el contact
pjsip show registrations     ; en el lado cliente de la variante B: Registered
```

Desde 1001 marcar `82001`: el prefijo `8` sale por la troncal y se envía `2001`.

Para marcar `2001` directo, sin prefijo, dividir el patrón en `extensions.conf`
de la PBX A:

```ini
exten => _1XXX,1,NoOp(Local)
 same => n,Dial(PJSIP/${EXTEN},20,tT)
 same => n,Hangup()

exten => _2XXX,1,NoOp(Hacia la otra sede)
 same => n,Dial(PJSIP/${EXTEN}@trunk_sip,20,tT)
 same => n,Hangup()
```

En la PBX B al revés. Entre sedes se envía la extensión **completa**, sin
`${EXTEN:1}`.

Si `trunk_sip` queda `Unavailable`, es red: firewall, IP del `contact`, o la
otra PBX apagada. No es dialplan.

### Escenario 3 — PBX con IP pública, softphones en otra red

```
  [ PBX  IP pública 200.44.x.x ]
        ▲                  ▲
        │                  │
   Softphone LAN      Softphone remoto
   192.168.0.x        (otra red / 4G)
```

**Configuración.** `external_*` = la IP **pública**. `local_net` = la LAN
interna, **descomentado** — es lo que hace que los dos softphones funcionen a
la vez. Requiere `network_mode: host`, así que servidor Linux.

Si está tras NAT, añadir el port forwarding del router (§6).

**Softphones.** El de la LAN apunta a la IP privada de la PBX; el remoto, a la
pública. Cada uno recibe en el SDP la dirección que le corresponde.

**Prueba.**

```
pjsip show contacts
```

El contacto local debe mostrar una IP `192.168.0.x` y el remoto su IP pública.
Llamar en los dos sentidos y confirmar audio **bidireccional**: si sólo se oye
en un sentido, es `local_net` o el rango RTP sin abrir.

Cambiar las claves antes de esta prueba. El 5060 queda expuesto.

### Escenario 4 — Dos PBX con IP pública, un softphone en cada LAN

**Éste es el escenario de entrega.** Dos servidores Linux, Docker Engine nativo,
`network_mode: host`, IP pública fija en la NIC de cada uno.

```
  [ PBX A  IP_A ]  ←── trunk_sip ──→  [ PBX B  IP_B ]
     │ LAN 192.168.0.0/24                │ LAN 10.0.0.0/24
   1001                                 2001
```

#### Ficheros por servidor

| Fichero | Sede A | Sede B |
|---|---|---|
| `compose.override.yaml` | **no existe** | **no existe** |
| `pjsip_local.conf` | sin IPs (§6) | sin IPs (§6) |
| `keys/` | generado en A | generado en B |
| `contact=` / `match=` | `IP_B` | `IP_A` |

Comprobar antes de nada que `ip -br -4 addr` muestra la pública en los dos.

#### Troncal — variante A en los dos lados

Sede A:

```ini
[trunk_sip](endpoint-troncal)
context=entrantes_troncal_sip
aors=trunk_sip

[trunk_sip](aor-troncal-externa)
contact=sip:IP_B:5060

[trunk_sip]
type=identify
endpoint=trunk_sip
match=IP_B
```

Sede B: idéntico con `IP_A` en las dos líneas.

Sin claves, sin registro y sin caducidad: con host networking la IP de origen
llega intacta, así que `identify` es control de acceso real. La variante B sólo
hace falta en Docker Desktop.

La plantilla es `aor-troncal-externa`, con el `qualify_timeout` más holgado para
la latencia de internet.

#### Firewall — aprovechar que las IPs son fijas

La troncal y los teléfonos tienen necesidades distintas, y conviene separarlos:

```bash
sudo ufw allow OpenSSH

# Troncal: sólo la otra sede. Nadie más toca el 5060.
sudo ufw allow from IP_B to any port 5060 proto udp comment 'Troncal SIP'
sudo ufw allow from IP_B to any port 10000:10020 proto udp comment 'Troncal RTP'

# Softphones: por TLS, abierto porque sus IPs no son fijas.
sudo ufw allow 5061/tcp comment 'Extensiones TLS'
sudo ufw allow 10000:10020/udp comment 'RTP extensiones'

sudo ufw enable
sudo ufw status numbered
```

Así el 5060 UDP no queda expuesto a internet, que es donde llegan los intentos
de registro automatizados en cuestión de horas. Para eso las extensiones deben
usar `(endpoint-interno-tls)` en lugar de `(endpoint-interno)`.

En cloud, abrir lo mismo en el grupo de seguridad, **en UDP y TCP** (§5).

#### Pruebas, en este orden

```
pjsip show transports        ; udp 5060 y tls 5061
pjsip show endpoints         ; trunk_sip debe estar Avail en los dos lados
pjsip show identifies        ; el match con la IP de la otra sede
pjsip show contacts          ; las extensiones, con ;transport=TLS
```

1. **Registro local.** `1001` en su LAN contra `IP_A`, con Transport = TLS.
2. **Llamada interna en cada sede**, para validar audio sin troncal por medio.
3. **Entre sedes.** Desde `1001` marcar `82001`.
4. **Audio bidireccional.** Es lo que se rompe aquí y no en LAN: si se oye en un
   solo sentido, revisar el rango RTP abierto en los dos firewalls.
5. **Conferencia mixta.** Los dos marcan `800`; comprobar `confbridge list 800`.
6. **Cifrado.** `core show channel <canal>` durante una llamada debe indicar
   SRTP. En Wireshark, si *Play Streams* reproduce la conversación, no está
   cifrado.

#### Antes de entregar

- [ ] `ip -br -4 addr` muestra la pública en los dos servidores
- [ ] No existe `compose.override.yaml` en ninguno
- [ ] `pjsip_local.conf` sin IPs, creado desde el `.example`
- [ ] Certificado generado en cada máquina; `keys/` no versionado
- [ ] Claves de las extensiones cambiadas: ya no son `1001`/`1002`
- [ ] `ufw` con el 5060 restringido por IP de origen
- [ ] `sudo ufw allow OpenSSH` antes de `ufw enable`
- [ ] Ninguna VPN activa en los servidores
- [ ] Cada sede con su propio rango de numeración

---

## 9. Verificación y diagnóstico

```bash
make cli
```

```
pjsip show transports        ; 2 objetos: udp 5060 y tls 5061
pjsip show endpoints
pjsip show contacts
pjsip show aors
pjsip show identifies
pjsip show registrations
voicemail show users
database show CF             ; desvíos activos
confbridge list
features show                ; códigos DTMF activos
dialplan show llamadas_internas
core show channels
pjsip set logger on          ; traza SIP en vivo
```

| Síntoma | Causa más probable |
|---|---|
| Softphone en *connecting* eterno | Falta `compose.override.yaml` en Windows, o VPN activa (§4) |
| `netstat` sin `:5060` en Windows | Docker no publica: `networkingMode=mirrored` o VPN (§4) |
| `127.0.0.1` funciona, la IP de LAN no | Falta la regla de firewall (§5) |
| Registra pero no hay audio | `external_*` mal, o rango RTP cerrado (§5) |
| Audio en un solo sentido | `local_net` activo en bridge, o RTP sin reenviar en un router |
| Fallan las llamadas a partir de la quinta | 11 puertos pares y 2 por llamada: ampliar el rango |
| `trunk_sip` en `Unavailable` | El `qualify` no obtiene respuesta: red, no Asterisk |
| Salientes van, entrantes se rechazan | `identify` no casa: Docker Desktop reescribe la IP. Variante B |
| `488 Not Acceptable Here` | Sin codec común, o SRTP exigido contra un cliente sin cifrado |
| El que llama cae al buzón tras hablar | Falta el `GotoIf` sobre `${DIALSTATUS}` |
| `#1` / `#2` no transfieren | Falta `tT` en el `Dial()`, o `featuremap` vacío |

Para captura en Wireshark: capturar en **Windows**, no en WSL, en el adaptador
que tiene la IP de LAN. Filtro de captura:

```
udp portrange 5060-5061 or udp portrange 10000-10020 or icmp
```

Un registro sano son cuatro paquetes: `REGISTER` → `401 Unauthorized` →
`REGISTER` con credenciales → `200 OK`. El 401 es normal. Para el audio,
*Telephony → RTP → RTP Streams*; si en *Play Streams* se oye la conversación,
el cifrado **no** está activo.
