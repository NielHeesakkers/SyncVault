.PHONY: build run test clean docker docker-run

build:
	go build ./cmd/server/

run:
	go run ./cmd/server/

test:
	go test ./... -v -count=1

clean:
	go clean
	rm -f server

docker:
	docker build -t syncvault .

docker-run:
	docker compose up
