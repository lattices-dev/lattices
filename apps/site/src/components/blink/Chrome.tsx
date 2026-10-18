import { LatticesMark } from '../LatticesMark'
import { ProductsMenu } from '../SiteChrome'
import { BlinkMark } from './BlinkMark'
import { ThemeSwitcher } from './ThemeSwitcher'

export function TopBar() {
  return <header className="blink-family-header">
    <div className="blink-family-inner">
      <div className="blink-family-brand"><a href="/" aria-label="Lattices home"><LatticesMark /><span>lattices</span></a><span className="blink-family-slash" aria-hidden>/</span><a href="#top" aria-label="Blink page top"><BlinkMark className="h-4 w-4" /><span>blink</span></a></div>
      <nav className="blink-family-links" aria-label="Lattices navigation"><ProductsMenu /><a className="blink-agent-link" href="/blink/agents.md">For agents</a><ThemeSwitcher /><a className="blink-nav-download" href="/blink/download">Download</a></nav>
    </div>
    <nav className="blink-section-nav" aria-label="Blink sections"><a href="#how">How it works</a><a href="#agents">For agents</a><a href="#desk">The desk</a><a href="#keys">Shortcuts</a><a href="#install">Install</a></nav>
  </header>
}
