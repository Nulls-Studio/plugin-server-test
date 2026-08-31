# Plugin Server Test

A GitHub Action for testing Minecraft plugins against a real Minecraft server.

The action:

1. Validates that the runner is Linux.
2. Installs the supported Java versions.
3. Downloads the requested Paper, Folia, or CraftBukkit server version.
4. Installs the plugin and dependencies.
5. Starts the server.
6. Waits for the server to start.
7. Executes the configured console commands.
8. Checks the server log for the expected patterns.
9. Optionally runs a custom check script against the server log.
10. Stops the server.
11. Returns the test result.

## Usage

```yaml
- name: Test plugin
  uses: Nulls-Studio/plugin-server-test@v1
  with:
    software: paper
    version: '1.21.11'
    java: '25'
    plugins: |
      target/*.jar
    commands: |
      say Hello from the test
    tocheck: |
      MyCustomPlugin is enabled
```

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `software` | Yes | — | Server software. Supported values: `paper`, `folia`, `bukkit`. |
| `version` | Yes | — | Minecraft version to test, for example `1.21.11`. |
| `java` | Yes | — | Java version. Supported values: `8`, `11`, `17`, `21`, `25`. |
| `plugins` | Yes | — | Newline-separated glob patterns for plugin JAR files. |
| `commands` | No | `""` | Newline-separated Minecraft console commands to execute. |
| `tocheck` | No | `""` | Newline-separated log patterns to check after commands finish. Supports `*` wildcards. |
| `checkscript` | No | `""` | Optional command to run after the test. The server log is passed through stdin. |
| `timeout` | No | `60` | Maximum number of seconds to wait for server startup. |
| `command-delay` | No | `2` | Number of seconds to wait after each console command. |

#### WARNING
When using the bukkit (spigot) software the .jar of the server must be built inplace, making the job way longer, (by about 2m30), i do not advise you to test the plugin on bukkit, unless its impossible to do it an other way.

### Plugins

The `plugins` input accepts newline-separated glob patterns relative to the GitHub workspace.

```yaml
plugins: |
  target/*.jar
  dependencies/*.jar
```

This allows multiple plugins or dependencies to be installed.

### Log Checks

The `tocheck` input is used to verify messages in the server log.

```yaml
tocheck: |
  MyCustomPlugin is enabled
  Test completed successfully
```

Patterns containing `*` are treated as wildcards:

```yaml
tocheck: |
  *MyCustomPlugin* enabled
  Player * joined the server
```

### Check Script

The `checkscript` input can be used for more advanced log validation.

The generated `server.log` is passed to the command through stdin. An exit code of `0` indicates success, while an exit code of `1` indicates failure.

```yaml
checkscript: python3 check-server.py
```

## Outputs

### `server-log`

Path to the generated server log.

```yaml
${{ steps.test.outputs.server-log }}
```

### `result`

Result of the plugin test.

```yaml
${{ steps.test.outputs.result }}
```

## Example

```yaml
- name: Test plugin
  id: test
  uses: Nulls-Studio/plugin-server-test@v1
  with:
    software: paper
    version: '1.21.11'
    java: '25'
    plugins: |
      target/*.jar
      test-dependencies/*.jar
    commands: |
      say Starting plugin test
      myplugin:test
    tocheck: |
      MyCustomPlugin is enabled
      *Test completed successfully*
    timeout: '120'
    command-delay: '3'
```
