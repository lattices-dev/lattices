import type { CheckedRunner, CommandResult, Runner } from "./types.ts";

export async function activateInstall(launcher: string, checked: CheckedRunner, run: Runner, log: (message: string) => void): Promise<void> {
  // Files are committed now. A service/health failure keeps this usable install
  // and reports recovery; it never claims a healthy desktop or rolls back data.
  try {
    checked("systemctl", ["--user", "import-environment", "WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE", "XDG_CURRENT_DESKTOP"], 5000);
    checked("systemctl", ["--user", "daemon-reload"], 5000);
    checked("systemctl", ["--user", "enable", "lattices-host.service", "lattices-tray.service"], 10000);
    checked("systemctl", ["--user", "restart", "lattices-host.service", "lattices-tray.service"], 15000);
    let doctor: CommandResult = { status: 1, stdout: "", stderr: "Host has not replied" };
    for (let attempt = 0; attempt < 8; ++attempt) {
      doctor = run(launcher, ["--host", "127.0.0.1:9399", "doctor", "--json"], 10000);
      if (doctor.status === 0) break;
      await Bun.sleep(250);
    }
    if (doctor.status !== 0) throw new Error(doctor.stdout || doctor.stderr);
    const health = JSON.parse(doctor.stdout);
    if (health.ok !== true) throw new Error(doctor.stdout);
    checked(launcher, ["app"], 15000);
    log("Lattices is installed. Host health passed; host and tray start at login. The app was opened.");
  } catch (error) {
    throw new Error(`Files are installed, but activation did not finish: ${(error as Error).message}\nRun lats --host 127.0.0.1:9399 doctor and journalctl --user -u lattices-host -u lattices-tray. Rerun the installer from your Hyprland desktop.`);
  }
}
