//go:build !generate

package main

// 零配置启动模式（TUIC + mTLS + 自动证书）。
//
// 用法：
//	sing-box                       首次: 交互询问域名/端口; 非首次: 复用已有配置
//	sing-box <domain> <port>       有参: 写入(首次创建 / 非首次覆盖)并启动
//
// 状态文件（含域名/端口/uuid/password）与客户端 CA 放在同一个 base 目录：
//
//	root  -> /etc/sing-box
//	普通用户 -> ~/.config/sing-box
//
// 覆盖时**保留 uuid 与客户端 CA**，只改域名/端口——否则已分发的客户端证书全部失效。

import (
	"bufio"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"
)

const (
	quickStateFile   = "quick-state.json"
	quickConfigFile  = "config.json"
	quickCACertFile  = "client-ca.pem"
	quickCAKeyFile   = "client-ca.key"
	quickCertFile    = "client.pem"
	quickClientKey   = "client.key"
	quickACMESubdir  = "acme"
	quickCertYears   = 10
	quickDefaultPort = 443
)

type quickState struct {
	Domain   string `json:"domain"`
	Port     int    `json:"port"`
	UUID     string `json:"uuid"`
	Password string `json:"password"`
}

func quickBaseDir() (string, error) {
	if os.Geteuid() == 0 {
		return "/etc/sing-box", nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("cannot resolve home directory: %w", err)
	}
	return filepath.Join(home, ".config", "sing-box"), nil
}

// runQuickStart 是 root 命令的 RunE：无子命令、至多两个位置参数时进入零配置模式。
func runQuickStart(cmd *cobra.Command, args []string) error {
	if len(args) > 2 {
		return fmt.Errorf("usage: sing-box [domain] [port]")
	}

	base, err := quickBaseDir()
	if err != nil {
		return err
	}
	statePath := filepath.Join(base, quickStateFile)
	cfgPath := filepath.Join(base, quickConfigFile)

	existing, loadErr := loadQuickState(statePath)
	firstRun := errors.Is(loadErr, os.ErrNotExist)

	var st quickState
	switch {
	case len(args) == 2:
		// 有参：首次创建，非首次覆盖（保留 uuid / CA）
		st.Domain = strings.TrimSpace(args[0])
		port, perr := parseQuickPort(args[1])
		if perr != nil {
			return perr
		}
		st.Port = port
		if firstRun {
			st.UUID, st.Password = quickRandomUUID(), quickRandomUUID()
		} else {
			st.UUID, st.Password = existing.UUID, existing.Password
		}
	case len(args) == 0 && !firstRun:
		// 非首次无参：复用
		st = existing
	case len(args) == 0 && firstRun:
		// 首次无参：交互询问
		if !quickIsInteractive() {
			return fmt.Errorf("no configuration found and stdin is not a terminal; run: sing-box <domain> <port>")
		}
		st.Domain = strings.TrimSpace(quickPrompt("Domain: "))
		port, perr := parseQuickPort(quickPrompt(fmt.Sprintf("Port [%d]: ", quickDefaultPort)))
		if perr != nil {
			return perr
		}
		st.Port = port
		st.UUID, st.Password = quickRandomUUID(), quickRandomUUID()
	default:
		return fmt.Errorf("usage: sing-box [domain] [port]")
	}

	if err := validateQuickDomain(st.Domain); err != nil {
		return err
	}

	if err := os.MkdirAll(base, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", base, err)
	}
	acmeDir := filepath.Join(base, quickACMESubdir)
	if err := os.MkdirAll(acmeDir, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", acmeDir, err)
	}

	caCertPath := filepath.Join(base, quickCACertFile)
	caKeyPath := filepath.Join(base, quickCAKeyFile)
	clientCertPath := filepath.Join(base, quickCertFile)
	clientKeyPath := filepath.Join(base, quickClientKey)

	// 首次：生成客户端 CA + 第一张客户端证书；非首次：原样保留。
	if firstRun {
		if err := quickGenerateCA(caCertPath, caKeyPath); err != nil {
			return err
		}
		if err := quickIssueClientCert(caCertPath, caKeyPath, clientCertPath, clientKeyPath, "first-client"); err != nil {
			return err
		}
	} else {
		for _, p := range []string{caCertPath, caKeyPath} {
			if _, statErr := os.Stat(p); statErr != nil {
				return fmt.Errorf("existing state found but %s is missing: %w", p, statErr)
			}
		}
	}

	cfg := quickBuildConfig(st, acmeDir, caCertPath)
	raw, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}
	raw = append(raw, '\n')
	if err := os.WriteFile(cfgPath, raw, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", cfgPath, err)
	}
	if err := saveQuickState(statePath, st); err != nil {
		return err
	}

	quickPrintSummary(firstRun, len(args) == 2 && !firstRun, base, cfgPath, statePath, clientCertPath, clientKeyPath, caCertPath, st)

	// systemd 子进程（ExecStart 拉起）：直接跑服务本体。
	if quickIsSystemdChild() {
		configPaths = []string{cfgPath}
		return run()
	}

	// 手动执行：确保 systemd 服务已安装并已启动，之后由服务接管，当前进程退出。
	if os.Geteuid() != 0 {
		return fmt.Errorf("installing the systemd service requires root; re-run with sudo")
	}
	if err := quickEnsureService(cfgPath); err != nil {
		return err
	}
	fmt.Fprintf(os.Stdout, "\nsystemd service '%s' installed and started (auto-start on boot).\n", quickServiceName)
	fmt.Fprintf(os.Stdout, "  status : systemctl status %s\n", quickServiceName)
	fmt.Fprintf(os.Stdout, "  logs   : journalctl -u %s -f\n", quickServiceName)
	fmt.Fprintf(os.Stdout, "  stop   : systemctl stop %s\n\n", quickServiceName)
	return nil
}

func parseQuickPort(raw string) (int, error) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return quickDefaultPort, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		return 0, fmt.Errorf("bad port %q: %w", raw, err)
	}
	if n < 1 || n > 65535 {
		return 0, fmt.Errorf("bad port %d: must be 1-65535", n)
	}
	return n, nil
}

func validateQuickDomain(d string) error {
	if d == "" {
		return fmt.Errorf("domain is required")
	}
	if strings.ContainsAny(d, " /:\\") {
		return fmt.Errorf("bad domain %q", d)
	}
	if !strings.Contains(d, ".") {
		return fmt.Errorf("bad domain %q: must contain a dot", d)
	}
	return nil
}

func quickIsInteractive() bool {
	fi, err := os.Stdin.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

func quickPrompt(label string) string {
	fmt.Fprint(os.Stdout, label)
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Scan()
	return scanner.Text()
}

func quickRandomUUID() string {
	// 32 hex chars，与 sing-box 的 uuid 字段兼容（也接受带连字符的 UUIDv4）。
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		// 这里失败意味着系统熵源不可用，无法继续。
		fmt.Fprintf(os.Stderr, "FATAL: cannot read random bytes: %v\n", err)
		os.Exit(1)
	}
	return hex.EncodeToString(b)
}

func loadQuickState(path string) (quickState, error) {
	var st quickState
	raw, err := os.ReadFile(path)
	if err != nil {
		return st, err
	}
	if err := json.Unmarshal(raw, &st); err != nil {
		return st, fmt.Errorf("parse %s: %w", path, err)
	}
	return st, nil
}

func saveQuickState(path string, st quickState) error {
	raw, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal state: %w", err)
	}
	raw = append(raw, '\n')
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

// quickBuildConfig 生成 TUIC + mTLS + ACME 的完整配置。
func quickBuildConfig(st quickState, acmeDir, caPath string) map[string]any {
	return map[string]any{
		"log": map[string]any{
			"level":     "info",
			"timestamp": true,
		},
		"inbounds": []any{
			map[string]any{
				"type":               "tuic",
				"tag":                "tuic-in",
				"listen":             "::",
				"listen_port":        st.Port,
				"users":              []any{map[string]any{"uuid": st.UUID, "password": st.Password}},
				"congestion_control": "bbr",
				"tls": map[string]any{
					"enabled":     true,
					"server_name": st.Domain,
					"alpn":        []any{"h3"},
					"acme": map[string]any{
						"domain":          []any{st.Domain},
						"data_directory":  acmeDir,
						"default_server_name": st.Domain,
						// ACME 未填 email 时 certmagic 会交互询问并阻塞启动；
						// 零配置模式用域名派生一个占位地址（LE 只用于到期通知，不发验证信）。
						"email": "admin@" + st.Domain,
						// 环境不可控：80 端口可能被封、443/TCP 可能被占，都不是本程序能修复的。
						// ACME 客户端同时登记 HTTP-01 与 TLS-ALPN-01，由 Let's Encrypt
						// 依据服务端实际可达性选择——这是 RFC 8555 的标准多挑战协商，不是失败降级。
						"disable_http_challenge":     false,
						"disable_tls_alpn_challenge": false,
					},
					"client_authentication": "require-and-verify",
					"client_certificate_path": caPath,
				},
			},
		},
		"outbounds": []any{
			map[string]any{"type": "direct", "tag": "direct"},
		},
	}
}

// quickGenerateCA 生成自签客户端 CA（ECDSA P-256，10 年）。
func quickGenerateCA(certPath, keyPath string) error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generate CA key: %w", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return fmt.Errorf("generate CA serial: %w", err)
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: "sing-box quick client CA"},
		NotBefore:             now.Add(-time.Hour),
		NotAfter:              now.AddDate(quickCertYears, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		IsCA:                  true,
		MaxPathLen:            0,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return fmt.Errorf("create CA cert: %w", err)
	}
	if err := writePEM(certPath, "CERTIFICATE", der, 0o644); err != nil {
		return err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return fmt.Errorf("marshal CA key: %w", err)
	}
	return writePEM(keyPath, "EC PRIVATE KEY", keyDER, 0o600)
}

// quickIssueClientCert 用 CA 签一张客户端证书（ClientAuth 用途）。
func quickIssueClientCert(caCertPath, caKeyPath, certPath, keyPath, commonName string) error {
	caRaw, err := os.ReadFile(caCertPath)
	if err != nil {
		return fmt.Errorf("read CA cert: %w", err)
	}
	caBlock, _ := pem.Decode(caRaw)
	if caBlock == nil {
		return fmt.Errorf("decode CA cert %s: no PEM block", caCertPath)
	}
	caCert, err := x509.ParseCertificate(caBlock.Bytes)
	if err != nil {
		return fmt.Errorf("parse CA cert: %w", err)
	}
	caKeyRaw, err := os.ReadFile(caKeyPath)
	if err != nil {
		return fmt.Errorf("read CA key: %w", err)
	}
	caKeyBlock, _ := pem.Decode(caKeyRaw)
	if caKeyBlock == nil {
		return fmt.Errorf("decode CA key %s: no PEM block", caKeyPath)
	}
	caKey, err := x509.ParseECPrivateKey(caKeyBlock.Bytes)
	if err != nil {
		return fmt.Errorf("parse CA key: %w", err)
	}

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return fmt.Errorf("generate client key: %w", err)
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return fmt.Errorf("generate client serial: %w", err)
	}
	now := time.Now()
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: commonName},
		NotBefore:    now.Add(-time.Hour),
		NotAfter:     now.AddDate(quickCertYears, 0, 0),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, caCert, &key.PublicKey, caKey)
	if err != nil {
		return fmt.Errorf("create client cert: %w", err)
	}
	if err := writePEM(certPath, "CERTIFICATE", der, 0o644); err != nil {
		return err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return fmt.Errorf("marshal client key: %w", err)
	}
	return writePEM(keyPath, "EC PRIVATE KEY", keyDER, 0o600)
}

func writePEM(path, blockType string, der []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		return fmt.Errorf("create %s: %w", path, err)
	}
	defer f.Close()
	if err := pem.Encode(f, &pem.Block{Type: blockType, Bytes: der}); err != nil {
		return fmt.Errorf("write %s: %w", path, err)
	}
	return nil
}

const (
	quickServiceName = "sing-box-quick"
	quickServicePath = "/etc/systemd/system/sing-box-quick.service"
)

// quickIsSystemdChild 判断当前进程是否由 systemd 拉起（systemd 注入 INVOCATION_ID）。
func quickIsSystemdChild() bool {
	return os.Getenv("INVOCATION_ID") != ""
}

// quickEnsureService 安装并启用 systemd 服务（幂等）。
//
// 环境适配而非降级：手动执行时把生命周期交给 systemd（开机自启/崩溃重启由它负责）；
// 由 systemd 拉起时直接跑服务本体。两条通道各自完整，不存在“失败回退”。
func quickEnsureService(cfgPath string) error {
	exe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("resolve executable path: %w", err)
	}
	unit := fmt.Sprintf(`[Unit]
Description=sing-box quick mode (TUIC + mTLS + ACME)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%s run -c %s
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
`, exe, cfgPath)

	if current, readErr := os.ReadFile(quickServicePath); readErr != nil || string(current) != unit {
		if writeErr := os.WriteFile(quickServicePath, []byte(unit), 0o644); writeErr != nil {
			return fmt.Errorf("write %s: %w", quickServicePath, writeErr)
		}
	}
	if out, err := exec.Command("systemctl", "daemon-reload").CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl daemon-reload: %w: %s", err, strings.TrimSpace(string(out)))
	}
	if out, err := exec.Command("systemctl", "enable", quickServiceName).CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl enable %s: %w: %s", quickServiceName, err, strings.TrimSpace(string(out)))
	}
	if out, err := exec.Command("systemctl", "start", quickServiceName).CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl start %s: %w: %s", quickServiceName, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func quickPrintSummary(firstRun, overwritten bool, base, cfgPath, statePath, certPath, keyPath, caPath string, st quickState) {
	fmt.Fprintf(os.Stdout, "\n=== sing-box quick start ===\n")
	switch {
	case firstRun:
		fmt.Fprintf(os.Stdout, "first run: generated config + client CA + first client certificate\n")
	case overwritten:
		fmt.Fprintf(os.Stdout, "config overwritten with new domain/port (uuid and client CA preserved)\n")
	default:
		fmt.Fprintf(os.Stdout, "existing config reused (uuid and client CA preserved)\n")
	}
	fmt.Fprintf(os.Stdout, "base        : %s\n", base)
	fmt.Fprintf(os.Stdout, "config      : %s\n", cfgPath)
	fmt.Fprintf(os.Stdout, "state       : %s\n", statePath)
	fmt.Fprintf(os.Stdout, "domain      : %s\n", st.Domain)
	fmt.Fprintf(os.Stdout, "port        : %d/udp\n", st.Port)
	fmt.Fprintf(os.Stdout, "uuid        : %s\n", st.UUID)
	fmt.Fprintf(os.Stdout, "password    : %s\n", st.Password)
	fmt.Fprintf(os.Stdout, "client cert : %s\n", certPath)
	fmt.Fprintf(os.Stdout, "client key  : %s\n", keyPath)
	fmt.Fprintf(os.Stdout, "client CA   : %s\n", caPath)
	fmt.Fprintf(os.Stdout, "\nclient config (TUIC + mTLS):\n")
	fmt.Fprintf(os.Stdout, "  server=%s port=%d uuid=%s password=%s\n", st.Domain, st.Port, st.UUID, st.Password)
	fmt.Fprintf(os.Stdout, "  alpn=h3  tls.server_name=%s  client_certificate=%s  client_key=%s\n",
		st.Domain, certPath, keyPath)
	fmt.Fprintf(os.Stdout, "\nACME: certificate for %s will be requested automatically (HTTP-01 via :80).\n", st.Domain)
	fmt.Fprintf(os.Stdout, "      Make sure %s resolves to this host and TCP :80 is reachable.\n\n", st.Domain)
}