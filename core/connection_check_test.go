package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
)

func TestCheckDefaultRouteUsesCatchAllAndRequiresSuccess(t *testing.T) {
	var status atomic.Int32
	status.Store(http.StatusNoContent)
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(int(status.Load()))
	}))
	defer origin.Close()
	if err := ca.AddCertificate(string(origin.Certificate().Raw)); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(ca.ResetCertificate)
	hop, hits := fixedTestHop(t, origin.Listener.Addr().String())
	cfg, err := config.Parse([]byte(fmt.Sprintf("proxies:\n  - {name: exit, type: http, server: 127.0.0.1, port: %d}\nrules: ['IP-CIDR,127.0.0.1/32,DIRECT', 'MATCH,exit']\n", hop)))
	if err != nil {
		t.Fatal(err)
	}
	proxies, providers, mode := tunnel.Proxies(), tunnel.Providers(), tunnel.Mode()
	rules, rp := tunnel.Rules(), tunnel.RuleProviders()
	t.Cleanup(func() {
		tunnel.UpdateProxies(proxies, providers)
		tunnel.UpdateRules(rules, nil, rp)
		tunnel.SetMode(mode)
	})
	tunnel.UpdateProxies(cfg.Proxies, cfg.Providers)
	tunnel.UpdateRules(cfg.Rules, nil, cfg.RuleProviders)
	tunnel.SetMode(tunnel.Rule)
	if !checkDefaultRoute(origin.URL) || hits.Load() != 1 {
		t.Fatal("healthy catch-all was not reached through the configured hop")
	}
	for _, code := range []int{http.StatusFound, http.StatusBadGateway} {
		status.Store(int32(code))
		if checkDefaultRoute(origin.URL) {
			t.Fatalf("catch-all returned %d but was marked healthy", code)
		}
	}
	status.Store(http.StatusNoContent)
	if !checkDefaultRoute(origin.URL) {
		t.Fatal("recovered route was not recognized")
	}
}
