# Connect Action to your agent

The macOS quick start proves that native capture works. MCP browser orchestration needs an additional runtime. Installing a skill alone does not install that runtime.

## Install the matching runtime

1. Install [Bun](https://bun.sh/docs/installation).
2. Open the [Action 0.3.1 release](https://github.com/arach/lattices/releases/tag/action-v0.3.1). Download `Action-agent-runtime-0.3.1.tar.gz` and `SHA256SUMS` from that release into the same directory. This is a pinned, published runtime, not the multi-workspace development build shown in the video.
3. In that directory, verify the archive before extracting it:

```sh
shasum -a 256 Action-agent-runtime-0.3.1.tar.gz
cat SHA256SUMS
```

The computed hash must equal the entry for the runtime archive. Stop if it differs.

4. Extract into a new directory. Keep its `bin/` and `products/` directories together:

```sh
mkdir action-runtime-0.3.1
tar -xzf Action-agent-runtime-0.3.1.tar.gz -C action-runtime-0.3.1
cd action-runtime-0.3.1
export ACTION_ROOT="$PWD/products/action"
open "$ACTION_ROOT/native/dist/Action.app"
bun "$ACTION_ROOT/packages/cli/src/main.ts" capabilities
```

Quit any other Action app before opening the bundled app. Grant permissions to the bundled app when requested. Keep the previous app/runtime for rollback. Expect `runtimeParity.state` to be `matched-source-digest`; a version number alone is not a match.

## Configure MCP

Add a local stdio MCP server in your agent's settings. Use the absolute path returned by `command -v bun` as the command, and the absolute path to `products/action/packages/mcp/src/index.ts` as its argument.

The following is a configuration template. Replace `/absolute/path` with your extracted runtime directory and `/absolute/path/to/bun` with your Bun executable. Your harness may use a different configuration format.

```json
{
  "mcpServers": {
    "action": {
      "command": "/absolute/path/to/bun",
      "args": ["/absolute/path/products/action/packages/mcp/src/index.ts"],
      "env": {
        "ACTION_ROOT": "/absolute/path/products/action"
      }
    }
  }
}
```

Restart the MCP connection. Ask your agent:

> Read Action's capabilities and available tools. Report the connected host, native/runtime match, and any setup requirements before taking control.

Expect a capabilities report, not immediate browser movement. Do not treat an open connection as proof that every feature is available.

## Before a private workspace

Read the [agent-layer guide](https://lattices.dev/action/agent-layer.md). Check fresh MCP capabilities, `tools/list`, host safety and private-layer acceptance before opening. A matching runtime does not certify a display configuration. Preparing a virtual monitor changes display topology and requires explicit user approval. Private browser input stays CDP-only; an input failure does not authorize control of the user's desktop.

The demo's named stage and agent workspaces are a development preview. Do not assume the published release supports them. Do not rebuild on an installation target to obtain a missing feature.

## Linux

Use the [remote Linux setup](https://lattices.dev/action/remote-engine.md). This is a remote-host workflow, not a Linux build of Action.app.
