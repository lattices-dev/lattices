import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ActionDemo } from "./ActionDemo";

describe("ActionDemo", () => {
  test("renders the actual capture with controls and a stable aspect ratio", () => {
    const html = renderToStaticMarkup(createElement(ActionDemo));
    expect(html).toContain('/action/virtual-workspaces-demo.mp4');
    expect(html).toContain('/action/virtual-workspaces-demo.webp');
    expect(html).toContain('controls=""');
    expect(html).toContain('playsInline=""');
    expect(html).toContain('width="1920" height="1080"');
    expect(html).not.toContain('autoPlay=');
  });

  test("keeps the text alternative available to screen readers without a visible disclosure", () => {
    const html = renderToStaticMarkup(createElement(ActionDemo));
    expect(html).toContain('aria-describedby="action-demo-description"');
    expect(html).toContain('id="action-demo-description" class="action-demo-description"');
    expect(html).toContain('29-second development preview. Scripted sequence, real MCP calls.');
    expect(html).not.toContain('<details');
    expect(html).not.toContain('What happens in the demo');
    expect(html).toContain('There is no audio.');
    expect(html).toContain('Open full-size video');
  });
});
