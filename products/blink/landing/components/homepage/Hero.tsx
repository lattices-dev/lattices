import Image from 'next/image'
import SpatialDemo from './SpatialDemo'
import { GhostButton, HyperChord, PrimaryButton } from './shared'

export default function Hero() {
  return (
    <section id="top" className="relative isolate overflow-hidden pt-32 md:pt-36 pb-16 md:pb-24">
      <div className="pointer-events-none absolute inset-0 -z-10" aria-hidden>
        <Image
          src="/hero-memory-field-warm.jpg"
          alt=""
          fill
          priority
          sizes="100vw"
          className="hero-art object-cover object-[58%_center]"
        />
        <div className="hero-art-wash absolute inset-0" />
        <div className="hero-dither absolute inset-0" />
      </div>
      <div className="relative mx-auto max-w-5xl px-4 md:px-6">
        <div className="grid gap-10 lg:grid-cols-[1fr_1.05fr] lg:gap-12 items-start">
          <div className="rise-in rise-1">
            <h1 className="text-balance">
              <span className="font-display block text-[66px] md:text-[86px] font-semibold tracking-[-0.025em] leading-[0.84] text-[var(--text)]">
                Canvas
              </span>
              <span className="font-display mt-6 block max-w-md text-[32px] md:text-[40px] font-medium tracking-[-0.012em] leading-[0.98] text-[var(--text)]">
                spatial notes for your Mac
              </span>
            </h1>

            <p className="mt-6 max-w-md text-[14px] leading-[1.75] text-dimx">
              A menubar app. Press Hyper+N anywhere and a glass note lands on your
              screen —{' '}
              <span className="text-acc">placed in space, remembered there</span>.
              Plain markdown you own. Open to your agents.
            </p>

            <div className="mt-7 space-y-2.5 text-[13px] text-dimx">
              <div className="flex items-center gap-3 flex-wrap">
                <HyperChord letter="N" action="New note" />
                <span className="text-faintx">new note</span>
              </div>
              <div className="flex items-center gap-3 flex-wrap">
                <HyperChord letter="B" action="Blink all panels" />
                <span className="text-faintx">blink all panels</span>
              </div>
            </div>

            <div className="mt-8 flex flex-wrap items-center gap-3">
              <PrimaryButton href="https://github.com/lattices-dev/lattices/releases/download/canvas-v2.3.0/Canvas.dmg">
                <span className="text-[15px] leading-none" aria-hidden>
                  ↓
                </span>{' '}
                download for macOS
              </PrimaryButton>
              <GhostButton href="https://github.com/lattices-dev/lattices/tree/main/products/blink">
                github <span className="text-faintx" aria-hidden>↗</span>
              </GhostButton>
            </div>

            <p className="mt-5 text-[11px] text-faintx">
              free & open source · macOS 14+ · Apple Silicon
            </p>
          </div>

          <div className="rise-in rise-2">
            <SpatialDemo />
            <p className="mt-3 text-[11px] leading-relaxed text-faintx">
              Panels remember position and size · native NSPanel glass
            </p>
          </div>
        </div>
      </div>
    </section>
  )
}
