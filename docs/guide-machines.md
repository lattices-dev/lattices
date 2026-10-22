---
title: Working across machines
description: Run lats commands on another machine, lend your mouse and keyboard to it, and move windows between displays
order: 1.5
---

Lattices reaches other machines in two separate ways. A **host** accepts
`lats` commands from this Mac over the network. A **visit** lends this Mac's
mouse and keyboard to another machine when you push the pointer past a
screen edge. The two are paired separately. This page sets up each one and
then covers the display commands that work with both.

Both ways go through the host's gateway, which binds only to the host's
Tailscale address. Install Tailscale on every machine first. Macs need the
Lattices app; Linux machines need the separate
[Linux install](/lattices/docs/install-linux).

The examples use two Macs, `mini` (this one) and `air`, and a Linux box,
`archie`.

## See what is around you

```bash
lats machines
lats machines --json
```

Expected: one row per machine with reachability, Lattices version, display
count, pairing state and placement. The local machine is always listed.

## Run commands on another machine

### 1. Start the gateway on the host

On `air`:

```bash
lats gateway start --tailnet
lats gateway status
```

The gateway runs until `lats gateway stop`. It does not install a login
item, so start it again after a reboot. It admits devices that belong to
the host's Tailscale user unless you pass `--allow-user` or `--allow-tag`.

### 2. Register the host here

On `mini`:

```bash
lats hosts add air air.tailnet-name.ts.net
lats hosts                # configured hosts and whether they answer
lats hosts --discover
```

Hosts are stored in `~/.lattices/hosts.json`.

### 3. Pair and approve

On `mini`, request a scope:

```bash
lats --host air pair --read-only            # core read methods, no screen contents
lats --host air pair --read-only --screen   # also screenshots, OCR, terminal text
lats --host air pair                        # read, screen and act
lats --host air pair --drive                # also desktop input and shell
lats --host air pair --grant lattices:windows.list --grant lattices:windows.place
```

On `air`, check the fingerprint and approve:

```bash
lats gateway clients
lats gateway approve <client-id>
```

Each stored grant names one `product:method`. A later request for more
methods needs another approval on the host. To reduce a client's access,
revoke it and pair again:

```bash
lats gateway revoke <client-id>
```

### 4. Run commands

```bash
lats @air windows
lats @air display list
lats @air call windows.search '{"query":"tideline"}'
lats --host air capture display 0     # screenshot saved on this Mac
```

`lats @<host>` forwards commands that wrap a daemon call. Commands that only
make sense locally say so. `@local` is this machine.

## Lend your mouse and keyboard

A visit lets you drive `archie` or `air` from `mini`'s keyboard. Your own
pointer parks at the edge; a labelled visitor cursor appears on the host.

### 1. Allow visits on the host

On a Mac host:

```bash
lats visit host on
```

A Linux host accepts visits through `lattices-host` once its gateway runs.

### 2. Pair the visit from here

On `mini`:

```bash
lats visit pair archie                 # uses the host's gateway address
lats visit pair air air.tailnet-name.ts.net:9399 right
lats visit status                      # paired hosts and this Mac's code
```

Approve the pairing on the host when asked. Visit pairing and host pairing
are different stores; approving one does not grant the other.

### 3. Say where the host sits

```bash
lats visit side archie left            # beside the leftmost display
lats visit place archie -1920 0        # exact global coordinates
```

Or open **Workspace > Machines** in the app and drag the machine against the
display edge where the pointer should cross.

### 4. Arm crossing and visit

```bash
lats visit on          # pushing past the edge starts a visit
lats visit archie      # start a visit now, without crossing
```

Expected: the host draws a visitor cursor named after this Mac. Your keys
type on the host. Command is sent as Super on Linux.

End a visit by moving back through the edge you came in by, by pressing
Control+Option+Command+Home, or with:

```bash
lats visit end
lats home              # end the visit and center the pointer on the main display
lats visit off         # stop crossing at edges
```

A visit also ends on its own when either side stops answering for six
seconds. Your own cursor never left, so nothing is stranded.

Forget a pairing:

```bash
lats visit forget archie
```

## Move windows between displays

These commands work on this Mac and, through `lats @<host>`, on a host.
Name a display by number or by any part of its name: `dell`, `u32`, `1`.

```bash
lats display list                        # displays and what each shows
lats bring dell                          # every other display's windows onto the Dell
lats bring --undo
lats display gather u32 --to dell        # one display's windows, laid out as they were
lats display restore u32
lats main dell                           # make it main; reverts after 15 seconds
lats main dell --keep
lats visit arrangement keep              # accept a trial started in the app
lats visit arrangement revert
```

A display plugged into another machine, through a monitor's second input for
example, can be marked so the pointer skips it:

```bash
lats elsewhere u32 arts-mini
lats here u32
lats visit screens
```

`lats display lend <display>` asks on the other screens where to gather a
display's windows, for an input switch the Mac cannot see.

In the app, **Workspace > Machines** does the same with a drawing of the
displays. Moving a local display there creates a draft: **Apply** starts a
15-second trial, **Keep** accepts it and **Revert** restores the previous
arrangement. Opening Machines does not arm a visit.

## What stays local

The gateway never forwards raw input events, Action drive leases, Speech
playback reservations, voice input or the VNC listener. Remote screenshots
need the `--screen` scope. See
[Private IPC and the gateway](/lattices/docs/concepts#private-ipc-and-the-gateway)
for the full list.

## Related

- [Visiting cursor](/lattices/docs/visit): the visit protocol and host-side
  behaviour.
- [Install on Linux](/lattices/docs/install-linux): the Hyprland host.
