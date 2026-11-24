package main

import (
	"reflect"
	"sync"
	"unsafe"

	"github.com/metacubex/mihomo/adapter/outbound"
	cProxy "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

type suspendedEntry struct {
	target *[]cProxy.Proxy
	orig   []cProxy.Proxy
}

var (
	suspendedHCLock    sync.Mutex
	suspendedEntries   []suspendedEntry
	suspendedWGLock    sync.Mutex
	suspendedWGDevices = make(map[*outbound.WireGuard]struct{})
)

func findFieldByName(v reflect.Value, name string) reflect.Value {
	for v.Kind() == reflect.Pointer || v.Kind() == reflect.Interface {
		if v.IsNil() {
			return reflect.Value{}
		}
		v = v.Elem()
	}
	if v.Kind() != reflect.Struct {
		return reflect.Value{}
	}

	f := v.FieldByName(name)
	if f.IsValid() {
		return f
	}

	for i := 0; i < v.NumField(); i++ {
		field := v.Field(i)
		for field.Kind() == reflect.Pointer || field.Kind() == reflect.Interface {
			if field.IsNil() {
				break
			}
			field = field.Elem()
		}
		if field.Kind() == reflect.Struct {
			if found := findFieldByName(field, name); found.IsValid() {
				return found
			}
		}
	}
	return reflect.Value{}
}

func pauseHealthChecks() {
	suspendedHCLock.Lock()
	defer suspendedHCLock.Unlock()

	providers := tunnel.Providers()
	if len(providers) == 0 {
		return
	}

	for _, p := range providers {
		hcField := findFieldByName(reflect.ValueOf(p), "healthCheck")
		if !hcField.IsValid() || hcField.IsNil() {
			continue
		}

		hcElem := hcField.Elem()
		if hcElem.Kind() != reflect.Struct {
			continue
		}

		proxiesField := hcElem.FieldByName("proxies")
		if proxiesField.IsValid() && proxiesField.CanAddr() {
			ptr := (*[]cProxy.Proxy)(unsafe.Pointer(proxiesField.UnsafeAddr()))
			orig := *ptr
			if len(orig) > 0 {
				alreadySaved := false
				for _, entry := range suspendedEntries {
					if entry.target == ptr {
						alreadySaved = true
						break
					}
				}
				if !alreadySaved {
					suspendedEntries = append(suspendedEntries, suspendedEntry{
						target: ptr,
						orig:   orig,
					})
					*ptr = nil
				}
			}
		}
	}
}

func resumeHealthChecks() {
	suspendedHCLock.Lock()
	defer suspendedHCLock.Unlock()

	for _, entry := range suspendedEntries {
		*entry.target = entry.orig
	}
	suspendedEntries = nil
}

func clearSuspendedHealthChecks() {
	suspendedHCLock.Lock()
	defer suspendedHCLock.Unlock()
	for _, entry := range suspendedEntries {
		*entry.target = entry.orig
	}
	suspendedEntries = nil
}

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
