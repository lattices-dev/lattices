# lattices

> macOS developer workspace manager — tmux sessions with a native menu bar app for tiling, navigation, and project management

You are an expert at installing lattices. Execute these steps autonomously
and inform the user of any decisions made. Request approval before running
installation commands.

## OBJECTIVE

Install the lattices CLI and optionally the native macOS menu bar companion app.

## DONE WHEN

`lats help` returns Usage information for lattices CLI

## TODO

- [ ] Install tmux if not present
- [ ] Clone the repository
- [ ] Link the CLI globally
- [ ] Build and launch the menu bar app
- [ ] Create a config in your project
- [ ] Start your first workspace

## Prerequisites

- macOS 26.0+
- tmux (brew install tmux)
- Node.js >= 18
- Swift 6.2 / Xcode 26+ (only if building the menu bar app from source)

## Step 1: Install tmux if not present

```bash
brew install tmux
```

## Step 2: Install from npm

```bash
npm install -g @lattices/lattices
```

Or with your preferred package manager:

```bash
pnpm add -g @lattices/lattices
bun add -g @lattices/lattices
```

### Alternative: Install from source

```bash
git clone https://github.com/lattices-dev/lattices && cd lattices
bun link
```

## Step 3: Build and launch the menu bar app

```bash
lats app
```

## Step 4: Create a config in your project

```bash
cd ~/your-project && lats init
```

## Step 5: Start your first workspace

```bash
lats
```

## EXECUTE NOW

Proceed with installation following the TODO checklist above.
