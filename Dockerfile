# Stage 1: Build frontend
FROM node:22-alpine AS frontend
WORKDIR /web
COPY web/package.json web/package-lock.json* ./
RUN npm install
COPY web/ .
RUN npm run build

# Stage 2: Build Go binary
FROM golang:1.26-alpine AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Copy frontend build into Go embed location
COPY --from=frontend /web/build ./internal/api/rest/dist/
RUN CGO_ENABLED=0 go build -o syncvault ./cmd/server

# Stage 3: Runtime
FROM alpine:3.19
RUN apk add --no-cache ca-certificates tzdata
RUN adduser -D -u 1000 syncvault
COPY --from=builder /build/syncvault /usr/local/bin/syncvault
USER syncvault
VOLUME /data
EXPOSE 8080 6690
ENV SYNCVAULT_DATA_DIR=/data
ENTRYPOINT ["syncvault"]
