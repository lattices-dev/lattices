import "../styles/blink.generated.css"
import "../styles/blink-integration.css"

import { TopBar } from "./blink/Chrome"
import Hero from "./blink/Hero"
import { SpecStrip } from "./blink/Architecture"
import Sheets from "./blink/Sheets"
import FilesystemAPI from "./blink/FilesystemAPI"
import AgentGuide from "./blink/AgentGuide"
import AgentCaseStudy, { AgentFilm } from "./blink/AgentCaseStudy"
import Keys from "./blink/Keys"
import { Install } from "./blink/Install"
import { SiteFooter } from "./SiteChrome"

export default function BlinkPage() {
  return (
    <div id="blink-landing" className="crt min-h-screen">
      <TopBar />
      <main>
        <Hero />
        <SpecStrip />
        <AgentFilm />
        <FilesystemAPI />
        <AgentGuide />
        <AgentCaseStudy />
        <Sheets />
        <Keys />
        <Install />
      </main>
      <SiteFooter current="/blink" />
    </div>
  )
}
