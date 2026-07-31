use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use std::thread;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State};

// ── State ──────────────────────────────────────────────────────────────────

struct VpnState {
    wdtt_process: Option<Child>,
    wg_process:   Option<Child>,
    turn_ips:     Vec<String>,
    peer_ip:      String,
    wg_addr:      String,
}
type Shared = Arc<Mutex<VpnState>>;

// ── Tauri entry ────────────────────────────────────────────────────────────

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(Arc::new(Mutex::new(VpnState {
            wdtt_process: None,
            wg_process:   None,
            turn_ips:     vec![],
            peer_ip:      String::new(),
            wg_addr:      String::new(),
        })))
        .invoke_handler(tauri::generate_handler![
            start_vpn,
            stop_vpn,
            teardown,
            check_needs_install,
            install_components,
            save_link,
            load_link,
            open_url,
        ])
        .run(tauri::generate_context!())
        .expect("error running IMBA VK Proxy");
}

// ── Helpers ────────────────────────────────────────────────────────────────

fn res_dir(app: &AppHandle) -> PathBuf {
    app.path().resource_dir().unwrap().join("resources")
}

fn emit_phase(app: &AppHandle, phase: &str, msg: &str) {
    #[derive(Serialize, Clone)] struct P { phase: String, message: String }
    let _ = app.emit("vpn:phase", P { phase: phase.into(), message: msg.into() });
}

fn emit_log(app: &AppHandle, line: &str) {
    let _ = app.emit("vpn:log", line);
}

// ── Parse wdtt:// link ─────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct WdttLink {
    peer:        String,
    peer_ip:     String,
    password:    String,
    vk_hash:     String,
    listen_port: String,
}

fn parse_link(raw: &str) -> Option<WdttLink> {
    let s = raw.trim().strip_prefix("wdtt://")?;
    let parts: Vec<&str> = s.splitn(7, ':').collect();
    if parts.len() < 6 || parts[0].is_empty() || parts[4].is_empty() || parts[5].is_empty() {
        return None;
    }
    Some(WdttLink {
        peer:        format!("{}:{}", parts[0], parts[1]),
        peer_ip:     parts[0].to_string(),
        password:    parts[4].to_string(),
        vk_hash:     parts[5].to_string(),
        listen_port: if parts[3].is_empty() { "9000".into() } else { parts[3].into() },
    })
}

// ── Commands ───────────────────────────────────────────────────────────────

#[tauri::command]
fn save_link(link: String) {
    let _ = std::fs::write(link_file(), link);
}

#[tauri::command]
fn load_link() -> String {
    std::fs::read_to_string(link_file()).unwrap_or_default()
}

fn link_file() -> PathBuf {
    let dir = std::env::temp_dir().join("imba-vkproxy");
    let _ = std::fs::create_dir_all(&dir);
    dir.join("link.txt")
}

#[tauri::command]
fn open_url(url: String) {
    let _ = Command::new("cmd").args(["/c", "start", &url]).spawn();
}

#[tauri::command]
fn check_needs_install(app: AppHandle) -> bool {
    let dir = res_dir(&app);
    !dir.join("wdtt-client.exe").exists()
        || !dir.join("wireguard-go.exe").exists()
        || !dir.join("wintun.dll").exists()
}

#[tauri::command]
fn install_components(app: AppHandle) -> Result<(), String> {
    // Components are bundled — if they're missing something is wrong with install
    let dir = res_dir(&app);
    if !dir.join("wdtt-client.exe").exists() {
        return Err("wdtt-client.exe не найден в бандле".into());
    }
    Ok(())
}

// ── start_vpn ──────────────────────────────────────────────────────────────

#[tauri::command]
fn start_vpn(link: String, app: AppHandle, state: State<Shared>) -> Result<(), String> {
    let parsed = parse_link(&link).ok_or("Неверный формат ссылки")?;
    let dir = res_dir(&app);

    {
        let mut s = state.lock().unwrap();
        if s.wdtt_process.is_some() {
            return Err("VPN уже запущен".into());
        }
        s.peer_ip = parsed.peer_ip.clone();
    }

    emit_phase(&app, "connecting", "Подключение через VK TURN…");
    emit_log(&app, "");

    let wdtt_exe = dir.join("wdtt-client.exe");
    let mut cmd = Command::new(&wdtt_exe);
    cmd.args([
        "-peer",     &parsed.peer,
        "-password", &parsed.password,
        "-vk",       &parsed.vk_hash,
        "-listen",   &format!("127.0.0.1:{}", parsed.listen_port),
        "-n",        "12",
    ])
    .env("WDTT_EVENTS", "1")
    .stdout(Stdio::piped())
    .stderr(Stdio::piped());

    let mut child = cmd.spawn().map_err(|e| format!("Не удалось запустить wdtt-client: {e}"))?;
    let stdout = child.stdout.take().unwrap();

    let app2    = app.clone();
    let dir2    = dir.clone();
    let state2  = Arc::clone(state.inner());
    let peer_ip = parsed.peer_ip.clone();

    thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines() {
            let line = match line { Ok(l) => l, Err(_) => break };
            handle_line(&app2, &line, &peer_ip, &dir2, &state2);
        }
        emit_log(&app2, "\n--- wdtt-client завершён ---");
        emit_phase(&app2, "idle", "");
        teardown_internal(&app2, &state2);
    });

    state.lock().unwrap().wdtt_process = Some(child);
    Ok(())
}

fn handle_line(app: &AppHandle, line: &str, peer_ip: &str, dir: &Path, state: &Shared) {
    if let Some(rest) = line.strip_prefix("__WDTT_EVENT__|CONFIG|") {
        if let Ok(obj) = serde_json::from_str::<serde_json::Value>(rest) {
            if let Some(config) = obj["config"].as_str() {
                emit_phase(app, "setting_up", "Настройка WireGuard…");
                emit_log(app, "[✓] Получен WireGuard конфиг");
                let pid = state.lock().unwrap().wdtt_process.as_ref().map(|c| c.id()).unwrap_or(0);
                match setup_wireguard(app, dir, config, peer_ip, pid, state) {
                    Ok(()) => {
                        emit_phase(app, "running", "VPN АКТИВЕН");
                        emit_log(app, "[✓] VPN АКТИВЕН");
                    }
                    Err(e) => {
                        emit_phase(app, "error", &format!("WireGuard: {e}"));
                        emit_log(app, &format!("[✗] {e}"));
                        teardown_internal(app, state);
                    }
                }
            }
        }
        return;
    }
    if let Some(rest) = line.strip_prefix("__WDTT_EVENT__|CAPTCHA_REQUEST|") {
        if let Ok(obj) = serde_json::from_str::<serde_json::Value>(rest) {
            if let Some(uri) = obj["redirect_uri"].as_str() {
                let _ = app.emit("vpn:captcha", uri);
                emit_log(app, "[!] Требуется капча");
            }
        }
        return;
    }
    if line.starts_with("__WDTT_EVENT__|CAPTCHA_DONE|") {
        let _ = app.emit("vpn:captcha_done", ());
        emit_log(app, "[✓] Капча пройдена");
        return;
    }
    if line.starts_with("__WDTT_EVENT__|READY|") {
        let _ = app.emit("vpn:phase", serde_json::json!({"phase":"waiting","message":"Получение конфига WireGuard…"}));
        return;
    }
    if line.starts_with("__WDTT_EVENT__") { return; }
    if !line.trim().is_empty() { emit_log(app, line); }
}

// ── WireGuard setup ────────────────────────────────────────────────────────

fn setup_wireguard(
    app: &AppHandle, dir: &Path, config: &str,
    peer_ip: &str, wdtt_pid: u32, state: &Shared,
) -> Result<(), String> {
    let wg_go  = dir.join("wireguard-go.exe");
    let wg_exe = dir.join("wg.exe");
    let wintun = dir.join("wintun.dll");

    // wintun.dll must be next to wireguard-go.exe — copy to same dir if needed
    let wg_dir = wg_go.parent().unwrap();
    let wintun_local = wg_dir.join("wintun.dll");
    if !wintun_local.exists() && wintun.exists() {
        let _ = std::fs::copy(&wintun, &wintun_local);
    }

    let filtered = filter_config(config);
    let addr     = extract_address(config);

    // Config file
    let conf_path = std::env::temp_dir().join("wg-imba.conf");
    std::fs::write(&conf_path, &filtered).map_err(|e| format!("Запись конфига: {e}"))?;

    // Get default gateway
    let gateway = get_default_gateway().unwrap_or_default();
    emit_log(app, &format!("[→] Шлюз по умолчанию: {}", if gateway.is_empty() { "не найден" } else { &gateway }));

    // TURN IP bypass routes (before adding WireGuard default routes)
    let turn_ips = detect_turn_ips(wdtt_pid);
    emit_log(app, &format!("[→] VK TURN IPs: {:?}", turn_ips));

    if !gateway.is_empty() {
        add_host_route(peer_ip, &gateway);
        for ip in &turn_ips {
            add_host_route(ip, &gateway);
        }
    }

    // Kill previous wireguard-go if any
    let _ = Command::new("taskkill").args(["/F", "/IM", "wireguard-go.exe"]).output();
    thread::sleep(Duration::from_millis(300));

    // Delete old adapter if present
    let _ = Command::new("netsh")
        .args(["interface", "delete", "interface", "imba0"])
        .output();

    // Start wireguard-go
    emit_log(app, "[→] Запуск wireguard-go…");
    let wg_proc = Command::new(&wg_go)
        .arg("imba0")
        .current_dir(wg_dir)
        .spawn()
        .map_err(|e| format!("wireguard-go: {e}"))?;

    // Wait for UAPI pipe to appear
    let pipe = format!(r"\\.\pipe\ProtectedPrefix\Servers\WireGuard\imba0");
    let mut ready = false;
    for _ in 0..20 {
        thread::sleep(Duration::from_millis(300));
        if Path::new(&pipe).exists() { ready = true; break; }
        // Also check via wg show
        if wg_exe.exists() {
            let out = Command::new(&wg_exe).args(["show", "imba0"]).output();
            if out.map(|o| o.status.success()).unwrap_or(false) { ready = true; break; }
        }
    }
    if !ready {
        // Try anyway — sometimes pipe check fails but wg setconf works
        emit_log(app, "[!] Интерфейс может быть ещё не готов, пробую setconf…");
    }

    // wg setconf imba0 <config>
    emit_log(app, "[→] wg setconf…");
    let wg_cmd = if wg_exe.exists() { wg_exe.clone() } else { PathBuf::from("wg") };
    let result = Command::new(&wg_cmd)
        .args(["setconf", "imba0", conf_path.to_str().unwrap()])
        .output()
        .map_err(|e| format!("wg setconf: {e}"))?;
    if !result.status.success() {
        let err = String::from_utf8_lossy(&result.stderr);
        return Err(format!("wg setconf ошибка: {err}"));
    }

    // Set IP address
    emit_log(app, &format!("[→] Устанавливаю адрес: {}", addr));
    let (ip, mask) = split_cidr(&addr);
    let _ = Command::new("netsh")
        .args(["interface", "ip", "set", "address", "name=imba0",
               "source=static", &format!("addr={ip}"), &format!("mask={mask}")])
        .output();

    // Wait a moment for interface to come up
    thread::sleep(Duration::from_millis(500));

    // Set DNS if present in config
    if let Some(dns) = extract_dns(config) {
        let _ = Command::new("netsh")
            .args(["interface", "ip", "set", "dns", "name=imba0", "source=static", &format!("addr={dns}")])
            .output();
    }

    // Add split default routes through WireGuard (0/1 + 128/1 trick)
    let _ = Command::new("route").args(["delete", "0.0.0.0",   "mask", "128.0.0.0"]).output();
    let _ = Command::new("route").args(["delete", "128.0.0.0", "mask", "128.0.0.0"]).output();
    let _ = Command::new("route").args(["add", "0.0.0.0",   "mask", "128.0.0.0", &ip, "metric", "5"]).output();
    let _ = Command::new("route").args(["add", "128.0.0.0", "mask", "128.0.0.0", &ip, "metric", "5"]).output();

    emit_log(app, &format!("[✓] WireGuard запущен (imba0, {})", addr));

    let mut s = state.lock().unwrap();
    s.wg_process = Some(wg_proc);
    s.turn_ips   = turn_ips;
    s.wg_addr    = ip;

    Ok(())
}

// ── Teardown ───────────────────────────────────────────────────────────────

#[tauri::command]
fn stop_vpn(app: AppHandle, state: State<Shared>) {
    teardown_internal(&app, state.inner());
}

#[tauri::command]
fn teardown(state: State<Shared>) {
    teardown_raw(state.inner());
}

fn teardown_internal(app: &AppHandle, state: &Shared) {
    teardown_raw(state);
    emit_phase(app, "idle", "");
}

fn teardown_raw(state: &Shared) {
    let mut s = state.lock().unwrap();

    if let Some(mut p) = s.wdtt_process.take() { let _ = p.kill(); }
    if let Some(mut p) = s.wg_process.take()   { let _ = p.kill(); }

    // Remove split default routes
    let _ = Command::new("route").args(["delete", "0.0.0.0",   "mask", "128.0.0.0"]).output();
    let _ = Command::new("route").args(["delete", "128.0.0.0", "mask", "128.0.0.0"]).output();

    // Remove peer + TURN bypass host routes
    if !s.peer_ip.is_empty() {
        let _ = Command::new("route").args(["delete", &s.peer_ip, "mask", "255.255.255.255"]).output();
    }
    for ip in &s.turn_ips {
        let _ = Command::new("route").args(["delete", ip, "mask", "255.255.255.255"]).output();
    }

    // Kill wireguard-go process
    let _ = Command::new("taskkill").args(["/F", "/IM", "wireguard-go.exe"]).output();

    s.turn_ips.clear();
    s.peer_ip.clear();
    s.wg_addr.clear();
}

// ── Routing helpers ────────────────────────────────────────────────────────

fn get_default_gateway() -> Option<String> {
    let out = Command::new("route")
        .args(["print", "0.0.0.0", "mask", "0.0.0.0"])
        .output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    // Look for line like: "         0.0.0.0          0.0.0.0    192.168.1.1  ..."
    for line in text.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 3 && parts[0] == "0.0.0.0" && parts[1] == "0.0.0.0" {
            let gw = parts[2];
            if gw != "On-link" && !gw.starts_with("0.0") {
                return Some(gw.to_string());
            }
        }
    }
    None
}

fn add_host_route(ip: &str, gateway: &str) {
    if ip.is_empty() || gateway.is_empty() { return; }
    let _ = Command::new("route")
        .args(["add", ip, "mask", "255.255.255.255", gateway, "metric", "1"])
        .output();
}

fn detect_turn_ips(pid: u32) -> Vec<String> {
    if pid == 0 { return vec![]; }
    let out = Command::new("netstat")
        .args(["-n", "-p", "UDP"])
        .output();
    let Ok(out) = out else { return vec![]; };
    let text = String::from_utf8_lossy(&out.stdout);
    // netstat on Windows doesn't easily filter by PID in UDP mode,
    // so we collect all foreign UDP addresses as potential TURN endpoints
    // (wdtt-client is typically the only thing talking to the TURN server)
    let mut ips = vec![];
    for line in text.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        // UDP  local  foreign
        if parts.len() >= 3 && parts[0] == "UDP" {
            let foreign = parts[2];
            if foreign == "*:*" { continue; }
            if let Some(ip) = foreign.rsplit_once(':').map(|(h, _)| h) {
                let ip = ip.trim_start_matches('[').trim_end_matches(']');
                if !ip.starts_with("127.") && !ip.starts_with("0.") && ip != "::" {
                    let s = ip.to_string();
                    if !ips.contains(&s) { ips.push(s); }
                }
            }
        }
    }
    ips
}

// ── Config helpers ─────────────────────────────────────────────────────────

fn filter_config(config: &str) -> String {
    let skip = ["Address", "DNS", "MTU", "Table", "PreUp", "PostUp", "PreDown", "PostDown"];
    config.lines()
        .filter(|l| {
            let key = l.split('=').next().unwrap_or("").trim();
            !skip.contains(&key)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn extract_address(config: &str) -> String {
    config.lines()
        .find(|l| l.trim_start().starts_with("Address"))
        .and_then(|l| l.splitn(2, '=').nth(1))
        .map(|v| v.trim().to_string())
        .unwrap_or_else(|| "10.66.66.99/32".into())
}

fn extract_dns(config: &str) -> Option<String> {
    config.lines()
        .find(|l| l.trim_start().starts_with("DNS"))
        .and_then(|l| l.splitn(2, '=').nth(1))
        .map(|v| v.split(',').next().unwrap_or("").trim().to_string())
        .filter(|s| !s.is_empty())
}

fn split_cidr(cidr: &str) -> (String, String) {
    let parts: Vec<&str> = cidr.split('/').collect();
    let ip = parts[0].to_string();
    let prefix: u32 = parts.get(1).and_then(|p| p.parse().ok()).unwrap_or(32);
    let mask = if prefix == 0 {
        "0.0.0.0".into()
    } else {
        let bits: u32 = !((1u32 << (32 - prefix)) - 1);
        format!("{}.{}.{}.{}", bits >> 24, (bits >> 16) & 0xff, (bits >> 8) & 0xff, bits & 0xff)
    };
    (ip, mask)
}
