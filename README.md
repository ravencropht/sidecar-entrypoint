# sidecar-entrypoint

A minimal Go application for managing the lifecycle of sidecar containers in Linux environments.

## Overview

`sidecar-entrypoint` launches a child process and monitors for two shutdown triggers:

1. **File-based shutdown**: Creates a file at a specified path to trigger termination
2. **HTTP-based shutdown**: Send a request to `/quit` endpoint to trigger termination

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `ENTRYPOINT_COMMAND` | The command to execute as the child process | `/bin/fluentbit -c /etc/fluent.conf` |
| `ENTRYPOINT_PORT` | Port for HTTP shutdown endpoint | `8080` |
| `ENTRYPOINT_STOPFILE` | File path that triggers shutdown when detected | `/tmp/shutdown` |

## Building

```bash
# Build statically linked binary (recommended for containers)
CGO_ENABLED=0 go build -o sidecar-entrypoint .
```

## Usage

```bash
# Start with example configuration
ENTRYPOINT_COMMAND="/bin/sleep 3600" \
ENTRYPOINT_PORT="8080" \
ENTRYPOINT_STOPFILE="/tmp/shutdown" \
./sidecar-entrypoint
```

### Triggering Shutdown

**Via HTTP:**
```bash
curl localhost:8080/quit
```

**Via file:**
```bash
touch /tmp/shutdown
```

### Health Check

```bash
curl localhost:8080/health
```

## License

See [LICENSE](LICENSE) file.
