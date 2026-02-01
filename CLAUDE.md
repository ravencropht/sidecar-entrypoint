# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`sidecar-entrypoint` is a minimal Go application for managing the lifecycle of sidecar containers in Linux environments. The application launches a child process and monitors for two shutdown triggers:

1. **File-based shutdown**: Creates a file at `ENTRYPOINT_STOPFILE` path to trigger termination
2. **HTTP-based shutdown**: Send a request to the HTTP server on `ENTRYPOINT_PORT` (e.g., `curl localhost:8080/quit`) to trigger termination

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `ENTRYPOINT_COMMAND` | The command to execute as the child process | `/bin/fluentbit -c /etc/fluent.conf` |
| `ENTRYPOINT_PORT` | Port for HTTP shutdown endpoint | `8080` |
| `ENTRYPOINT_STOPFILE` | File path that triggers shutdown when detected | `/tmp/shutdown` |

## Architecture

The application follows this workflow:

1. On startup, immediately launch the child process specified by `ENTRYPOINT_COMMAND`
2. Monitor filesystem for existence of `ENTRYPOINT_STOPFILE` - if detected, terminate child and exit
3. Start HTTP server on `ENTRYPOINT_PORT` - any request to `/quit` triggers termination
4. Log all events (startup, process launch, shutdown triggers, exit) to STDOUT

## Development Principles

- **Minimal dependencies**: Prefer Go standard library only
- **Single binary**: Must compile to a standalone executable
- **Minimalist & clear**: Keep logic straightforward and well-commented
- **All logging in English**

## Build Commands

```bash
# Build statically linked binary (recommended for containers)
CGO_ENABLED=0 go build -o sidecar-entrypoint .

# Run with example configuration
ENTRYPOINT_COMMAND="/bin/sleep 3600" ENTRYPOINT_PORT="8080" ENTRYPOINT_STOPFILE="/tmp/shutdown" ./sidecar-entrypoint

# Trigger shutdown via HTTP
curl localhost:8080/quit

# Trigger shutdown via file
touch /tmp/shutdown
```
