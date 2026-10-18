import competitorData from '../data/learning-competitors.json'
import videoManifest from '../../public/learn/media/manifest.json'

export const LEARNING_SITE_URL = 'https://lattices.dev'
export const REVIEW_DATE = '2026-10-02'
export type Source = { title: string; url: string }
export type Guide = {
  slug: string; title: string; searchTitle?: string; description: string; format: string; minutes: number
  takeaway: string; sections: { title: string; text: string }[]; sources: Source[]
}
export const appleSources = {
  model: { title: 'Apple: the accessibility model (archived conceptual guide)', url: 'https://developer.apple.com/library/archive/documentation/Accessibility/Conceptual/AccessibilityMacOSX/OSXAXmodel.html' },
  ax: { title: 'Apple: AXUIElement API', url: 'https://developer.apple.com/documentation/applicationservices/axuielement_h' },
  access: { title: 'Apple: allow accessibility apps to access your Mac', url: 'https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac' },
  capture: { title: 'Apple: control screen and system audio recording', url: 'https://support.apple.com/guide/mac-help/control-access-to-screen-and-system-audio-recording-mchld6aa7d23/mac' },
  automation: { title: 'Apple: allow apps to automate and control other apps', url: 'https://support.apple.com/guide/mac-help/allow-apps-to-automate-and-control-other-apps-mchl108e1718/mac' },
  appleEvents: { title: 'Apple: permission to send Apple Events', url: 'https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events' },
  screenKit: { title: 'Apple: ScreenCaptureKit', url: 'https://developer.apple.com/documentation/screencapturekit' },
}

export const guides: Guide[] = [
  {
    slug: 'ax-tree', title: 'How your Mac describes a button', searchTitle: 'macOS accessibility tree: an interactive AX guide', format: 'Interactive lesson', minutes: 4,
    description: 'Explore the macOS accessibility tree with a working example. See how apps describe windows, text fields, and buttons to automation tools.',
    takeaway: 'A button has more than a position on your screen. An app can describe what it is, what it says, and what you can do with it.',
    sections: [
      { title: 'Meet the accessibility tree', text: 'AX is shorthand for accessibility. The accessibility tree is an app’s description of its interface: windows contain controls, and controls expose information such as their role and label. Assistive technology uses this information to help people navigate. Automation tools can use the same interface.' },
      { title: 'Try it: select a control', text: 'Select the text field or either button in the example. The inspector shows the information an automation tool might receive. These are made-up example values, not a scan of your Mac. Select “Press Save” to see the difference between reading a control and asking it to perform an action.' },
      { title: 'Why a visible button can still be hard to automate', text: 'An app chooses what it exposes. Custom controls can be missing a useful label or action. An accessibility hierarchy can also simplify the visual layout. Granting permission does not add information that the app has never provided.' },
      { title: 'Put the idea to work', text: 'When an automation cannot find a control, check its permission and the information the target app exposes before adding more clicks. For organizing your working environment, Lattices connects window navigation with project workspaces and terminal sessions. Its app guide explains the permissions behind those features.' },
    ], sources: [appleSources.model, appleSources.ax, appleSources.access],
  },
  {
    slug: 'macos-automation-permissions', title: 'Which permission does your Mac automation need?', format: 'Permission guide', minutes: 5,
    description: 'Understand Accessibility, Screen Recording, and Automation permissions on macOS. Choose a task and learn which permission to investigate first.',
    takeaway: 'Start with what the app is trying to do. Reading controls, capturing a screen, and sending commands to another app use different kinds of access.',
    sections: [
      { title: 'Three permissions, three different jobs', text: 'Accessibility lets an authorized app interact through accessibility features. Screen & System Audio Recording controls capture access. Automation controls permission for one app to automate another. A workflow can require more than one permission; approving one does not approve the others.' },
      { title: 'Check the app that actually performs the action', text: 'Open System Settings, then Privacy & Security. Find the relevant category and review the listed app. An automation launched from a terminal or helper can involve a different application identity than you expect. Follow that tool’s instructions and the name in the macOS prompt.' },
      { title: 'Permission is only one part of the diagnosis', text: 'If access is already enabled, inspect the exact error and the target app. A missing AX label, an unavailable window, or an action the target does not expose can still prevent success. A permission toggle is not evidence that every control can now be automated.' },
      { title: 'Use the smallest permission set the task needs', text: 'Give access to tools you trust and understand. This guide explains the categories; it cannot check or change your Mac settings. Lattices documents how its window features use Accessibility and Screen Recording so you can connect each request to a feature you intend to use.' },
    ], sources: [appleSources.access, appleSources.capture, appleSources.automation],
  },
  {
    slug: 'ax-vs-screenshots', title: 'What can an automation tool actually see?', searchTitle: 'Accessibility tree vs screenshots for Mac automation', format: 'Visual comparison', minutes: 4,
    description: 'Compare accessibility information with screenshots using a simple example. Learn why automation tools sometimes need both labels and pixels.',
    takeaway: 'A screenshot shows appearance. An accessibility tree supplies the interface information the app exposes. Each answers a different question.',
    sections: [
      { title: 'Two views of the same window', text: 'A screenshot contains pixels: layout, colors, artwork, and visible text. An accessibility query can return structured information about exposed controls, including roles and supported actions. A screenshot alone does not carry a button’s AX action; an AX label alone does not describe an illustration.' },
      { title: 'Try a question before choosing an approach', text: 'Use the selector below to compare finding a named button with checking a drawing. The example is a teaching model. Real results depend on the app, permissions, and the automation tool’s implementation.' },
      { title: 'Why both can be useful', text: 'A tool can use accessible information to identify a control, then examine the visible result after acting. For a custom canvas, pixels might show detail that the accessibility tree omits. Neither view, by itself, proves that the intended task succeeded.' },
      { title: 'Choose tools around the job', text: 'Start with the outcome: arrange your workspace, automate a repeatable task, or interact with an interface. Lattices focuses on the workspace. Action is the separate Lattices product for computer use. The tool directory explains where other Mac utilities fit.' },
    ], sources: [appleSources.model, appleSources.ax, appleSources.screenKit],
  },
]

export type Competitor = {
  slug: string; name: string; category: string; summary: string; bestFor: string; tradeoff: string
  latticesFit: string; capabilities: { label: string; value: string }[]; sources: Source[]; reviewedAt: string
}
export const competitors = competitorData as Competitor[]

export const videoAssets: Record<string, { durationSeconds: number; width: number; height: number; transcript: { start: number; end: number; text: string }[]; fullTranscript: string }> = videoManifest

export type ExplainerVideo = {
  slug: string; title: string; searchTitle?: string; description: string; takeaway: string; sources: Source[]
  related: { title: string; href: string }[]; action?: boolean
}

export const videos: ExplainerVideo[] = [
  {
    slug: 'ax-tree', title: 'The macOS accessibility tree, explained',
    description: 'Watch how a window becomes a tree of named controls and supported actions. A short visual explanation for aspiring Mac power users.',
    takeaway: 'A button has more than a position on your screen. An app can describe what it is, what it says, and what you can do with it.',
    sources: [appleSources.model, appleSources.ax, appleSources.access],
    related: [{ title: 'How your Mac describes a button', href: '/learn/ax-tree' }],
  },
  {
    slug: 'ax-vs-screenshots', title: 'AX and screenshots: two ways to see a Mac',
    description: 'See the difference between interface information and pixels, and why a successful automation may use both.',
    takeaway: 'A screenshot shows appearance. An accessibility tree supplies the interface information the app exposes. Each answers a different question.',
    sources: [appleSources.model, appleSources.ax, appleSources.screenKit],
    related: [{ title: 'What can an automation tool actually see?', href: '/learn/ax-vs-screenshots' }], action: true,
  },
  {
    slug: 'macos-automation-permissions', title: 'Three Mac permissions, three different jobs',
    description: 'A visual guide to Accessibility, Screen & System Audio Recording, and Automation on macOS. Match the permission to the task before changing settings.',
    takeaway: 'Operating exposed controls, capturing a screen, and sending Apple Events use different kinds of access. A workflow can need more than one. Start with the task and the app making the request; settings names can vary by macOS version.',
    sources: [appleSources.access, appleSources.capture, appleSources.automation, appleSources.appleEvents],
    related: [{ title: 'Choose a task in the permission guide', href: '/learn/macos-automation-permissions' }, { title: 'Read Lattices’ feature and permission guide', href: '/docs/app' }],
  },
  {
    slug: 'observe-act-verify', title: 'A click is not a completed task', searchTitle: 'Observe, act, verify: checking Mac automation results',
    description: 'Learn the observe, act, verify loop with an illustrative failed-save example. Check the outcome and inspect the cause before a bounded retry.',
    takeaway: 'Decide what success looks like before acting. An accepted press is only a step toward that result. Read the app’s response, investigate an error, and retry only when the correction and the repeated action are safe. Stop when the result remains unclear.',
    sources: [appleSources.model, { title: 'Hammerspoon: accepted actions and their limits', url: 'https://www.hammerspoon.org/docs/hs.axuielement.html#performAction' }, { title: 'Lattices: checking post-action outcomes', url: '/docs/api' }],
    related: [{ title: 'Compare accessibility information and screenshots', href: '/learn/ax-vs-screenshots' }, { title: 'Read the post-action verification reference', href: '/docs/api' }], action: true,
  },
  {
    slug: 'window-snapping-vs-tiling', title: 'Window snapping, tiling, and workspaces',
    description: 'See how placing one window, automatically arranging several, and grouping a work context solve different problems. Choose the approach that fits your Mac routine.',
    takeaway: 'Snapping places a chosen window. Automatic tiling applies a layout to managed windows. A workspace groups related work so you can return to a context. Tools can combine these ideas, and workspace behavior varies by app; the name alone does not promise process restoration or a macOS Space.',
    sources: [{ title: 'Rectangle: shortcuts and snap areas', url: 'https://rectangleapp.com/' }, { title: 'AeroSpace: tiling layouts and virtual workspaces', url: 'https://nikitabobko.github.io/AeroSpace/guide' }, { title: 'Lattices: workspace concepts', url: '/docs/concepts' }, { title: 'Lattices: layers and tab groups', url: '/docs/layers' }],
    related: [{ title: 'Find a tool for your window workflow', href: '/compare' }, { title: 'Read how Lattices groups related work', href: '/docs/layers' }],
  },
]

export type LearningRoute = { path: string; title: string; description: string; family: 'learn' | 'compare' | 'watch'; slug?: string }
export const learningRoutes: LearningRoute[] = [
  { path: '/learn', title: 'Become a more capable Mac user', description: 'Learn how Mac automation works with interactive lessons, practical permission guides, fair tool comparisons, and short animated explainers.', family: 'learn' },
  { path: '/compare', title: 'Find the right Mac automation tool', description: 'Compare Rectangle, AeroSpace, yabai, Hammerspoon, Keyboard Maestro, and Raycast by the job you want to do, with sourced analysis and tradeoffs.', family: 'compare' },
  { path: '/watch', title: 'Mac automation, explained visually', description: 'Short animated lessons about Mac accessibility, screenshots, permissions, checking automation results, and arranging your workspace.', family: 'watch' },
  ...guides.map(g => ({ path: `/learn/${g.slug}`, title: g.searchTitle || g.title, description: g.description, family: 'learn' as const, slug: g.slug })),
  ...competitors.map(c => ({ path: `/compare/${c.slug}`, title: `${c.name} and Lattices: which fits your workflow?`, description: `Compare ${c.name} with Lattices for your Mac workflow. Understand its strengths, setup tradeoffs, and when each tool is a useful choice.`, family: 'compare' as const, slug: c.slug })),
  ...videos.map(v => ({ path: `/watch/${v.slug}`, title: v.searchTitle || v.title, description: v.description, family: 'watch' as const, slug: v.slug })),
]

export function getLearningRoute(path: string) {
  return learningRoutes.find(route => route.path === path)
}

export function learningSchema(route: LearningRoute) {
  const name = route.family === 'learn' ? 'Learn' : route.family === 'compare' ? 'Compare' : 'Watch'
  return {
    '@context': 'https://schema.org', '@graph': [
      { '@type': route.slug ? 'WebPage' : 'CollectionPage', '@id': `${LEARNING_SITE_URL}${route.path}#page`, url: `${LEARNING_SITE_URL}${route.path}`, name: route.title, description: route.description, inLanguage: 'en', publisher: { '@type': 'Organization', name: 'Lattices', url: LEARNING_SITE_URL } },
      { '@type': 'BreadcrumbList', itemListElement: [
        { '@type': 'ListItem', position: 1, name: 'Lattices', item: LEARNING_SITE_URL },
        { '@type': 'ListItem', position: 2, name, item: `${LEARNING_SITE_URL}/${route.family}` },
        ...(route.slug ? [{ '@type': 'ListItem', position: 3, name: route.title, item: `${LEARNING_SITE_URL}${route.path}` }] : []),
      ] },
    ],
  }
}

// The existing GA tag is optional. Lesson choices contain no user-entered data.
export function trackLearning(event: string, detail: Record<string, string>) {
  if (typeof window === 'undefined') return
  if (window.location.hostname !== new URL(LEARNING_SITE_URL).hostname) return
  const analytics = window as Window & { gtag?: (type: string, event: string, values: Record<string, string>) => void }
  analytics.gtag?.('event', event, { ...detail, content_group: 'mac-learning', page_path: window.location.pathname })
}
