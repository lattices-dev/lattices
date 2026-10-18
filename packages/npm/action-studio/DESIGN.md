# Action Studio design contract

Action Studio treats an action as a document that can be inspected and edited.
The spoken instruction stays visible, while the structured trigger, outcomes,
placement plan, and safety behavior remain directly editable below it.

The component owns the editor and spatial preview. A host owns its surrounding
navigation, persistence, voice capture, planning, execution, and receipts. This
keeps the same definition surface usable inside Talkie, Lattices, and a plain
browser preview.

Hosts change the visual treatment through the semantic `--las-*` properties.
They can disable unavailable planning, testing, saving, or placement features
through `setCapabilities`; the rest of the document remains usable.

The interface uses native form elements, visible focus states, an `aria-live`
status line, reduced-motion support, and container-based layout changes so it
responds to its WebView width rather than the outer browser window.
