package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
)

// A mock CONNECT hop accepts only its expected next hop. A direct connection
// bypassing either mock cannot accidentally satisfy the counters.
func fixedTestHop(t *testing.T, destination string) (int, *atomic.Int32) {
	t.Helper()
	count := new(atomic.Int32)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodConnect || r.Host != destination {
			http.Error(w, "wrong hop", http.StatusBadRequest)
			return
		}
		next, err := net.DialTimeout("tcp", destination, 2*time.Second)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer next.Close()
		client, buf, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		defer client.Close()
		count.Add(1)
		fmt.Fprint(buf, "HTTP/1.1 200 Connection established\r\n\r\n")
		buf.Flush()
		go func() { io.Copy(next, buf); next.Close() }()
		io.Copy(client, next)
	}))
	t.Cleanup(server.Close)
	return server.Listener.Addr().(*net.TCPAddr).Port, count
}

func TestFixedRouteSurvivesMainSelection(t *testing.T) {
	previous, running := currentConfig, isRunning
	proxies, providers, mode := tunnel.Proxies(), tunnel.Providers(), tunnel.Mode()
	status := tunnel.Status()
	allowed, denied, skip := inbound.AllowedIPs(), inbound.DisAllowedIPs(), inbound.SkipAuthPrefixes()
	t.Cleanup(func() {
		handleStopListener()
		currentConfig, isRunning = previous, running
		tunnel.UpdateProxies(proxies, providers)
		tunnel.SetMode(mode)
		inbound.SetAllowedIPs(allowed)
		inbound.SetDisAllowedIPs(denied)
		inbound.SetSkipAuthPrefixes(skip)
		switch status {
		case tunnel.Running:
			tunnel.OnRunning()
		case tunnel.Inner:
			tunnel.OnInnerLoading()
		default:
			tunnel.OnSuspend()
		}
	})
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer origin.Close()
	exit, exitHits := fixedTestHop(t, origin.Listener.Addr().String())
	front, frontHits := fixedTestHop(t, fmt.Sprintf("127.0.0.1:%d", exit))
	ports := make([]int, 3)
	var reserved []net.Listener
	for i := range ports {
		sock, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		reserved = append(reserved, sock)
		ports[i] = sock.Addr().(*net.TCPAddr).Port
	}
	for _, sock := range reserved {
		sock.Close()
	}
	raw := fmt.Sprintf(`mixed-port: %d
mode: global
proxies:
  - {name: pinned-front, type: http, server: 127.0.0.1, port: %d, fluxora-private: true}
  - {name: pinned-exit, type: http, server: 127.0.0.1, port: %d, dialer-proxy: pinned-front, fluxora-private: true}
  - {name: pinned-single, type: http, server: 127.0.0.1, port: %d, fluxora-private: true}
listeners:
  - {name: fluxora-fixed-chain, type: mixed, listen: 127.0.0.1, port: %d, udp: true, proxy: pinned-exit}
  - {name: fixed-single, type: mixed, listen: 127.0.0.1, port: %d, proxy: pinned-single}
`, ports[0], front, exit, exit, ports[1], ports[2])
	cfg, err := config.Parse([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	members, err := cfg.Proxies["GLOBAL"].MarshalJSON()
	if err != nil || strings.Contains(string(members), "pinned-") {
		t.Fatalf("private hops in GLOBAL: %s (%v)", members, err)
	}
	currentConfig = cfg
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	tunnel.SetMode(tunnel.Global)
	tunnel.OnRunning()
	if !handleStartListener() {
		t.Fatal("core failed to start")
	}
	if status := fixedListenerStatus(); len(status) != 1 || status["fluxora-fixed-chain"] != "" {
		t.Fatalf("successful fixed bind not reported: %v", status)
	}
	request := func(scheme string, port int) bool {
		transport := origin.Client().Transport.(*http.Transport).Clone()
		transport.Proxy = http.ProxyURL(&url.URL{Scheme: scheme, Host: fmt.Sprintf("127.0.0.1:%d", port)})
		defer transport.CloseIdleConnections()
		client := &http.Client{Transport: transport, Timeout: 3 * time.Second}
		resp, err := client.Get(origin.URL)
		if err != nil {
			return false
		}
		defer resp.Body.Close()
		return resp.StatusCode == http.StatusNoContent
	}
	patchSelectGroup(map[string]string{"GLOBAL": "DIRECT"})
	if !request("http", ports[0]) || !request("http", ports[1]) || !request("socks5", ports[2]) || frontHits.Load() != 1 || exitHits.Load() != 2 {
		t.Fatal("first requests used wrong path")
	}
	patchSelectGroup(map[string]string{"GLOBAL": "REJECT"})
	if request("http", ports[0]) || !request("socks5", ports[1]) || !request("http", ports[2]) || frontHits.Load() != 2 || exitHits.Load() != 4 {
		t.Fatal("switching GLOBAL changed fixed route")
	}
	handleStopListener()
	sock, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", ports[1]))
	if err != nil {
		t.Fatalf("stopped listener still owns its port: %v", err)
	}
	sock.Close()

	// A failed UDP bind must release TCP, preserve the other ports and be retryable.
	occupied, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: ports[1]})
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	if !handleStartListener() || updateListeners() == nil {
		t.Fatal("expected a fixed-port bind error with the main listener running")
	}
	if fixedListenerStatus()["fluxora-fixed-chain"] == "" {
		t.Fatal("occupied fixed listener reported as bound")
	}
	tcp, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", ports[1]))
	if err != nil {
		t.Fatalf("partial bind kept TCP: %v", err)
	}
	tcp.Close()
	occupied.Close()
	if err := updateListeners(); err != nil || !request("http", ports[1]) {
		t.Fatalf("fixed port did not recover: %v", err)
	}
	if status := fixedListenerStatus(); len(status) != 1 || status["fluxora-fixed-chain"] != "" {
		t.Fatalf("recovered listener still unavailable: %v", status)
	}
}
