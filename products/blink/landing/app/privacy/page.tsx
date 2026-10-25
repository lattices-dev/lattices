import type { Metadata } from "next"
import { BlinkMark } from "@/components/homepage/BlinkMark"

export const metadata: Metadata = {
  title: "Privacy — Canvas",
  description: "How Canvas handles notes, device data, local-network access, and website analytics.",
  alternates: { canonical: "/privacy/" },
}

const appFacts = [
  "No Canvas account is required.",
  "The app contains no advertising or tracking SDKs.",
  "Canvas does not send your notes or workspace metadata to Arach or another cloud service.",
  "The mobile companion is read-only in this release.",
]

export default function PrivacyPage() {
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
          <a
            href="https://github.com/lattices-dev/lattices/tree/main/products/blink"
            className="rounded-[4px] py-1 text-[11px] text-dimx transition-colors hover:text-acc"
          >
            source ↗
          </a>
        </div>
      </header>

      <main className="mx-auto max-w-3xl px-4 pb-24 pt-14 md:px-6 md:pt-20">
        <div className="max-w-2xl">
          <p className="label-x">Privacy policy</p>
          <h1 className="font-display mt-4 text-balance text-5xl font-semibold leading-[0.95] tracking-[-0.025em] text-[var(--text)] md:text-6xl">
            Canvas privacy policy.
          </h1>
          <p className="mt-6 max-w-[66ch] text-[15px] leading-7 text-dimx">
            Canvas, formerly Blink, is local-first software. The Mac app keeps notes as Markdown files you control,
            and the iPhone and iPad companion receives a replaceable, read-only copy directly
            from your Mac.
          </p>
          <p className="mt-4 text-[11px] text-faintx">Updated October 19, 2026</p>
        </div>

        <div className="mt-14 divide-y divide-[var(--line)] border-y border-linex">
          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">The app</h2>
            <ul className="space-y-3 text-[14px] leading-6 text-dimx">
              {appFacts.map((fact) => (
                <li key={fact} className="flex gap-3">
                  <span className="mt-[0.65rem] h-1.5 w-1.5 shrink-0 bg-[var(--acc)]" aria-hidden />
                  <span>{fact}</span>
                </li>
              ))}
            </ul>
          </section>

          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">Local connection</h2>
            <div className="space-y-4 text-[14px] leading-6 text-dimx">
              <p>
                Canvas asks for local-network access so the mobile companion can discover and pair
                with Canvas on your Mac. Note snapshots travel over the local network inside an
                encrypted peer session. You select a Mac and request access. The Mac must approve
                your device before it can receive your personal notes. Access can be revoked on the Mac.
              </p>
              <p>
                Canvas for Mac is required to read your personal notes on iPhone or iPad. Once a
                copy is saved on your mobile device, you can read it without the Mac or a network connection.
              </p>
              <p>
                The mobile copy is stored in the app&apos;s private container and is excluded from
                device backups. The device&apos;s pairing identity is kept in non-synchronizing
                Keychain storage.
              </p>
            </div>
          </section>

          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">Sample notes</h2>
            <p className="text-[14px] leading-6 text-dimx">
              You can choose Try sample notes on iPhone or iPad without connecting to a Mac.
              These bundled examples are displayed separately from your personal notes and never
              replace or change the saved offline copy. Choose Exit Samples to return to your notes.
            </p>
          </section>

          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">Your controls</h2>
            <div className="space-y-4 text-[14px] leading-6 text-dimx">
              <p>
                In Canvas on your iPhone or iPad, open <strong className="font-semibold text-[var(--text)]">Settings → On This Device → Notes → Remove Notes</strong>{" "}
                to delete the offline copy and disconnect from the Mac. Your original Markdown files
                stay on the Mac. Reconnecting can download a new copy.
              </p>
            </div>
          </section>

          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">This website</h2>
            <div className="space-y-4 text-[14px] leading-6 text-dimx">
              <p>
                blink.arach.dev uses Google Analytics to understand aggregate site visits. Google
                may receive browser and device details, referring pages, page interactions, and an
                approximate location derived from your IP address. This website analytics is
                separate from the Canvas apps; the apps do not contain Google Analytics.
              </p>
              <p>
                Learn more in Google&apos;s{" "}
                <a
                  href="https://policies.google.com/privacy"
                  className="text-acc underline decoration-[var(--line-2)] underline-offset-4 hover:decoration-[var(--acc)]"
                >
                  privacy policy
                </a>
                .
              </p>
            </div>
          </section>

          <section className="grid gap-5 py-9 md:grid-cols-[10rem_1fr] md:gap-8">
            <h2 className="text-[12px] font-bold text-[var(--text)]">Contact</h2>
            <p className="text-[14px] leading-6 text-dimx">
              Questions about Canvas privacy can be sent to{" "}
              <a
                href="mailto:arach@tchoupani.com"
                className="text-acc underline decoration-[var(--line-2)] underline-offset-4 hover:decoration-[var(--acc)]"
              >
                arach@tchoupani.com
              </a>
              .
            </p>
          </section>
        </div>
      </main>

      <footer className="border-t border-linex py-8">
        <div className="mx-auto flex max-w-3xl flex-wrap items-center justify-between gap-3 px-4 text-[10px] text-[var(--ghost)] md:px-6">
          <span>Canvas · local-first spatial notes</span>
          <a href="/support/" className="transition-colors hover:text-acc">Support</a>
          <a href="/" className="transition-colors hover:text-acc">
            blink.arach.dev
          </a>
        </div>
      </footer>
    </div>
  )
}
