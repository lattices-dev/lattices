import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const rootPath = fileURLToPath(new URL("..", import.meta.url));

export const port = Number(process.env.ACTION_CHROME_COMPANION_DEBUG_PORT || 9333);
export const profileName = process.env.ACTION_CHROME_COMPANION_PROFILE || "mira";
export const profileDir = process.env.ACTION_CHROME_COMPANION_PROFILE_DIR ||
  join(process.env.HOME || "", "Library/Application Support/Action/ChromeProfiles", profileName);
export const dist = process.env.ACTION_CHROME_COMPANION_DIST || join(rootPath, "dist");
export const companionName = "Action Chrome Companion";

export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function miraChromePid() {
  const result = spawnSync("pgrep", ["-f", `${profileDir}.*remote-debugging-port=${port}`], {
    encoding: "utf8",
  });
  const pid = result.stdout.trim().split("\n").find(Boolean);
  if (!pid) {
    throw new Error(
      `Could not find mira Chrome process for profile ${profileName} (port ${port}). ` +
      "Launch it with: bun run profile -- launch mira",
    );
  }
  return pid;
}

export function stopMiraChrome() {
  try {
    const pid = miraChromePid();
    spawnSync("kill", [pid]);
    return pid;
  } catch {
    return undefined;
  }
}

export async function launchMira(url = "https://www.midjourney.com/imagine") {
  const launch = spawnSync("bun", ["scripts/profile.mjs", "launch", profileName, "--url", url], {
    cwd: rootPath,
    stdio: "inherit",
  });
  if (launch.status !== 0) {
    throw new Error(`Failed to launch ${profileName} Chrome profile`);
  }
  await sleep(2500);
}

export function osa(script) {
  const result = spawnSync("osascript", ["-e", script], { encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "osascript failed");
  }
  return (result.stdout || "").trim();
}

export function activateMiraProcess(pid) {
  osa(`tell application "System Events"
    set frontmost of (first process whose unix id is ${pid}) to true
  end tell`);
}

export function activateMiraExtensionsWindow(pid) {
  return osa(`tell application "System Events"
    set chromeProc to first process whose unix id is ${pid}
    set frontmost of chromeProc to true
    repeat with win in windows of chromeProc
      if name of win contains "Extensions" then
        perform action "AXRaise" of win
        return name of win
      end if
    end repeat
    return "NO_EXTENSIONS_WINDOW"
  end tell`);
}

export function pickerState(pid) {
  return osa(`tell application "System Events"
    tell (first process whose unix id is ${pid})
      set frontName to name of front window
      if (count of sheets of front window) > 0 then
        return "SHEET|" & frontName
      end if
      repeat with win in windows
        try
          set winName to name of win
          if winName contains "Select" or winName contains "Directory" then
            return "DIALOG|" & winName
          end if
        end try
      end repeat
      return "NONE|" & frontName
    end tell
  end tell`);
}

export function uiState(pid) {
  const result = spawnSync("osascript", ["-e", `tell application "System Events"
    tell (first process whose unix id is ${pid})
      return (name of front window) & " | sheets:" & (count of sheets of front window)
    end tell
  end tell`], { encoding: "utf8" });
  return (result.stdout || result.stderr || "").trim();
}

export function sheetDump(pid) {
  const result = spawnSync("osascript", ["-e", `tell application "System Events"
    tell (first process whose unix id is ${pid})
      if (count of sheets of front window) is 0 then return "NO SHEET"
      set out to "SHEET"
      repeat with e in entire contents of sheet 1 of front window
        try
          set nm to name of e
          if nm is not missing value and nm is not "" then
            set out to out & linefeed & (role of e) & ": " & nm
          end if
        end try
      end repeat
      return out
    end tell
  end tell`], { encoding: "utf8" });
  return (result.stdout || result.stderr || "").trim();
}

export function completePicker(pid, folderPath) {
  osa(`tell application "System Events"
    tell (first process whose unix id is ${pid})
      set frontmost to true
      keystroke "g" using {command down, shift down}
      delay 0.8
      keystroke "${folderPath.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"
      delay 0.3
      keystroke return
      delay 0.4
      keystroke return
    end tell
  end tell`);

  try {
    osa(`tell application "System Events"
      tell (first process whose unix id is ${pid})
        click button "Open" of sheet 1 of front window
      end tell
    end tell`);
  } catch {
    // Return may have already confirmed the picker.
  }
}

export async function fetchJson(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`${url} -> ${response.status}`);
  }
  return response.json();
}

export async function connectCdp(wsUrl) {
  const ws = new WebSocket(wsUrl);
  let id = 1;
  const pending = new Map();
  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.id && pending.has(message.id)) {
      const { resolve, reject } = pending.get(message.id);
      pending.delete(message.id);
      message.error ? reject(new Error(JSON.stringify(message.error))) : resolve(message.result);
    }
  });
  await new Promise((resolve, reject) => {
    ws.addEventListener("open", resolve, { once: true });
    ws.addEventListener("error", reject, { once: true });
  });
  const call = (method, params = {}) => new Promise((resolve, reject) => {
    const messageId = id++;
    pending.set(messageId, { resolve, reject });
    ws.send(JSON.stringify({ id: messageId, method, params }));
  });
  return { call, close: () => ws.close() };
}

export async function listExtensions(call) {
  const result = await call("Runtime.evaluate", {
    expression: `(() => {
      const items = [...document.querySelector("extensions-manager")?.shadowRoot
        ?.querySelector("extensions-item-list")?.shadowRoot
        ?.querySelectorAll("extensions-item") || []];
      return items.map((el) => ({
        name: el.shadowRoot?.querySelector("#name")?.textContent?.trim(),
        id: el.id,
      }));
    })()`,
    returnByValue: true,
  });
  return result.result?.value || [];
}

export async function ensureExtensionsTarget() {
  const pages = await fetchJson(`http://127.0.0.1:${port}/json/list`);
  let page = pages.find((entry) => entry.url?.startsWith("chrome://extensions") && entry.type === "page");
  if (!page) {
    await fetch(`http://127.0.0.1:${port}/json/new?chrome://extensions`, { method: "PUT" });
    await sleep(1200);
    const refreshed = await fetchJson(`http://127.0.0.1:${port}/json/list`);
    page = refreshed.find((entry) => entry.url?.startsWith("chrome://extensions") && entry.type === "page");
  }
  if (!page) {
    throw new Error(`Could not open chrome://extensions in the ${profileName} profile`);
  }
  return page;
}

export async function stageMiraWindow(page, pid) {
  const version = await fetchJson(`http://127.0.0.1:${port}/json/version`);
  const browser = await connectCdp(version.webSocketDebuggerUrl);
  try {
    const { windowId } = await browser.call("Browser.getWindowForTarget", { targetId: page.id });
    await browser.call("Browser.setWindowBounds", {
      windowId,
      bounds: {
        left: 80,
        top: 80,
        width: 1400,
        height: 900,
        windowState: "normal",
      },
    });
  } finally {
    browser.close();
  }

  const cdp = await connectCdp(page.webSocketDebuggerUrl);
  try {
    await cdp.call("Page.bringToFront");
    await sleep(300);
    activateMiraExtensionsWindow(pid);
    await sleep(400);
    return cdp;
  } catch (error) {
    cdp.close();
    throw error;
  }
}

export async function pollPickerAndComplete(pid, folderPath, timeoutMs = 20000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const state = pickerState(pid);
    if (state.startsWith("SHEET|") || state.startsWith("DIALOG|")) {
      completePicker(pid, folderPath);
      return { completed: true, state };
    }
    await sleep(200);
  }
  return { completed: false, state: pickerState(pid) };
}

export async function triggerLoadUnpacked(call) {
  const result = await call("Runtime.evaluate", {
    expression: `(async () => {
      const toolbar = document.querySelector("extensions-manager")?.shadowRoot
        ?.querySelector("extensions-toolbar");
      const devToggle = toolbar?.shadowRoot?.querySelector("#devMode");
      if (devToggle && !devToggle.checked) {
        devToggle.click();
      }
      // The checkbox changes before Chrome has persisted its developer-mode setting.
      // Loading in that interval fails, even though the switch already looks enabled.
      let ready = false;
      for (let attempt = 0; attempt < 50; attempt++) {
        const info = await new Promise(resolve => chrome.developerPrivate.getProfileConfiguration(resolve));
        if (info.inDeveloperMode && info.canLoadUnpacked) { ready = true; break; }
        await new Promise(resolve => setTimeout(resolve, 100));
      }
      if (!ready) throw new Error("Chrome did not enable unpacked extension loading");
      const load = toolbar?.shadowRoot?.querySelector("#loadUnpacked");
      if (!load) throw new Error("Load unpacked button is unavailable");
      load.click();
      return {
        devMode: Boolean(devToggle?.checked),
        clicked: true,
      };
    })()`,
    awaitPromise: true,
    returnByValue: true,
  });
  if (result.exceptionDetails) throw new Error("Chrome could not open the extension directory picker");
  return result.result?.value ?? result;
}

export async function launchMiraExtensions() {
  const launch = spawnSync("bun", ["scripts/profile.mjs", "launch", profileName, "--url", "chrome://extensions"], {
    cwd: rootPath,
    stdio: "inherit",
  });
  if (launch.status !== 0) {
    throw new Error(`Failed to launch ${profileName} Chrome profile`);
  }
  await sleep(2500);
}
