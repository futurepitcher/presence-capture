# Connecting an agent

Presence Capture serves nothing by itself. An agent reads your captures by
starting `pcap-mcp`, a read-only server, under a **grant** of its own. To
connect an agent, you give it that grant and add `pcap-mcp` to its MCP
settings. Two ways do both at once, and they run the same code:

- the menu: **Connect an Agent**, then Claude Code…, Claude Desktop… or Cursor…
  (the set-up window has the same three buttons);
- the command line: `pcap connect <claude-code|claude-desktop|cursor>`.

For any other MCP client, see [Other clients](#other-clients). For what an agent
can ask once it's connected, see [tools.md](tools.md).

## What Connect does

1. It issues a grant named for the client: standard captures of every type, 100
   rows a read, for 30 days.
2. It works out the change to the client's settings, shows it as a diff, and
   asks before it writes anything.
3. It copies the settings file aside first, beside itself, as
   `<file>.presence-capture-backup-<time>`.
4. It adds an entry named `presence-capture`. If one is already there, it's
   replaced, and the grant it used is revoked.

If you say no, or the write fails, the grant it issued is revoked again. A grant
that can't be revoked is reported, with the command that revokes it.

The menu always uses the defaults above. The command line can change them:

```sh
P="/Applications/Presence Capture.app/Contents/MacOS/pcap"   # Homebrew puts pcap on your PATH
"$P" connect claude-code --types screen_text,activity --days 7
```

| Option | Meaning |
|--------|---------|
| `--types t,…` | Capture types to allow: `screen_frame`, `screen_text`, `audio_segment`, `audio_transcript`, `audio_alignment`, `activity` |
| `--levels l,…` | Privacy levels: `standard` (the default), `sensitive`, `excluded`. `sacred_mode` is refused |
| `--days n` | Days until the grant expires, 1 to 3650. The default is 30 |
| `--dry-run` | Show the change and write nothing |
| `--yes` | Don't ask. With no terminal to ask on, `connect` refuses unless you pass this |

## Claude Code

Choose **Connect an Agent → Claude Code…**, or run `pcap connect claude-code`.
You need Claude Code installed. Connect finds `claude` on your `PATH` and in the
usual install folders.

Connect doesn't edit `~/.claude.json` itself. It runs Claude Code's own
commands, at user scope, so every project has the server:

```sh
claude mcp remove presence-capture --scope user    # only when an entry exists
claude mcp add-json presence-capture '<entry>' --scope user
```

The entry names `pcap-mcp` and the store by their full paths. The agent starts
the server in its own environment, so nothing is left for the server to guess:

```json
{
  "args": ["--grant", "grn_…", "--store", "/Users/you/Library/Application Support/Presence Capture/store.sqlite"],
  "command": "/Applications/Presence Capture.app/Contents/MacOS/pcap-mcp",
  "type": "stdio"
}
```

New Claude Code sessions have it. Check with `claude mcp get presence-capture`.
If a project has its own `presence-capture` entry, Claude Code uses that one, and
Connect says so when it shows the change. If `CLAUDE_CONFIG_DIR` is set, Connect
refuses, because it can't be sure where your settings are. Add the entry by
hand, as under [Other clients](#other-clients).

To undo it, revoke the grant ([Disconnect](#disconnect)) and remove the entry:

```sh
claude mcp remove presence-capture --scope user
```

## Claude Desktop and Cursor

Choose **Claude Desktop…** or **Cursor…**, or run `pcap connect claude-desktop`
or `pcap connect cursor`. Connect edits the client's settings file and keeps
every other key in it:

| Client | File | After connecting |
|--------|------|------------------|
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json` | Quit Claude Desktop completely and open it again |
| Cursor | `~/.cursor/mcp.json` | Cursor loads it from Settings → MCP. Reload the window if it doesn't appear |

The entry is the same, except that Claude Desktop's has no `type` and Cursor's
has `"type": "stdio"`. Claude Desktop's:

```json
{
  "mcpServers": {
    "presence-capture": {
      "args": ["--grant", "grn_…", "--store", "/Users/you/Library/Application Support/Presence Capture/store.sqlite"],
      "command": "/Applications/Presence Capture.app/Contents/MacOS/pcap-mcp"
    }
  }
}
```

## Other clients

Connect knows only the three clients above. Any other MCP client that starts a
stdio server from a JSON `mcpServers` entry can use `pcap-mcp`, but you make the
grant and write the entry yourself. This route is manual.

```sh
"$P" grant add my-agent --days 7
```

```
grn_49ed9c6d-6f4a-4819-8e42-3489bd5b8f3a
  my-agent: standard captures of every type, for 100 rows a read at most, until 2026-10-21 15:58.
  Its server: '/Applications/Presence Capture.app/Contents/MacOS/pcap-mcp' --grant grn_49ed9c6d-6f4a-4819-8e42-3489bd5b8f3a --store '/Users/you/Library/Application Support/Presence Capture/store.sqlite'
```

`my-agent` is the name the agent goes by in Agents Read… and `pcap egress`.
`grant add` takes the same `--types`, `--levels` and `--days`. Put the command
and arguments from the "Its server" line into the client's entry:

```json
{
  "mcpServers": {
    "presence-capture": {
      "type": "stdio",
      "command": "/Applications/Presence Capture.app/Contents/MacOS/pcap-mcp",
      "args": ["--grant", "grn_49ed9c6d-6f4a-4819-8e42-3489bd5b8f3a", "--store", "/Users/you/Library/Application Support/Presence Capture/store.sqlite"]
    }
  }
}
```

That's the shape in the [daemon README](https://github.com/futurepitcher/presence-capture/blob/main/packages/daemon/README.md). Claude
Desktop's entry leaves out `type`.

Connect always writes `--store` as a full path, so the entry doesn't depend on
the environment the client starts the server in. Without it, `pcap-mcp` opens
the app's own store (or the folder `PRESENCE_CAPTURE_HOME` names).

## See what an agent has read

**Agents Read…** in the menu lists every grant, with its state and what it may
read. Below that is what each agent read in the last 7 days, by day and tool. It
shows counts and kinds only, never content. The same from a terminal:

```sh
"$P" egress              # the last 7 days; --days 30 for a month
"$P" grant list          # active grants; --all adds revoked and expired ones
```

```
2026-10-14
  my-agent  index  17 reads, 153 rows  read into its search index, in pcap-mcp's memory on this Mac
  my-agent  recent  3 reads, 20 rows  activity 12, screen_text 8
  my-agent  search  2 reads, 2 rows  screen_text 2
```

The `index` line is the search index the server builds in memory each time it
starts ([tools.md](tools.md#grants-and-the-egress-log)). `"$P" check` also
verifies the egress log's hash chain.

## Disconnect

Take away the grant, and the agent can't read, even with its entry still in
place:

- **Menu:** Agents Read…, then **Withdraw…** next to the grant, then **Withdraw
  This Grant**.
- **Terminal:** `"$P" grant revoke grn_…`. `grant list` shows the id.

It takes effect on the agent's next call, which gets `authorization denied:
grant revoked`. What the agent already read stays in the log, so you can still
see it.

To remove the server from the client too, delete the `presence-capture` entry:
for Claude Code, with the command above; for Claude Desktop and Cursor, in the
settings file, or by restoring the copy Connect made. Connecting again replaces
the entry and revokes the grant it used. A grant also expires on its own.

## Troubleshooting

| You see | What it means |
|---------|---------------|
| Claude Code's `claude` command wasn't found | Install Claude Code, then connect again |
| CLAUDE_CONFIG_DIR is set, so Claude Code keeps its settings where this can't be sure of finding them | Unset it, or add the entry by hand |
| connect asks before it writes; with no one to ask, pass --yes | There's no terminal to answer on. Pass `--yes`, or `--dry-run` to see the change |
| there's no store at …: open Presence Capture once to make it | Open the app once, so it makes its store |
| authorization denied: grant expired (from the agent) | Connect again for a new grant |

If an agent can't start the server, run `pcap-mcp --check` from the
`Contents/MacOS` folder inside the app to see whether the store opens, and
`"$P" grant list` to see whether the grant is active. More in
[tools.md](tools.md#errors).
