package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestSpeedClientDoesNotFallBackToDirectOnUnknownOutbound(t *testing.T) {
	client := newSpeedClient("missing-speed-test-outbound")
	defer client.CloseIdleConnections()
	transport := client.Transport.(*http.Transport)
	// This must reject the route before resolving or dialing the address.
	conn, err := transport.DialContext(context.Background(), "tcp", "invalid-address")
	if conn != nil || err == nil || !strings.Contains(err.Error(), "missing-speed-test-outbound") {
		t.Fatalf("expected a route rejection without a direct dial, got conn=%v err=%v", conn, err)
	}
}

func TestDownloadRateUsesDurationBetweenSamples(t *testing.T) {
	first := downloadSample{bytes: 2_000_000, elapsed: 2 * time.Second}
	last := downloadSample{bytes: 10_000_000, elapsed: 10 * time.Second}
	if rate := last.mbpsSince(first); rate != 8 {
		t.Fatalf("got %v Mbps for 8 MB over 8 seconds", rate)
	}
	if rate := first.mbpsSince(downloadSample{}); rate != 8 {
		t.Fatalf("full-run rate for a short test: %v", rate)
	}
}
