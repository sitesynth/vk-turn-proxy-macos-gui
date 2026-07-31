package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

const sockPath = "/var/run/vkproxy.sock"

type setupReq struct {
	Config string `json:"config"`
	PeerIP string `json:"peer_ip"`
	AddrIP string `json:"addr_ip"`
	WGBin  string `json:"wg_bin"`
	WGCtrl string `json:"wg_ctrl"`
}

type resp struct {
	OK  bool   `json:"ok"`
	Err string `json:"err,omitempty"`
}

var (
	mu     sync.Mutex
	wgProc *os.Process
	lastPeerIP string
)

func main() {
	if os.Getuid() != 0 {
		fmt.Fprintln(os.Stderr, "vkproxy-helper: must run as root")
		os.Exit(1)
	}
	os.Remove(sockPath)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "listen:", err)
		os.Exit(1)
	}
	if err := os.Chmod(sockPath, 0o666); err != nil {
		fmt.Fprintln(os.Stderr, "chmod:", err)
	}
	fmt.Println("vkproxy-helper: ready")
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go func() {
			defer conn.Close()
			handle(conn)
		}()
	}
}

func handle(conn net.Conn) {
	var msg map[string]json.RawMessage
	if err := json.NewDecoder(conn).Decode(&msg); err != nil {
		reply(conn, false, err.Error())
		return
	}
	var cmd string
	json.Unmarshal(msg["cmd"], &cmd)

	mu.Lock()
	defer mu.Unlock()

	var err error
	switch cmd {
	case "ping":
		// ok
	case "setup":
		var req setupReq
		raw, _ := json.Marshal(msg)
		json.Unmarshal(raw, &req)
		err = doSetup(req)
	case "teardown":
		doTeardown()
	default:
		err = fmt.Errorf("unknown cmd %q", cmd)
	}

	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		reply(conn, false, err.Error())
	} else {
		reply(conn, true, "")
	}
}

func reply(conn net.Conn, ok bool, errMsg string) {
	json.NewEncoder(conn).Encode(resp{OK: ok, Err: errMsg})
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

func doSetup(req setupReq) error {
	doTeardown()

	// Strip wg-quick-only keys that bare wg setconf doesn't understand
	wgQuickOnly := []string{"Address", "DNS", "MTU", "Table", "PreUp", "PostUp", "PreDown", "PostDown"}
	var lines []string
	for _, l := range strings.Split(req.Config, "\n") {
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
	cleanConf := strings.Join(lines, "\n")

	if err := os.WriteFile("/tmp/wg-vkproxy.conf", []byte(cleanConf), 0o600); err != nil {
		return fmt.Errorf("write config: %w", err)
	}

	// Add host route for wdtt-server so wdtt-client traffic bypasses the tunnel
	if req.PeerIP != "" {
		if gw := defaultGW(); gw != "" {
			run("route", "-q", "-n", "delete", "-host", req.PeerIP)
			run("route", "-q", "-n", "add", "-host", req.PeerIP, gw)
			lastPeerIP = req.PeerIP
		}
	}

	// Kill any leftover wireguard-go
	if pid, err := os.ReadFile("/var/run/wireguard/utun99.pid"); err == nil {
		run("kill", strings.TrimSpace(string(pid)))
		time.Sleep(300 * time.Millisecond)
	}

	// Start wireguard-go
	wgCmd := exec.Command(req.WGBin, "utun99")
	wgCmd.Stderr = os.Stderr
	if err := wgCmd.Start(); err != nil {
		return fmt.Errorf("start wireguard-go: %w", err)
	}
	wgProc = wgCmd.Process
	go wgCmd.Wait()

	// Wait for wireguard-go to create its socket
	sockFile := "/var/run/wireguard/utun99.sock"
	for i := 0; i < 30; i++ {
		if _, err := os.Stat(sockFile); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	if err := runCheck(req.WGCtrl, "setconf", "utun99", "/tmp/wg-vkproxy.conf"); err != nil {
		wgProc.Kill()
		wgProc = nil
		return fmt.Errorf("wg setconf: %w", err)
	}
	if err := runCheck("ifconfig", "utun99", "inet", req.AddrIP, req.AddrIP); err != nil {
		wgProc.Kill()
		wgProc = nil
		return fmt.Errorf("ifconfig: %w", err)
	}

	run("route", "-q", "-n", "add", "-inet", "0.0.0.0/1", "-interface", "utun99")
	run("route", "-q", "-n", "add", "-inet", "128.0.0.0/1", "-interface", "utun99")
	return nil
}

func doTeardown() {
	run("route", "-q", "-n", "delete", "-inet", "0.0.0.0/1")
	run("route", "-q", "-n", "delete", "-inet", "128.0.0.0/1")
	if lastPeerIP != "" {
		run("route", "-q", "-n", "delete", "-host", lastPeerIP)
		lastPeerIP = ""
	}
	if wgProc != nil {
		wgProc.Kill()
		wgProc = nil
	}
	if pid, err := os.ReadFile("/var/run/wireguard/utun99.pid"); err == nil {
		run("kill", strings.TrimSpace(string(pid)))
	}
}
