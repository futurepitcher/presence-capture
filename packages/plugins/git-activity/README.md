# git-activity

A [sensor plugin](../../../docs/adr/0007-plugins.md) that notes each commit
made in the repositories it's given, as activity: `repo — subject`.

Each commit carries its hash as `dedupe`, so a restarted sensor, which sends
the last day's commits again, adds nothing, and a revoked commit never comes
back.

It's an example of how little a sensor is. It writes observations to stdout,
and the host does the rest: exclusion, redaction (a key pasted into a commit
message is replaced before anything is written) and sealing. Its captures are
`sensor:git-activity`, so they can all be revoked at once.

```sh
node sensor.mjs --once ~/code/my-repo                 # the last day's commits, then exit
node sensor.mjs --every 30 ~/code/a ~/code/b          # watch
node ../../schema/bin/sensor-kit.js -- node "$PWD/sensor.mjs" --once ~/code/my-repo   # check it (an absolute path: sensors start in /)
```

On macOS, list it in `~/Library/Application Support/Presence Capture/sensors.json`.
It won't run until you approve it from the app's menu, which pins `node` and
`sensor.mjs` as they are:

```json
[{ "name": "git-activity", "command": ["/opt/homebrew/bin/node", "/path/to/sensor.mjs", "/Users/you/code/my-repo"] }]
```
