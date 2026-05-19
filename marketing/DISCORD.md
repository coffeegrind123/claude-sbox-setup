**Claude Code integration for the s&box editor.**

Anything user-facing in the editor → reachable from the agent. 593 MCP tools across scene, inspector, Hammer, ModelDoc, AnimGraph, assets, schema, Roslyn, hotload, physics, audio, particles, NavMesh - agent can spawn prefabs, drive Hammer cameras, swap entity classes, query the live API schema, run C# snippets, batch-transform selections, etc.

A docked PTY terminal (View → ClaudeSbox) lets you bring your own harness - Codex, Claude Code, anything you can run in a shell - straight inside sbox-dev. Three concurrent MCP transports on 127.0.0.1:6790 - HTTP, SSE, stdio bridge - any MCP client connects.

**Install**

From your sbox-public checkout (`git clone --recursive https://github.com/Facepunch/sbox-public`), open a terminal and run:

```
cd game\addons
git clone https://github.com/coffeegrind123/claude-sbox-setup.git
cd claude-sbox-setup
.\Setup.bat
.\Bootstrap-And-Capture.bat
```

Launch `game\sbox-dev.exe` with any project, open the developer console, and run once, ever:

```
package_install ghage.claude-sbox tools
```

That's it. The engine patches from the setup repo handle everything from here on - the addon auto-mounts for every project on every editor restart, with no redownload (files are mirrored to a global cache at `<sbox-public>/game/.sbox-global/cloud/.bin/`). The MCP host comes up automatically on http://127.0.0.1:6790.

**Connect Claude Code**

```
claude mcp add --transport http -s user sbox http://127.0.0.1:6790/mcp
```

(or `http://host.docker.internal:6790/mcp` if you run Claude Code inside a devcontainer for example)

For stdio-only MCP clients (Claude Desktop, Cline, etc.), use the bundled bridge at `game/addons/claude-sbox-setup/bridge/dist/bridge.js` - see the setup repo's README for client configs.

https://sbox.game/ghage/claude-sbox/
Setup repo: <https://github.com/coffeegrind123/claude-sbox-setup>
