import { createFastActions } from "./fast-actions.js";
import type {
  ActionMessage,
  ActionResponse,
  ElementDescriptor,
  MidjourneyResult,
  MidjourneyState,
  TargetQuery,
} from "./messages.js";

declare const chrome: {
  runtime: {
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
};

const fastActions = createFastActions(document, setElementValue);

const companionGlobal = globalThis as { __ACTION_CHROME_COMPANION_LOADED__?: boolean };

if (!companionGlobal.__ACTION_CHROME_COMPANION_LOADED__) {
  companionGlobal.__ACTION_CHROME_COMPANION_LOADED__ = true;
  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    const response = handleMessage(message);
    Promise.resolve(response).then(sendResponse, error => sendResponse({ ok: false, error: String(error) }));
    return true;
  });
}

const defaultObserveSelector = [
  "a[href]",
  "button",
  "input",
  "select",
  "textarea",
  "[role]",
  "[tabindex]",
  "[contenteditable='true']",
  "[contenteditable='plaintext-only']"
].join(",");

function handleMessage(message: unknown): ActionResponse | Promise<ActionResponse> {
  if (!isActionMessage(message)) {
    return { ok: false, error: "Unsupported Action companion message." };
  }

  try {
    switch (message.method) {
      case "action.fast.observe":
        return { ok: true, result: fastActions.observe() };
      case "action.fast.act":
        return fastActions.act(message.params).then(result => ({ ok: true as const, result }));
      case "action.observe":
        return { ok: true, result: observe(message.params) };
      case "action.resolve":
        return { ok: true, result: describe(resolveElement(message.params)) };
      case "action.setValue":
        return { ok: true, result: setValue(message.params, message.params.value) };
      case "action.click":
        return { ok: true, result: clickElement(message.params) };
      case "action.rect":
        return { ok: true, result: describe(resolveElement(message.params))?.rect ?? null };
      case "midjourney.observe":
        return { ok: true, result: observeMidjourney() };
      case "midjourney.setPrompt":
        return { ok: true, result: setMidjourneyPrompt(message.params.prompt) };
      case "midjourney.submitPrompt":
        return { ok: true, result: submitMidjourneyPrompt(message.params?.prompt) };
      case "midjourney.readResults":
        return { ok: true, result: readMidjourneyResults() };
      case "action.tabs.query":
      case "action.tabs.ensure":
        return { ok: false, error: `${message.method} must be handled by the extension service worker.` };
    }
  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : String(error)
    };
  }
}

function observe(query: (TargetQuery & { limit?: number }) | undefined) {
  const selector = query?.selector ?? defaultObserveSelector;
  const limit = query?.limit ?? 50;
  const elements = Array.from(document.querySelectorAll<HTMLElement>(selector))
    .filter(isVisible)
    .slice(0, limit)
    .map(describe)
    .filter((descriptor): descriptor is ElementDescriptor => descriptor !== null);

  return {
    url: location.href,
    title: document.title,
    activeElement: describe(document.activeElement),
    elements
  };
}

function observeMidjourney(): MidjourneyState {
  assertMidjourney();
  return {
    url: location.href,
    title: document.title,
    prompt: describe(findMidjourneyPromptElement()),
    statusTexts: readMidjourneyStatusTexts(),
    results: readMidjourneyResults(),
  };
}

function setMidjourneyPrompt(prompt: string): ElementDescriptor {
  assertMidjourney();
  const element = findMidjourneyPromptElement();
  setElementValue(element, prompt);
  const descriptor = describe(element);
  if (!descriptor) {
    throw new Error("Midjourney prompt element could not be described after value set.");
  }
  return descriptor;
}

function submitMidjourneyPrompt(prompt?: string) {
  assertMidjourney();
  const element = findMidjourneyPromptElement();
  if (prompt !== undefined) {
    setElementValue(element, prompt);
  }

  const submitButton = findMidjourneySubmitButton(element);
  if (!submitButton) {
    throw new Error("Could not resolve Midjourney submit button; refusing to synthesize global keyboard input.");
  }

  submitButton.click();
  return {
    prompt: describe(element),
    submittedWith: "dom-button",
    submitButton: describe(submitButton),
  };
}

function readMidjourneyResults(): MidjourneyResult[] {
  assertMidjourney();
  return Array.from(document.querySelectorAll<HTMLAnchorElement>("a[href*='/jobs/']"))
    .filter(isVisible)
    .map((link) => {
      const rect = link.getBoundingClientRect();
      const image = link.querySelector<HTMLImageElement>("img");
      return {
        href: absoluteURL(link.href),
        imageUrl: image?.currentSrc || image?.src || null,
        text: normalizedText(link),
        rect: {
          x: rect.x,
          y: rect.y,
          width: rect.width,
          height: rect.height
        }
      };
    })
    .filter((result) => result.rect.width > 24 && result.rect.height > 24);
}

function readMidjourneyStatusTexts(): string[] {
  const texts = Array.from(document.querySelectorAll<HTMLElement>("body *"))
    .filter(isVisible)
    .map((element) => normalizedText(element))
    .filter((text) => /starting|submitting|waiting|\d+%\s*complete|relax|fast|draft/i.test(text));
  return [...new Set(texts)].slice(0, 12);
}

function findMidjourneyPromptElement(): HTMLElement {
  const candidates = Array.from(
    document.querySelectorAll<HTMLElement>(
      [
        "textarea",
        "input[type='text']",
        "[contenteditable='true']",
        "[contenteditable='plaintext-only']",
        "[role='textbox']"
      ].join(",")
    )
  )
    .filter(isVisible)
    .map((element) => ({ element, score: scorePromptElement(element) }))
    .filter((candidate) => candidate.score > 0)
    .sort((a, b) => b.score - a.score);

  const match = candidates[0]?.element;
  if (!match) {
    throw new Error("Could not resolve Midjourney prompt input.");
  }
  return match;
}

function scorePromptElement(element: HTMLElement): number {
  const text = [
    element.getAttribute("aria-label"),
    element.getAttribute("placeholder"),
    element.getAttribute("name"),
    element.textContent,
  ].filter(Boolean).join(" ").toLowerCase();
  const rect = element.getBoundingClientRect();
  let score = 0;

  if (/imagine|prompt|what will you/i.test(text)) {
    score += 100;
  }
  if (element instanceof HTMLTextAreaElement || element.getAttribute("role") === "textbox") {
    score += 30;
  }
  if (rect.width > 240) {
    score += 20;
  }
  if (rect.y < window.innerHeight * 0.35 || rect.y > window.innerHeight * 0.65) {
    score += 8;
  }

  return score;
}

function findMidjourneySubmitButton(editor: HTMLElement): HTMLButtonElement | null {
  const editorRect = editor.getBoundingClientRect();
  const roots = ancestorChain(editor).slice(0, 8);
  const buttons = roots
    .flatMap((root) => Array.from(root.querySelectorAll<HTMLButtonElement>("button")))
    .filter((button, index, list) => list.indexOf(button) === index)
    .filter(isVisible)
    .filter((button) => !button.disabled)
    .map((button) => ({ button, score: scoreSubmitButton(button, editorRect) }))
    .filter((candidate) => candidate.score > 0)
    .sort((a, b) => b.score - a.score);

  return buttons[0]?.button ?? null;
}

function scoreSubmitButton(button: HTMLButtonElement, editorRect: DOMRect): number {
  const rect = button.getBoundingClientRect();
  const label = [
    button.innerText,
    button.getAttribute("aria-label"),
    button.getAttribute("title"),
    button.getAttribute("data-testid"),
  ].filter(Boolean).join(" ").toLowerCase();

  let score = 0;
  const verticalOverlap = rect.bottom >= editorRect.top && rect.top <= editorRect.bottom;
  const nearRightEdge = rect.left >= editorRect.right - 100 && rect.left <= editorRect.right + 140;

  if (/send|submit|create|imagine|generate/.test(label)) {
    score += 120;
  }
  if (verticalOverlap) {
    score += 35;
  }
  if (nearRightEdge) {
    score += 60;
  }
  if (button.querySelector("svg")) {
    score += 12;
  }

  return score;
}

function resolveElement(query: TargetQuery | undefined): HTMLElement | null {
  const candidates = getCandidates(query);
  const index = query?.index ?? 0;
  return candidates[index] ?? null;
}

function getCandidates(query: TargetQuery | undefined): HTMLElement[] {
  if (!query || Object.keys(query).length === 0) {
    return document.activeElement instanceof HTMLElement ? [document.activeElement] : [];
  }

  const selector = query.selector ?? selectorForQuery(query);
  const rootCandidates = selector
    ? Array.from(document.querySelectorAll<HTMLElement>(selector))
    : Array.from(document.querySelectorAll<HTMLElement>(defaultObserveSelector));

  return rootCandidates.filter((element) => {
    if (!isVisible(element)) {
      return false;
    }

    if (query.text && !normalizedText(element).includes(normalize(query.text))) {
      return false;
    }

    if (query.role && element.getAttribute("role") !== query.role) {
      return false;
    }

    if (query.testId && element.getAttribute("data-testid") !== query.testId) {
      return false;
    }

    return true;
  });
}

function selectorForQuery(query: TargetQuery): string | null {
  if (query.testId) {
    return `[data-testid="${cssEscape(query.testId)}"]`;
  }

  if (query.role) {
    return `[role="${cssEscape(query.role)}"]`;
  }

  return null;
}

function setValue(query: TargetQuery, value: string) {
  const element = resolveElement(query);

  if (!element) {
    throw new Error("No element matched setValue target.");
  }

  setElementValue(element, value);
  return describe(element);
}

function setElementValue(element: HTMLElement, value: string) {
  if (
    element instanceof HTMLInputElement ||
    element instanceof HTMLTextAreaElement ||
    element instanceof HTMLSelectElement
  ) {
    element.focus();
    setNativeValue(element, value);
    element.dispatchEvent(new InputEvent("input", { bubbles: true, data: value, inputType: "insertText" }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
    return;
  }

  if (element.isContentEditable || element.getAttribute("role") === "textbox") {
    element.focus();
    selectElementContents(element);
    if (!document.execCommand("insertText", false, value)) {
      element.textContent = value;
    }
    element.dispatchEvent(new InputEvent("input", { bubbles: true, data: value, inputType: "insertText" }));
    return;
  }

  throw new Error("Matched element does not accept text values.");
}

function clickElement(query: TargetQuery | undefined) {
  const element = resolveElement(query);

  if (!element) {
    throw new Error("No element matched click target.");
  }

  element.scrollIntoView({ block: "center", inline: "center" });
  element.click();
  return describe(element);
}

function describe(element: Element | null): ElementDescriptor | null {
  if (!(element instanceof HTMLElement)) {
    return null;
  }

  const rect = element.getBoundingClientRect();

  return {
    selector: stableSelector(element),
    tagName: element.tagName.toLowerCase(),
    text: normalizedText(element),
    role: element.getAttribute("role"),
    testId: element.getAttribute("data-testid"),
    name: element.getAttribute("aria-label") ?? element.getAttribute("name") ?? element.getAttribute("placeholder"),
    value: valueFor(element),
    rect: {
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height
    }
  };
}

function stableSelector(element: HTMLElement): string | null {
  if (element.id) {
    return `#${cssEscape(element.id)}`;
  }

  const testId = element.getAttribute("data-testid");
  if (testId) {
    return `[data-testid="${cssEscape(testId)}"]`;
  }

  const role = element.getAttribute("role");
  if (role) {
    return `${element.tagName.toLowerCase()}[role="${cssEscape(role)}"]`;
  }

  return element.tagName.toLowerCase();
}

function valueFor(element: HTMLElement): string | null {
  if (
    element instanceof HTMLInputElement ||
    element instanceof HTMLTextAreaElement ||
    element instanceof HTMLSelectElement
  ) {
    return element.value;
  }

  if (element.isContentEditable || element.getAttribute("role") === "textbox") {
    return element.textContent;
  }

  return null;
}

function isVisible(element: HTMLElement): boolean {
  const style = getComputedStyle(element);
  const rect = element.getBoundingClientRect();

  return (
    style.visibility !== "hidden" &&
    style.display !== "none" &&
    rect.width > 0 &&
    rect.height > 0
  );
}

function normalizedText(element: HTMLElement): string {
  return normalize(
    element.innerText ||
      element.textContent ||
      element.getAttribute("aria-label") ||
      element.getAttribute("title") ||
      element.getAttribute("placeholder") ||
      ""
  );
}

function normalize(value: string): string {
  return value.replace(/\s+/g, " ").trim().toLowerCase();
}

function cssEscape(value: string): string {
  return typeof CSS === "undefined" ? value.replace(/"/g, '\\"') : CSS.escape(value);
}

function assertMidjourney() {
  if (!location.hostname.endsWith("midjourney.com")) {
    throw new Error(`Current page is not Midjourney: ${location.href}`);
  }
}

function ancestorChain(element: HTMLElement): HTMLElement[] {
  const ancestors: HTMLElement[] = [];
  let current: HTMLElement | null = element;
  while (current) {
    ancestors.push(current);
    current = current.parentElement;
  }
  return ancestors;
}

function setNativeValue(
  element: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement,
  value: string
) {
  const prototype = Object.getPrototypeOf(element) as HTMLElement;
  const setter = Object.getOwnPropertyDescriptor(prototype, "value")?.set;
  if (setter) {
    setter.call(element, value);
  } else {
    element.value = value;
  }
}

function selectElementContents(element: HTMLElement) {
  const selection = window.getSelection();
  const range = document.createRange();
  range.selectNodeContents(element);
  selection?.removeAllRanges();
  selection?.addRange(range);
}

function absoluteURL(value: string): string | null {
  try {
    return new URL(value, location.href).href;
  } catch {
    return null;
  }
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
