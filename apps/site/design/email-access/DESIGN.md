---
name: "Lattices email access"
description: "Scoped inline continuation for documentation and the main-site study entry."
colors:
  paper: "#f2eee3"
  ink: "#101617"
  muted-ink: "rgba(16, 22, 23, 0.68)"
  ink-rule: "rgba(16, 22, 23, 0.18)"
  focus-light: "#c2461f"
  night: "#0a0f0e"
  paper-type: "#ece5d6"
  muted-paper: "rgba(236, 229, 214, 0.66)"
  paper-rule: "rgba(236, 229, 214, 0.18)"
  focus-dark: "#ef6a47"
typography:
  title:
    fontFamily: '"Space Grotesk", -apple-system, sans-serif'
    fontSize: "1.7rem"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "-0.025em"
  body:
    fontFamily: '"Space Grotesk", -apple-system, sans-serif'
    fontSize: "15px"
    lineHeight: 1.65
  label:
    fontFamily: '"Space Grotesk", -apple-system, sans-serif'
    fontSize: "13px"
    fontWeight: 500
  control:
    fontFamily: '"Space Grotesk", -apple-system, sans-serif'
    fontSize: "14px"
    fontWeight: 500
  footnote:
    fontFamily: '"Space Grotesk", -apple-system, sans-serif'
    fontSize: "12px"
rounded:
  control: "7px"
spacing:
  compact: "8px"
  gap: "10px"
  status: "12px"
  supporting-copy: "24px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    typography: "{typography.control}"
    rounded: "{rounded.control}"
    padding: "11px 18px"
  button-alternate:
    textColor: "{colors.ink}"
    typography: "{typography.footnote}"
    padding: "0"
  input:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "11px 14px"
---

# Design System: Lattices email access

## Overview

**Creative North Star: "Keep exploring"**

The access form continues the existing documentation's cream-and-ink reading surface. A quiet divider marks the end of the public excerpt. The heading, short explanation and labeled field keep the reader oriented toward the guide. The primary action is solid ink; the alternate path is an underlined text button.

This is a scoped record of the new inline form and main-site study entry. It preserves the incumbent docs palette, type and page structure. The approved direction is Read mode: no modal, new palette or surrounding-page redesign.

Source authority: [EmailAccess.tsx](../../src/components/EmailAccess.tsx), [StudyAccess.tsx](../../src/components/StudyAccess.tsx), [Docs.tsx](../../src/components/Docs.tsx), [email-access.css](../../src/styles/email-access.css), [docs.css](../../src/styles/docs.css), [index.css](../../src/index.css) and the root [PRODUCT.md](../../../../PRODUCT.md). The [server contract](../../server/README.md) owns delivery, code validation, cookies and protected asset handling; this document owns the visual treatment.

**Key Characteristics:**

- An inline continuation at the content cutoff.
- Two paths: request an emailed code or enter an existing code.
- Incumbent docs colors, clear labels and restrained status text.
- A horizontal desktop form that stacks on narrow screens.

### Review evidence and limits

The final independent review disposition was **ship**, with no material visual findings in the supplied docs states: [desktop](../../../../.impeccable/review/email-access/desktop.png), [mobile](../../../../.impeccable/review/email-access/mobile.png), [sent](../../../../.impeccable/review/email-access/sent.png) and [not connected](../../../../.impeccable/review/email-access/not-connected.png). The [recorded browser checks](../../../../.impeccable/review/email-access/checks.json) cover wrong-code recovery, shared-code unlock, a full guide (94,421 characters), remembered access on the next guide, a protected study chunk response (200), no horizontal overflow at 390px and no recorded console errors.

The completed implementation handoff reports a passing build, 72 audited document cutoffs with no detailed-content leaks, 8 access tests with 36 assertions, passing app and server TypeScript checks, and a bundled Worker. These are existing results; this documentation pass ran no new checks.

The study entry, dark theme, keyboard interaction and loading states were not separately visually reviewed. Delivery tests used a mocked transport. The local preview at `http://127.0.0.1:5187/docs/api` was opened in regular Chrome and reported that email access was not connected. No Resend key, verified sender, production runtime, real email delivery or deployment was provisioned or verified.

## Colors

### Primary

**Ink** fills the primary button and labels controls. **Focus Light** marks keyboard focus on the cream surface. The implementation reads the corresponding docs variables instead of defining form-specific colors.

### Neutral

**Paper** is the article and field ground. **Muted Ink** supports the explanation, placeholders and footnote. **Ink Rule** marks the cutoff and field boundary. The incumbent dark theme maps these roles to **Night**, **Paper Type**, **Muted Paper** and **Paper Rule**, with **Focus Dark** for focus. Dark-theme values are extracted from source; their appearance is outside the supplied visual review.

**The Inherited Material Rule.** Use the docs theme variables for the form. Keep its paper, ink, muted text and divider connected to the surrounding article.

The sidecar's tonal ramps are synthesized swatch previews, not additional implementation colors.

## Typography

The form inherits **Space Grotesk**, with the incumbent system sans-serif fallback. It introduces no display or monospaced type role.

- **Title:** the compact semibold heading uses the frontmatter title token.
- **Body:** supporting copy uses the body token and a measure of 52ch.
- **Label:** a persistent label sits above the field; a placeholder never replaces it.
- **Control:** the primary action uses the control token. Input text is body-sized.
- **Footnote:** the free-access statement and alternate action use the footnote token.
- **Error:** normal ink text uses a smaller body treatment (14px, line-height 1.5).

## Layout

The continuation follows the public Markdown and precedes the document pager. Its measure matches the article header (72ch). A top rule, generous opening margin (44px) and vertical padding (30px) create the cutoff without enclosing the form in a card. The label sits above a flex row with a compact gap. The input expands; the primary button retains its content width.

At viewport widths up to 520px, the field and primary button stack. The button fills the row. The opening margin becomes 32px and top padding becomes 25px. Both controls retain a minimum height (46px). The footer wraps naturally, with the free-access statement and alternate path at opposite ends when space allows.

The main-site study entry reuses the docs page, site header and footer. A short “Lattices studies” heading and explanation precede the same form. An accepted or remembered code loads the study; its pending fallback reads “Opening study…”.

**The Quiet Continuation Rule.** Keep access in the reading flow at the excerpt boundary. Preserve the article, navigation and pager around it.

## Elevation & Depth

The form has no shadow, blur, raised surface or modal backdrop. The divider, field stroke and filled action establish hierarchy. Hover reduces primary-button opacity (0.88); disabled controls use lower opacity (0.55) and a waiting cursor. No custom animation or transition is introduced.

**The Flat Form Rule.** Separate the form with space and a rule. Do not add a card shadow or overlay.

## Shapes

Fields and primary buttons share gently rounded corners through the control token. Their boundaries use a thin stroke (1px). The continuation itself stays open on the article ground. The alternate path is an unboxed underlined text button with a small underline offset (3px).

## Components

### Inline continuation

“Keep exploring.” introduces free access to full guides and studies. The form offers **Email my code** and **I have a code**. The footer reads “Free. No account or password.” The section has a heading association and is excluded from Pagefind indexing.

The product contract remains a transferable shared code with no accounts or OAuth. The user subsequently chose Cloudflare for both hosting and email: private KV captures the contact and the native Email Service binding sends the welcome code. This provider change does not alter the form's visual design. Code composition, remembered access, and the current domain-onboarding status are defined in the [server contract](../../server/README.md). Earlier mocked Resend evidence above describes the prior transport, not live Cloudflare email delivery.

Product pages, installation, overviews and the first four quickstart sections remain public. Detailed docs, raw agent material, and the main-site concept/experiment study require the code. The approved Hyperspace product demo stays public. Independently hosted studios are outside this gate.

### Fields

The email field has the visible label **Email address**, the placeholder “you@example.com” and email autocomplete. The code field has the visible label **Access code**, the placeholder “Access code from your email”, one-time-code autocomplete, uppercase entry hints and spellcheck disabled. Both are required and keep the same shape and dimensions.

All controls have a visible focus outline (2px, offset 3px) in the docs accent. During a request, fields and both actions are disabled; the form exposes its busy state.

### Primary and alternate actions

| State | Field label | Primary action | Alternate action |
| --- | --- | --- | --- |
| Request a code | Email address | Email my code | I have a code |
| Send pending | Email address | Sending… | I have a code, disabled |
| Enter a code | Access code | Continue reading | Send another code |
| Unlock pending | Access code | Opening… | Send another code, disabled |

Switching paths clears the current error. A successful code request switches to code entry. A successful unlock replaces the excerpt with the full guide or opens the study. Remembered access checks the server session without exposing an access token in the UI.

### Sent and error states

The sent status is plain ink text above the form. It identifies the submitted email in bold and asks the reader to check their inbox, then enter the code. It uses `role="status"`.

Errors appear below the field row in normal ink, without a new warning palette. They use `role="alert"` and are associated with the input. A wrong code asks the reader to copy the code from the welcome email. Missing delivery configuration reports “Email access is not connected yet. Please try again later.” It must not show a sent confirmation. If an accepted code cannot load the guide, a separate alert asks the reader to refresh.

## Do's and Don'ts

### Do:

- **Do** reuse the docs theme variables and inherited sans-serif family.
- **Do** keep visible labels, the 46px minimum field and primary-button height, and the narrow-screen stack.
- **Do** retain both code-request and code-entry paths, including recovery and pending states.
- **Do** keep sent confirmation dependent on a successful email response.
- **Do** preserve the public product and first-run reading path.

### Don't:

- **Don't** introduce a modal, a new palette or account and OAuth controls in this slice.
- **Don't** turn the cutoff into a floating promotional card or hide the document navigation.
- **Don't** describe mocked email success as verified delivery or a local preview as deployed production.
- **Don't** extend this gate to the approved public Hyperspace product demo or independently hosted studios.
