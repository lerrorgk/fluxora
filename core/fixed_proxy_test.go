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
	if !handleStartListener() || updateListeners() != nil || !request("http", ports[2]) {
		t.Fatal("a failed optional port blocked the other listeners during reload")
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

func TestInvalidFixedRouteIsIsolatedAndPortHandoffSucceeds(t *testing.T) {
	previous, running := currentConfig, isRunning
	proxies, providers, mode := tunnel.Proxies(), tunnel.Providers(), tunnel.Mode()
	status := tunnel.Status()
	allowed, denied, skip := inbound.AllowedIPs(), inbound.DisAllowedIPs(), inbound.SkipAuthPrefixes()
	t.Cleanup(func() {
		handleStopListener()
		currentConfig, isRunning = previous, running
		tunnel.UpdateProxies(proxies, providers)
		tunnel.UpdatePrivateProxies(nil)
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
	exitPort, _ := fixedTestHop(t, origin.Listener.Addr().String())
	ports := make([]int, 4)
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

	// Start with a non-fixed custom listener holding ports[1], plus one healthy
	// fixed route on ports[2] and one broken private fixed route on ports[3].
	rawA := fmt.Sprintf(`mixed-port: %d
mode: global
proxies:
  - {name: fluxora-fixed-good-hop-1, type: http, server: 127.0.0.1, port: %d, fluxora-private: true}
  - {name: fluxora-fixed-bad-hop-1, type: ss, server: 127.0.0.1, port: 443, cipher: nonexistent-cipher, password: x, fluxora-private: true}
  - {name: fluxora-fixed-bad-hop-2, type: http, server: 127.0.0.1, port: %d, dialer-proxy: fluxora-fixed-bad-hop-1, fluxora-private: true}
listeners:
  - {name: custom-legacy, type: mixed, listen: 127.0.0.1, port: %d, proxy: DIRECT}
  - {name: fluxora-fixed-good, type: mixed, listen: 127.0.0.1, port: %d, proxy: fluxora-fixed-good-hop-1}
  - {name: fluxora-fixed-bad, type: mixed, listen: 127.0.0.1, port: %d, proxy: fluxora-fixed-bad-hop-2}
`, ports[0], exitPort, exitPort, ports[1], ports[2], ports[3])

	cfgA, err := config.Parse([]byte(rawA))
	if err != nil {
		t.Fatalf("broken private fixed route failed main config parse: %v", err)
	}
	if cfgA.ListenerErrors["fluxora-fixed-bad"] == nil {
		t.Fatalf("expected parse error recorded for fluxora-fixed-bad, got %v", cfgA.ListenerErrors)
	}
	if _, exists := cfgA.Listeners["fluxora-fixed-bad"]; exists {
		t.Fatal("broken fixed listener should not be registered in cfg.Listeners")
	}
	currentConfig = cfgA
	tunnel.UpdateProxies(cfgA.Proxies, cfgA.Providers)
	tunnel.UpdatePrivateProxies(cfgA.PrivateProxies)
	tunnel.SetMode(tunnel.Global)
	tunnel.OnRunning()
	if !handleStartListener() {
		t.Fatal("core failed to start with isolated broken fixed route")
	}
	if !tunnel.IsPrivateProxy("fluxora-fixed-good-hop-1") {
		t.Fatal("private fixed hop was not tracked in tunnel.IsPrivateProxy")
	}
	if sock, err := net.Listen("tcp4", fmt.Sprintf("127.0.0.1:%d", ports[1])); err == nil {
		sock.Close()
		t.Fatal("custom-legacy did not bind ports[1] before handoff")
	}
	st := fixedListenerStatus()
	if st["fluxora-fixed-good"] != "" {
		t.Fatalf("healthy fixed listener failed: %v", st)
	}
	if !strings.Contains(st["fluxora-fixed-bad"], "cipher") {
		t.Fatalf("broken fixed listener did not report cipher parse error: %v", st)
	}

	// Switch to a config where custom-legacy is dropped and fluxora-fixed-handoff
	// takes over ports[1]. dropOld must release ports[1] before binding the new listener.
	rawB := fmt.Sprintf(`mixed-port: %d
mode: global
proxies:
  - {name: fluxora-fixed-handoff-hop-1, type: http, server: 127.0.0.1, port: %d, fluxora-private: true}
listeners:
  - {name: fluxora-fixed-handoff, type: mixed, listen: 127.0.0.1, port: %d, proxy: fluxora-fixed-handoff-hop-1}
`, ports[0], exitPort, ports[1])
	cfgB, err := config.Parse([]byte(rawB))
	if err != nil {
		t.Fatal(err)
	}
	currentConfig = cfgB
	tunnel.UpdateProxies(cfgB.Proxies, cfgB.Providers)
	tunnel.UpdatePrivateProxies(cfgB.PrivateProxies)
	if err := updateListeners(); err != nil {
		t.Fatalf("updateListeners failed on handoff: %v", err)
	}
	if st := fixedListenerStatus(); len(st) != 1 || st["fluxora-fixed-handoff"] != "" {
		t.Fatalf("port handoff from removed listener failed: %v", st)
	}
}
