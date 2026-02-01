package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Configuration holds the application settings read from environment variables.
type Configuration struct {
	Command   string // The command to execute as the child process
	Port      string // The port for the HTTP shutdown endpoint
	StopFile  string // The file path that triggers shutdown when detected
}

func main() {
	// Load configuration from environment variables
	config, err := loadConfiguration()
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	log.Println("sidecar-entrypoint starting up")

	// Create a context that can be cancelled to trigger shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Channel to signal shutdown from various sources
	shutdownChan := make(chan struct{})

	// Start the child process
	cmd := startChildProcess(config.Command, cancel)

	// Start the shutdown monitoring goroutines
	var wg sync.WaitGroup
	wg.Add(3)

	// Monitor for stopfile
	go func() {
		defer wg.Done()
		monitorStopFile(config.StopFile, shutdownChan, cancel)
	}()

	// Start HTTP server for shutdown endpoint
	go func() {
		defer wg.Done()
		startHTTPServer(config.Port, shutdownChan, cancel)
	}()

	// Wait for shutdown signal
	select {
	case <-shutdownChan:
		log.Println("Shutdown signal received, terminating child process")
	case <-ctx.Done():
		log.Println("Context cancelled, terminating child process")
	case <-cmd.done:
		log.Println("Child process exited")
	}

	// Terminate the child process gracefully
	cmd.stop()

	// Wait for all goroutines to finish (with timeout)
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		log.Println("All goroutines finished")
	case <-time.After(5 * time.Second):
		log.Println("Timeout waiting for goroutines to finish")
	}

	log.Println("sidecar-entrypoint exiting")
}

// loadConfiguration reads and validates configuration from environment variables.
func loadConfiguration() (*Configuration, error) {
	command := os.Getenv("ENTRYPOINT_COMMAND")
	if command == "" {
		return nil, fmt.Errorf("ENTRYPOINT_COMMAND environment variable is required")
	}

	port := os.Getenv("ENTRYPOINT_PORT")
	if port == "" {
		return nil, fmt.Errorf("ENTRYPOINT_PORT environment variable is required")
	}

	stopFile := os.Getenv("ENTRYPOINT_STOPFILE")
	if stopFile == "" {
		return nil, fmt.Errorf("ENTRYPOINT_STOPFILE environment variable is required")
	}

	return &Configuration{
		Command:  command,
		Port:     port,
		StopFile: stopFile,
	}, nil
}

// childProcess wraps a running command with synchronization primitives.
type childProcess struct {
	cmd  *exec.Cmd
	done chan struct{}
}

// startChildProcess launches the child process and returns a wrapper for managing it.
func startChildProcess(command string, cancel context.CancelFunc) *childProcess {
	// Parse the command into parts
	parts := strings.Fields(command)
	if len(parts) == 0 {
		log.Fatalf("Invalid command: %s", command)
	}

	// Create the command
	cmd := exec.Command(parts[0], parts[1:]...)

	// Set the command to use its own process group
	cmd.SysProcAttr = &syscall.SysProcAttr{
		Setpgid: true,
	}

	// Set standard streams to inherit from parent
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	log.Printf("Launching child process: %s", command)

	if err := cmd.Start(); err != nil {
		log.Fatalf("Failed to start child process: %v", err)
	}

	log.Printf("Child process started with PID: %d", cmd.Process.Pid)

	done := make(chan struct{})

	// Goroutine to wait for the process to complete
	go func() {
		err := cmd.Wait()
		if err != nil {
			log.Printf("Child process exited with error: %v", err)
		} else {
			log.Println("Child process exited successfully")
		}
		close(done)
	}()

	return &childProcess{
		cmd:  cmd,
		done: done,
	}
}

// stop terminates the child process gracefully, then forcefully if needed.
func (cp *childProcess) stop() {
	if cp.cmd.Process == nil {
		return
	}

	log.Printf("Sending SIGTERM to child process PID: %d", cp.cmd.Process.Pid)

	// Send SIGTERM to the process group
	err := syscall.Kill(-cp.cmd.Process.Pid, syscall.SIGTERM)
	if err != nil {
		log.Printf("Failed to send SIGTERM: %v", err)
	}

	// Wait a bit for graceful shutdown
	done := make(chan error, 1)
	go func() {
		_, err := cp.cmd.Process.Wait()
		done <- err
	}()

	select {
	case <-done:
		log.Println("Child process terminated gracefully")
	case <-time.After(10 * time.Second):
		log.Println("Child process did not terminate gracefully, sending SIGKILL")
		_ = syscall.Kill(-cp.cmd.Process.Pid, syscall.SIGKILL)
		<-done
		log.Println("Child process terminated forcefully")
	}
}

// monitorStopFile periodically checks if the stop file exists and triggers shutdown if found.
func monitorStopFile(stopFile string, shutdownChan chan struct{}, cancel context.CancelFunc) {
	// Get the absolute path
	absPath, err := filepath.Abs(stopFile)
	if err != nil {
		log.Printf("Failed to resolve stop file path: %v", err)
		cancel()
		return
	}

	log.Printf("Monitoring stop file: %s", absPath)

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-shutdownChan:
			return
		case <-ticker.C:
			if _, err := os.Stat(absPath); err == nil {
				log.Printf("Stop file detected: %s", absPath)
				cancel()
				return
			}
		}
	}
}

// startHTTPServer starts an HTTP server that listens for shutdown requests.
func startHTTPServer(port string, shutdownChan chan struct{}, cancel context.CancelFunc) {
	// Setup HTTP quit endpoint
	http.HandleFunc("/quit", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("Received shutdown request from %s", r.RemoteAddr)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("Shutting down...\n"))
		cancel()
	})

	// Health check endpoint
	http.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK\n"))
	})

	addr := ":" + port
	log.Printf("Starting HTTP server on %s", addr)

	// Create a custom server to allow graceful shutdown
	server := &http.Server{
		Addr:    addr,
		Handler: nil,
	}

	// Start server in a goroutine
	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Printf("HTTP server error: %v", err)
		}
	}()

	// Wait for shutdown signal
	<-shutdownChan

	// Gracefully shutdown the HTTP server
	shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelShutdown()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("HTTP server shutdown error: %v", err)
	}
	log.Println("HTTP server stopped")
}

// init sets up signal handling for graceful shutdown.
func init() {
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigChan
		log.Printf("Received signal: %v", sig)
		os.Exit(0)
	}()
}
