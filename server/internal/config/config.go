package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
)

// Config holds server runtime configuration assembled from the environment.
type Config struct {
	DataDir string
	Addr    string
	Token   string
}

// Load reads HONGNI_DATA_DIR / HONGNI_ADDR / HONGNI_TOKEN from the
// environment, falling back to defaults. If no token is provided it is read
// from <DataDir>/config.json, and if still absent a fresh 32-byte hex token is
// generated, persisted to config.json, and printed to stdout exactly once.
func Load() (Config, error) {
	cfg := Config{
		DataDir: envOr("HONGNI_DATA_DIR", "./data"),
		Addr:    envOr("HONGNI_ADDR", ":8354"),
		Token:   os.Getenv("HONGNI_TOKEN"),
	}

	for _, d := range []string{"", "blobs", "thumbs"} {
		if err := os.MkdirAll(filepath.Join(cfg.DataDir, d), 0o755); err != nil {
			return cfg, err
		}
	}

	if cfg.Token == "" {
		if b, err := os.ReadFile(filepath.Join(cfg.DataDir, "config.json")); err == nil {
			var m map[string]string
			if json.Unmarshal(b, &m) == nil {
				cfg.Token = m["token"]
			}
		}
	}

	if cfg.Token == "" {
		tok, err := newToken()
		if err != nil {
			return cfg, err
		}
		cfg.Token = tok
		b, _ := json.MarshalIndent(map[string]string{"token": tok}, "", "  ")
		if err := os.WriteFile(filepath.Join(cfg.DataDir, "config.json"), b, 0o600); err != nil {
			return cfg, err
		}
		// Print once, only when a fresh token is generated.
		os.Stdout.WriteString("HONGNI_TOKEN=" + tok + "\n")
	}

	return cfg, nil
}

func newToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
