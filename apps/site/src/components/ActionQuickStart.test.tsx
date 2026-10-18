import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ActionQuickStart } from "./ActionQuickStart";
import { actionSchema } from "../lib/action-schema";
import guide from "../data/action-start.json";

describe("Action quick start", () => {
  test("renders ordered commands, expected results, prerequisites, and agent links", () => {
    const html = renderToStaticMarkup(createElement(ActionQuickStart));
    expect(html).toContain('id="get-started"');
    expect(html).toContain("Install Bun first");
    expect(html).toContain("lats action install --launch");
    expect(html).toContain("permissions.snapshot");
    expect(html).toContain("capture.screenshotScreen");
    expect(html).toContain("&quot;output&quot;");
    expect(html.match(/<li /g)).toHaveLength(3);
    expect(html.match(/<strong>Expect:<\/strong>/g)).toHaveLength(3);
    expect(html.match(/<button /g)).toHaveLength(3);
    expect(html).toContain('role="status"');
    expect(html).toContain("not a private workspace");
    expect(html).toContain("matching MCP runtime");
    expect(html).toContain(guide.links.agents);
    expect(html).toContain(guide.links.linux);
  });

  test("structured steps match the visible guide and keep platform limits explicit", () => {
    const graph = actionSchema()["@graph"];
    const howTo = graph.find((entry) => entry["@type"] === "HowTo");
    expect(howTo?.step).toHaveLength(guide.steps.length);
    guide.steps.forEach((step, index) => {
      expect(howTo?.step?.[index].text).toBe(`${step.command}\nExpected result: ${step.expected}`);
      expect(howTo?.step?.[index].url).toEndWith(`#action-start-${step.id}`);
    });
    const software = graph.find((entry) => entry["@type"] === "SoftwareApplication");
    expect(software?.operatingSystem).toContain("Linux via remote lattices-host");
    expect(software?.downloadUrl).toBe("https://lattices.dev/action/download");
    const video = graph.find((entry) => entry["@type"] === "VideoObject");
    expect(video?.duration).toBe("PT29.25S");
    expect(video?.description).toContain("Scripted development sequence");
    expect(video).not.toHaveProperty("uploadDate");
  });
});
