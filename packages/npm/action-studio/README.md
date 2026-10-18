# @lattices/action-studio

Action Studio is an embeddable web component for defining workspace actions.
Hosts provide voice capture, persistence, planning, execution, and receipts.
The component owns the editable definition document and spatial preview.

## Preview

    bun run action-studio:dev

Open http://127.0.0.1:4177. The preview can switch between Talkie and Lattices
host themes.

The browser host now saves action documents in local browser storage. Save,
reload, reopen from the sidebar, and create a new action from the sample are
functional. Names, triggers, steps, placements, and behavior are validated
before saving. Storage failures keep edits open, and invalid existing storage
is preserved rather than silently replaced. Unsaved edits prompt before
switching actions or leaving the page.

This preview does not connect to the native Lattices runtime. Interpretation
and native testing are disabled; voice requests explain that capture is
unavailable. The spatial preview is illustrative. Saving does not apply window
changes, install a plugin, or sync to paired devices. Storage belongs to the
browser origin/profile and is not a backup; simultaneous edits to the same
action use the last successful save. The Studio route remains a design study,
while this standalone host owns the functional browser library.

## Embed

Bundle these package files into the host WebView resource directory:

- index.mjs
- editor.html
- action-studio.css

Load the module and place the custom element in the host document:

    <script type="module" src="action-studio/index.mjs"></script>
    <lattices-action-editor></lattices-action-editor>

The host supplies definitions and handles requested operations:

    const editor = document.querySelector("lattices-action-editor");

    editor.setDefinition(definition);
    editor.setCapabilities({ canTest: true });
    editor.setStatus({
      tone: "idle",
      message: "Ready to test on this Mac"
    });

    editor.addEventListener("lattices-action-test", (event) => {
      host.plan(event.detail.definition);
    });

## Host API

Methods:

- setDefinition
- getDefinition
- setCapabilities
- setStatus

Events:

- lattices-action-change
- lattices-action-interpret
- lattices-action-test
- lattices-action-save
- lattices-action-voice-request

All events bubble across the shadow boundary.

## Theme contract

Hosts skin Action Studio through semantic custom properties:

    lattices-action-editor {
      --las-surface: #fbfaf7;
      --las-surface-raised: #ffffff;
      --las-live-surface: #071c42;
      --las-text: #182037;
      --las-text-secondary: #697086;
      --las-text-on-live: #f7f9ff;
      --las-accent: #1768e8;
      --las-separator: #18203720;
      --las-control: #1820370d;
      --las-font-ui: -apple-system, BlinkMacSystemFont, sans-serif;
      --las-font-instrument: ui-monospace, monospace;
      --las-radius: 9px;
    }

Unsupported host capabilities can be disabled with setCapabilities. The
remaining definition stays editable, allowing hosts to degrade by capability
instead of rejecting the whole component.
