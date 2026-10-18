import { createFastPresentation, type FastPresentationPrefs } from "./fast-presentation.js";
/** Experimental, observation-bound actions. No model-supplied selectors or coordinates. */
export type FastOperation = "CLICK" | "TYPE_TEXT";
export type FastControl = { id: string; role: string; name: string; value: string; operations: FastOperation[] };
export type FastSnapshot = { observationId: string; url: string; title: string; text: string; controls: FastControl[]; observeMs: number };
export type FastChoice = { observationId: string; target: string; operation: FastOperation; text?: string; presentation?: boolean | FastPresentationPrefs };
export type FastReceipt = { status: "executed" | "stale" | "invalid" | "uncertain"; reason?: string; executeMs: number; navigationExpected?: boolean };

const selector = 'a[href],button,input,textarea,[contenteditable="true"],[role="button"],[role="link"]';
const textTypes = new Set(["text", "search", "email", "url", "tel"]);

export function createFastActions(doc: Document, writeText: (element: HTMLElement, text: string) => void) {
  let current: { id: string; page: string; targets: Map<string, { element: HTMLElement; guard: string; control: FastControl }> } | undefined;
  const win = doc.defaultView!;
  const presentation = createFastPresentation(doc);
  const value = (e: HTMLElement) => e instanceof win.HTMLInputElement || e instanceof win.HTMLTextAreaElement ? e.value : e.isContentEditable ? e.textContent ?? "" : "";
  const name = (e: HTMLElement) => {
    const labelled = (e.getAttribute("aria-labelledby") ?? "").split(/\s+/).map(id => doc.getElementById(id)?.textContent ?? "").join(" ").trim();
    const labels = e instanceof win.HTMLInputElement || e instanceof win.HTMLTextAreaElement ? Array.from(e.labels ?? []).map(l => l.textContent).join(" ") : "";
    return (labelled || e.getAttribute("aria-label") || labels || e.innerText || e.getAttribute("placeholder") || "").trim().slice(0, 500);
  };
  const eligible = (e: HTMLElement) => {
    if (!e.isConnected || e.closest('[inert],[aria-hidden="true"],[aria-disabled="true"]') || e.matches(':disabled')) return false;
    const r = e.getBoundingClientRect();
    return e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true }) && r.width > 0 && r.height > 0 && r.x + r.width / 2 >= 0 && r.y + r.height / 2 >= 0 && r.x + r.width / 2 < win.innerWidth && r.y + r.height / 2 < win.innerHeight;
  };
  const operations = (e: HTMLElement): FastOperation[] => {
    if (e.getAttribute("aria-readonly") === "true") return [];
    if (e instanceof win.HTMLInputElement) {
      if (textTypes.has(e.type)) return e.readOnly ? [] : ["TYPE_TEXT"];
      return ["button", "submit", "reset", "checkbox", "radio"].includes(e.type) ? ["CLICK"] : [];
    }
    if (e instanceof win.HTMLTextAreaElement) return e.readOnly ? [] : ["TYPE_TEXT"];
    return e.isContentEditable ? ["TYPE_TEXT"] : ["CLICK"];
  };
  const page = () => JSON.stringify([win.location.href, win.innerWidth, win.innerHeight, win.scrollX, win.scrollY,
    Array.from(doc.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>('input:not([type="password"]):not([type="hidden"]):not([type="file"]),textarea,select')).map(e => [e.value, e instanceof win.HTMLInputElement ? e.checked : null])]);
  const guard = (e: HTMLElement) => JSON.stringify([name(e), value(e), e.getAttribute("role"), e.getAttribute("href"), e.getAttribute("aria-expanded"), e.getAttribute("aria-checked"), e.getAttribute("aria-selected"), operations(e),
    (e.closest('form,dialog,[role="dialog"],li,tr') ?? e.parentElement)?.textContent?.slice(0, 6000)]);

  const visibleText = () => {
    const walker = doc.createTreeWalker(doc.body, 4);
    const parts: string[] = [];
    let length = 0, scanned = 0;
    while (walker.nextNode() && scanned++ < 2000 && length < 6000) {
      const parent = walker.currentNode.parentElement;
      if (!parent || parent.closest('script,style,noscript,[aria-hidden="true"],[inert]') || !eligible(parent)) continue;
      const text = walker.currentNode.textContent?.trim();
      if (text) { parts.push(text); length += text.length; }
    }
    return parts.join(" ").slice(0, 6000);
  };

  return {
    observe(): FastSnapshot {
      const started = performance.now();
      const id = win.crypto.randomUUID();
      const targets = new Map<string, { element: HTMLElement; guard: string; control: FastControl }>();
      for (const element of doc.querySelectorAll<HTMLElement>(selector)) {
        if (targets.size >= 80) break;
        if (!eligible(element)) continue;
        const ops = operations(element);
        if (!ops.length) continue;
        const target = String(targets.size + 1);
        const control = { id: target, role: element.getAttribute("role") ?? element.tagName.toLowerCase(), name: name(element), value: value(element).slice(0, 2000), operations: ops };
        targets.set(target, { element, guard: guard(element), control });
      }
      current = { id, page: page(), targets };
      return { observationId: id, url: win.location.href, title: doc.title, text: visibleText(), controls: [...targets.values()].map(t => t.control), observeMs: performance.now() - started };
    },
    async act(choice: FastChoice): Promise<FastReceipt> {
      const started = performance.now();
      const receipt = (status: FastReceipt["status"], reason?: string): FastReceipt => ({ status, reason, executeMs: performance.now() - started });
      const observed = current;
      // Consume before any mutation. Lost replies and duplicate requests cannot replay input.
      current = undefined;
      if (!choice || !observed || choice.observationId !== observed.id) return receipt("stale", "Observation expired or already consumed.");
      const target = observed.targets.get(choice.target);
      if (!target || !target.control.operations.includes(choice.operation)) return receipt("invalid", "Operation and target were not offered together.");
      if (choice.operation === "TYPE_TEXT" && (typeof choice.text !== "string" || !choice.text.length || choice.text.length > 2000)) return receipt("invalid", "Text must contain 1–2000 characters.");
      const e = target.element;
      if (page() !== observed.page || !eligible(e) || guard(e) !== target.guard) return receipt("stale", "Target or relevant page state changed.");
      const r = e.getBoundingClientRect();
      const hit = doc.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
      if (!hit || !e.contains(hit)) return receipt("stale", "Target is covered.");
      const show = Boolean(choice.presentation);
      if (show) {
        if (typeof choice.presentation === "object") presentation.configure(choice.presentation);
        await presentation.target(e, choice.operation, target.control.name);
        const now = e.getBoundingClientRect();
        const hitNow = doc.elementFromPoint(now.x + now.width / 2, now.y + now.height / 2);
        if (page() !== observed.page || !eligible(e) || guard(e) !== target.guard || !hitNow || !e.contains(hitNow) || Math.abs(now.x-r.x)>1 || Math.abs(now.y-r.y)>1) {
          presentation.finish("Target changed — paused");
          return receipt("stale", "Target changed during presentation.");
        }
      }
      const navigationExpected = choice.operation === "CLICK" && (
        (e instanceof win.HTMLAnchorElement && Boolean(e.href) && e.href.split('#')[0] !== win.location.href.split('#')[0] && (!e.target || e.target === '_self')) ||
        ((e instanceof win.HTMLButtonElement || e instanceof win.HTMLInputElement) && e.type === 'submit' && Boolean(e.form))
      );
      try {
        if (choice.operation === "CLICK") {
          if (show) presentation.pulse();
          e.click();
        } else if (show) {
          // Progressive inserts make typing feedback real: each keystroke tick marks
          // characters that were actually written, never a replayed simulation.
          const text = choice.text!;
          const chunk = 3;
          let index = 0;
          for (let end = chunk; ; end += chunk, index++) {
            if (index > 0 && (!eligible(e) || !operations(e).includes("TYPE_TEXT") || doc.activeElement !== e || value(e) !== text.slice(0, end - chunk) || win.location.href !== JSON.parse(observed.page)[0])) {
              presentation.finish("Typing interrupted — paused");
              return receipt("uncertain", "Field changed after partial input; inspect before continuing.");
            }
            writeText(e, text.slice(0, Math.min(end, text.length)));
            presentation.keystroke(index);
            if (end >= text.length) break;
            await new Promise(resolve => setTimeout(resolve, 45));
          }
        } else {
          writeText(e, choice.text!);
        }
        if (show) presentation.finish("Input sent");
        return { ...receipt("executed"), navigationExpected };
      } catch {
        if (show) presentation.finish("Input uncertain");
        return receipt("uncertain", "Input was attempted; inspect before continuing.");
      }
    },
  };
}
