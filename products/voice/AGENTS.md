# Voice

Voice (formerly Speech) is a separate macOS helper app. It owns synthesis
requests, queue state, audio playback, playback HUD, preferences, and its
authenticated local RPC server. Lattices is a client. Never transfer a Voice
process handle or queue ownership to Lattices, and never stop either app while
quitting the other.

Frozen identifiers, keyed to shipped installs: bundle ID `dev.lattices.Speech`,
RPC methods `speech.*`, RPC port, capability token path, UserDefaults domains,
and Keychain service `dev.lattices.app.voice`. Internal Swift types and the
`SpeechAppRuntime` module keep their Speech names.

Reuse HudsonUIAudio providers. Phonon (Gradium's Phonon 31m, Apache 2.0) renders
in-process on the Neural Engine through xn-ptts, pinned to 0.4.0, with its model
bundle pinned by SHA-256; do not route local speech through Vox or a Python runtime.
Do not add FluidAudio: its NeMo normalizer and Phonon both link a Rust std, and their
duplicate rust_eh_personality fails the link. Keep existing credential service
`dev.lattices.app.voice`; do not copy credential values into preferences or logs.
Source provenance is recorded in SOURCE-PROVENANCE.json. The source checkout is
an active snapshot and must remain untouched.

Build/test with `HUDSONKIT_WITH_VOICE=0 swift test --package-path products/voice`.
Without the variable, Hudson adds Vox and Moonshine back to Package.resolved;
tools/package.sh sets it from build.json. The remote Hudson default contains
the shared speech changes.
Set SPEECH_HUDSON_PATH only for an explicit local dependency experiment.
Phonon's live tests load the real model and run only with VOICE_PHONON_LIVE=1;
set VOICE_PHONON_LIVE_OUT to a directory to keep their WAVs.
Do not publish, install, or launch this app implicitly.
