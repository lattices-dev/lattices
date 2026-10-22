---
title: Overview
description: What Action is, what it installs, and how it relates to Lattices
order: 0
---

Action is a native macOS app that lets agents inspect and control Mac apps and
browser surfaces, and record what they did. It is a separate product in the
Lattices family. It has its own signed `Action.app`, its own local agent, its
own release tags (`action-vX.Y.Z`), and its own lifecycle.

## What Action does

| Job | Surfaces |
| --- | --- |
| Inspect | Screenshots, accessibility trees, Apple Vision OCR, optional provider vision |
| Control | Target resolution, clicks, typing, key chords, drags, scrolls, focus, app launch |
| Record | ScreenCaptureKit video of a window or region, plus session traces and artifacts |
| Stage | A flat backdrop behind listed windows for a clean take (see [Stage](/action/docs/stage)) |
| Work out of sight | A private virtual display for an app or Action-owned browser (see [Agent layer](/action/docs/agent-layer)) |

## What gets installed

| Part | Where | Purpose |
| --- | --- | --- |
| `Action.app` | `/Applications/Action.app` (bundle id `dev.lattices.Action`) | AppKit lifecycle, menus, WebKit, permission UI, recording probes |
| Action agent | `Action.app/Contents/Helpers/ActionAgent.app`, `ws://127.0.0.1:4319` | Local WebSocket RPC for native requests and drive leases |
| Agent runtime | A runtime bundle or a `products/action` checkout | TypeScript runtime, product CLI, and the Action MCP server |

`lats action install` installs the app only. The app alone does not include MCP
orchestration. To connect an agent over MCP, install the matching runtime as
described in [Agent setup](/action/docs/agent-setup).

## How Action relates to Lattices

Lattices 0.15.1 owns workspace organization on `lattices.sock`. Action 0.4.0
owns native computer use on `action.sock`. Both sockets are in
`~/.lattices/run`. Quitting one app does not stop the other. Remote access goes only through the opt-in Lattices gateway. See
[API](/action/docs/api#private-connection).

The Lattices CLI is the family entry point. `lats action` installs, launches,
quits, and queries Action, and forwards other verbs to the Action CLI. Two
nearby commands do not reach Action:

- `lats computer` calls the core daemon's `computer.*` methods. See the
  [Lattices API](/lattices/docs/api).
- `lats mcp` serves the `browser_*` tools that drive Action-owned Chrome
  profiles over CDP. That server is part of the Lattices CLI, not Action.app.
  See [Browser](/action/docs/browser) and the [Lattices MCP](/lattices/docs/mcp).

[Concepts](/action/docs/concepts) has the full command-to-process table.

## Platforms

Action.app runs on macOS. There is no Linux build of Action.app. The Action
runtime can drive a Linux desktop that runs `lattices-host`. See
[Remote engine](/action/docs/remote-engine).

## Next steps

- [Getting started](/action/docs/getting-started): install, launch, and check the app.
- [Agent setup](/action/docs/agent-setup): connect an MCP agent to a matched runtime.
- [Concepts](/action/docs/concepts): processes, ports, sessions, and leases.
- [API](/action/docs/api): the agent WebSocket protocol.
