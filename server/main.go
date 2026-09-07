package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/deminzhang/hongni/server/internal/api"
	"github.com/deminzhang/hongni/server/internal/blob"
	"github.com/deminzhang/hongni/server/internal/config"
	"github.com/deminzhang/hongni/server/internal/store"
	"github.com/grandcat/zeroconf"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	st, err := store.Open(filepath.Join(cfg.DataDir, "hongni.db"))
	if err != nil {
		log.Fatalf("store: %v", err)
	}
	defer st.Close()
	bl := blob.New(cfg.DataDir)
	handler := api.New(st, bl, cfg)

	srv := &http.Server{
		Addr:    cfg.Addr,
		Handler: handler,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Advertise the service over mDNS (_hongni._tcp) for LAN discovery.
	zc, err := registerZeroconf(cfg.Addr)
	if err != nil {
		log.Printf("zeroconf: %v", err)
	} else {
		defer zc.Shutdown()
		log.Printf("mDNS registered as _hongni._tcp")
	}

	go func() {
		log.Printf("listening on %s", cfg.Addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown error: %v", err)
	}
}

func registerZeroconf(addr string) (*zeroconf.Server, error) {
	port := 8354
	if _, p, err := net.SplitHostPort(addr); err == nil {
		if n, err := strconv.Atoi(p); err == nil {
			port = n
		}
	}
	host, _ := os.Hostname()
	return zeroconf.Register(
		"hongni-"+host,
		"_hongni._tcp",
		"local.",
		port,
		[]string{"txtv=0", "version=1"},
		nil,
	)
}
