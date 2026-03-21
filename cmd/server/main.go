package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/NielHeesakkers/SyncVault/internal/api/rest"
	"github.com/NielHeesakkers/SyncVault/internal/auth"
	"github.com/NielHeesakkers/SyncVault/internal/config"
	"github.com/NielHeesakkers/SyncVault/internal/email"
	"github.com/NielHeesakkers/SyncVault/internal/metadata"
	"github.com/NielHeesakkers/SyncVault/internal/storage"
)

func main() {
	// 1. Load config.
	cfg := config.Load()

	log.Printf("Starting SyncVault server")
	log.Printf("  Data directory:    %s", cfg.DataDir)
	log.Printf("  Storage directory: %s", cfg.StorageDir)
	log.Printf("  HTTP port:         %d", cfg.HTTPPort)
	log.Printf("  gRPC port:         %d", cfg.GRPCPort)
	log.Printf("  Max chunk size:    %d bytes", cfg.MaxChunkSize)

	// 2. Create data directories.
	for _, dir := range []string{cfg.DataDir, cfg.StorageDir} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			log.Fatalf("Failed to create directory %s: %v", dir, err)
		}
	}

	// 3. Open metadata DB.
	dbPath := filepath.Join(cfg.DataDir, "syncvault.db")
	db, err := metadata.Open(dbPath)
	if err != nil {
		log.Fatalf("Failed to open metadata DB: %v", err)
	}
	defer db.Close()

	// 4. Create storage Store.
	store, err := storage.NewStore(cfg.StorageDir, cfg.MaxChunkSize)
	if err != nil {
		log.Fatalf("Failed to create storage store: %v", err)
	}

	// 5. Setup JWT.
	jwtSecret := cfg.JWTSecret
	if jwtSecret == "" {
		log.Println("WARNING: JWT_SECRET is not set — using insecure default, do not use in production")
		jwtSecret = "insecure-default-secret-change-me"
	} else if jwtSecret == "change-me-in-production" {
		log.Println("WARNING: JWT_SECRET is set to the default value — change it in production")
	}
	jwtManager := auth.NewJWT(jwtSecret)

	// 6. Create default admin user if no users exist.
	users, err := db.ListUsers()
	if err != nil {
		log.Fatalf("Failed to list users: %v", err)
	}
	if len(users) == 0 {
		hashed, err := auth.HashPassword("admin")
		if err != nil {
			log.Fatalf("Failed to hash admin password: %v", err)
		}
		adminUser, err := db.CreateUser("admin", "admin@localhost", hashed, "admin")
		if err != nil {
			log.Fatalf("Failed to create default admin user: %v", err)
		}
		// Create admin's root folder.
		if _, err := db.CreateFile("", adminUser.ID, adminUser.Username, true, 0, "", ""); err != nil {
			log.Printf("WARNING: could not create admin root folder: %v", err)
		}
		log.Println("WARNING: Created default admin user (username: admin, password: admin) — change this immediately")
	}

	// 7. Create email service from env-var config, then apply any DB overrides.
	emailSvc := email.NewService(
		cfg.SMTPHost,
		cfg.SMTPPort,
		cfg.SMTPUser,
		cfg.SMTPPassword,
		cfg.SMTPFrom,
		cfg.SMTPEnabled,
	)

	// Load SMTP settings stored in the DB (admin UI overrides env vars).
	if smtpSettings, err := db.GetSettingsWithPrefix("smtp."); err == nil && len(smtpSettings) > 0 {
		emailSvc.UpdateFromSettings(smtpSettings)
		log.Printf("  SMTP settings:  loaded from database (overriding env vars)")
	}

	if emailSvc.Enabled() {
		log.Printf("  SMTP enabled:   true")
	} else {
		log.Printf("  SMTP enabled:   false (email notifications disabled)")
	}

	// 8. Create REST server.
	srv := rest.NewServer(db, store, jwtManager, emailSvc)

	addr := fmt.Sprintf(":%d", cfg.HTTPPort)
	httpServer := &http.Server{
		Addr:    addr,
		Handler: srv.Router(),
	}

	// 8. Start HTTP server (with optional TLS).
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("Failed to listen on %s: %v", addr, err)
	}

	// 9. Graceful shutdown on SIGINT/SIGTERM.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		if cfg.TLSCertFile != "" && cfg.TLSKeyFile != "" {
			log.Printf("SyncVault listening on %s (TLS)", addr)
			if err := httpServer.ServeTLS(ln, cfg.TLSCertFile, cfg.TLSKeyFile); err != nil && err != http.ErrServerClosed {
				log.Fatalf("HTTPS server error: %v", err)
			}
		} else {
			log.Printf("SyncVault listening on %s", addr)
			if err := httpServer.Serve(ln); err != nil && err != http.ErrServerClosed {
				log.Fatalf("HTTP server error: %v", err)
			}
		}
	}()

	<-ctx.Done()
	log.Println("Shutting down gracefully...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		log.Printf("HTTP server shutdown error: %v", err)
	}

	log.Println("SyncVault stopped.")
}
