package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

const stateFile = "/tmp/vkproxy-state.json"

type state struct {
	WGPID   int    `json:"wg_pid"`
	PeerIP  string `json:"peer_ip"`
	TurnIPs []string `json:"turn_ips"`
}

func main() {
	if os.Getuid() != 0 {
		fmt.Fprintln(os.Stderr, "vkproxy-helper: must run as root")
		os.Exit(1)
	}
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: vkproxy-helper {setup|teardown} [flags]")
		os.Exit(1)
	}
	switch os.Args[1] {
	case "setup":
		fs := flag.NewFlagSet("setup", flag.ExitOnError)
		conf := fs.String("config", "", "wireguard config path")
		peerIP := fs.String("peer-ip", "", "wdtt server IP")
		addrIP := fs.String("addr", "", "client WireGuard IP")
		wgBin := fs.String("wg-bin", "", "wireguard-go path")
		wgCtrl := fs.String("wg-ctrl", "", "wg path")
		clientPID := fs.Int("pid", 0, "wdtt-client PID")
		fs.Parse(os.Args[2:])
		if err := doSetup(*conf, *peerIP, *addrIP, *wgBin, *wgCtrl, *clientPID); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
	case "teardown":
		doTeardown()
	default:
		fmt.Fprintln(os.Stderr, "unknown command:", os.Args[1])
		os.Exit(1)
	}
}

func run(name string, args ...string) {
	exec.Command(name, args...).Run()
}

func runCheck(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func defaultGW() string {
	out, _ := exec.Command("route", "-n", "get", "default").Output()
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "gateway:") {
			return strings.TrimSpace(strings.TrimPrefix(line, "gateway:"))
		}
	}
	return ""
}

// Detect VK TURN server IPs that wdtt-client is connected to via UDP
func detectTurnIPs(clientPID int) []string {
	if clientPID <= 0 {
		return nil
	}
	out, err := exec.Command("lsof", "-p", strconv.Itoa(clientPID), "-i", "UDP", "-n", "-P").Output()
	if err != nil {
		return nil
	}
	seen := map[string]bool{}
	var ips []string
	for _, line := range strings.Split(string(out), "\n") {
		// Lines look like: wdtt-cli 1234 user ... UDP local->remote
		if !strings.Contains(line, "->") {
			continue
		}
		parts := strings.Fields(line)
		for _, p := range parts {
			if strings.Contains(p, "->") {
				remote := strings.Split(p, "->")[1]
				ip := strings.Split(remote, ":")[0]
				if ip != "" && ip != "*" && !seen[ip] {
					seen[ip] = true
					ips = append(ips, ip)
				}
			}
		}
	}
	return ips
}

// Strip wg-quick-only keys that bare wg setconf doesn't understand
func filterConfig(raw string) string {
	wgQuickOnly := []string{"Address", "DNS", "MTU", "Table", "PreUp", "PostUp", "PreDown", "PostDown"}
	var lines []string
	for _, l := range strings.Split(raw, "\n") {
		t := strings.TrimSpace(l)
		skip := false
		for _, prefix := range wgQuickOnly {
			if strings.HasPrefix(t, prefix) {
				skip = true
				break
			}
		}
		if !skip {
			lines = append(lines, l)
		}
	}
	return strings.Join(lines, "\n")
}

func doSetup(confPath, peerIP, addrIP, wgBin, wgCtrl string, clientPID int) error {
	// Clean up any stale state first
	doTeardown()

	// Read and filter config
	raw, err := os.ReadFile(confPath)
	if err != nil {
		return fmt.Errorf("read config: %w", err)
	}
	clean := filterConfig(string(raw))
	if err := os.WriteFile(confPath, []byte(clean), 0o600); err != nil {
		return fmt.Errorf("write config: %w", err)
	}

	gw := defaultGW()
	if gw == "" {
		return fmt.Errorf("could not determine default gateway")
	}

	// Add bypass routes: wdtt-server and VK TURN IPs must not go through our tunnel
	turnIPs := detectTurnIPs(clientPID)
	bypassIPs := append([]string{peerIP}, turnIPs...)
	for _, ip := range bypassIPs {
		if ip == "" {
			continue
		}
		run("route", "-q", "-n", "delete", "-host", ip)
		run("route", "-q", "-n", "add", "-host", ip, gw)
	}

	// Kill any leftover wireguard-go
	if pid, err := os.ReadFile("/var/run/wireguard/utun99.pid"); err == nil {
		run("kill", strings.TrimSpace(string(pid)))
		time.Sleep(300 * time.Millisecond)
	}

	// Start wireguard-go
	wgCmd := exec.Command(wgBin, "utun99")
	wgCmd.Stderr = os.Stderr
	if err := wgCmd.Start(); err != nil {
		return fmt.Errorf("start wireguard-go: %w", err)
	}
	wgPID := wgCmd.Process.Pid
	go wgCmd.Wait()

	// Wait for wireguard-go to create its socket
	for i := 0; i < 30; i++ {
		if _, err := os.Stat("/var/run/wireguard/utun99.sock"); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	if err := runCheck(wgCtrl, "setconf", "utun99", confPath); err != nil {
		exec.Command("kill", strconv.Itoa(wgPID)).Run()
		return fmt.Errorf("wg setconf: %w", err)
	}
	if err := runCheck("ifconfig", "utun99", "inet", addrIP, addrIP); err != nil {
		exec.Command("kill", strconv.Itoa(wgPID)).Run()
		return fmt.Errorf("ifconfig: %w", err)
	}

	run("route", "-q", "-n", "add", "-inet", "0.0.0.0/1", "-interface", "utun99")
	run("route", "-q", "-n", "add", "-inet", "128.0.0.0/1", "-interface", "utun99")

	// Save state for teardown
	st := state{WGPID: wgPID, PeerIP: peerIP, TurnIPs: turnIPs}
	if data, err := json.Marshal(st); err == nil {
		os.WriteFile(stateFile, data, 0o600)
	}
	return nil
}

func doTeardown() {
	run("route", "-q", "-n", "delete", "-inet", "0.0.0.0/1")
	run("route", "-q", "-n", "delete", "-inet", "128.0.0.0/1")

	// Read saved state
	if data, err := os.ReadFile(stateFile); err == nil {
		var st state
		if json.Unmarshal(data, &st) == nil {
			if st.PeerIP != "" {
				run("route", "-q", "-n", "delete", "-host", st.PeerIP)
			}
			for _, ip := range st.TurnIPs {
				run("route", "-q", "-n", "delete", "-host", ip)
			}
			if st.WGPID > 0 {
				run("kill", strconv.Itoa(st.WGPID))
			}
		}
		os.Remove(stateFile)
	}

	// Also kill by pid file in case state was lost
	if pid, err := os.ReadFile("/var/run/wireguard/utun99.pid"); err == nil {
		run("kill", strings.TrimSpace(string(pid)))
	}
}
