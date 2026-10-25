import type { Metadata } from "next"
import { BlinkMark } from "@/components/homepage/BlinkMark"

export const metadata: Metadata = {
  title: "Support — Canvas",
  description: "Get help with Canvas on Mac, iPhone, and iPad, including local pairing and offline notes.",
  alternates: { canonical: "/support/" },
}

export default function SupportPage() {
  return (
    <div className="min-h-screen">
      <header className="border-b border-linex bg-[rgba(var(--bg-rgb),0.88)] backdrop-blur-md">
        <div className="mx-auto flex h-12 max-w-3xl items-center justify-between px-4 md:px-6">
          <a
            href="/"
            className="font-display flex items-center gap-2 text-[17px] font-semibold leading-none tracking-[-0.015em] text-[var(--text)] transition-colors hover:text-acc"
          >
            <BlinkMark className="h-4 w-4 text-acc" />
            <span>Canvas</span>
          </a>
          <a href="/privacy/" className="rounded-[4px] py-1 text-[11px] text-dimx transition-colors hover:text-acc">
            Privacy
          </a>
        </div>
      </header>

      <main className="mx-auto max-w-3xl px-4 pb-24 pt-14 md:px-6 md:pt-20">
        <div className="max-w-2xl">
          <p className="label-x">Support</p>
          <h1 className="font-display mt-4 text-balance text-5xl font-semibold leading-[0.95] tracking-[-0.025em] text-[var(--text)] md:text-6xl">
            Help with Canvas.
          </h1>
          <p className="mt-6 max-w-[66ch] text-[15px] leading-7 text-dimx">
            Canvas, formerly Blink, keeps spatial notes on your Mac. The iPhone and iPad app is
            a read-only companion that can keep a copy of those notes available offline.
          </p>
        </div>

        <div className="mt-14 divide-y divide-[var(--line)] border-y border-linex">
          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">Try it first</h2>
            <p className="text-[14px] leading-6 text-dimx">
              Choose Try sample notes on the welcome screen to explore Canvas without a Mac.
              You can also find sample notes in Settings → About. The Sample Notes banner identifies
              the examples. Choose Exit Samples to leave them. Samples do not replace or change
              your personal notes or the saved offline copy.
            </p>
          </section>

          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">Personal notes</h2>
            <div className="space-y-4 text-[14px] leading-6 text-dimx">
              <p>
                Canvas for Mac is required to read your personal notes on iPhone or iPad.
                Keep Canvas running on your Mac and connect both devices to the same local network.
              </p>
              <ol className="list-decimal space-y-3 pl-5">
                <li>On your Mac, right-click the Canvas menu bar icon and choose Mobile Access → Enable Mobile Access.</li>
                <li>On your iPhone or iPad, open Settings in Canvas, then choose Mac under Connection.</li>
                <li>Allow local-network access when Canvas asks on your iPhone or iPad.</li>
                <li>Select your Mac in Canvas and request access.</li>
                <li>Approve the request in Canvas on your Mac.</li>
              </ol>
              <p>
                Once the copy reaches your mobile device, you can read it without a network
                connection. Changes to the original notes are made on your Mac.
              </p>
            </div>
          </section>

          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">Connection help</h2>
            <div className="space-y-4 text-[14px] leading-6 text-dimx">
              <p>
                If your Mac does not appear, check that it is awake, Canvas is running, and both
                devices are on the same local network. Check that Mobile Access is enabled in
                Canvas&apos;s Mac menu and that Canvas has Local Network
                permission in your iPhone or iPad&apos;s system Settings.
              </p>
              <p>
                If the connection is waiting for approval, check Canvas on the Mac for the
                access request. Each device must be approved before it can receive personal notes.
              </p>
            </div>
          </section>

          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">Remove offline notes</h2>
            <p className="text-[14px] leading-6 text-dimx">
              In Canvas, open <strong className="font-semibold text-[var(--text)]">Settings → On This Device → Notes → Remove Notes</strong>{" "}
              to delete the offline copy and disconnect from the Mac. Your original Markdown files
              stay on the Mac. Reconnecting can download a new copy.
            </p>
          </section>

          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">Contact</h2>
            <div className="space-y-4 text-[14px] leading-6 text-dimx">
              <p>
                Email{" "}
                <a
                  href="mailto:arach@tchoupani.com"
                  className="text-acc underline decoration-[var(--line-2)] underline-offset-4 hover:decoration-[var(--acc)]"
                >
                  arach@tchoupani.com
                </a>{" "}
                for help with Canvas.
              </p>
              <p>
                Include your device model, operating system version, Canvas version, and the step
                where the problem occurs. You do not need to include the contents of your notes.
              </p>
            </div>
          </section>
        </div>
      </main>

      <footer className="border-t border-linex py-8">
        <div className="mx-auto flex max-w-3xl flex-wrap items-center justify-between gap-3 px-4 text-[10px] text-[var(--ghost)] md:px-6">
          <span>Canvas · local-first spatial notes</span>
          <a href="/privacy/" className="transition-colors hover:text-acc">Privacy</a>
          <a href="/" className="transition-colors hover:text-acc">blink.arach.dev</a>
        </div>
      </footer>
    </div>
  )
}
