import guide from "../data/action-start.json";

export const actionDescription = "A standalone CLI, MCP server and Mac app for computer use. Choose Action’s native engine, Codex Computer Use or Cua Driver.";

export function actionSchema() {
  const productUrl = `${guide.siteUrl}/action`;
  return {
    "@context": "https://schema.org",
    "@graph": [
      {
        "@type": "SoftwareApplication",
        "@id": `${productUrl}#software`,
        name: "Action",
        url: productUrl,
        description: actionDescription,
        applicationCategory: "DeveloperApplication",
        operatingSystem: "macOS; Linux via remote lattices-host",
        downloadUrl: `${productUrl}/download`,
        installUrl: `${productUrl}#get-started`,
        softwareRequirements: guide.prerequisites,
        permissions: "Accessibility and Screen Recording for native macOS automation and capture.",
        softwareHelp: { "@type": "CreativeWork", url: `${guide.siteUrl}${guide.links.agents}` },
        subjectOf: { "@id": `${productUrl}#demo` },
      },
      {
        "@type": "HowTo",
        "@id": `${productUrl}#get-started`,
        name: guide.title,
        description: `${guide.description} ${guide.prerequisites}`,
        step: guide.steps.map((step, index) => ({
          "@type": "HowToStep",
          position: index + 1,
          name: step.title,
          url: `${productUrl}#action-start-${step.id}`,
          text: `${step.command}\nExpected result: ${step.expected}`,
        })),
      },
      {
        "@type": "VideoObject",
        "@id": `${productUrl}#demo`,
        name: "Action virtual workspaces demo",
        description: "A real terminal drives a browser and live agent preview. Scripted development sequence with real MCP calls; no audio.",
        contentUrl: `${productUrl}/virtual-workspaces-demo.mp4`,
        thumbnailUrl: `${productUrl}/virtual-workspaces-demo.webp`,
        duration: "PT29.25S",
        dateCreated: "2026-10-12",
      },
    ],
  };
}
