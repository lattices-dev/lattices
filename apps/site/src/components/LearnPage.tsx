import { useState } from 'react'
import { SiteHeader } from './SiteChrome'
import { appleSources, competitors, getLearningRoute, guides, learningSchema, REVIEW_DATE, trackLearning, videoAssets, videos, type LearningRoute, type Source } from '../lib/learning'

const controls = [
  { id: 'name', label: 'File name', role: 'AXTextField', value: 'Weekend plans', action: 'No press action', explanation: 'A text field can expose its current value. A tool changes a writable value attribute rather than pressing the field. The app decides whether that value is writable.' },
  { id: 'cancel', label: 'Cancel', role: 'AXButton', value: 'No value', action: 'AXPress', explanation: 'The role describes the kind of control. The label helps distinguish this button from other buttons.' },
  { id: 'save', label: 'Save', role: 'AXButton', value: 'No value', action: 'AXPress', explanation: 'The app exposes a press action for this example button. Asking for that action is different from guessing where to click.' },
]

export function AXPlayground({ compact = false }: { compact?: boolean }) {
  const [selected, setSelected] = useState('save')
  const [pressed, setPressed] = useState(false)
  const control = controls.find(c => c.id === selected)!
  function select(id: string) {
    setSelected(id)
    setPressed(false)
    trackLearning('lesson_interaction', { lesson: 'ax-tree', choice: id })
  }
  return <section className={`ax-playground ${compact ? 'ax-compact' : ''}`} aria-label="Illustrative accessibility explorer">
    <div className="lab-topline"><span>Try it: select a control</span><span>Illustrative app</span></div>
    <div className="ax-workbench">
      <div className="ax-window">
        <div className="ax-titlebar"><span className="ax-window-dots" aria-hidden="true"><i /><i /><i /></span><span>Save a note</span></div>
        <div className="ax-window-body">
          <p className="ax-dialog-title">Keep that thought.</p>
          <button className={`ax-field ${selected === 'name' ? 'is-selected' : ''}`} onClick={() => select('name')} aria-pressed={selected === 'name'}><span>File name</span><strong>Weekend plans</strong></button>
          <div className="ax-dialog-actions">
            {controls.slice(1).map(c => <button key={c.id} className={`ax-fake-button ${selected === c.id ? 'is-selected' : ''}`} onClick={() => select(c.id)} aria-pressed={selected === c.id}>{c.label}</button>)}
          </div>
          <p className="ax-simulation-note">Selecting a control inspects it in this example.</p>
        </div>
      </div>
      <div className="ax-inspector" aria-live="polite">
        <p className="ax-tree-path">App / Window / <strong>{control.label}</strong></p>
        <dl><div><dt>Role</dt><dd><code>{control.role}</code></dd></div><div><dt>Label</dt><dd>{control.label}</dd></div><div><dt>Value</dt><dd>{control.value}</dd></div><div><dt>Action</dt><dd><code>{control.action}</code></dd></div></dl>
        <p>{control.explanation}</p>
        {!compact && selected === 'save' && <button className="learn-button" onClick={() => { setPressed(true); trackLearning('lesson_complete', { lesson: 'ax-tree' }) }}>Press Save in the example</button>}
        {!compact && <p className="ax-result" role="status">{pressed ? 'The example app reports “Saved”. In a real workflow, check the result after acting.' : 'Example only. This page cannot inspect or control your Mac.'}</p>}
      </div>
    </div>
  </section>
}

const permissionTasks = [
  { id: 'controls', label: 'Find or press a button', permission: 'Accessibility', reason: 'Start here when a tool reads or operates another app’s accessible controls.', check: 'In Privacy & Security → Accessibility, review the app doing the work. If access is enabled, check whether the target app exposes the control and action.', source: appleSources.access },
  { id: 'screen', label: 'Capture what is on screen', permission: 'Screen & System Audio Recording', reason: 'Start here when a tool requests permission to capture the screen. Capture behavior also depends on the API and any system picker the app uses.', check: 'In Privacy & Security → Screen & System Audio Recording, review the requesting app. A capture permission does not grant Accessibility access.', source: appleSources.capture },
  { id: 'commands', label: 'Send commands to another app', permission: 'Automation', reason: 'Start here when macOS asks whether one app may control another, such as in an Apple Events workflow.', check: 'In Privacy & Security → Automation, review the requesting app and the target app listed beneath it. UI scripting can also require Accessibility.', source: appleSources.automation },
]

function PermissionGuide() {
  const [task, setTask] = useState(permissionTasks[0].id)
  const result = permissionTasks.find(t => t.id === task)!
  return <section className="learn-tool" aria-labelledby="permission-task-title">
    <h2 id="permission-task-title">What are you trying to do?</h2>
    <div className="learn-choices">{permissionTasks.map(t => <button key={t.id} aria-pressed={task === t.id} onClick={() => { setTask(t.id); trackLearning('permission_result', { choice: t.id }) }}>{t.label}</button>)}</div>
    <div className="permission-result" aria-live="polite"><span>First permission to investigate</span><h3>{result.permission}</h3><p>{result.reason}</p><p>{result.check}</p><a href={result.source.url}>Read Apple’s instructions</a></div>
    <p className="learn-small">Educational guidance, not a scan of your settings. Other permissions can apply to a particular workflow. Names can vary by macOS version.</p>
  </section>
}

function SightComparison() {
  const [question, setQuestion] = useState('button')
  return <section className="learn-tool" aria-labelledby="sight-title"><h2 id="sight-title">What do you want to know?</h2>
    <div className="learn-choices"><button aria-pressed={question === 'button'} onClick={() => { setQuestion('button'); trackLearning('lesson_interaction', { lesson: 'ax-vs-screenshots', choice: 'button' }) }}>Where is the Save button?</button><button aria-pressed={question === 'drawing'} onClick={() => { setQuestion('drawing'); trackLearning('lesson_interaction', { lesson: 'ax-vs-screenshots', choice: 'drawing' }) }}>What does the drawing look like?</button></div>
    <div className="sight-columns" aria-live="polite">
      <div><h3>Accessibility information</h3><pre>{question === 'button' ? 'Window\n└─ Button\n   label: Save\n   action: AXPress' : 'Window\n└─ Canvas\n   label: Drawing area\n   contents: not exposed'}</pre><p>{question === 'button' ? 'The example app names the button and supplies an action. The tool can use this information to identify it.' : 'This example exposes a canvas, without describing its artwork. A real app could provide richer accessible information.'}</p></div>
      <div><h3>Screenshot</h3><div className="sight-pixels">{question === 'button' ? <span className="sight-save">Save</span> : <svg role="img" aria-label="An example drawing of an orange circle and green arch" width="180" height="105" viewBox="0 0 180 105"><circle cx="116" cy="32" r="23" fill="#b66b32"/><path d="M22 95 V60 A35 35 0 0 1 92 60 V95" fill="none" stroke="#256746" strokeWidth="18" /></svg>}</div><p>{question === 'button' ? 'The button is visible as pixels. Recognizing its text and location requires image interpretation; its AX action is not part of the image.' : 'The picture preserves the drawing’s appearance, even if the app does not expose its contents through accessibility.'}</p></div>
    </div><p className="learn-small">Both views are illustrative. No screenshot of your Mac is captured.</p>
  </section>
}

function Sources({ items, date = REVIEW_DATE }: { items: Source[]; date?: string }) {
  return <section className="learn-sources" aria-label="Sources"><h2>Go to the source</h2><p className="learn-small">Documentation reviewed {date}. Examples are illustrative; this is not a hands-on product benchmark.</p><ul>{items.map(s => <li key={s.url}><a href={s.url}>{s.title}</a></li>)}</ul></section>
}

function ProductBridge({ action = false }: { action?: boolean }) {
  return <aside className="learn-bridge"><div><h2>{action ? 'Put the right tool behind the task.' : 'Bring a little order to your Mac.'}</h2><p>{action ? 'Lattices organizes your workspace. Action is a separate product for computer use.' : 'Lattices brings windows, projects, and terminal sessions into a workspace you can navigate.'}</p></div><a className="learn-button" href={action ? '/action' : '/docs/quickstart'} onClick={() => trackLearning('product_bridge_click', { target: action ? 'action' : 'lattices-quickstart' })}>{action ? 'Explore Action' : 'Explore Lattices'}</a></aside>
}

function GuideIndex() {
  return <>
    <header className="learn-intro"><h1>Become a more<br /><em>capable Mac user.</em></h1><p>Understand the tools behind the shortcuts. Try a small experiment, choose your next automation, and make your Mac work a little more like you do.</p></header>
    <div className="learn-feature"><div className="learn-feature-copy"><h2>Your Mac has another way to see a button.</h2><p>Automation tools can ask an app what a control is called and what it can do. Meet the accessibility tree.</p><a href="/learn/ax-tree">Explore the interactive lesson <Arrow /></a></div><AXPlayground compact /></div>
    <section className="learn-section"><h2>Start with a question.</h2><div className="learn-lesson-list">{guides.map(g => <a className="learn-lesson-row" key={g.slug} href={`/learn/${g.slug}`}><div><span className="learn-small">{g.format} · {g.minutes} min</span><h3>{g.title}</h3><p>{g.description}</p></div><Arrow /></a>)}</div></section>
    <section className="learn-section learn-directory-teaser"><div><h2>A tool for the way you work.</h2><p>Window snapping, keyboard launchers, custom scripts: Mac utilities solve different problems. Compare six options and see where Lattices fits.</p><a href="/compare">Browse the tool directory <Arrow /></a></div><ul>{competitors.map(c => <li key={c.slug}><a href={`/compare/${c.slug}`}><strong>{c.name}</strong><span>{c.category}</span></a></li>)}</ul></section>
    <VideoList /><ProductBridge />
  </>
}

function GuidePage({ slug }: { slug: string }) {
  const guide = guides.find(g => g.slug === slug)!
  const [first, second, ...rest] = guide.sections
  return <>
    <header className="learn-article-header"><h1>{guide.title}</h1><p>{guide.takeaway}</p><span className="learn-small">{guide.format} · {guide.minutes} min · Reviewed {REVIEW_DATE}</span></header>
    <div className="learn-prose"><section><h2>{first.title}</h2><p>{first.text}</p></section>{slug !== 'macos-automation-permissions' && <section><h2>{second.title}</h2><p>{second.text}</p></section>}</div>
    {slug === 'ax-tree' ? <AXPlayground /> : slug === 'macos-automation-permissions' ? <PermissionGuide /> : <SightComparison />}
    <div className="learn-prose">{(slug === 'macos-automation-permissions' ? [second, ...rest] : rest).map(s => <section key={s.title}><h2>{s.title}</h2><p>{s.text}</p></section>)}</div>
    {videos.some(video => video.slug === slug) && <p className="learn-watch-link"><a href={`/watch/${slug}`}>Watch the animated explanation <Arrow /></a></p>}
    {slug === 'ax-vs-screenshots' && <p className="learn-watch-link"><a href="/watch/observe-act-verify">See why an accepted action still needs a result check <Arrow /></a></p>}
    <Sources items={guide.sources} /><RelatedGuides current={slug} /><ProductBridge action={slug === 'ax-vs-screenshots'} />
  </>
}

function ComparisonIndex() {
  const [category, setCategory] = useState('All tools')
  const categories = ['All tools', ...new Set(competitors.map(c => c.category))]
  const filtered = category === 'All tools' ? competitors : competitors.filter(c => c.category === category)
  return <><header className="learn-article-header"><h1>Find the right tool<br /><em>for your kind of Mac.</em></h1><p>Start with the job you want to do. These tools overlap in places, but they ask different things of you and solve different problems.</p></header>
    <p className="learn-disclosure">Published by Lattices. Based on official documentation, not hands-on rankings. Each review includes reasons to choose the other tool. Reviewed {REVIEW_DATE}.</p>
    <div className="learn-filter"><label htmlFor="tool-category">The kind of tool</label><select id="tool-category" value={category} onChange={e => { setCategory(e.target.value); trackLearning('comparison_filter', { category: e.target.value }) }}>{categories.map(c => <option key={c}>{c}</option>)}</select><span aria-live="polite">{filtered.length} tools</span></div>
    <div className="learn-comparison-list">{filtered.map(c => <article key={c.slug}><div><h2><a href={`/compare/${c.slug}`}>{c.name} <Arrow /></a></h2><span>{c.category}</span></div><div><p>{c.summary}</p><p className="learn-best-for">{c.bestFor}</p><a href={`/compare/${c.slug}`}>Read the analysis</a></div></article>)}</div>
    <div className="learn-prose"><section><h2>How to use these comparisons</h2><p>Pick one recurring annoyance first: arranging windows, launching commands, or repeating a sequence of actions. Read the setup and tradeoffs before installing. Overlapping window rules or shortcuts need a separate compatibility check; inclusion here does not mean every pair works together.</p><p><a href="/watch/window-snapping-vs-tiling">Watch how snapping, tiling, and workspaces differ <Arrow /></a></p></section></div><ProductBridge /></>
}

function ComparisonPage({ slug }: { slug: string }) {
  const item = competitors.find(c => c.slug === slug)!
  return <><header className="learn-article-header"><h1>{item.name} and Lattices.<br /><em>Which fits your workflow?</em></h1><p>{item.summary}</p></header>
    <p className="learn-disclosure">A comparison from Lattices · Official documentation reviewed {item.reviewedAt} · No hands-on benchmark or overall score</p>
    <div className="learn-verdict"><section><h2>When {item.name} makes sense</h2><p>{item.bestFor}</p></section><section><h2>When to consider Lattices</h2><p>{item.latticesFit}</p></section></div>
    <div className="learn-prose"><section><h2>The tradeoff to understand</h2><p>{item.tradeoff}</p></section></div>
    <section className="learn-facts"><h2>What {item.name} gives you</h2><dl>{item.capabilities.map(f => <div key={f.label}><dt>{f.label}</dt><dd>{f.value}</dd></div>)}</dl></section>
    <div className="learn-prose"><section><h2>Try one workflow before switching</h2><p>Choose a task you repeat and check the tool’s official setup guide. Pay attention to permissions, configuration, and conflicting shortcuts. This page compares documented approaches; it does not establish compatibility between two apps running together.</p></section></div>
    <Sources items={[...item.sources, { title: 'Lattices: app features and permissions', url: '/docs/app' }, { title: 'Lattices: workspace concepts', url: '/docs/concepts' }]} date={item.reviewedAt} />
    <section className="learn-section"><h2>Keep comparing</h2><div className="learn-related">{competitors.filter(c => c.slug !== slug).map(c => <a href={`/compare/${c.slug}`} key={c.slug}>{c.name}<Arrow /></a>)}</div></section><ProductBridge />
  </>
}

function VideoList({ heading = true }: { heading?: boolean }) {
  return <section className="learn-section">{heading && <h2>See the idea in motion.</h2>}<div className="learn-video-list">{videos.map(v => <a key={v.slug} href={`/watch/${v.slug}`}><img loading="lazy" src={`/learn/media/${v.slug}-poster.jpg`} alt="" width="1280" height="720" /><h3>{v.title} <Arrow /></h3><p>{videoAssets[v.slug] ? `${videoAssets[v.slug].durationSeconds}-second animation` : 'Short animated lesson'} · Transcript included</p></a>)}</div></section>
}

function WatchPage({ slug }: { slug: string }) {
  const video = videos.find(v => v.slug === slug)!
  const asset = videoAssets[slug]
  const transcript = asset.fullTranscript.trim().split(/\n\n/).slice(2)
  return <><header className="learn-article-header"><h1>{video.title}</h1><p>{video.description}</p></header>
    <video className="learn-video" width={asset.width} height={asset.height} controls playsInline preload="metadata" poster={`/learn/media/${slug}-poster.jpg`} onPlay={() => trackLearning('explainer_play', { video: slug })} onEnded={() => trackLearning('explainer_complete', { video: slug })} aria-label={video.title}><source src={`/learn/media/${slug}.mp4`} type="video/mp4" /><track kind="captions" src={`/learn/media/${slug}.vtt`} srcLang="en" label="English" /><p>Your browser cannot play this video. <a href={`/learn/media/${slug}.mp4`}>Download the MP4</a> or read the lesson below.</p></video>
    <p className="learn-small">{asset.durationSeconds}-second silent visual explanation. The interfaces and values are illustrative. <a href={`/learn/media/${slug}.mp4`} download>Download video</a> · <a href={`/learn/media/${slug}.vtt`} download>Captions (VTT)</a> · <a href={`/learn/media/${slug}-transcript.txt`} download>Transcript (text)</a></p>
    <div className="learn-prose"><section aria-labelledby="video-transcript-title"><h2 id="video-transcript-title">Read the visual transcript</h2><ol className="learn-transcript">{transcript.map((text, index) => { const timed = text.match(/^\[(.+?) seconds\] (.+)$/s); return <li key={index}>{timed ? <><span className="learn-transcript-time">{timed[1]} seconds</span><p>{timed[2]}</p></> : <p>{text}</p>}</li> })}</ol></section><section><h2>The idea</h2><p>{video.takeaway}</p></section><section><h2>Keep learning</h2>{video.related.map(link => <p key={link.href}><a href={link.href}>{link.title}</a></p>)}</section></div><Sources items={video.sources} /><ProductBridge action={video.action} />
  </>
}

function RelatedGuides({ current }: { current: string }) {
  return <section className="learn-section"><h2>Keep learning</h2><div className="learn-related">{guides.filter(g => g.slug !== current).map(g => <a href={`/learn/${g.slug}`} key={g.slug}>{g.title}<Arrow /></a>)}</div></section>
}

function Arrow() { return <svg className="learn-arrow" viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path d="M4 12h15M13 6l6 6-6 6" fill="none" stroke="currentColor" strokeWidth="1.5" /></svg> }

export default function LearnPage({ path }: { path: string }) {
  const route: LearningRoute | undefined = getLearningRoute(path)
  if (!route) return null
  return <div className="learning-shell"><SiteHeader /><a className="learn-skip" href="#learning-main">Skip to content</a>
    <div className="learn-subnav"><nav aria-label="Learning"><a href="/learn" aria-current={route.family === 'learn' ? 'page' : undefined}>Learn</a><a href="/compare" aria-current={route.family === 'compare' ? 'page' : undefined}>Compare tools</a><a href="/watch" aria-current={route.family === 'watch' ? 'page' : undefined}>Watch</a></nav><span>A more intentional Mac.</span></div>
    <main id="learning-main" className="learn-main" data-pagefind-body>
      {route.slug && <nav className="learn-breadcrumb" aria-label="Breadcrumb"><a href={`/${route.family}`}>{route.family === 'learn' ? 'All lessons' : route.family === 'compare' ? 'All tools' : 'All videos'}</a><span aria-hidden="true"> / </span><span>{route.family === 'compare' ? competitors.find(c => c.slug === route.slug)?.name : route.title}</span></nav>}
      {route.family === 'learn' ? route.slug ? <GuidePage key={route.slug} slug={route.slug} /> : <GuideIndex /> : route.family === 'compare' ? route.slug ? <ComparisonPage slug={route.slug} /> : <ComparisonIndex /> : route.slug ? <WatchPage key={route.slug} slug={route.slug} /> : <><header className="learn-article-header"><h1>Mac automation,<br /><em>explained visually.</em></h1><p>One concept at a time. Short animations to make the invisible parts of your Mac easier to understand.</p></header><VideoList heading={false} /><RelatedGuides current="" /></>}
    </main><footer className="learn-footer"><a href="/">Lattices</a><span>Learn the mechanism. Choose the tool.</span><a href="/docs/overview">Documentation</a></footer>
    <script type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(learningSchema(route)).replace(/</g, '\\u003c') }} />
  </div>
}
