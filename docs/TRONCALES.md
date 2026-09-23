# Troncales SIP y llamadas entre dos laptops

Guía práctica para que dos máquinas con este repo (o una máquina y un
proveedor SIP) puedan llamarse entre sí, en la misma LAN o en redes distintas.

Orden recomendado de lectura: **§2 → §3 → §4 o §5**. Para desplegar en un
servidor Linux con Docker, el apartado clave es **§2.4.2**. La sección 2 es
obligatoria en ambas laptops antes de tocar nada de troncales; la mayoría de
los fallos "de Asterisk" son en realidad fallos de red que se resuelven ahí.

| Sección | Contenido |
|---|---|
| [1](#1-qué-es-una-troncal-en-pjsip) | Qué objetos componen una troncal en PJSIP |
| [2](#2-preparar-la-red-obligatorio-en-todas-las-máquinas) | IPs, `compose.yaml`, firewall (Windows y **servidor Linux**), transporte PJSIP |
| [3](#3-llamadas-entre-softphones-en-dos-laptops-distintas) | Softphones en dos laptops, **sin** troncal |
| [4](#4-escenario-a--dos-pbx-en-la-misma-lan) | Troncal entre dos PBX en la misma LAN |
| [5](#5-escenario-b--dos-pbx-en-redes-distintas) | Troncal entre redes distintas (NAT, registro, VPN) |
| [6](#6-troncal-hacia-un-proveedor-sip-comercial) | Proveedor SIP comercial |
| [7](#7-seguridad-no-te-dejes-la-puerta-abierta) | Seguridad / fraude telefónico |
| [8](#8-diagnóstico-rápido) | Tabla de síntomas y causas |

Los objetos PJSIP a rellenar ya están escritos y comentados en la sección 5 de
[`config/etc/asterisk/pjsip.conf`](../config/etc/asterisk/pjsip.conf).

---

## 1. Qué es una troncal en PJSIP

Una troncal no es un objeto único: son **cuatro o cinco objetos** que comparten
nombre y trabajan juntos.

| Objeto | Para qué sirve | ¿Obligatorio? |
|---|---|---|
| `type=endpoint` | Define el "otro lado": codecs, contexto de entrada, NAT | Sí |
| `type=aor` | *Address of Record*: a qué IP/puerto salen las llamadas | Sí |
| `type=auth` | Usuario y clave | Sólo con autenticación por credenciales |
| `type=identify` | Reconoce llamadas **entrantes** por su IP de origen | Sí, salvo que el otro lado se autentique con usuario/clave |
| `type=registration` | Registro saliente: le dice al otro lado dónde encontrarte | Sólo si tu IP es dinámica o estás tras NAT |

La regla mental útil:

- **`aor`** responde a *"¿a dónde llamo yo?"*
- **`identify`** (o `auth`) responde a *"¿de quién acepto llamadas?"*

Hay que resolver **las dos direcciones**. Configurar sólo el `aor` produce una
troncal que puede llamar pero no recibir.

### Plantillas de AOR disponibles

`pjsip.conf` define tres plantillas según dónde esté el otro extremo:

| Plantilla | Cuándo usarla | Lleva `contact=` |
|---|---|---|
| `[aor-troncal-lan]` | La otra PBX está en la misma LAN, IP fija | Sí, la IP de LAN |
| `[aor-troncal-externa]` | Otro extremo fuera de la LAN con IP pública o dominio fijo | Sí, la IP pública o el host |
| `[aor-troncal-dinamica]` | El otro extremo no tiene IP fija y **se registra** contra esta PBX | No: se aprende del `REGISTER` |

---

## 2. Preparar la red (obligatorio en todas las máquinas)

Este es el paso que más tiempo hace perder si se salta. Hay que hacerlo
**en las dos máquinas**, no sólo en una.

### 2.1 Obtener la IP interna (LAN) con `ipconfig`

Abrir **PowerShell o CMD en Windows** (no en WSL) y ejecutar:

```powershell
ipconfig
```

Salida típica, recortada:

```
Adaptador de LAN inalámbrica Wi-Fi:

   Sufijo DNS específico para la conexión. . :
   Dirección IPv6 temporal. . . . . . . . . : 2800:...
   Dirección IPv4. . . . . . . . . . . . . . : 192.168.1.10     <-- ESTA
   Máscara de subred . . . . . . . . . . . . : 255.255.255.0
   Puerta de enlace predeterminada . . . . . : 192.168.1.1      <-- el router
```

Lo que importa:

- **`Dirección IPv4`** del adaptador que realmente usas (Wi-Fi o Ethernet) es
  la IP interna de esa laptop. Es la que va en `external_media_address`, en
  `contact=` y en `match=` cuando ambas máquinas están en la misma LAN.
- **`Puerta de enlace predeterminada`** es tu router. Sirve para saber si
  estás detrás de NAT (ver §2.2) y para entrar a configurarlo.
- Ignora los adaptadores `vEthernet (WSL)`, `vEthernet (Default Switch)` y
  los de Docker: son redes virtuales internas de la máquina y **no son
  alcanzables desde la otra laptop**.

> **Cuidado con WSL.** Dentro de WSL, `hostname -I` devuelve algo como
> `172.28.x.x`. Esa IP es del subsistema Linux y **no sirve** para que otra
> computadora te alcance. La IP buena es siempre la de `ipconfig` en Windows.

Si las dos laptops están en la misma LAN, sus IPv4 comparten los primeros tres
octetos (`192.168.1.10` y `192.168.1.20`). Si no coinciden, no están en la
misma red y aplica el §5, no el §4.

Comprobación rápida desde la laptop A hacia la B:

```powershell
ping 192.168.1.20
```

Si no responde, casi siempre es el firewall de Windows de la laptop B (§2.4) o
un **aislamiento de clientes** activado en el router WiFi (típico en redes de
universidad, cafés y hoteles: cada dispositivo ve internet pero no a sus
vecinos). En ese caso no hay solución por configuración: hay que usar otra red
o una VPN (§5.1).

### 2.2 Obtener la IP pública

**`ipconfig` NO te da la IP pública si estás detrás de un router**, que es el
caso normal en casa, en la universidad o con datos móviles. Lo que muestra es
tu IP privada.

Sabes que estás detrás de NAT si tu `Dirección IPv4` cae en uno de estos
rangos privados:

| Rango | Ejemplo |
|---|---|
| `10.0.0.0` – `10.255.255.255` | `10.0.0.5` |
| `172.16.0.0` – `172.31.255.255` | `172.20.1.8` |
| `192.168.0.0` – `192.168.255.255` | `192.168.1.10` |

Para ver la IP pública real, desde PowerShell:

```powershell
curl.exe -4 https://ifconfig.me
```

O desde WSL:

```bash
curl -4 ifconfig.me
```

También sirve abrir cualquier buscador y escribir "cuál es mi ip".

Sólo cuando `ipconfig` muestra directamente una IP **no** privada tienes IP
pública en la máquina, y entonces `ipconfig` sí te la da.

> **Caso sin salida: CGNAT.** Si tu IP pública (la de `ifconfig.me`) no
> coincide con la WAN que muestra tu router, o el router reporta una WAN en el
> rango `100.64.x.x` – `100.127.x.x`, tu operador te tiene detrás de *Carrier
> Grade NAT*. Abrir puertos en el router no servirá de nada porque no controlas
> el NAT de arriba. La salida práctica es una VPN (§5.1).

### 2.3 Configurar `compose.yaml`

**El repo viene configurado para el destino real: `network_mode: host`**, que
es lo correcto en el servidor Linux de producción (§2.4.2). En Windows con
Docker Desktop eso no funciona, así que para desarrollar en una laptop hay que
sustituir esa línea por un bloque `ports:`.

**Sólo local** (un softphone en la misma máquina, nada entra de fuera):

```yaml
    ports:
      - "127.0.0.1:5060:5060/udp"
      - "127.0.0.1:10000-10020:10000-10020/udp"
```

**Dos laptops / troncales** — quitar el bind a loopback para escuchar en todas
las interfaces:

```yaml
    ports:
      - "5060:5060/udp"
      - "10000-10020:10000-10020/udp"
```

Aplicar el cambio (recrear el contenedor, no basta con `restart`):

```bash
make down && make up
make check     # confirmar que aparece 0.0.0.0:5060->5060/udp
```

Notas:

- El rango RTP `10000-10020` son **21 puertos**. Cada llamada consume 2 (RTP y
  RTCP), así que el tope real son ~10 llamadas simultáneas. Si hacen falta
  más, hay que ampliar el rango **en los dos sitios a la vez**:
  `rtp.conf` (`rtpstart`/`rtpend`) y `compose.yaml`. Publicar un rango grande
  en Docker Desktop es lento de arrancar, así que conviene no pasarse.
- Recuerda revertir a `network_mode: host` antes de desplegar en el servidor,
  y ampliar el rango RTP de vuelta (`rtp.conf` trae `10000-20000`, pensado
  para host; en bridge hay que reducirlo).
- No uses `network_mode: host` **en Windows**: con Docker Desktop el motor
  corre en su propia VM, no en la distro WSL, y el host de esa VM no es tu
  Windows. En un **servidor Linux sí es la opción recomendada** y cambia
  bastante las cosas — ver §2.4.2.

### 2.4 Reglas de puertos UDP en el firewall

Dos entornos distintos: **§2.4.1** para las laptops Windows de desarrollo,
**§2.4.2** para el servidor Linux de despliegue.

#### 2.4.1 Windows (laptops de desarrollo)

Hay que crearlas **en las dos laptops**. El firewall que importa es el de
**Windows**, no el de WSL ni el del contenedor.

Abrir **PowerShell como administrador** y ejecutar en cada máquina:

```powershell
New-NetFirewallRule -DisplayName "Asterisk SIP (UDP 5060)" `
  -Direction Inbound -Protocol UDP -LocalPort 5060 `
  -Action Allow -Profile Private

New-NetFirewallRule -DisplayName "Asterisk RTP (UDP 10000-10020)" `
  -Direction Inbound -Protocol UDP -LocalPort 10000-10020 `
  -Action Allow -Profile Private
```

Sobre `-Profile Private`: limita la regla a redes marcadas como privadas
(tu casa). Si la laptop está en una red marcada como pública, la regla no
aplicará. Comprobar y, si hace falta, cambiar el perfil de esa red:

```powershell
Get-NetConnectionProfile
Set-NetConnectionProfile -InterfaceAlias "Wi-Fi" -NetworkCategory Private
```

No uses `-Profile Any` en una red que no controles: expondría el 5060 a toda
la red, y un 5060 abierto con claves débiles es el vector clásico de fraude
telefónico (§7).

Verificar que las reglas quedaron y que Asterisk escucha:

```powershell
Get-NetFirewallRule -DisplayName "Asterisk*" | Format-Table DisplayName, Enabled, Direction
```

Desde la **otra** laptop, comprobar que el 5060 responde de verdad:

```powershell
Test-NetConnection -ComputerName 192.168.1.10 -Port 5060 -InformationLevel Detailed
```

`Test-NetConnection` prueba TCP, así que sobre UDP 5060 no es concluyente. La
prueba buena es registrar un softphone (§3) o mirar la señalización con
`pjsip set logger on` en la PBX destino.

Si borras las reglas después de las pruebas:

```powershell
Remove-NetFirewallRule -DisplayName "Asterisk SIP (UDP 5060)"
Remove-NetFirewallRule -DisplayName "Asterisk RTP (UDP 10000-10020)"
```

#### 2.4.2 Servidor Linux con Docker

En un servidor Linux dedicado el planteamiento cambia, y para mejor: Docker
corre directamente sobre el kernel del host, sin VM intermedia.

##### Opción recomendada: `network_mode: host`

En Linux (a diferencia de Docker Desktop) el modo host funciona de verdad, y
para una PBX es claramente la mejor opción:

```yaml
services:
  app:
    build:
      context: .
    container_name: novalink-voip-pbx
    network_mode: host          # sustituye por completo al bloque 'ports'
    volumes:
      - ./config/etc/asterisk:/etc/asterisk
    restart: unless-stopped
```

Con `network_mode: host` se elimina el bloque `ports:` entero (se ignora si se
deja). Lo que ganas:

| Ventaja | Por qué importa |
|---|---|
| Sin DNAT para el rango RTP | Publicar miles de puertos UDP en modo bridge es lento de arrancar y consume recursos. En host no se publica nada. |
| **La IP de origen se conserva** | `type=identify` funciona de verdad. Desaparece el problema descrito en el aviso de §2.5. |
| **El firewall del host vuelve a funcionar** | El tráfico llega a la cadena `INPUT`, que es donde `ufw` y `firewalld` sí mandan. Ver el aviso de abajo. |
| Rango RTP ampliable sin coste | Basta cambiar `rtp.conf`; no hay que replicarlo en `compose.yaml`. |

Contrapartida: se pierde el aislamiento de red del contenedor y Asterisk
compite por el 5060 con cualquier otro servicio SIP de la máquina. En un
servidor dedicado a la PBX no es un problema real.

> ### Aviso: Docker en modo bridge **se salta `ufw`**
>
> Si prefieres seguir publicando puertos con `ports:` en vez de usar
> `network_mode: host`, tienes que saber esto:
>
> Docker escribe sus propias reglas `DNAT` en iptables y las inserta **antes**
> de las de `ufw`. El resultado es que un puerto publicado con `ports:` queda
> **accesible desde internet aunque `ufw` lo tenga denegado**. `ufw status`
> dirá que está bloqueado y no será verdad.
>
> Comprobarlo:
>
> ```bash
> sudo iptables -t nat -L DOCKER -n --line-numbers
> sudo ufw status verbose
> ```
>
> Si ves una regla `DNAT ... udp dpt:5060` mientras `ufw` dice `deny`, estás en
> este caso. Tres formas de resolverlo, de mejor a peor:
>
> **1. Usar `network_mode: host`** (arriba). El tráfico pasa por `INPUT` y
> `ufw` recupera el control. Es la razón principal para preferirlo.
>
> **2. Filtrar en la cadena `DOCKER-USER`.** Docker garantiza que esa cadena se
> evalúa antes que sus propias reglas, así que es el punto correcto donde
> filtrar tráfico hacia contenedores:
>
> ```bash
> # Permitir SIP y RTP sólo desde la IP de la otra PBX o del proveedor
> sudo iptables -I DOCKER-USER -p udp --dport 5060 -s 203.0.113.10 -j RETURN
> sudo iptables -I DOCKER-USER -p udp --dport 10000:10020 -s 203.0.113.10 -j RETURN
> # Y descartar el resto que venga de fuera
> sudo iptables -A DOCKER-USER -i eth0 -p udp --dport 5060 -j DROP
> sudo iptables -A DOCKER-USER -i eth0 -p udp --dport 10000:10020 -j DROP
> ```
>
> Sustituye `eth0` por la interfaz real (`ip -br addr`) y `203.0.113.10` por
> la IP autorizada. El orden importa: los `RETURN` van insertados arriba con
> `-I`, los `DROP` añadidos al final con `-A`.
>
> **Estas reglas no sobreviven a un reinicio.** Para persistirlas:
>
> ```bash
> sudo apt install -y iptables-persistent
> sudo netfilter-persistent save
> ```
>
> **3. Publicar sólo en una IP concreta**, por ejemplo la de una VPN:
> `- "10.8.0.1:5060:5060/udp"`. Limita la exposición pero no sustituye a un
> firewall.

##### Reglas con `ufw` (Debian / Ubuntu)

Válidas tal cual **si usas `network_mode: host`**. Si usas `ports:`, lee antes
el aviso de arriba.

```bash
sudo ufw allow 5060/udp comment 'Asterisk SIP'
sudo ufw allow 10000:10020/udp comment 'Asterisk RTP'
sudo ufw reload
sudo ufw status numbered
```

Mejor todavía: **no abrir el 5060 a todo internet**. Si ya conoces la IP del
proveedor o de la otra sede, restringe el origen:

```bash
sudo ufw allow from 203.0.113.10 to any port 5060 proto udp comment 'Trunk proveedor'
sudo ufw allow from 203.0.113.10 to any port 10000:10020 proto udp comment 'RTP proveedor'
```

Para borrar una regla, localiza su número y elimínala:

```bash
sudo ufw status numbered
sudo ufw delete 3
```

No olvides dejar abierto el SSH antes de activar `ufw`, o te quedas fuera del
servidor:

```bash
sudo ufw allow OpenSSH
sudo ufw enable
```

##### Reglas con `firewalld` (RHEL / Rocky / Alma / Fedora)

```bash
sudo firewall-cmd --permanent --add-port=5060/udp
sudo firewall-cmd --permanent --add-port=10000-10020/udp
sudo firewall-cmd --reload
sudo firewall-cmd --list-all
```

Restringido a un origen concreto, con una *rich rule*:

```bash
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" \
  source address="203.0.113.10" port port="5060" protocol="udp" accept'
sudo firewall-cmd --reload
```

Existe además el servicio predefinido `sip`, que abre el 5060 en UDP y TCP:

```bash
sudo firewall-cmd --permanent --add-service=sip
```

Conviene evitarlo por ahora: abre también TCP 5060, que este proyecto no usa
(el transporte configurado es sólo UDP).

El mismo aviso sobre Docker aplica a `firewalld`: en modo bridge, Docker
gestiona sus propias cadenas y se salta las zonas. La solución sigue siendo
`network_mode: host` o filtrar en `DOCKER-USER`.

##### Grupos de seguridad del proveedor cloud

Si el servidor está en AWS, Azure, GCP, DigitalOcean, Hetzner o similar, hay
**una segunda capa de firewall fuera de la máquina** que Docker no puede
saltarse. Hay que abrir ahí también:

| Proveedor | Dónde |
|---|---|
| AWS | *Security Group* de la instancia EC2 → reglas de entrada |
| Azure | *Network Security Group* de la NIC o la subred |
| GCP | *VPC → Firewall rules* |
| DigitalOcean | *Networking → Firewalls* |
| Hetzner | *Firewalls* en el panel del proyecto |

En todos: **UDP 5060** y **UDP 10000-10020** (o el rango que definas en
`rtp.conf`), idealmente restringidos a las IPs de tus troncales.

Dos cosas que sorprenden a menudo:

- Muchos proveedores abren TCP por defecto y **dejan todo UDP cerrado**. SIP y
  RTP aquí son UDP; si sólo abres TCP no funciona nada.
- Algunos proveedores **bloquean el 5060 de entrada por defecto** para frenar
  el abuso de PBX comprometidas, y hay que pedir explícitamente que lo abran.

##### Ampliar el rango RTP en producción

El rango por defecto (`10000-10020`, 21 puertos) da para ~10 llamadas
simultáneas. Para un despliegue real conviene ampliarlo en `rtp.conf`:

```ini
[general]
rtpstart=10000
rtpend=20000
```

Con `network_mode: host` eso es todo: no hay que tocar `compose.yaml`. Luego
abre el rango nuevo en el firewall y, si lo hay, en el grupo de seguridad.

Si te quedas en modo bridge, tienes que replicar el rango en `compose.yaml`
además de en `rtp.conf`, y publicar 10.000 puertos UDP en Docker es lento de
arrancar y pesado. Es otra razón para usar `network_mode: host`.

##### Verificar que quedó bien

```bash
# Asterisk escuchando en el 5060 del host
sudo ss -ulnp | grep 5060

# Estado del contenedor y puertos publicados (vacío si usas network_mode: host)
make check

# Reglas activas
sudo ufw status verbose            # Debian/Ubuntu
sudo firewall-cmd --list-all       # RHEL/Rocky/Alma
sudo iptables -t nat -L DOCKER -n  # lo que Docker añadió por su cuenta

# Interfaces e IPs del servidor
ip -br addr
```

Desde otra máquina, comprobar que el puerto responde de verdad:

```bash
sudo nmap -sU -p 5060 IP_DEL_SERVIDOR
```

`open|filtered` en UDP es ambiguo. La prueba concluyente sigue siendo activar
`pjsip set logger on` en el servidor y registrar un softphone contra él.

##### Endurecer el servidor

Un 5060 accesible desde internet recibe intentos de registro automatizados en
cuestión de horas. Además de §7:

- **Restringe por IP** siempre que sea posible (`ufw allow from ...`). Si sólo
  hay dos sedes y un proveedor, no hay motivo para abrir a todo internet.
- **fail2ban** con el filtro `asterisk`. Requiere que los logs sean visibles
  desde el host, así que hay que añadir el volumen:
  ```yaml
      volumes:
        - ./config/etc/asterisk:/etc/asterisk
        - ./logs:/var/log/asterisk
  ```
  Y en `logger.conf`, habilitar el canal `security`, que es el que registra
  los intentos fallidos de autenticación.
- **Nunca dejes claves iguales al número de extensión** en un servidor
  expuesto. Ver §7.

### 2.5 Configurar el transporte para aceptar tráfico externo

Con los puertos abiertos falta que Asterisk **anuncie una dirección correcta**
en el SDP.

El transporte **no está en `pjsip.conf`**: vive en `pjsip_local.conf`, que no
se versiona precisamente porque sus valores cambian en cada máquina. Así el
resto de la configuración (extensiones, troncales, dialplan) es idéntica en
las laptops y en el servidor. En cada máquina, la primera vez:

```bash
cd config/etc/asterisk
cp pjsip_local.conf.example pjsip_local.conf
```

Y dentro, poner **su propia IP** de `ipconfig` (§2.1):

```ini
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_media_address=192.168.1.10        ; IP de ESTA máquina (§2.1)
external_signaling_address=192.168.1.10
local_net=192.168.1.0/24                   ; la LAN de esta máquina
```

Para el escenario de internet (§5), `external_*` van con la **IP pública**
(§2.2) y `local_net` se queda con la LAN:

```ini
external_media_address=200.44.x.x
external_signaling_address=200.44.x.x
local_net=192.168.1.0/24
```

**Esa combinación es la que permite atender a la vez llamadas de la propia LAN
y de otra red**, que es el requisito de producción:

| Destino | Qué anuncia Asterisk |
|---|---|
| Dentro de `local_net` (teléfono de la sede) | su dirección real privada |
| Fuera de `local_net` (otra sede, proveedor) | `external_*`, la pública |

Sin `local_net`, Asterisk trata **todo** como externo y le anuncia la IP
pública también a los teléfonos de la propia LAN. El audio sale al router para
volver a entrar (*hairpin*) y en muchos routers eso no funciona.

> **`local_net` exige `network_mode: host`.** En modo bridge la "dirección
> real" de Asterisk es la del contenedor (`172.17.0.x`), así que con
> `local_net` puesto anunciaría esa IP a los teléfonos de la LAN y se
> quedarían sin audio. En bridge: comenta `local_net` y deja sólo
> `external_*`. Es otra razón para preferir `host` (§2.4.2).

Por qué importa: Asterisk corre dentro de un contenedor y sólo se ve a sí
mismo como `172.17.0.x`. Si no le dices cuál es su dirección real, anunciará
la del contenedor en el SDP y el otro extremo mandará el audio a una IP que no
existe fuera de Docker. **Síntoma: la llamada timbra, se contesta, y no se oye
nada.**

Los endpoints ya traen los ajustes de NAT necesarios heredados de
`[endpoint-interno]` / `[endpoint-troncal]`:

| Opción | Problema que resuelve |
|---|---|
| `rtp_symmetric=yes` | El router del cliente cambia el puerto RTP anunciado; Asterisk responde al puerto realmente visto |
| `force_rport=yes` | Lo mismo para la señalización SIP |
| `rewrite_contact=yes` | El cliente anuncia una IP privada en su `Contact`; Asterisk la sustituye por la real |
| `direct_media=no` | Impide que dos teléfonos intenten mandarse RTP directo entre redes privadas |

Aplicar sin reconstruir la imagen (la config está montada como volumen):

```bash
make cli
```

```
pjsip reload
pjsip show transports
```

> ### Aviso: Docker Desktop puede romper la autenticación por IP
>
> Docker Desktop no corre sobre tu Windows directamente sino dentro de su
> propia VM, y el reenvío de puertos suele **reescribir la IP de origen** de
> los paquetes entrantes. Asterisk entonces ve todas las llamadas llegando
> desde la puerta de enlace de Docker (`172.17.0.1` o similar) en vez de desde
> la IP real de la otra laptop.
>
> Si eso pasa, un `type=identify` con `match=192.168.1.20` **nunca coincidirá**
> y las llamadas entrantes se rechazarán.
>
> Cómo comprobarlo, en la PBX que recibe:
>
> ```
> make cli
> pjsip set logger on
> ```
>
> Provoca una llamada o un registro desde la otra máquina y mira la línea
> `<--- Received SIP request ... from <IP> --->`. Si esa IP no es la de la otra
> laptop, estás en este caso.
>
> Tres salidas, de mejor a peor:
>
> 1. **Usar autenticación por usuario/clave** en lugar de por IP: variante B de
>    `trunk_sip` en `pjsip.conf` (`auth` + `aor-troncal-dinamica`). Funciona
>    sin depender de la IP de origen y es lo recomendable.
> 2. **Docker Engine nativo** en lugar de Docker Desktop: conserva la IP de
>    origen. Dentro de WSL hay que instalarlo y arrancarlo a mano; en un
>    servidor Linux es lo normal, y con `network_mode: host` (§2.4.2) el
>    problema no existe en absoluto.
> 3. **`match=` la IP de la gateway de Docker**: funciona en un laboratorio
>    cerrado, pero deja de ser un control de acceso real — aceptaría llamadas
>    de cualquier origen. No lo dejes así fuera de pruebas.

### 2.6 Lista de verificación antes de seguir

En **ambas** laptops:

- [ ] `ipconfig` da una IPv4 y la anotaste (§2.1)
- [ ] `ping` de una laptop a la otra responde (§2.1)
- [ ] `compose.yaml` sin el bind a `127.0.0.1` (§2.3)
- [ ] `make check` muestra `0.0.0.0:5060->5060/udp` (§2.3)
- [ ] Reglas de firewall UDP 5060 y 10000-10020 creadas (§2.4)
- [ ] Perfil de red en `Private` (§2.4)
- [ ] `pjsip_local.conf` creado desde el `.example`, con la IP real (§2.5)
- [ ] Claves de 1001/1002 cambiadas: ya no estás en loopback (§7)

Si el destino es un **servidor Linux** en vez de dos laptops (§2.4.2):

- [ ] `network_mode: host` en `compose.yaml`, sin bloque `ports:`
- [ ] `pjsip_local.conf` del servidor con la IP **pública** en `external_*`
      y la LAN de la sede en `local_net` (§2.5)
- [ ] `ufw` / `firewalld` con UDP 5060 y el rango RTP, restringidos por IP de origen
- [ ] `sudo ufw allow OpenSSH` antes de `ufw enable`
- [ ] Grupo de seguridad del proveedor cloud abierto en **UDP** (no sólo TCP)
- [ ] `sudo ss -ulnp | grep 5060` muestra Asterisk escuchando
- [ ] Si sigues en modo bridge: reglas en `DOCKER-USER` y persistidas con `netfilter-persistent`

---

## 3. Llamadas entre softphones en dos laptops distintas

Antes de montar troncales conviene validar la red con el caso simple: **una
sola PBX** y softphones registrados desde las dos máquinas. Si esto no
funciona, una troncal tampoco va a funcionar.

Aquí no hay dos PBX: la laptop A corre Asterisk, y la laptop B sólo corre
MicroSIP apuntando a la laptop A.

### 3.1 Misma LAN

Requisito: §2 completo en la laptop A (la que corre la PBX). En la laptop B
basta con el softphone; no necesita reglas de firewall de entrada porque es
ella la que inicia la conexión.

**En la PBX (laptop A)** no hace falta ningún cambio más allá del §2.5: los
endpoints 1001 y 1002 ya aceptan registros desde cualquier IP, porque su
autenticación es por usuario y clave, no por IP.

**Configuración de MicroSIP en la laptop B:**

| Campo | Valor |
|---|---|
| SIP Server / Domain | `192.168.1.10` (IP de la laptop A, §2.1) |
| Username | `1002` |
| Domain | `192.168.1.10` |
| Login | `1002` |
| Password | la que hayas puesto en `pjsip.conf` |
| Transport | UDP |

En la laptop A, MicroSIP se registra como `1001` contra `127.0.0.1` o contra
su propia IP de LAN — ambas funcionan.

**Verificar el registro**, desde `make cli` en la laptop A:

```
pjsip show endpoints
pjsip show contacts
```

`1002` debe aparecer con un contacto cuya IP sea la de la laptop B. Luego,
marcar `1001` desde `1002` y a la inversa.

Si registra pero no hay audio, es `external_media_address` (§2.5) o el rango
RTP cerrado en el firewall (§2.4).

### 3.2 Redes distintas

Mismo montaje, pero la laptop B llega desde internet. Cambia lo siguiente:

1. La PBX (laptop A) necesita ser alcanzable desde fuera. Si está detrás de un
   router doméstico, hay que hacer **port forwarding** en el router:
   `UDP 5060` y `UDP 10000-10020` hacia la IP de LAN de la laptop A
   (`192.168.1.10`). El menú suele llamarse *Port Forwarding*, *Virtual
   Server* o *NAT*.
2. `external_media_address` y `external_signaling_address` pasan a ser la
   **IP pública** (§2.2), con `local_net` para la red interna.
3. En MicroSIP (laptop B), el servidor pasa a ser la IP pública de la laptop A.
4. Si hay CGNAT (§2.2), el port forwarding no va a funcionar: monta una VPN
   (§5.1) y vuelve al caso §3.1.

**Antes de exponer el 5060 a internet, cambia las contraseñas.** Un 5060
público con claves iguales al número de extensión recibe intentos de registro
automatizados en cuestión de horas. Ver §7.

---

## 4. Escenario A — Dos PBX en la misma LAN

Ahora sí, cada laptop corre su propia instancia de Asterisk y se enlazan por
troncal. Requisito: §2 completo en **ambas**, y §3.1 funcionando.

Supongamos:

- PBX A (Caracas, extensiones 1XXX) → `192.168.1.10`
- PBX B (Maracaibo, extensiones 2XXX) → `192.168.1.20`

### 4.1 Troncal en la PBX A

Descomentar la **variante A** de la sección 5.2 de `pjsip.conf`:

```ini
[trunk_sip](endpoint-troncal)
context=entrantes_troncal_sip
aors=trunk_sip

[trunk_sip](aor-troncal-lan)
contact=sip:192.168.1.20:5060      ; IP de la PBX B

[trunk_sip]
type=identify
endpoint=trunk_sip
match=192.168.1.20                 ; acepto llamadas de la PBX B
```

### 4.2 Troncal en la PBX B

**Simétrico**, invirtiendo las IPs:

```ini
[trunk_sip](endpoint-troncal)
context=entrantes_troncal_sip
aors=trunk_sip

[trunk_sip](aor-troncal-lan)
contact=sip:192.168.1.10:5060      ; IP de la PBX A

[trunk_sip]
type=identify
endpoint=trunk_sip
match=192.168.1.10
```

> Si el aviso del §2.5 se cumple y Asterisk ve las llamadas llegando desde la
> gateway de Docker, usa la variante B (usuario/clave) en ambos lados en lugar
> de `identify`.

### 4.3 Enrutar el plan de numeración por la troncal

Hasta aquí la troncal existe pero nadie la usa: marcar `2001` desde la PBX A
sigue buscando la extensión localmente y falla.

En `extensions.conf` de la **PBX A**, dentro de `[llamadas_internas]`,
sustituir el patrón genérico `_[1-5]XXX` por rangos separados:

```ini
; 1XXX es local en esta sede
exten => _1XXX,1,NoOp(Interna local: ${EXTEN})
 same => n,Dial(PJSIP/${EXTEN},20)
 same => n,Hangup()

; 2XXX vive en la otra sede: sale por la troncal
exten => _2XXX,1,NoOp(Hacia sede Maracaibo: ${EXTEN})
 same => n,Dial(PJSIP/${EXTEN}@trunk_sip,20)
 same => n,Hangup()
```

En la **PBX B** es al revés: `2XXX` local, `1XXX` por troncal.

Aquí **no** se usa `${EXTEN:1}`: entre sedes se envía la extensión completa,
porque el otro extremo espera `2001`, no `001`. El `${EXTEN:1}` de
`[salientes_troncal_sip]` existe sólo para quitar el prefijo `8` de marcación
manual.

### 4.4 Aplicar y verificar

No hace falta reconstruir la imagen:

```bash
make cli
```

```
pjsip reload
dialplan reload
pjsip show endpoints          ; trunk_sip debe aparecer "Avail" / "Not in use"
pjsip show aors               ; confirma el contact hacia la otra IP
pjsip show identifies         ; confirma el match por IP
dialplan show llamadas_internas
```

Si `trunk_sip` aparece **Unavailable**, el `qualify` no recibe respuesta: es
red, no Asterisk. Repasa §2.3 (puertos aún en loopback), §2.4 (firewall) y la
IP del `contact`.

Prueba final: desde el softphone registrado en 1001, marcar `2001`.

---

## 5. Escenario B — Dos PBX en redes distintas

Cambia una cosa fundamental: al menos uno de los dos lados no tiene IP pública
fija alcanzable, así que la autenticación por IP deja de servir.

### 5.1 Elegir quién es "servidor"

El lado con IP pública fija hace de servidor; el otro se registra contra él.

Si **ninguno** tiene IP pública, o hay CGNAT (§2.2), hay dos salidas:

- **Port forwarding** en el router de uno de los dos (UDP 5060 y el rango RTP
  hacia la IP de LAN de esa máquina). No funciona bajo CGNAT.
- **VPN — la opción recomendada.** Con WireGuard o Tailscale ambas máquinas
  reciben una IP fija dentro de la VPN y vuelven a verse directamente. Eso
  convierte el problema en el §4, que es mucho más simple: no hace falta
  registro, ni port forwarding, ni preocuparse por NAT. Las IPs de la VPN
  (`100.x.x.x` en Tailscale, `10.x.x.x` en WireGuard) se usan tal cual en
  `contact=`, `match=` y `external_media_address`.

### 5.2 Lado servidor (IP pública fija)

Transporte con la IP pública y la red interna declarada:

```ini
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
external_media_address=200.44.x.x        ; IP PÚBLICA (§2.2)
external_signaling_address=200.44.x.x
local_net=192.168.1.0/24
```

Troncal — **variante B** de la sección 5.2 de `pjsip.conf`:

```ini
[trunk_sip](endpoint-troncal)
context=entrantes_troncal_sip
aors=trunk_sip
auth=trunk_sip-auth                  ; auth ENTRANTE: le pido credenciales

[trunk_sip](aor-troncal-dinamica)    ; sin contact: se aprende del REGISTER

[trunk_sip-auth]
type=auth
auth_type=userpass
username=sede2
password=UNA_CLAVE_LARGA_Y_ALEATORIA
```

### 5.3 Lado cliente (IP dinámica / detrás de NAT)

```ini
[trunk_sip](endpoint-troncal)
context=entrantes_troncal_sip
aors=trunk_sip
outbound_auth=trunk_sip-auth         ; auth SALIENTE: yo presento credenciales
from_user=sede2
from_domain=200.44.x.x

[trunk_sip](aor-troncal-externa)
contact=sip:200.44.x.x:5060

[trunk_sip-auth]
type=auth
auth_type=userpass
username=sede2
password=UNA_CLAVE_LARGA_Y_ALEATORIA

[trunk_sip-reg]
type=registration
transport=transport-udp
outbound_auth=trunk_sip-auth
server_uri=sip:200.44.x.x
client_uri=sip:sede2@200.44.x.x
retry_interval=60
```

Verificar el registro en el lado cliente:

```
pjsip show registrations      ; debe decir "Registered"
```

Y en el servidor, que el contacto se aprendió:

```
pjsip show aors
pjsip show contacts
```

El enrutamiento del dialplan (§4.3) es idéntico en este escenario.

---

## 6. Troncal hacia un proveedor SIP comercial

Es el §5 con el proveedor haciendo de servidor. Qué pedirle y dónde va cada
dato:

| Dato que entrega el proveedor | Dónde se pone |
|---|---|
| Host / dominio SIP | `contact=` del aor, `server_uri`, `from_domain` |
| Usuario SIP | `username` del auth, `from_user`, `client_uri` |
| Contraseña | `password` del auth |
| IP(s) desde las que envía llamadas | `match=` del identify |
| ¿Requiere registro? | Si sí, añadir el objeto `type=registration` |
| Codecs soportados | Ya cubierto por `[codec-troncal]` (ulaw, alaw) |
| Formato del número a marcar | Determina si hace falta manipular `${EXTEN:1}` |

Ese bloque ya está escrito y comentado como `trunk_redpublica` en la sección
5.1 de `pjsip.conf`, usando `[aor-troncal-externa]`.

---

## 7. Seguridad: no te dejes la puerta abierta

Cuatro reglas que evitan el fraude telefónico, el riesgo real de exponer una
PBX:

1. **El contexto de entrada de una troncal nunca incluye rutas de salida.**
   Por eso `[entrantes_redpublica]` y `[entrantes_troncal_sip]` no tienen
   ningún `include => salientes_*`. Si se añade, cualquiera que alcance tu
   troncal puede hacer llamadas internacionales a tu costa.
2. **Con autenticación por IP, el `identify` es el único control de acceso.**
   Un `match=` demasiado amplio (una red `/16`, o la gateway de Docker)
   equivale a no tener control.
3. **Cambia las contraseñas antes de salir de loopback.** Las extensiones de
   prueba usan `1001/1001` y `1002/1002`. Eso es tolerable mientras los
   puertos estén atados a `127.0.0.1`; es inaceptable en el momento en que
   apliques el §2.3. Usa claves largas y aleatorias:
   ```bash
   openssl rand -base64 24
   ```
4. **Limita el firewall a lo necesario.** `-Profile Private` en las reglas del
   §2.4, y port forwarding sólo mientras dure la prueba.

---

## 8. Diagnóstico rápido

| Síntoma | Causa más probable |
|---|---|
| `ping` entre laptops falla | Firewall de Windows, o aislamiento de clientes en el router WiFi (§2.1) |
| `make check` no muestra `0.0.0.0:5060` | `compose.yaml` sigue con el bind a `127.0.0.1` (§2.3) |
| El softphone no registra | Puerto cerrado (§2.3/§2.4), IP del servidor equivocada, o clave incorrecta |
| `Unavailable` en `pjsip show endpoints` | El `qualify` no recibe respuesta: firewall, IP equivocada, o puertos en loopback |
| Timbra y contesta pero **no hay audio** | `external_media_address` mal puesto (§2.5), o rango RTP cerrado en el firewall |
| Audio en **un solo sentido** | NAT: falta `rtp_symmetric` / `direct_media=no` en un extremo |
| `401 Unauthorized` repetido | Usuario o clave incorrectos en el `auth` |
| `403 Forbidden` en llamadas entrantes | Falta el `identify`, o el `match=` no corresponde a la IP real de origen — ver el aviso de Docker Desktop en §2.5 |
| `404 Not Found` desde el otro extremo | El dialplan del otro lado no tiene ruta para esa extensión (§4.3) |
| `488 Not Acceptable Here` | No hay codec en común: revisar `[codec-troncal]` contra lo que ofrece el otro lado |
| Fallan las llamadas a partir de la décima | El rango RTP sólo tiene 21 puertos, ~10 llamadas (§2.3 / §2.4.2) |
| `ufw status` dice `deny` pero el puerto responde desde fuera | Docker en modo bridge se salta `ufw`: filtrar en `DOCKER-USER` o usar `network_mode: host` (§2.4.2) |
| En cloud: registra desde la LAN pero no desde internet | Grupo de seguridad sin UDP abierto, o el proveedor bloquea el 5060 (§2.4.2) |

Ver la señalización en vivo, desde la consola de Asterisk:

```
pjsip set logger on
```

Para capturar el tráfico y abrirlo en Wireshark, ver el pendiente 4.8 de
[`CurrentState.md`](../CurrentState.md).
