package config

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Defaults for the listen address and the data directory.
const (
	DefaultPort    = 8354
	DefaultAddr    = ":8354"
	DefaultDataDir = "./data"
)

// Journal modes the store accepts. WAL is the default and the only one that is
// safe on a local disk; a data directory on a network share (SMB/NAS) needs a
// rollback journal instead, because WAL keeps its index in a shared-memory
// "-shm" mapping that network filesystems do not arbitrate between hosts.
const (
	JournalWAL      = "WAL"
	JournalDelete   = "DELETE"
	JournalTruncate = "TRUNCATE"
)

// Config holds server runtime configuration assembled from the flags and the
// environment.
type Config struct {
	DataDir string
	Addr    string
	Token   string
	Journal string
}

// Load assembles the runtime configuration, most specific first: the -data /
// -port / -journal flags, then HONGNI_DATA_DIR / HONGNI_ADDR / HONGNI_TOKEN,
// then the defaults (./data, :8354, WAL). If no token is provided it is read
// from <DataDir>/config.json, and if still absent a fresh 32-byte hex token is
// generated, persisted to config.json, and printed to stdout exactly once.
func Load(args []string) (Config, error) {
	envAddr := envOr("HONGNI_ADDR", DefaultAddr)

	fs := flag.NewFlagSet("hongni", flag.ContinueOnError)
	dataDir := fs.String("data", envOr("HONGNI_DATA_DIR", DefaultDataDir), "数据目录：hongni.db / blobs / thumbs 的存放处")
	port := fs.Int("port", addrPort(envAddr), "监听端口")
	journal := fs.String("journal", JournalWAL, "SQLite journal 模式：WAL（本地盘）/ DELETE / TRUNCATE（网络盘）")
	if err := fs.Parse(args); err != nil {
		return Config{}, err
	}

	j, err := normalizeJournal(*journal)
	if err != nil {
		return Config{}, err
	}

	cfg := Config{
		DataDir: *dataDir,
		Addr:    addrWithPort(envAddr, *port),
		Token:   os.Getenv("HONGNI_TOKEN"),
		Journal: j,
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

// addrPort is the port of a host:port listen address, or DefaultPort when the
// address carries none.
func addrPort(addr string) int {
	if _, p, err := net.SplitHostPort(addr); err == nil {
		if n, err := strconv.Atoi(p); err == nil {
			return n
		}
	}
	return DefaultPort
}

// addrWithPort keeps the host HONGNI_ADDR asked for and puts port on it:
// "192.168.1.5:8354" with -port 9000 listens on 192.168.1.5:9000, and the
// default (empty host) binds every interface.
func addrWithPort(addr string, port int) string {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = ""
	}
	return net.JoinHostPort(host, strconv.Itoa(port))
}

// normalizeJournal maps a -journal argument onto one of the accepted modes.
func normalizeJournal(s string) (string, error) {
	switch strings.ToUpper(strings.TrimSpace(s)) {
	case JournalWAL:
		return JournalWAL, nil
	case JournalDelete:
		return JournalDelete, nil
	case JournalTruncate:
		return JournalTruncate, nil
	}
	return "", fmt.Errorf("journal 模式 %q 不支持（WAL / DELETE / TRUNCATE）", s)
}

// OnNetworkShare reports whether dir names a network share rather than a local
// directory. Only UNC paths (`\\nas\photos`) are recognized — a mapped drive
// letter looks local from here, so the -journal choice stays the operator's.
func OnNetworkShare(dir string) bool {
	if strings.HasPrefix(dir, `\\?\`) || strings.HasPrefix(dir, `\\.\`) {
		return false // extended-length local path, not a share
	}
	return strings.HasPrefix(dir, `\\`) || strings.HasPrefix(dir, "//")
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
