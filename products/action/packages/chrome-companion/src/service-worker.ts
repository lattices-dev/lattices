import type {
  ActionMessage,
  ActionResponse,
  BrowserSurfaceTarget,
  BrowserTabDescriptor,
} from "./messages.js";

type ChromeTab = {
  id?: number;
  windowId: number;
  active: boolean;
  url?: string;
  title?: string;
};

declare const chrome: {
  runtime: {
    lastError?: { message?: string };
    getURL: (path: string) => string;
    onInstalled?: { addListener: (callback: () => void) => void };
    onStartup?: { addListener: (callback: () => void) => void };
    onMessage: {
      addListener: (
        callback: (
          message: unknown,
          sender: unknown,
          sendResponse: (response: ActionResponse) => void
        ) => boolean | void
      ) => void;
    };
  };
  windows: { update: (windowId: number, properties: { focused: boolean }, callback: () => void) => void };
  scripting: {
    executeScript: (
      details:
        | { target: { tabId: number }; files: string[] }
        | { target: { tabId: number }; func: () => boolean },
      callback: (result?: Array<{ result?: boolean }>) => void
    ) => void;
  };
  tabs: {
    create: (
      createProperties: { url: string; active?: boolean },
      callback: (tab: ChromeTab) => void
    ) => void;
    query: (
      queryInfo: { active?: boolean; currentWindow?: boolean; url?: string | string[] },
      callback: (tabs: ChromeTab[]) => void
    ) => void;
    sendMessage: (
      tabId: number,
      message: ActionMessage,
      callback: (response?: ActionResponse) => void
    ) => void;
    update: (
      tabId: number,
      updateProperties: { active?: boolean; url?: string },
      callback: (tab: ChromeTab) => void
    ) => void;
  };
};

type BridgeRequest = {
  id: string;
  message: ActionMessage;
};

const bridgeURL = "ws://127.0.0.1:4321/chrome-companion";
let bridgeSocket: WebSocket | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | undefined;

chrome.runtime.onInstalled?.addListener(() => {
  connectBridge();
  void ensureBridgePage();
});
chrome.runtime.onStartup?.addListener(() => {
  connectBridge();
  void ensureBridgePage();
});
connectBridge();

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (!isActionMessage(message)) {
    sendResponse({ ok: false, error: "Unsupported Action companion message." });
    return;
  }

  dispatchMessage(message)
    .then(sendResponse)
    .catch((error) => sendResponse({ ok: false, error: errorMessage(error) }));

  return true;
});

function connectBridge() {
  if (bridgeSocket && bridgeSocket.readyState <= WebSocket.OPEN) {
    return;
  }

  bridgeSocket = new WebSocket(bridgeURL);
  bridgeSocket.addEventListener("open", () => {
    bridgeSocket?.send(JSON.stringify({ type: "hello", name: "Action Chrome Companion" }));
  });
  bridgeSocket.addEventListener("message", (event) => {
    void handleBridgeMessage(event.data);
  });
  bridgeSocket.addEventListener("close", scheduleReconnect);
  bridgeSocket.addEventListener("error", scheduleReconnect);
}

function scheduleReconnect() {
  bridgeSocket = null;
  if (reconnectTimer !== undefined) {
    return;
  }

  reconnectTimer = setTimeout(() => {
    reconnectTimer = undefined;
    connectBridge();
  }, 2000);
}

async function handleBridgeMessage(data: unknown) {
  let request: BridgeRequest;
  try {
    request = JSON.parse(String(data)) as BridgeRequest;
  } catch {
    return;
  }

  const response = isActionMessage(request.message)
    ? await dispatchMessage(request.message).catch((error) => ({ ok: false as const, error: errorMessage(error) }))
    : ({ ok: false as const, error: "Unsupported Action companion message." });

  bridgeSocket?.send(JSON.stringify({ id: request.id, response }));
}

async function dispatchMessage(message: ActionMessage): Promise<ActionResponse> {
  switch (message.method) {
    case "action.tabs.query":
      return { ok: true, result: await queryTabs(message.params) };
    case "action.tabs.ensure":
      return { ok: true, result: await ensureTab(message.params) };
    default:
      return sendToContentScript(message);
  }
}

async function ensureBridgePage(): Promise<void> {
  const bridgePageURL = chrome.runtime.getURL("bridge.html");
  const existing = await queryTabs({ url: bridgePageURL });
  if (existing.length > 0) {
    return;
  }

  await createTab(bridgePageURL, false);
}

async function sendToContentScript(message: ActionMessage): Promise<ActionResponse> {
  const target = surfaceTargetFor(message);
  if ((message.method === "action.fast.observe" || message.method === "action.fast.act") &&
      (!Number.isSafeInteger(target?.tabId) || (target?.tabId ?? -1) < 0)) {
    return { ok: false, error: "Fast actions require an explicit tabId." };
  }
  const tab = await ensureTab(target);

  if (tab.id === undefined) {
    return { ok: false, error: "Resolved Chrome tab does not have an id." };
  }

  await ensureContentScript(tab.id);
  return sendTabMessage(tab.id, message);
}

async function queryTabs(target: BrowserSurfaceTarget | undefined): Promise<BrowserTabDescriptor[]> {
  const tabs = await allTabs();
  return tabs.filter((tab) => tabMatchesTarget(tab, target)).map(describeTab);
}

async function ensureTab(target: BrowserSurfaceTarget | undefined): Promise<BrowserTabDescriptor> {
  if (target?.tabId !== undefined) {
    const tabs = await allTabs();
    const tab = tabs.find((candidate) => candidate.id === target.tabId);
    if (!tab) {
      throw new Error(`No Chrome tab found for id ${target.tabId}.`);
    }
    return describeTab(await maybeActivateTab(tab, target.activate));
  }

  const tabs = await allTabs();
  const existing = tabs.find((tab) => tabMatchesTarget(tab, target));
  if (existing) {
    return describeTab(await maybeActivateTab(existing, target?.activate));
  }

  const createUrl = target?.createUrl ?? target?.url;
  if (!createUrl) {
    throw new Error("No Chrome tab matched the requested surface.");
  }

  const created = await createTab(createUrl, target?.activate ?? false);
  return describeTab(created);
}

async function ensureContentScript(tabId: number): Promise<void> {
  const loaded = await executeScript(tabId, {
    func: () => Boolean((globalThis as { __ACTION_CHROME_COMPANION_LOADED__?: boolean }).__ACTION_CHROME_COMPANION_LOADED__),
  }).catch(() => false);

  if (loaded) {
    return;
  }

  await executeScript(tabId, { files: ["content-script.js"] });
}

function surfaceTargetFor(message: ActionMessage): BrowserSurfaceTarget | undefined {
  const params = (message as { params?: { surface?: BrowserSurfaceTarget } }).params;
  return params?.surface;
}

function allTabs(): Promise<ChromeTab[]> {
  return new Promise((resolve) => {
    chrome.tabs.query({}, (tabs) => resolve(tabs));
  });
}

function createTab(url: string, active: boolean): Promise<ChromeTab> {
  return new Promise((resolve, reject) => {
    chrome.tabs.create({ url, active }, (tab) => {
      const error = chrome.runtime.lastError;
      if (error) {
        reject(new Error(error.message ?? "Failed to create Chrome tab."));
        return;
      }
      resolve(tab);
    });
  });
}

function maybeActivateTab(tab: ChromeTab, activate: boolean | undefined): Promise<ChromeTab> {
  if (!activate || tab.id === undefined) {
    return Promise.resolve(tab);
  }

  return new Promise((resolve, reject) => {
    chrome.tabs.update(tab.id!, { active: true }, (updated) => {
      const error = chrome.runtime.lastError;
      if (error) {
        reject(new Error(error.message ?? "Failed to activate Chrome tab."));
        return;
      }
      chrome.windows.update(updated.windowId, { focused: true }, () => {
        const focusError = chrome.runtime.lastError;
        if (focusError) reject(new Error(focusError.message ?? "Failed to focus Chrome window."));
        else resolve(updated);
      });
    });
  });
}

function sendTabMessage(tabId: number, message: ActionMessage): Promise<ActionResponse> {
  return new Promise((resolve) => {
    chrome.tabs.sendMessage(tabId, message, (response) => {
      const error = chrome.runtime.lastError;
      if (error) {
        resolve({ ok: false, error: error.message ?? "No content script response." });
        return;
      }
      resolve(response ?? { ok: false, error: "No content script response." });
    });
  });
}

function executeScript(
  tabId: number,
  details: { files: string[] } | { func: () => boolean }
): Promise<boolean> {
  return new Promise((resolve, reject) => {
    chrome.scripting.executeScript({ target: { tabId }, ...details }, (result) => {
      const error = chrome.runtime.lastError;
      if (error) {
        reject(new Error(error.message ?? "Failed to inject Action content script."));
        return;
      }
      resolve(Boolean(result?.[0]?.result));
    });
  });
}

function tabMatchesTarget(tab: ChromeTab, target: BrowserSurfaceTarget | undefined): boolean {
  if (!target || Object.keys(target).length === 0) {
    return tab.active;
  }

  if (target.tabId !== undefined) {
    return tab.id === target.tabId;
  }

  const url = tab.url ?? "";
  if (target.url && !url.startsWith(target.url)) {
    return false;
  }

  if (target.urlMatches?.length) {
    return target.urlMatches.some((pattern) => wildcardMatch(url, pattern));
  }

  return Boolean(target.url);
}

function wildcardMatch(value: string, pattern: string): boolean {
  const escaped = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
  return new RegExp(`^${escaped}$`).test(value);
}

function describeTab(tab: ChromeTab): BrowserTabDescriptor {
  if (tab.id === undefined) {
    throw new Error("Chrome tab is missing an id.");
  }

  return {
    id: tab.id,
    windowId: tab.windowId,
    active: tab.active,
    url: tab.url ?? null,
    title: tab.title ?? null,
  };
}

function isActionMessage(message: unknown): message is ActionMessage {
  if (!message || typeof message !== "object") {
    return false;
  }

  const method = (message as { method?: unknown }).method;
  return (
    method === "action.tabs.query" ||
    method === "action.tabs.ensure" ||
    method === "action.fast.observe" ||
    method === "action.fast.act" ||
    method === "action.observe" ||
    method === "action.resolve" ||
    method === "action.setValue" ||
    method === "action.click" ||
    method === "action.rect" ||
    method === "midjourney.observe" ||
    method === "midjourney.setPrompt" ||
    method === "midjourney.submitPrompt" ||
    method === "midjourney.readResults"
  );
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
