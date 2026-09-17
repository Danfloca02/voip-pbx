build:
	docker compose build
up:
	docker compose up -d
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