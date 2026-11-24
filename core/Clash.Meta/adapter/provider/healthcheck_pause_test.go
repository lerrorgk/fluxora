package provider

import (
	"context"
	"testing"

	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
)

type countedProbe struct {
	C.Proxy
	checks int
}

func (*countedProbe) Name() string                      { return "test" }
func (*countedProbe) AliveForTestUrl(string) bool       { return true }
func (*countedProbe) LastDelayForTestUrl(string) uint16 { return 1 }
func (p *countedProbe) URLTest(context.Context, string, utils.IntRanges[uint16]) (uint16, error) {
	p.checks++
	return 1, nil
}

func TestResumeChecksRefreshedProxies(t *testing.T) {
	old, updated := &countedProbe{}, &countedProbe{}
	hc := NewHealthCheck([]C.Proxy{old}, "https://test.invalid", 0, 10, false, nil)
	defer hc.close()
	SetHealthChecksPaused(true)
	t.Cleanup(func() { SetHealthChecksPaused(false) })
	hc.setProxies([]C.Proxy{updated})
	hc.check()
	if updated.checks != 0 {
		t.Fatal("refresh launched a probe while paused")
	}
	SetHealthChecksPaused(false)
	hc.check()
	if old.checks != 0 || updated.checks != 1 {
		t.Fatal("resume did not probe only the refreshed nodes")
	}
}
