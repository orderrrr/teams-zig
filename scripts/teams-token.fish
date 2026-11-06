#!/usr/bin/env fish
# Signs in to Teams in a dedicated agent-browser profile and stores the skype token in the
# login keychain for teams-zig. Token values are never printed.

set -l profile "$HOME/Library/Application Support/teams-zig/browser"
set -l wait_seconds 300
set -lx AGENT_BROWSER_SESSION teams-zig

# The web client sends the skype token as a request header, not as the skypetoken_asm cookie.
set -l skype_token_query '[.data.requests[].headers | to_entries[]
    | select(.key | ascii_downcase == "x-skypetoken") | .value | sub("^skypetoken="; "")] | first // empty'

mkdir -p $profile
agent-browser --headed --profile $profile open https://teams.microsoft.com >/dev/null
or begin
    echo "teams-token: couldn't open the browser" >&2
    exit 1
end

echo "Sign in to Teams in the browser window if asked. Waiting up to $wait_seconds seconds..." >&2
set -l skype_token
for second in (seq 2 2 $wait_seconds)
    set skype_token (agent-browser network requests --json | jq -r $skype_token_query)
    test -n "$skype_token"; and break
    sleep 2
end

agent-browser close >/dev/null
test -n "$skype_token"
or begin
    echo "teams-token: no skype token seen before the timeout" >&2
    exit 1
end
echo "Found the skype token." >&2
