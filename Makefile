build:
	docker compose build
up:
	docker compose up -d
	@$(MAKE) --no-print-directory logdirs

# Asterisk NO crea estos directorios y el CDR falla con "No such file or
# directory". El bind mount de logs tapa los que traia la imagen, asi que hay
# que recrearlos en cada arranque.
logdirs:
	@docker exec novalink-voip-pbx mkdir -p \
	  /var/log/asterisk/cdr-csv /var/log/asterisk/cdr-custom
cli:
	docker exec -it novalink-voip-pbx asterisk -rvvv
down:
	docker compose down
check:
	docker compose ps
logs:
	docker compose logs -f
rebuild:
	docker compose down && docker compose build --no-cache && docker compose up -d
	@$(MAKE) --no-print-directory logdirs
# --- Diagnostico de red / troncal -------------------------------------------
# Comprueba que Asterisk escucha SIP y RTP en la pila de red del host.
net:
	@echo "--- Puertos UDP en escucha (esperado: 5060 y rango RTP) ---"
	@ss -lunp | grep -E 'asterisk|Local' || echo "Asterisk no escucha: contenedor caido?"
	@echo "--- IP de esta PBX segun la LAN (debe ser 192.168.0.9) ---"
	@ip -4 -o addr show | awk '{print $$2, $$4}'

# Estado de la troncal hacia la otra sede (192.168.0.10).
trunk:
	@docker exec novalink-voip-pbx asterisk -rx "pjsip show endpoint trunk_sip"
	@docker exec novalink-voip-pbx asterisk -rx "pjsip show identifies"
	@docker exec novalink-voip-pbx asterisk -rx "pjsip show aors"

# Traza SIP en vivo: dejar corriendo mientras la otra sede llama.
trace:
	@docker exec novalink-voip-pbx asterisk -rx "pjsip set logger on"
	@docker compose logs -f
