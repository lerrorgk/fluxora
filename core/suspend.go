package main

import (
	"sync"

	"github.com/metacubex/mihomo/adapter/outbound"
	cProxy "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

var (
	suspendedWGLock    sync.Mutex
	suspendedWGDevices = make(map[*outbound.WireGuard]struct{})
)

func pauseSingleWireGuard(p cProxy.Proxy) {
	if p == nil || p.Type() != cProxy.WireGuard {
		return
	}

	device := outbound.WireGuardFor(p.Adapter())
	if device == nil {
		return
	}
	if _, exists := suspendedWGDevices[device]; exists {
		return
	}
	if err := device.SetDevicePaused(true); err != nil {
		log.Warnln("[WG] Pause %s: %v", p.Name(), err)
		return
	}
	suspendedWGDevices[device] = struct{}{}
}

func pauseWireGuard() {
	suspendedWGLock.Lock()
	defer suspendedWGLock.Unlock()

	for _, p := range tunnel.Proxies() {
		pauseSingleWireGuard(p)
	}
	for _, pr := range tunnel.Providers() {
		for _, p := range pr.Proxies() {
			pauseSingleWireGuard(p)
		}
	}
}

func resumeWireGuard() {
	suspendedWGLock.Lock()
	defer suspendedWGLock.Unlock()

	for device := range suspendedWGDevices {
		if err := device.SetDevicePaused(false); err != nil {
			log.Warnln("[WG] Resume %s: %v", device.Name(), err)
		}
	}
	suspendedWGDevices = make(map[*outbound.WireGuard]struct{})
}

func clearSuspendedWireGuard() {
	suspendedWGLock.Lock()
	defer suspendedWGLock.Unlock()
	suspendedWGDevices = make(map[*outbound.WireGuard]struct{})
}
