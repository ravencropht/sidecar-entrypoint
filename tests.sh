#!/usr/bin/env bash
# Integration tests for sidecar-entrypoint

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Helper functions
log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

# Test wrapper
run_test() {
    local test_name="$1"
    local test_func="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    log_info "Running: $test_name"

    if $test_func; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_success "$test_name"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "$test_name"
        return 1
    fi
}

# Cleanup function
cleanup() {
    local pid="$1"
    local stopfile="$2"

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -f "$stopfile" 2>/dev/null || true
}

# Build the application first
build_app() {
    log_info "Building sidecar-entrypoint..."
    CGO_ENABLED=0 go build -o sidecar-entrypoint .
    if [ ! -f "./sidecar-entrypoint" ]; then
        log_error "Build failed - binary not found"
        exit 1
    fi
    log_success "Build successful"
}

# Test: Missing required environment variables
test_missing_env_vars() {
    OUTPUT=$(unset ENTRYPOINT_COMMAND ENTRYPOINT_PORT ENTRYPOINT_STOPFILE && \
             ./sidecar-entrypoint 2>&1 &)
    sleep 0.2

    # Check that process exited due to missing env vars
    if pgrep -f "sidecar-entrypoint" >/dev/null; then
        pkill -f "sidecar-entrypoint"
        return 1
    fi
    return 0
}

# Test: Health endpoint returns 200
test_health_endpoint() {
    local port="18080"
    local stopfile="/tmp/test_shutdown_$$"

    ENTRYPOINT_COMMAND="/bin/sleep 3600" \
    ENTRYPOINT_PORT="$port" \
    ENTRYPOINT_STOPFILE="$stopfile" \
    ./sidecar-entrypoint >/dev/null 2>&1 &
    local pid=$!

    # Wait for server to start
    sleep 0.5

    # Test health endpoint
    local response
    response=$(curl -s "http://localhost:$port/health" 2>/dev/null || echo "FAILED")
    cleanup "$pid" "$stopfile"

    [[ "$response" == *"OK"* ]]
}

# Test: Quit endpoint triggers shutdown
test_quit_endpoint() {
    local port="18081"
    local stopfile="/tmp/test_shutdown_$$"

    ENTRYPOINT_COMMAND="/bin/sleep 3600" \
    ENTRYPOINT_PORT="$port" \
    ENTRYPOINT_STOPFILE="$stopfile" \
    ./sidecar-entrypoint >/dev/null 2>&1 &
    local pid=$!

    # Wait for server to start
    sleep 0.5

    # Send quit request
    curl -s "http://localhost:$port/quit" >/dev/null 2>&1

    # Wait for process to exit
    local count=0
    while kill -0 "$pid" 2>/dev/null && [ $count -lt 20 ]; do
        sleep 0.1
        count=$((count + 1))
    done

    cleanup "$pid" "$stopfile"

    # Process should have exited
    ! kill -0 "$pid" 2>/dev/null
}

# Test: Stopfile triggers shutdown
test_stopfile_shutdown() {
    local port="18082"
    local stopfile="/tmp/test_shutdown_$$"

    ENTRYPOINT_COMMAND="/bin/sleep 3600" \
    ENTRYPOINT_PORT="$port" \
    ENTRYPOINT_STOPFILE="$stopfile" \
    ./sidecar-entrypoint >/dev/null 2>&1 &
    local pid=$!

    # Wait for server to start
    sleep 0.5

    # Create stopfile
    touch "$stopfile"

    # Wait for process to exit
    local count=0
    while kill -0 "$pid" 2>/dev/null && [ $count -lt 20 ]; do
        sleep 0.1
        count=$((count + 1))
    done

    cleanup "$pid" "$stopfile"

    # Process should have exited
    ! kill -0 "$pid" 2>/dev/null
}

# Test: Child process is terminated on shutdown
test_child_process_termination() {
    local port="18083"
    local stopfile="/tmp/test_shutdown_$$"

    ENTRYPOINT_COMMAND="/bin/sleep 3600" \
    ENTRYPOINT_PORT="$port" \
    ENTRYPOINT_STOPFILE="$stopfile" \
    ./sidecar-entrypoint >/dev/null 2>&1 &
    local pid=$!

    # Wait for server and child to start
    sleep 0.5

    # Find child sleep process
    local child_pid
    child_pid=$(pgrep -P "$pid" "sleep" | head -1)

    if [ -z "$child_pid" ]; then
        cleanup "$pid" "$stopfile"
        return 1
    fi

    # Send quit request
    curl -s "http://localhost:$port/quit" >/dev/null 2>&1

    # Wait for processes to exit
    sleep 0.5

    # Check child is also terminated
    local child_running=false
    if kill -0 "$child_pid" 2>/dev/null; then
        child_running=true
    fi

    cleanup "$pid" "$stopfile"

    [ "$child_running" = false ]
}

# Test: Invalid endpoint returns 404
test_invalid_endpoint() {
    local port="18084"
    local stopfile="/tmp/test_shutdown_$$"

    ENTRYPOINT_COMMAND="/bin/sleep 3600" \
    ENTRYPOINT_PORT="$port" \
    ENTRYPOINT_STOPFILE="$stopfile" \
    ./sidecar-entrypoint >/dev/null 2>&1 &
    local pid=$!

    # Wait for server to start
    sleep 0.5

    # Test invalid endpoint
    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/invalid" 2>/dev/null || echo "000")

    cleanup "$pid" "$stopfile"

    [ "$status_code" = "404" ]
}

# Test: Multiple shutdown methods (quit takes precedence)
test_quit_before_stopfile() {
    local port="18085"
    local stopfile="/tmp/test_shutdown_$$"

    ENTRYPOINT_COMMAND="/bin/sleep 3600" \
    ENTRYPOINT_PORT="$port" \
    ENTRYPOINT_STOPFILE="$stopfile" \
    ./sidecar-entrypoint >/dev/null 2>&1 &
    local pid=$!

    # Wait for server to start
    sleep 0.5

    # Send quit request first
    curl -s "http://localhost:$port/quit" >/dev/null 2>&1

    # Wait for process to exit
    local count=0
    while kill -0 "$pid" 2>/dev/null && [ $count -lt 20 ]; do
        sleep 0.1
        count=$((count + 1))
    done

    cleanup "$pid" "$stopfile"

    # Process should have exited
    ! kill -0 "$pid" 2>/dev/null
}

# Test: Command with arguments
test_command_with_arguments() {
    local port="18086"
    local stopfile="/tmp/test_shutdown_$$"

    # Use echo which exits quickly
    ENTRYPOINT_COMMAND="echo hello world" \
    ENTRYPOINT_PORT="$port" \
    ENTRYPOINT_STOPFILE="$stopfile" \
    timeout 5 ./sidecar-entrypoint >/dev/null 2>&1 &
    local pid=$!

    # Wait for process to complete (echo exits quickly)
    sleep 10

    # Process should have exited after child completed
    local result=0
    if kill -0 "$pid" 2>/dev/null; then
        # Still running - kill it
        kill "$pid" 2>/dev/null || true
        result=1
    fi

    cleanup "$pid" "$stopfile"
    return $result
}

# Main test execution
main() {
    echo "======================================"
    echo "Sidecar Entrypoint Integration Tests"
    echo "======================================"
    echo ""

    build_app
    echo ""

    run_test "Missing environment variables causes exit" test_missing_env_vars
    run_test "Health endpoint returns OK" test_health_endpoint
    run_test "Quit endpoint triggers shutdown" test_quit_endpoint
    run_test "Stopfile triggers shutdown" test_stopfile_shutdown
    run_test "Child process is terminated on shutdown" test_child_process_termination
    run_test "Invalid endpoint returns 404" test_invalid_endpoint
    run_test "Command with arguments works" test_command_with_arguments

    echo ""
    echo "======================================"
    echo "Test Results"
    echo "======================================"
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    else
        echo "Tests failed: $TESTS_FAILED"
    fi
    echo "======================================"

    # Clean up the binary
    rm -f ./sidecar-entrypoint

    if [ $TESTS_FAILED -gt 0 ]; then
        exit 1
    fi
    exit 0
}

# Run tests
main "$@"
