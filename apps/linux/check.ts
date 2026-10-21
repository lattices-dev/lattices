import { existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

if (process.platform !== "linux") throw new Error("The Linux app checks require Qt 6 on Linux.");
const root = fileURLToPath(new URL("../../", import.meta.url));
const visualFiles = [
  "Theme", "BrandMark", "Symbol", "ShellChrome", "shell", "OverviewPage", "MissionControlPage", "OperatorConsolePage",
  "DeckButton", "SpaceCell", "KeyBar", "KeyCap", "Tag", "DeckLabel", "SectionHeader",
  "PlacementGlyph", "Brackets", "LatticeGrid", "NavRow", "InputField", "ActionButton", "WindowRow", "WorkspaceCanvas",
  "VirtualSpaceView", "VirtualPreviewSession", "VirtualViewer", "VirtualViewerWindow",
].map(name => `apps/linux/${name}.qml`);
for (const [name, args] of [
  ["qmllint", visualFiles],
  ["qmltestrunner", ["-input", "apps/linux/test", "-o", "-,txt"]],
] as const) {
  const command = Bun.which(name) || ["/usr/lib/qt6/bin/", "/usr/lib64/qt6/bin/"].map(dir => dir + name).find(existsSync);
  if (!command) throw new Error(`Install the Qt 6 declarative tools (${name}) to check the Linux app.`);
  const result = spawnSync(command, [...args], {
    cwd: root, stdio: "inherit",
    env: { ...process.env, QT_QPA_PLATFORM: "offscreen", QT_QPA_PLATFORMTHEME: "none", QT_QUICK_BACKEND: "software" },
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
