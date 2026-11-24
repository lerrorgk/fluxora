package outbound

import (
	"context"
	"testing"
)

type suspendTestDevice struct{ up, down int }

func (d *suspendTestDevice) Up() error         { d.up++; return nil }
func (d *suspendTestDevice) Down() error       { d.down++; return nil }
func (*suspendTestDevice) IpcSet(string) error { return nil }
func (*suspendTestDevice) Close()              {}

func TestWireGuardPauseThroughOutboundWrappers(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dev := &suspendTestDevice{}
	wg := &WireGuard{runCtx: ctx, device: dev}
	proxy := &autoCloseProxyAdapter{ProxyAdapter: &SingMux{ProxyAdapter: wg}}
	if got := WireGuardFor(proxy); got != wg {
		t.Fatal("WireGuard not found behind wrappers")
	}
	if err := wg.SetDevicePaused(true); err != nil {
		t.Fatal(err)
	}
	if err := wg.SetDevicePaused(false); err != nil {
		t.Fatal(err)
	}
	cancel()
	if err := wg.SetDevicePaused(false); err != nil {
		t.Fatal(err)
	}
	if dev.down != 1 || dev.up != 1 {
		t.Fatalf("unexpected transitions: %+v", dev)
	}
}
