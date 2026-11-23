# teams-zig

A Microsoft Teams client in Zig, with no third-party dependencies.

## Build

```sh
zig build
```

The binary is `zig-out/bin/teams-zig`.

## Sign in

```fish
scripts/teams-token.fish
```

The script signs in through agent-browser. It stores the skype token and region in the login keychain.

## Use it as an MCP server in Claude Code

1. Build with `zig build`.
2. Register the server at user scope. Replace `<repo>` with the path to this repo:

   ```sh
   claude mcp add --scope user teams-zig -- <repo>/zig-out/bin/teams-zig mcp
   ```

The server has five tools: `whoami`, `chats`, `messages`, `unread` and `send`.

`send` posts a message to Teams.

Optional: add an `ask` rule for `mcp__teams-zig__send` to your Claude Code settings. With this rule, Claude Code prompts before each send, even in bypass mode:

```json
{
  "permissions": {
    "ask": ["mcp__teams-zig__send"]
  }
}
```
