---
title: Skills
description: Review patterns an AI agent follows when changing Action
order: 11
---

These are project-specific skills or task patterns an AI agent should follow.

## Native runtime review

Use when:

- changing AppKit lifecycle code
- changing agent startup or bridge logic
- changing WebKit entry paths

Instructions:

1. read [Native runtime](/action/docs/native-runtime)
2. verify whether the change belongs in app code or agent code
3. keep AppKit-owned behavior in `Action.app`
4. verify the signed app still builds

## Recording review

Use when:

- changing `ScreenCaptureKit` recording
- changing stop-file or finished-file handling
- changing probe launch behavior

Instructions:

1. read [Recording](/action/docs/recording)
2. inspect the probe launcher and probe app runner
3. preserve `.mov` + `.finished` behavior
4. test a real recording path, not just a unit-level refactor

## Agent API review

Use when:

- adding WebSocket methods
- changing request or response shape
- updating CLI-to-agent behavior

Instructions:

1. read [Api](/action/docs/api)
2. update the protocol source of truth
3. confirm method names remain documented
4. verify callers still match the transport contract

## Hermes Action

Use when:

- connecting Hermes to the native Action runtime
- using Action MCP tools from a harness
- recording or inspecting native macOS surfaces through Hermes

Instructions:

1. read [docs/harnesses/hermes-action.md](harnesses/hermes-action.md)
2. use [skills/hermes-action/SKILL.md](../skills/hermes-action/SKILL.md) as the harness doctrine
3. prefer observe and resolve before act
4. treat recording start as asynchronous until `.finished` or `action.record.status` confirms completion
