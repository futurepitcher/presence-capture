# git-activity

A [sensor plugin](../../../docs/adr/0007-plugins.md) that notes each commit
made in the repositories it's given, as activity: `repo — subject`.

It's an example of how little a sensor is. It writes observations to stdout,
and the host does the rest: exclusion, redaction (a key pasted into a commit
message is replaced before anything is written) and sealing. Its captures are
`sensor:git-activity`, so they can all be revoked at once.

```sh
node sensor.mjs --once ~/code/my-repo                 # the last day's commits, then exit
node sensor.mjs --every 30 ~/code/a ~/code/b          # watch
node ../../schema/bin/sensor-kit.js -- node sensor.mjs --once ~/code/my-repo   # check it
```

On macOS, list it in `~/Library/Application Support/Presence Capture/sensors.json`:

```json
[{ "name": "git-activity", "command": ["/opt/homebrew/bin/node", "/path/to/sensor.mjs", "/Users/you/code/my-repo"] }]
```
