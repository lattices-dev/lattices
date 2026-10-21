#[cfg(not(unix))]
compile_error!("action-supervisor first slice requires a Unix-like platform.");

use std::collections::HashSet;
use std::env;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const DEFAULT_HOST: &str = "127.0.0.1";
const RESTART_MIN_DELAY: Duration = Duration::from_secs(1);
const RESTART_MAX_DELAY: Duration = Duration::from_secs(30);
const START_TIMEOUT: Duration = Duration::from_secs(15);
const STOP_TIMEOUT: Duration = Duration::from_secs(20);
const CHILD_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(12);
const POLL_INTERVAL: Duration = Duration::from_millis(100);
const STATE_WRITE_INTERVAL: Duration = Duration::from_secs(2);
const SIGINT: i32 = 2;
const SIGTERM: i32 = 15;
const OPTIONAL_ENV_KEYS: &[&str] = &[
    "MINIMAX_API_KEY",
    "ACTION_SECRETS_FILE",
    "ACTION_COMPANION_SECRETS_FILE",
    "ACTION_VISION_PROVIDER",
    "ACTION_MOONDREAM_PYTHON",
    "MOONDREAM_PYTHON",
    "ACTION_COMPANION_MAX_WORKERS",
    "ACTION_COMPANION_PORT",
    "ACTION_COMPANION_ALLOW_TCP",
    "LATTICES_RUNTIME_DIR",
];

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

unsafe extern "C" {
    fn signal(signum: i32, handler: extern "C" fn(i32)) -> usize;
}

extern "C" fn request_shutdown(_: i32) {
    SHUTDOWN_REQUESTED.store(true, Ordering::SeqCst);
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("{error}");
            ExitCode::from(1)
        }
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "-h" || arg == "--help" || arg == "help") {
        print_help();
        return Ok(());
    }

    let json = args.iter().any(|arg| arg == "--json");
    let command = args
        .iter()
        .find(|arg| !arg.starts_with("--"))
        .map(String::as_str)
        .unwrap_or("status");
    let config = Config::resolve()?;

    match command {
        "status" => {
            let status = companion_service_status(&config);
            print_status(&status, json);
            Ok(())
        }
        "doctor" => {
            let report = doctor_report(&config);
            print_doctor(&report, json);
            Ok(())
        }
        "start" => {
            let status = start_service(&config)?;
            print_status(&status, json);
            Ok(())
        }
        "stop" => {
            let status = stop_service(&config)?;
            print_status(&status, json);
            Ok(())
        }
        "restart" => {
            stop_service(&config)?;
            let status = start_service(&config)?;
            print_status(&status, json);
            Ok(())
        }
        "supervise" | "daemon" => supervise_service(&config),
        other => Err(format!("unknown command: {other}")),
    }
}

#[derive(Clone, Debug)]
struct Config {
    label: String,
    domain_target: String,
    service_target: String,
    launch_agent_path: PathBuf,
    support_directory: PathBuf,
    runtime_directory: PathBuf,
    logs_directory: PathBuf,
    stdout_log_path: PathBuf,
    stderr_log_path: PathBuf,
    action_root: PathBuf,
    supervisor_executable: PathBuf,
    supervisor_state_path: PathBuf,
    bun_executable: String,
    bun_resolution_error: Option<String>,
    companion_host: String,
    companion_url: String,
    companion_socket_path: PathBuf,
}

impl Config {
    fn resolve() -> Result<Self, String> {
        let home = home_dir()?;
        let uid = user_id()?;
        let label = env_nonempty("ACTION_COMPANION_SERVICE_LABEL")
            .unwrap_or_else(|| "dev.action.companion".to_string());
        let support_directory = non_tmp_path_or_default(
            env_nonempty("ACTION_SUPPORT_DIRECTORY")
                .or_else(|| env_nonempty("ACTION_COMPANION_SUPPORT_DIRECTORY"))
                .map(PathBuf::from),
            home.join("Library/Application Support/Action"),
        );
        let runtime_directory = support_directory.join("runtime");
        let logs_directory = support_directory.join("logs/companion");
        let action_root = match env_nonempty("ACTION_ROOT") {
            Some(value) => PathBuf::from(value),
            None => find_action_root(&env::current_dir().map_err(|error| error.to_string())?)
                .ok_or_else(|| "unable to resolve ACTION_ROOT; run from the action repo or set ACTION_ROOT".to_string())?,
        };
        let supervisor_executable = match env_nonempty("ACTION_SUPERVISOR_BIN") {
            Some(value) => PathBuf::from(value),
            None => env::current_exe().map_err(|error| error.to_string())?,
        };
        let supervisor_state_path = runtime_directory.join("supervisor-state.json");
        let (bun_executable, bun_resolution_error) = match resolve_bun(
            &home,
            env_nonempty("ACTION_BUN_BIN").as_deref(),
            &env::var("PATH").unwrap_or_default(),
            executable_file,
        ) {
            Ok(path) => (path, None),
            Err(error) => (String::new(), Some(error)),
        };
        let companion_host = env_nonempty("ACTION_COMPANION_HOST").unwrap_or_else(|| DEFAULT_HOST.to_string());
        let companion_socket_path = PathBuf::from(
            env_nonempty("ACTION_COMPANION_SOCKET_PATH").unwrap_or_else(|| {
                runtime_directory
                    .join("companion.sock")
                    .to_string_lossy()
                    .to_string()
            }),
        );
        let companion_url = format!("unix:{}", companion_socket_path.display());

        Ok(Self {
            label: label.clone(),
            domain_target: format!("gui/{uid}"),
            service_target: format!("gui/{uid}/{label}"),
            launch_agent_path: home.join(format!("Library/LaunchAgents/{label}.plist")),
            support_directory,
            runtime_directory,
            logs_directory: logs_directory.clone(),
            stdout_log_path: logs_directory.join("stdout.log"),
            stderr_log_path: logs_directory.join("stderr.log"),
            action_root,
            supervisor_executable,
            supervisor_state_path,
            bun_executable,
            bun_resolution_error,
            companion_host,
            companion_url,
            companion_socket_path,
        })
    }

    fn companion_entrypoint(&self) -> PathBuf {
        self.action_root.join("packages/companion/src/server.ts")
    }
}

#[derive(Clone, Debug)]
struct LaunchctlStatus {
    loaded: bool,
    pid: Option<u32>,
    launchd_state: Option<String>,
    last_exit_status: Option<i32>,
}

#[derive(Clone, Debug)]
struct HealthStatus {
    reachable: bool,
    ok: bool,
    transport: Option<String>,
    status_code: Option<u16>,
    body: Option<String>,
    error: Option<String>,
}

#[derive(Clone, Debug)]
struct ServiceStatus {
    config: Config,
    launchctl: LaunchctlStatus,
    health: HealthStatus,
    supervisor_state: Option<String>,
}

#[derive(Clone, Debug)]
struct ProcessInfo {
    pid: u32,
    ppid: u32,
    pcpu: String,
    pmem: String,
    elapsed: String,
    command: String,
}

#[derive(Clone, Debug)]
struct DoctorReport {
    status: ServiceStatus,
    processes: Vec<ProcessInfo>,
    warnings: Vec<String>,
}

fn start_service(config: &Config) -> Result<ServiceStatus, String> {
    validate_bun(config)?;
    ensure_launch_agent(config)?;
    let _ = run_command("/bin/launchctl", &["bootout", &config.service_target]);
    let _ = wait_for_stopped(config);
    run_command_checked(
        "/bin/launchctl",
        &[
            "bootstrap",
            &config.domain_target,
            path_str(&config.launch_agent_path)?,
        ],
    )?;
    let _ = run_command("/bin/launchctl", &["kickstart", "-k", &config.service_target]);
    wait_for_healthy(config)
}

fn stop_service(config: &Config) -> Result<ServiceStatus, String> {
    let _ = run_command("/bin/launchctl", &["bootout", &config.service_target]);
    wait_for_stopped(config)
}

fn supervise_service(config: &Config) -> Result<(), String> {
    validate_bun(config)?;
    install_signal_handlers();
    ensure_supervisor_directories(config)?;
    eprintln!(
        "[action-supervisor] starting Bun companion from {}",
        config.companion_entrypoint().display(),
    );

    let started_at_ms = epoch_ms();
    let mut restart_count = 0_u32;
    let mut restart_delay = RESTART_MIN_DELAY;
    let mut child = spawn_companion_process(config)?;
    write_supervisor_state(config, started_at_ms, Some(child.id()), "running", restart_count)?;
    let mut next_state_write = Instant::now() + STATE_WRITE_INTERVAL;

    while !SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
        match child.try_wait().map_err(|error| error.to_string())? {
            Some(status) => {
                write_supervisor_state(config, started_at_ms, None, "exited", restart_count)?;
                eprintln!("[action-supervisor] Bun companion exited: {status}");
                restart_count = restart_count.saturating_add(1);
                sleep_until_or_shutdown(Instant::now() + restart_delay);
                if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
                    break;
                }
                restart_delay = doubled_delay(restart_delay);
                child = spawn_companion_process(config)?;
                write_supervisor_state(config, started_at_ms, Some(child.id()), "running", restart_count)?;
                next_state_write = Instant::now() + STATE_WRITE_INTERVAL;
            }
            None => {
                if Instant::now() >= next_state_write {
                    write_supervisor_state(config, started_at_ms, Some(child.id()), "running", restart_count)?;
                    next_state_write = Instant::now() + STATE_WRITE_INTERVAL;
                }
                thread::sleep(POLL_INTERVAL);
            }
        }
    }

    write_supervisor_state(config, started_at_ms, Some(child.id()), "stopping", restart_count)?;
    terminate_child(&mut child, "Bun companion", CHILD_SHUTDOWN_TIMEOUT)?;
    write_supervisor_state(config, started_at_ms, None, "stopped", restart_count)?;
    Ok(())
}

fn install_signal_handlers() {
    unsafe {
        let _ = signal(SIGINT, request_shutdown);
        let _ = signal(SIGTERM, request_shutdown);
    }
}

fn spawn_companion_process(config: &Config) -> Result<Child, String> {
    let mut command = Command::new(&config.bun_executable);
    command
        .arg(config.companion_entrypoint())
        .current_dir(&config.action_root)
        .env("ACTION_ROOT", config.action_root.to_string_lossy().to_string())
        .env("ACTION_SUPPORT_DIRECTORY", config.support_directory.to_string_lossy().to_string())
        .env("ACTION_COMPANION_SOCKET_PATH", config.companion_socket_path.to_string_lossy().to_string())
        .env("ACTION_COMPANION_HOST", &config.companion_host)
        .env("ACTION_COMPANION_PARENT_PID", std::process::id().to_string())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());

    for &key in OPTIONAL_ENV_KEYS {
        if let Some(value) = env_nonempty(key) {
            command.env(key, value);
        }
    }

    command
        .spawn()
        .map_err(|error| format!("failed to start Bun companion: {error}"))
}

fn sleep_until_or_shutdown(deadline: Instant) {
    while Instant::now() < deadline && !SHUTDOWN_REQUESTED.load(Ordering::SeqCst) {
        thread::sleep(POLL_INTERVAL);
    }
}

fn doubled_delay(delay: Duration) -> Duration {
    let doubled = delay.as_millis().saturating_mul(2);
    Duration::from_millis(doubled.min(RESTART_MAX_DELAY.as_millis()) as u64)
}

fn terminate_child(child: &mut Child, label: &str, timeout: Duration) -> Result<(), String> {
    if child.try_wait().map_err(|error| error.to_string())?.is_some() {
        return Ok(());
    }

    let _ = send_process_signal(child.id(), "TERM");
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if child.try_wait().map_err(|error| error.to_string())?.is_some() {
            return Ok(());
        }
        thread::sleep(POLL_INTERVAL);
    }

    eprintln!("[action-supervisor] {label} did not exit after SIGTERM; forcing shutdown");
    child.kill().map_err(|error| error.to_string())?;
    let _ = child.wait();
    Ok(())
}

fn send_process_signal(pid: u32, signal_name: &str) -> Result<(), String> {
    let status = Command::new("/bin/kill")
        .arg(format!("-{signal_name}"))
        .arg(pid.to_string())
        .status()
        .map_err(|error| error.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("kill -{signal_name} {pid} exited with {status}"))
    }
}

fn companion_service_status(config: &Config) -> ServiceStatus {
    ServiceStatus {
        config: config.clone(),
        launchctl: inspect_launchctl(config),
        health: fetch_health(config),
        supervisor_state: read_supervisor_state_json(config),
    }
}

fn wait_for_healthy(config: &Config) -> Result<ServiceStatus, String> {
    let deadline = Instant::now() + START_TIMEOUT;
    let mut last = companion_service_status(config);
    while Instant::now() < deadline {
        last = companion_service_status(config);
        if last.health.reachable && last.health.ok {
            return Ok(last);
        }
        thread::sleep(POLL_INTERVAL);
    }
    Err(format!(
        "companion did not become healthy: {}",
        last.health.error.clone().unwrap_or_else(|| "health check failed".to_string()),
    ))
}

fn wait_for_stopped(config: &Config) -> Result<ServiceStatus, String> {
    let deadline = Instant::now() + STOP_TIMEOUT;
    let mut last = companion_service_status(config);
    while Instant::now() < deadline {
        last = companion_service_status(config);
        if !last.launchctl.loaded && !last.health.reachable {
            return Ok(last);
        }
        thread::sleep(POLL_INTERVAL);
    }
    Err(format!(
        "service did not stop within {:?}: launchd loaded={}, companion reachable={}",
        STOP_TIMEOUT, last.launchctl.loaded, last.health.reachable,
    ))
}

fn inspect_launchctl(config: &Config) -> LaunchctlStatus {
    let output = match run_command("/bin/launchctl", &["print", &config.service_target]) {
        Ok(output) => output,
        Err(_) => {
            return LaunchctlStatus { loaded: false, pid: None, launchd_state: None, last_exit_status: None };
        }
    };

    if output.status != 0 {
        return LaunchctlStatus { loaded: false, pid: None, launchd_state: None, last_exit_status: None };
    }

    LaunchctlStatus {
        loaded: true,
        pid: parse_launchctl_u32(&output.stdout, "pid ="),
        launchd_state: parse_launchctl_string(&output.stdout, "state ="),
        last_exit_status: parse_launchctl_i32(&output.stdout, "last exit code =")
            .or_else(|| parse_launchctl_i32(&output.stdout, "last exit status =")),
    }
}

fn fetch_health(config: &Config) -> HealthStatus {
    match fetch_unix_health(&config.companion_socket_path) {
        Ok(mut health) => {
            health.transport = Some("unix_socket".to_string());
            health
        }
        Err(error) => HealthStatus { reachable: false, ok: false, transport: None, status_code: None, body: None, error: Some(error) },
    }
}

fn fetch_unix_health(socket_path: &Path) -> Result<HealthStatus, String> {
    let mut stream = UnixStream::connect(socket_path).map_err(|error| error.to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(1))).map_err(|error| error.to_string())?;
    stream.set_write_timeout(Some(Duration::from_secs(1))).map_err(|error| error.to_string())?;
    fetch_http_health(&mut stream, "localhost")
}

#[cfg(target_os = "macos")]
fn no_follow_flag() -> i32 { 0x100 }
#[cfg(not(target_os = "macos"))]
fn no_follow_flag() -> i32 { 0x20000 }

fn fetch_http_health<T: Read + Write>(stream: &mut T, host: &str) -> Result<HealthStatus, String> {
    let token_dir = env_nonempty("LATTICES_RUNTIME_DIR").map(PathBuf::from).unwrap_or(home_dir()?.join(".lattices/run"));
    let directory = fs::symlink_metadata(&token_dir).map_err(|error| error.to_string())?;
    if !directory.is_dir() || directory.uid() != user_id()? || directory.mode() & 0o077 != 0 { return Err("Companion IPC directory must be private and user-owned".to_string()); }
    let token_path = token_dir.join("action-companion.token");
    let mut file = fs::OpenOptions::new().read(true).custom_flags(no_follow_flag()).open(token_path).map_err(|error| error.to_string())?;
    let meta = file.metadata().map_err(|error| error.to_string())?;
    if !meta.is_file() || meta.nlink() != 1 || meta.uid() != user_id()? || meta.mode() & 0o777 != 0o600 || meta.len() > 1024 { return Err("Companion token must be private and user-owned".to_string()); }
    let mut token = String::new(); file.read_to_string(&mut token).map_err(|error| error.to_string())?;
    let token = token.trim();
    if token.len() != 64 || !token.chars().all(|c| c.is_ascii_hexdigit()) { return Err("Invalid companion token".to_string()); }
    let request = format!("GET /health HTTP/1.1\r\nHost: {host}\r\nx-lattices-token: {token}\r\nAccept: application/json\r\nConnection: close\r\n\r\n");
    stream.write_all(request.as_bytes()).map_err(|error| error.to_string())?;
    let mut response = String::new();
    stream.read_to_string(&mut response).map_err(|error| error.to_string())?;
    parse_health_response(&response)
}

fn parse_health_response(response: &str) -> Result<HealthStatus, String> {
    let status_line = response.lines().next().unwrap_or_default();
    let status_code = status_line.split_whitespace().nth(1).and_then(|value| value.parse::<u16>().ok());
    let body = response.split_once("\r\n\r\n").map(|(_, body)| body.to_string()).unwrap_or_default();
    let ok = status_code == Some(200) && health_body_reports_ok(&body);
    Ok(HealthStatus {
        reachable: status_code.is_some(),
        ok,
        transport: None,
        status_code,
        body: if body.is_empty() { None } else { Some(body) },
        error: if status_code.is_some() { None } else { Some("missing HTTP status".to_string()) },
    })
}

fn health_body_reports_ok(body: &str) -> bool {
    let Some((_, after_key)) = body.split_once("\"ok\"") else { return false; };
    let Some((_, after_colon)) = after_key.split_once(':') else { return false; };
    after_colon.trim_start().starts_with("true")
}

fn doctor_report(config: &Config) -> DoctorReport {
    let status = companion_service_status(config);
    let processes = process_snapshot();
    let mut warnings = Vec::new();

    if !config.companion_entrypoint().exists() {
        warnings.push(format!("companion entrypoint is missing: {}", config.companion_entrypoint().display()));
    }
    if let Some(error) = &config.bun_resolution_error {
        warnings.push(error.clone());
    } else if !command_available(&config.bun_executable) {
        warnings.push(format!("bun executable is not available: {}", config.bun_executable));
    }
    if !status.health.reachable {
        warnings.push("companion health is unreachable".to_string());
    }
    if status.config.companion_socket_path.exists() && !status.health.reachable {
        warnings.push(format!("companion socket exists but health is unreachable: {}", status.config.companion_socket_path.display()));
    }
    if status.launchctl.loaded && status.supervisor_state.is_none() {
        warnings.push(format!("launchd service is loaded but supervisor state is missing: {}", status.config.supervisor_state_path.display()));
    }

    let supervisor_processes: Vec<&ProcessInfo> = processes.iter().filter(|process| command_invokes_supervisor_daemon(&process.command)).collect();
    if supervisor_processes.len() > 1 {
        warnings.push(format!("multiple action-supervisor processes found: {}", supervisor_processes.len()));
    }
    for process in supervisor_processes {
        if process.ppid == 1 && status.launchctl.pid != Some(process.pid) {
            warnings.push(format!("orphaned action-supervisor process: pid {}", process.pid));
        }
    }
    for process in processes.iter().filter(|process| command_references_process(&process.command, "packages/companion/src/server.ts")) {
        if process.ppid == 1 {
            warnings.push(format!("orphaned action-companion process: pid {}", process.pid));
        }
    }

    DoctorReport { status, processes, warnings }
}

fn process_snapshot() -> Vec<ProcessInfo> {
    let output = match run_command("ps", &["-axo", "pid=,ppid=,pcpu=,pmem=,etime=,command="]) {
        Ok(output) if output.status == 0 => output.stdout,
        _ => return Vec::new(),
    };

    output
        .lines()
        .filter_map(parse_process_line)
        .filter(|process| {
            command_references_process(&process.command, "action-supervisor")
                || process.command.contains("packages/companion/src/server.ts")
                || process.command.contains("packages/runtime/src/companion-worker.ts")
        })
        .collect()
}

fn command_references_process(command: &str, process_name: &str) -> bool {
    command
        .split_whitespace()
        .any(|part| part == process_name || part.rsplit('/').next() == Some(process_name) || part.contains(process_name))
}

fn command_invokes_supervisor_daemon(command: &str) -> bool {
    let mut parts = command.split_whitespace();
    while let Some(part) = parts.next() {
        if part == "action-supervisor" || part.rsplit('/').next() == Some("action-supervisor") {
            return matches!(parts.next(), Some("supervise" | "daemon"));
        }
    }
    false
}

fn parse_process_line(line: &str) -> Option<ProcessInfo> {
    let mut parts = line.split_whitespace();
    let pid = parts.next()?.parse::<u32>().ok()?;
    let ppid = parts.next()?.parse::<u32>().ok()?;
    let pcpu = parts.next()?.to_string();
    let pmem = parts.next()?.to_string();
    let elapsed = parts.next()?.to_string();
    let command = parts.collect::<Vec<_>>().join(" ");
    Some(ProcessInfo { pid, ppid, pcpu, pmem, elapsed, command })
}

fn ensure_launch_agent(config: &Config) -> Result<(), String> {
    ensure_supervisor_directories(config)?;
    let plist = render_launch_agent_plist(config);
    if fs::read_to_string(&config.launch_agent_path).ok().as_deref() != Some(plist.as_str()) {
        fs::write(&config.launch_agent_path, plist).map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn ensure_supervisor_directories(config: &Config) -> Result<(), String> {
    fs::create_dir_all(&config.support_directory).map_err(|error| error.to_string())?;
    fs::create_dir_all(&config.runtime_directory).map_err(|error| error.to_string())?;
    fs::create_dir_all(&config.logs_directory).map_err(|error| error.to_string())?;
    if let Some(parent) = config.launch_agent_path.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    Ok(())
}

fn render_launch_agent_plist(config: &Config) -> String {
    let mut env_entries = vec![
        ("ACTION_ROOT", config.action_root.to_string_lossy().to_string()),
        ("ACTION_BUN_BIN", config.bun_executable.clone()),
        ("ACTION_SUPPORT_DIRECTORY", config.support_directory.to_string_lossy().to_string()),
        ("ACTION_COMPANION_SOCKET_PATH", config.companion_socket_path.to_string_lossy().to_string()),
        ("ACTION_COMPANION_HOST", config.companion_host.clone()),
        ("HOME", home_dir().map(|path| path.to_string_lossy().to_string()).unwrap_or_default()),
        ("PATH", launch_agent_path_env()),
    ];
    for &key in OPTIONAL_ENV_KEYS {
        if let Some(value) = env_nonempty(key) {
            env_entries.push((key, value));
        }
    }
    let env_block = env_entries
        .into_iter()
        .map(|(key, value)| format!("\n    <key>{}</key>\n    <string>{}</string>", xml_escape(key), xml_escape(&value)))
        .collect::<String>();

    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{supervisor}</string>
    <string>supervise</string>
  </array>
  <key>WorkingDirectory</key>
  <string>{cwd}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
  <key>EnvironmentVariables</key>
  <dict>{env_block}
  </dict>
</dict>
</plist>
"#,
        label = xml_escape(&config.label),
        supervisor = xml_escape(&config.supervisor_executable.to_string_lossy()),
        cwd = xml_escape(&config.action_root.to_string_lossy()),
        stdout = xml_escape(&config.stdout_log_path.to_string_lossy()),
        stderr = xml_escape(&config.stderr_log_path.to_string_lossy()),
    )
}

fn read_supervisor_state_json(config: &Config) -> Option<String> {
    let raw = fs::read_to_string(&config.supervisor_state_path).ok()?;
    let trimmed = raw.trim();
    if trimmed.starts_with('{') && trimmed.ends_with('}') { Some(trimmed.to_string()) } else { None }
}

fn write_supervisor_state(config: &Config, started_at_ms: u128, companion_pid: Option<u32>, companion_state: &str, restart_count: u32) -> Result<(), String> {
    fs::create_dir_all(&config.runtime_directory).map_err(|error| error.to_string())?;
    let payload = format!(
        "{{\"schemaVersion\":1,\"supervisorPid\":{},\"startedAtMs\":{},\"companionPid\":{},\"companionState\":{},\"restartCount\":{},\"updatedAtMs\":{}}}\n",
        std::process::id(),
        started_at_ms,
        json_opt_u32(companion_pid),
        json_string(companion_state),
        restart_count,
        epoch_ms(),
    );
    let temporary_path = config.supervisor_state_path.with_extension("json.tmp");
    fs::write(&temporary_path, payload).map_err(|error| error.to_string())?;
    fs::rename(&temporary_path, &config.supervisor_state_path).map_err(|error| error.to_string())
}

fn epoch_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|duration| duration.as_millis()).unwrap_or(0)
}

#[derive(Debug)]
struct CommandOutput {
    status: i32,
    stdout: String,
    stderr: String,
}

fn run_command(command: &str, args: &[&str]) -> Result<CommandOutput, String> {
    let output = Command::new(command).args(args).output().map_err(|error| format!("{command}: {error}"))?;
    Ok(CommandOutput {
        status: output.status.code().unwrap_or(1),
        stdout: String::from_utf8_lossy(&output.stdout).trim().to_string(),
        stderr: String::from_utf8_lossy(&output.stderr).trim().to_string(),
    })
}

fn run_command_checked(command: &str, args: &[&str]) -> Result<CommandOutput, String> {
    let output = run_command(command, args)?;
    if output.status == 0 { Ok(output) } else { Err(first_nonempty(&output.stderr, &output.stdout)) }
}

fn parse_launchctl_u32(raw: &str, prefix: &str) -> Option<u32> {
    parse_launchctl_string(raw, prefix).and_then(|value| value.parse::<u32>().ok())
}

fn parse_launchctl_i32(raw: &str, prefix: &str) -> Option<i32> {
    parse_launchctl_string(raw, prefix).and_then(|value| value.parse::<i32>().ok())
}

fn parse_launchctl_string(raw: &str, prefix: &str) -> Option<String> {
    raw.lines().map(str::trim).find_map(|line| line.strip_prefix(prefix).map(|value| value.trim().to_string()))
}

fn command_available(command: &str) -> bool {
    if command.contains('/') {
        Path::new(command).exists()
    } else {
        run_command("which", &[command]).map(|output| output.status == 0).unwrap_or(false)
    }
}

fn env_nonempty(name: &str) -> Option<String> {
    env::var(name).ok().map(|value| value.trim().to_string()).filter(|value| !value.is_empty())
}

fn is_tmp_path(path: &Path) -> bool {
    let value = path.to_string_lossy();
    value == "/tmp" || value == "/private/tmp" || value.starts_with("/tmp/") || value.starts_with("/private/tmp/")
}

fn non_tmp_path_or_default(value: Option<PathBuf>, fallback: PathBuf) -> PathBuf {
    match value {
        Some(path) if !is_tmp_path(&path) => path,
        _ => fallback,
    }
}

fn launch_agent_path_env() -> String {
    let mut entries = Vec::new();
    if let Ok(home) = home_dir() {
        entries.push(home.join(".bun/bin").to_string_lossy().to_string());
    }
    entries.extend(env::var("PATH").unwrap_or_default().split(':').map(str::to_string));
    entries.extend([
        "/opt/homebrew/bin".to_string(),
        "/usr/local/bin".to_string(),
        "/usr/bin".to_string(),
        "/bin".to_string(),
        "/usr/sbin".to_string(),
        "/sbin".to_string(),
    ]);

    let mut seen = HashSet::new();
    entries
        .into_iter()
        .filter(|entry| !entry.is_empty() && !is_tmp_path(Path::new(entry)))
        .filter(|entry| seen.insert(entry.clone()))
        .collect::<Vec<_>>()
        .join(":")
}

fn home_dir() -> Result<PathBuf, String> {
    env_nonempty("HOME").map(PathBuf::from).ok_or_else(|| "HOME is not set".to_string())
}

fn user_id() -> Result<u32, String> {
    if let Some(uid) = env_nonempty("UID").and_then(|value| value.parse::<u32>().ok()) {
        return Ok(uid);
    }
    let output = run_command_checked("id", &["-u"])?;
    output.stdout.parse::<u32>().map_err(|error| error.to_string())
}

fn find_action_root(start: &Path) -> Option<PathBuf> {
    let mut current = start.to_path_buf();
    loop {
        let package_json = current.join("package.json");
        let companion = current.join("packages/companion/src/server.ts");
        if package_json.exists() && companion.exists() {
            return Some(current);
        }
        if !current.pop() {
            return None;
        }
    }
}

fn path_str(path: &Path) -> Result<&str, String> {
    path.to_str().ok_or_else(|| format!("path is not valid UTF-8: {}", path.display()))
}

fn first_nonempty(first: &str, second: &str) -> String {
    if !first.trim().is_empty() { first.trim().to_string() } else { second.trim().to_string() }
}

fn print_help() {
    println!("action-supervisor <status|start|stop|restart|doctor|supervise> [--json]\n\nFirst native supervisor slice for the Action companion.");
}

fn print_status(status: &ServiceStatus, json: bool) {
    if json {
        println!("{}", status_json(status));
    } else {
        println!("label: {}", status.config.label);
        println!("loaded: {}", yes_no(status.launchctl.loaded));
        println!("pid: {}", status.launchctl.pid.map(|pid| pid.to_string()).unwrap_or_else(|| "-".to_string()));
        println!("launchd state: {}", status.launchctl.launchd_state.as_deref().unwrap_or("-"));
        println!("supervisor state: {}", if status.supervisor_state.is_some() { "recorded" } else { "missing" });
        println!("companion socket: {}", status.config.companion_socket_path.display());
        println!("reachable: {}", yes_no(status.health.reachable));
        println!("health: {}", if status.health.ok { "ok" } else { "unhealthy" });
    }
}

fn print_doctor(report: &DoctorReport, json: bool) {
    if json {
        println!("{}", doctor_json(report));
    } else {
        print_status(&report.status, false);
        if report.warnings.is_empty() {
            println!("warnings: none");
        } else {
            println!("warnings:");
            for warning in &report.warnings {
                println!("- {warning}");
            }
        }
        println!("processes: {}", report.processes.len());
    }
}

fn status_json(status: &ServiceStatus) -> String {
    format!(
        "{{\"label\":{},\"launchAgentPath\":{},\"supervisorExecutable\":{},\"supervisorStatePath\":{},\"supervisorState\":{},\"actionRoot\":{},\"companionUrl\":{},\"companionSocketPath\":{},\"loaded\":{},\"pid\":{},\"launchdState\":{},\"lastExitStatus\":{},\"reachable\":{},\"health\":{},\"healthTransport\":{},\"healthStatusCode\":{},\"healthBody\":{},\"healthError\":{}}}",
        json_string(&status.config.label),
        json_string(&status.config.launch_agent_path.to_string_lossy()),
        json_string(&status.config.supervisor_executable.to_string_lossy()),
        json_string(&status.config.supervisor_state_path.to_string_lossy()),
        status.supervisor_state.as_deref().unwrap_or("null"),
        json_string(&status.config.action_root.to_string_lossy()),
        json_string(&status.config.companion_url),
        json_string(&status.config.companion_socket_path.to_string_lossy()),
        status.launchctl.loaded,
        json_opt_u32(status.launchctl.pid),
        json_opt_str(status.launchctl.launchd_state.as_deref()),
        json_opt_i32(status.launchctl.last_exit_status),
        status.health.reachable,
        status.health.ok,
        json_opt_str(status.health.transport.as_deref()),
        json_opt_u16(status.health.status_code),
        json_opt_str(status.health.body.as_deref()),
        json_opt_str(status.health.error.as_deref()),
    )
}

fn doctor_json(report: &DoctorReport) -> String {
    let warnings = report.warnings.iter().map(|warning| json_string(warning)).collect::<Vec<_>>().join(",");
    let processes = report.processes.iter().map(process_json).collect::<Vec<_>>().join(",");
    format!("{{\"status\":{},\"warnings\":[{}],\"processes\":[{}]}}", status_json(&report.status), warnings, processes)
}

fn process_json(process: &ProcessInfo) -> String {
    format!(
        "{{\"pid\":{},\"ppid\":{},\"pcpu\":{},\"pmem\":{},\"elapsed\":{},\"command\":{}}}",
        process.pid,
        process.ppid,
        json_string(&process.pcpu),
        json_string(&process.pmem),
        json_string(&process.elapsed),
        json_string(&process.command),
    )
}

fn yes_no(value: bool) -> &'static str {
    if value { "yes" } else { "no" }
}

fn json_opt_str(value: Option<&str>) -> String {
    value.map(json_string).unwrap_or_else(|| "null".to_string())
}

fn json_opt_u16(value: Option<u16>) -> String {
    value.map(|number| number.to_string()).unwrap_or_else(|| "null".to_string())
}

fn json_opt_u32(value: Option<u32>) -> String {
    value.map(|number| number.to_string()).unwrap_or_else(|| "null".to_string())
}

fn json_opt_i32(value: Option<i32>) -> String {
    value.map(|number| number.to_string()).unwrap_or_else(|| "null".to_string())
}

fn json_string(value: &str) -> String {
    format!("\"{}\"", json_escape(value))
}

fn json_escape(value: &str) -> String {
    let mut escaped = String::new();
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            character if character.is_control() => escaped.push_str(&format!("\\u{:04x}", character as u32)),
            character => escaped.push(character),
        }
    }
    escaped
}

fn xml_escape(value: &str) -> String {
    value.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;").replace('\'', "&apos;")
}

// Status/doctor/stop must remain usable even if Bun was removed after startup.
fn validate_bun(config: &Config) -> Result<(), String> {
    match &config.bun_resolution_error {
        Some(error) => Err(error.clone()),
        None => Ok(()),
    }
}

// Resolve before writing launchd configuration: GUI environments omit shell PATH.
fn resolve_bun(
    home: &Path,
    explicit: Option<&str>,
    path: &str,
    executable: impl Fn(&Path) -> bool,
) -> Result<String, String> {
    let search = |name: &str| -> Option<PathBuf> {
        env::split_paths(path)
            .filter(|directory| directory.is_absolute())
            .map(|directory| directory.join(name))
            .find(|candidate| executable(candidate))
    };
    if let Some(value) = explicit {
        let candidate = if Path::new(value).is_absolute() {
            Some(PathBuf::from(value))
        } else if !value.contains('/') {
            search(value)
        } else {
            None
        };
        return candidate.filter(|candidate| executable(candidate))
            .map(|candidate| candidate.to_string_lossy().into_owned())
            .ok_or_else(|| format!("ACTION_BUN_BIN is not an executable file: {value}"));
    }
    let candidates = [
        home.join(".bun/bin/bun"),
        PathBuf::from("/opt/homebrew/bin/bun"),
        PathBuf::from("/usr/local/bin/bun"),
    ];
    search("bun").or_else(|| candidates.into_iter().find(|candidate| executable(candidate)))
        .map(|candidate| candidate.to_string_lossy().into_owned())
        .ok_or_else(|| "Bun was not found. Install Bun or set ACTION_BUN_BIN to its absolute executable path.".to_string())
}

fn executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path).is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

#[cfg(test)]
mod bun_tests {
    use super::*;

    #[test]
    fn resolves_bun_without_shell_path() {
        let result = resolve_bun(Path::new("/Users/test"), None, "/usr/bin:/bin", |path| path == Path::new("/Users/test/.bun/bin/bun"));
        assert_eq!(result.unwrap(), "/Users/test/.bun/bin/bun");
    }

    #[test]
    fn supports_homebrew_and_path_installations() {
        for expected in ["/opt/homebrew/bin/bun", "/usr/local/bin/bun", "/custom/bin/bun"] {
            let result = resolve_bun(Path::new("/Users/test"), None, "/custom/bin:/usr/bin", |path| path == Path::new(expected));
            assert_eq!(result.unwrap(), expected);
        }
    }

    #[test]
    fn rejects_bad_override_instead_of_silently_selecting_another_bun() {
        let result = resolve_bun(Path::new("/Users/test"), Some("/missing/bun"), "/bin", |path| path == Path::new("/bin/bun"));
        assert!(result.unwrap_err().contains("ACTION_BUN_BIN"));
    }

    #[test]
    fn fails_early_when_bun_is_missing_and_ignores_relative_path_entries() {
        let result = resolve_bun(Path::new("/Users/test"), None, ".:relative", |path| !path.is_absolute());
        assert!(result.unwrap_err().contains("Bun was not found"));
    }
}
