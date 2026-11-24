package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
	D "github.com/miekg/dns"
)

func TestStartListenerRejectsUnconfiguredAndOccupiedPort(t *testing.T) {
	previous := currentConfig
	proxies, providers, mode := tunnel.Proxies(), tunnel.Providers(), tunnel.Mode()
	status := tunnel.Status()
	allowed, denied, skipAuth := inbound.AllowedIPs(), inbound.DisAllowedIPs(), inbound.SkipAuthPrefixes()
	t.Cleanup(func() {
		handleStopListener()
		currentConfig = previous
		tunnel.UpdateProxies(proxies, providers)
		tunnel.SetMode(mode)
		inbound.SetAllowedIPs(allowed)
		inbound.SetDisAllowedIPs(denied)
		inbound.SetSkipAuthPrefixes(skipAuth)
		switch status {
		case tunnel.Inner:
			tunnel.OnInnerLoading()
		case tunnel.Running:
			tunnel.OnRunning()
		default:
			tunnel.OnSuspend()
		}
	})
	currentConfig = nil
	if handleStartListener() || isRunning {
		t.Fatal("unconfigured core reported running")
	}
	blocker, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()
	port := blocker.Addr().(*net.TCPAddr).Port
	currentConfig = &config.Config{General: &config.General{
		Inbound: config.Inbound{
			MixedPort: port, BindAddress: "127.0.0.1",
			LanAllowedIPs: []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")},
		},
	}}
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"DIRECT": adapter.NewProxy(outbound.NewDirect()),
	}, nil)
	tunnel.SetMode(tunnel.Direct)
	tunnel.OnRunning()
	if handleStartListener() || isRunning {
		t.Fatal("core reported running with an occupied mixed port")
	}
	if err := blocker.Close(); err != nil {
		t.Fatal(err)
	}
	if !handleStartListener() || listener.GetPorts().MixedPort != port {
		t.Fatal("core could not start after the port became available")
	}

	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer origin.Close()
	proxy := &url.URL{Scheme: "http", Host: blocker.Addr().String()}
	client := origin.Client()
	transport := client.Transport.(*http.Transport)
	transport.Proxy = http.ProxyURL(proxy)
	defer transport.CloseIdleConnections()
	client.Timeout = 5 * time.Second
	response, err := client.Get(origin.URL)
	if err != nil {
		t.Fatalf("HTTPS through the restarted mixed listener: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("HTTPS through the mixed listener returned %s", response.Status)
	}

	free, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer free.Close()
	udp, err := net.ListenPacket("udp4", free.Addr().String())
	free.Close()
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	conflict := udp.LocalAddr().(*net.UDPAddr).Port
	if err := updateConfig(&UpdateParams{MixedPort: &conflict}); err == nil {
		t.Fatal("accepted a UDP-only conflict")
	}
	if currentConfig.General.MixedPort != port || listener.GetPorts().MixedPort != port {
		t.Fatal("failed rebind moved the active port")
	}
	handleStopListener()
	currentConfig.General.MixedPort = conflict
	if handleStartListener() || listener.GetPorts().MixedPort != 0 {
		t.Fatal("UDP failure left a partially active mixed listener")
	}
	if err := udp.Close(); err != nil {
		t.Fatal(err)
	}
	if !handleStartListener() || listener.GetPorts().MixedPort != conflict {
		t.Fatal("could not retry the same mixed port")
	}
}

func TestForwardedPortFollowsListenerLifecycle(t *testing.T) {
	previous, running := currentConfig, isRunning
	t.Cleanup(func() {
		handleStopListener()
		currentConfig, isRunning = previous, running
	})
	port, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := port.Addr().String()
	_ = port.Close()
	currentConfig = &config.Config{
		General: &config.General{},
		Tunnels: []LC.Tunnel{{
			Network: []string{"tcp", "udp"}, Address: address,
			Target: "127.0.0.1:1", Proxy: "Local/Forward",
		}},
	}
	expectAvailable := func(want bool) {
		t.Helper()
		tcp, tcpErr := net.Listen("tcp4", address)
		if tcp != nil {
			tcp.Close()
		}
		udp, udpErr := net.ListenPacket("udp4", address)
		if udp != nil {
			udp.Close()
		}
		if (tcpErr == nil) != want || (udpErr == nil) != want {
			t.Fatalf("available=%v, tcp=%v, udp=%v", want, tcpErr, udpErr)
		}
	}
	isRunning = false
	listener.PatchTunnel(currentConfig.Tunnels, tunnel.Tunnel)
	expectAvailable(true)
	if !handleStartListener() {
		t.Fatal("failed to start")
	}
	expectAvailable(false)
	listener.PatchTunnel(currentConfig.Tunnels, tunnel.Tunnel)
	expectAvailable(false)
	handleStopListener()
	expectAvailable(true)
}

type localDNSReply int

func (rcode localDNSReply) ServeMsg(_ context.Context, q *D.Msg) (*D.Msg, error) {
	return new(D.Msg).SetRcode(q, int(rcode)), nil
}

func TestDNSPortFollowsListenerLifecycle(t *testing.T) {
	previous, running := currentConfig, isRunning
	t.Cleanup(func() {
		handleStopListener()
		dns.ReCreateServer("", nil, nil)
		currentConfig, isRunning = previous, running
	})
	currentConfig = &config.Config{General: &config.General{}}
	blocker, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer blocker.Close()
	addr := blocker.Addr().String()
	checkUDPFree := func() {
		t.Helper()
		p, err := net.ListenPacket("udp4", addr)
		if err != nil {
			t.Fatal("DNS UDP port still held:", err)
		}
		p.Close()
	}
	checkReplies := func(want int, networks ...string) {
		t.Helper()
		q := new(D.Msg).SetQuestion("fluxora.test.", D.TypeA)
		for _, network := range networks {
			client := D.Client{Net: network, Timeout: time.Second}
			got, _, err := client.Exchange(q, addr)
			if err != nil || got.Rcode != want {
				t.Fatalf("%s DNS query: got %v, err %v", network, got, err)
			}
		}
	}

	lc := inbound.NewListenConfig()
	dns.ReCreateServer(addr, lc, localDNSReply(D.RcodeSuccess))
	checkUDPFree()
	currentConfig.General.MixedPort = blocker.Addr().(*net.TCPAddr).Port
	if handleStartListener() {
		t.Fatal("occupied mixed port unexpectedly started")
	}
	checkUDPFree()
	currentConfig.General.MixedPort = 0
	if !handleStartListener() {
		t.Fatal("occupied DNS TCP port prevented the proxy from starting")
	}
	checkReplies(D.RcodeSuccess, "udp")
	handleStopListener()
	checkUDPFree()
	blocker.Close()
	if !handleStartListener() {
		t.Fatal("could not retry the configured DNS port")
	}
	checkReplies(D.RcodeSuccess, "udp", "tcp")
	dns.ReCreateServer(addr, lc, localDNSReply(D.RcodeNameError))
	checkReplies(D.RcodeNameError, "udp", "tcp")

	handleStopListener()
	dns.ReCreateServer(addr, lc, localDNSReply(D.RcodeRefused))
	checkUDPFree()
	tcp, err := net.Listen("tcp4", addr)
	if err != nil {
		t.Fatal("DNS TCP port still held:", err)
	}
	tcp.Close()
	if !handleStartListener() {
		t.Fatal("could not reopen DNS after a stopped config reload")
	}
	checkReplies(D.RcodeRefused, "udp", "tcp")
}
