<a href="https://lattices.dev">
  <picture>
    <source media="(max-width: 600px) and (prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/lattices-dev/.github/main/profile/assets/hero-mobile-dark.svg">
    <source media="(max-width: 600px) and (prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/lattices-dev/.github/main/profile/assets/hero-mobile-light.svg">
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/lattices-dev/.github/main/profile/assets/hero-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/lattices-dev/.github/main/profile/assets/hero-light.svg">
    <img src="https://raw.githubusercontent.com/lattices-dev/.github/main/profile/assets/hero-light.svg" width="1200" alt="Lattices. Workspaces for agents (and you). Native Mac tools. A shared desktop.">
  </picture>
</a>

<p align="center">
  Arrange your windows. Keep your terminals running.<br>
  Give your agents the same workspace controls you use.
</p>

<p align="center">
  <a href="https://github.com/lattices-dev/lattices/releases/latest"><strong>Download for Mac ↗</strong></a>
  &nbsp; · &nbsp;
  <a href="https://lattices.dev/docs/overview">Read the docs</a>
  &nbsp; · &nbsp;
  <a href="https://github.com/lattices-dev/lattices">Explore the source</a>
</p>

<p align="center"><sub>Native macOS apps · Open source · Built for people and agents</sub></p>

<br>

## Meet the family

Four apps, one repository. Open a product below for its README, installation steps, and source. Speech lives in `products/voice`, where the app is called **Voice**.

<table>
<tr>
<td width="50%" valign="top">
  <a href="https://lattices.dev"><img src="https://raw.githubusercontent.com/lattices-dev/.github/main/profile/assets/lattices.png" width="48" height="48" alt="Lattices icon"></a>
  <h3><a href="https://lattices.dev">Lattices</a></h3>
  <p><strong>A workspace you can program.</strong></p>
  <p>Tile windows, switch projects, search your screen, and return to persistent terminal sessions.</p>
  <p><a href="https://lattices.dev/docs/quickstart">Set up your workspace →</a></p>
</td>
<td width="50%" valign="top">
  <a href="https://github.com/lattices-dev/lattices/tree/main/products/action"><img src="https://raw.githubusercontent.com/lattices-dev/.github/main/profile/assets/action.png" width="48" height="48" alt="Action icon"></a>
  <h3><a href="https://github.com/lattices-dev/lattices/tree/main/products/action">Action</a></h3>
  <p><strong>Let your agents use your Mac.</strong></p>
  <p>Observe apps, operate browser surfaces, and record what happens along the way.</p>
  <p><a href="https://lattices.dev/action">Explore computer use →</a> · <a href="https://github.com/lattices-dev/lattices/tree/main/products/action">README &amp; source</a></p>
</td>
</tr>
<tr>
<td width="50%" valign="top">
  <a href="https://github.com/lattices-dev/lattices/tree/main/products/blink"><img src="https://raw.githubusercontent.com/lattices-dev/.github/main/profile/assets/blink.png" width="48" height="48" alt="Blink icon"></a>
  <h3><a href="https://github.com/lattices-dev/lattices/tree/main/products/blink">Blink</a></h3>
  <p><strong>Keep a thought where you need it.</strong></p>
  <p>Write and arrange notes in floating windows. Leave context beside the work it belongs to.</p>
  <p><a href="https://lattices.dev/blink">Make room for your notes →</a> · <a href="https://github.com/lattices-dev/lattices/tree/main/products/blink">README &amp; source</a></p>
</td>
<td width="50%" valign="top">
  <a href="https://github.com/lattices-dev/lattices/tree/main/products/voice"><img src="https://raw.githubusercontent.com/lattices-dev/.github/main/profile/assets/speech.png" width="48" height="48" alt="Speech icon"></a>
  <h3><a href="https://github.com/lattices-dev/lattices/tree/main/products/voice">Speech</a></h3>
  <p><strong>Give your agents a voice.</strong></p>
  <p>Listen to queued readouts, follow the words in a playback HUD, and control the pace.</p>
  <p><a href="https://lattices.dev/speech">Hear what comes next →</a> · <a href="https://github.com/lattices-dev/lattices/tree/main/products/voice">README &amp; source</a></p>
</td>
</tr>
</table>

## Your next workspace starts here

**Start with the Mac app.** [Download Lattices](https://github.com/lattices-dev/lattices/releases/latest), drag it to Applications, and launch it. Press **⌘⇧M** to open the command palette. Requires macOS 26 or later.

**Prefer the terminal?** Install [Bun](https://bun.sh), then install the CLI and bundled app:

```sh
npm install -g @lattices/lattices
lats app
```

**Bring your coding agent.** Install the skills for Lattices and its companion tools:

```sh
npx skills add lattices-dev/lattices --all --global --yes
```

<details>
<summary><strong>A few commands to try</strong></summary>

With the Lattices app running:

```sh
lats map                 # See the current workspace
lats tile right          # Tile the frontmost window
lats search api --deep   # Search windows and terminal context
```

The [agent API](https://lattices.dev/docs/api) exposes workspace controls to your own tools. The [agent guide](https://lattices.dev/docs/agents) covers skills and setup.

</details>

<br>

---

<p align="center">
  <strong>Make yourself at home.</strong><br>
  The apps, CLI, and skills live together in <a href="https://github.com/lattices-dev/lattices">lattices-dev/lattices</a>.<br>
  <a href="https://github.com/lattices-dev/lattices/issues">Report an issue</a> ·
  <a href="https://github.com/lattices-dev/lattices/blob/main/.github/CONTRIBUTING.md">Contribute</a> ·
  <a href="https://lattices.dev">lattices.dev ↗</a>
</p>
