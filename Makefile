IMAGE := ghcr.io/nielheesakkers/syncvault:latest

.PHONY: build run test clean docker push deploy frontend macos

build:
	go build ./cmd/server/

run:
	go run ./cmd/server/

test:
	go test ./... -v -count=1

clean:
	go clean
	rm -f server

# Build frontend, embed in Go, build Docker image, push to registry
push: frontend docker
	docker push $(IMAGE)
	@echo "Pushed $(IMAGE) — redeploy in Portainer"

# Build frontend and copy to embed location
frontend:
	cd web && npm run build && cp -r build ../internal/api/rest/dist/

# Build Docker image
docker:
	docker build -t $(IMAGE) .

# Build + push + done
deploy: push

# Build macOS app
macos:
	cd macos && swift build -c release
	@echo "Binary at macos/.build/release/SyncVault"
