.PHONY: build run test clean

build:
	go build ./cmd/server/

run:
	go run ./cmd/server/

test:
	go test ./... -v -count=1

clean:
	go clean
	rm -f server
