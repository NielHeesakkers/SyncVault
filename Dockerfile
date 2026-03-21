FROM golang:1.22-alpine AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o syncvault ./cmd/server

FROM alpine:3.19
RUN apk add --no-cache ca-certificates tzdata
RUN adduser -D -u 1000 syncvault
COPY --from=builder /build/syncvault /usr/local/bin/syncvault
USER syncvault
VOLUME /data
EXPOSE 8080 6690
ENV SYNCVAULT_DATA_DIR=/data
ENTRYPOINT ["syncvault"]
