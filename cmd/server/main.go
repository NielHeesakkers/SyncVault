package main

import (
	"fmt"
	"log"

	"github.com/NielHeesakkers/SyncVault/internal/config"
)

func main() {
	cfg := config.Load()

	log.Printf("Starting SyncVault server")
	log.Printf("  Data directory: %s", cfg.DataDir)
	log.Printf("  HTTP port:      %d", cfg.HTTPPort)
	log.Printf("  gRPC port:      %d", cfg.GRPCPort)
	log.Printf("  Max chunk size: %d bytes", cfg.MaxChunkSize)

	if cfg.JWTSecret == "" {
		log.Println("  WARNING: JWT_SECRET is not set — authentication will not work securely")
	}

	fmt.Println("SyncVault ready.")
}
