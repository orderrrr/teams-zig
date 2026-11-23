# teams-zig

A Microsoft Teams client in Zig, with no third-party dependencies.

## Install

The releases page has a binary for Apple silicon Macs (macOS 15 or later). Replace `0.11.0` with the release you want.

1. Download the binary and its checksum:

   ```sh
   curl -LO https://github.com/orderrrr/teams-zig/releases/download/v0.11.0/teams-zig-0.11.0-aarch64-macos.tar.gz
   curl -LO https://github.com/orderrrr/teams-zig/releases/download/v0.11.0/SHA256SUMS
   ```

2. Check the download:

   ```sh
   shasum -a 256 -c SHA256SUMS
   ```

3. Unpack it:

   ```sh
   tar -xzf teams-zig-0.11.0-aarch64-macos.tar.gz
   ```

4. If you downloaded the file with a browser, remove the quarantine attribute. The binary is not signed by an Apple developer, so macOS stops it otherwise:

   ```sh
   xattr -d com.apple.quarantine teams-zig
   ```

5. Put the binary on your `PATH`, for example:

   ```sh
   mkdir -p ~/.local/bin
   mv teams-zig ~/.local/bin/
   ```

## Build from source

```sh
zig build
```

The binary is `zig-out/bin/teams-zig`. It needs Zig 0.17 and the Xcode Command Line Tools.

`zig build release` builds the release binary, `zig-out/release/teams-zig-aarch64-macos`.

## Sign in

`teams-zig login` signs in through agent-browser, tested with version 0.43.0. Install it once:

1. Install agent-browser. Homebrew's formula also installs Node:

   ```sh
   brew install agent-browser
   ```

2. Let agent-browser download its browser:

   ```sh
   agent-browser install
   ```

Then sign in:

```sh
teams-zig login
```

Teams opens in a browser window. Sign in if Teams asks. `login` stores the skype token and region in the login keychain, then closes the window. The skype token lasts about a day; when a command says it has expired, run `teams-zig login` again.

teams-zig keeps a cache in `~/Library/Caches/teams-zig/cache.txt`: your user, the names in 1:1 chats and which chat each name picks. The cache holds no token. The script deletes it at each sign-in.

## Use it as an MCP server in Claude Code

1. Install the binary, or build it with `zig build`.
2. Register the server at user scope. Use the binary's full path, for example `~/.local/bin/teams-zig` or `<repo>/zig-out/bin/teams-zig`:

   ```sh
   claude mcp add --scope user teams-zig -- ~/.local/bin/teams-zig mcp
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
