# Build Go binary (frontend dist is already committed in internal/api/rest/dist/)
FROM golang:1.26-alpine AS builder
ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown
WORKDIR /build
RUN apk add --no-cache git
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# Fall back to reading git from the working tree if no build-arg was passed.
RUN if [ "$GIT_SHA" = "unknown" ] && [ -d .git ]; then GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo unknown); fi && \
    if [ "$BUILD_TIME" = "unknown" ]; then BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ); fi && \
    echo "Building with sha=$GIT_SHA time=$BUILD_TIME" && \
    CGO_ENABLED=0 go build \
      -ldflags "-X main.gitSHA=$GIT_SHA -X main.buildTime=$BUILD_TIME" \
      -o syncvault ./cmd/server

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
