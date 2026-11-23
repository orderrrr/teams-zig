#!/usr/bin/env fish
# Signs in to Teams in a dedicated agent-browser profile and stores the skype token and
# Chat Service region in the login keychain for teams-zig. Token values are never printed.

set -l service teams-zig
set -l profile "$HOME/Library/Application Support/teams-zig/browser"
set -l wait_seconds 300
set -lx AGENT_BROWSER_SESSION teams-zig

# The web client never sets the skypetoken_asm cookie. At startup it posts the skype token to
# .../v1/skypetokenauth as a form body; some loads also send it as an x-skypetoken header.
set -l skype_token_query '[(.data.requests[]
        | select(.method == "POST" and (.url | test("/v1/skypetokenauth$")))
        | .postData // "" | select(startswith("skypetoken=")) | ltrimstr("skypetoken=")),
    (.data.requests[].headers | to_entries[]
        | select(.key | ascii_downcase == "x-skypetoken") | .value | sub("^skypetoken="; ""))]
    | map(select(length > 0)) | first // empty'
# Chat Service URLs carry the region in the host or, on the newer web host, in the path.
# The comma makes capture try each pattern.
set -l region_query '[.data.requests[].url
    | capture("^https://(?<region>[a-z]+)[.]ng[.]msg[.]teams[.]microsoft[.]com/",
        "^https://teams[.]cloud[.]microsoft/api/(?:chatsvc|mt)/(?<region>[a-z]+)/")
    | .region] | first // empty'

mkdir -p $profile
agent-browser --headed --profile $profile open https://teams.microsoft.com >/dev/null
or begin
    echo "teams-token: couldn't open the browser" >&2
    exit 1
end

echo "Sign in to Teams in the browser window if asked. Waiting up to $wait_seconds seconds..." >&2
set -l skype_token
set -l region
for second in (seq 2 2 $wait_seconds)
    set -l requests (agent-browser network requests --json | string collect)
    or begin
        # Usually the browser window was closed; polling again would only repeat the failure.
        echo "teams-token: agent-browser stopped answering; was the browser window closed?" >&2
        agent-browser close >/dev/null 2>&1
        exit 1
    end
    set skype_token (echo $requests | jq -r $skype_token_query)
    set region (echo $requests | jq -r $region_query)
    test -n "$skype_token" -a -n "$region"; and break
    sleep 2
end

agent-browser close >/dev/null
test -n "$skype_token"
or begin
    echo "teams-token: no skype token seen in $wait_seconds seconds; did sign-in finish?" >&2
    exit 1
end
contains -- $region amer emea apac
or begin
    echo "teams-token: no Chat Service region seen in $wait_seconds seconds (got '$region')" >&2
    exit 1
end

# -A opens the items' access list. macOS's partition list still trusts only security itself, which
# is why teams-zig reads them back through /usr/bin/security too. See docs/PLAN.md M1.7.
security add-generic-password -U -A -s $service -a skype-token -w $skype_token
and security add-generic-password -U -A -s $service -a region -w $region
or begin
    echo "teams-token: couldn't write to the login keychain" >&2
    exit 1
end
echo "Stored the skype token and region $region in the login keychain." >&2

# A new token may be another account, so teams-zig's cache (your user, chat names and ids) is
# dropped; teams-zig builds it again as it runs. See Cache.sub_path in src/Cache.zig.
rm -f $HOME/Library/Caches/teams-zig/cache.txt
