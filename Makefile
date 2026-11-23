# Load environment variables from .env
ifneq (,$(wildcard ./.env))
include .env
export
endif

# Override on the command line, e.g. make migrate-up DB=wallet
DB ?= paygrid

# Connection pieces (override via .env or command line if needed)
DB_USER     ?= user
DB_PASSWORD ?= password
DB_HOST     ?= localhost
DB_PORT     ?= 5432

# Built from the pieces above
DATABASE_URL ?= postgresql://$(DB_USER):$(DB_PASSWORD)@$(DB_HOST):$(DB_PORT)/$(DB)?sslmode=disable
MIGRATIONS_PATH ?= ./db/$(DB)/migrations

.PHONY: migrate-up migrate-down migrate-down-n migrate-force migrate-version migrate-create generate-test test

## Apply all pending migrations (usage: make migrate-up DB=wallet)
migrate-up:
	migrate -path $(MIGRATIONS_PATH) -database "$(DATABASE_URL)" up

## Rollback all migrations (usage: make migrate-down DB=auth)
migrate-down:
	migrate -path $(MIGRATIONS_PATH) -database "$(DATABASE_URL)" down

## Rollback N migrations (usage: make migrate-down-n DB=wallet N=1)
migrate-down-n:
	@test -n "$(N)" || (echo "usage: make migrate-down-n DB=db_name N=1" && exit `1)
	migrate -path $(MIGRATIONS_PATH) -database "$(DATABASE_URL)" down $(N)

## Force set migration version (usage: make migrate-force DB=transfer VERSION=1)
migrate-force:
	@test -n "$(VERSION)" || (echo "usage: make migrate-force DB=db_name VERSION=1" && exit 1)
	migrate -path $(MIGRATIONS_PATH) -database "$(DATABASE_URL)" force $(VERSION)

## Show current migration version (usage: make migrate-version DB=wallet)
migrate-version:
	migrate -path $(MIGRATIONS_PATH) -database "$(DATABASE_URL)" version

## Create a new migration (usage: make migrate-create DB=wallet NAME=init_ledger)
migrate-create:
	@test -n "$(NAME)" || (echo "usage: make migrate-create DB=db_name NAME=add_something" && exit 1)
	migrate create -ext sql -dir $(MIGRATIONS_PATH) -seq $(NAME)


generate-test:
	@sqlc generate

WALLET_TEST_DATABASE_URL ?= postgresql://$(DB_USER):$(DB_PASSWORD)@$(DB_HOST):$(DB_PORT)/wallet?sslmode=disable

test:
	WALLET_TEST_DATABASE_URL="$(WALLET_TEST_DATABASE_URL)" go test -count=1 $(TESTFLAGS) ./...
