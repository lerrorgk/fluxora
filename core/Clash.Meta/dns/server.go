package dns

import (
	"context"
	"errors"
	"net"
	"sync"

	"github.com/metacubex/mihomo/common/sockopt"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"

	D "github.com/miekg/dns"
)

var (
	serverMu      sync.Mutex
	serverEnabled = true
	configured    serverConfig
	server        *Server

	dnsDefaultTTL uint32 = 600
)

type serverConfig struct {
	addr    string
	listen  C.InboundListenConfig
	service resolver.Service
}

type Server struct {
	addr      string
	ctx       context.Context
	cancel    context.CancelFunc
	serviceMu sync.RWMutex
	service   resolver.Service
	tcpServer *D.Server
	udpServer *D.Server
}

type serverHandler struct {
	*Server
	isUDP bool
}

// ServeDNS implement D.Handler ServeDNS
func (s serverHandler) ServeDNS(w D.ResponseWriter, r *D.Msg) {
	s.serviceMu.RLock()
	service := s.service
	s.serviceMu.RUnlock()
	ctx := s.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	msg, err := service.ServeMsg(ctx, r)
	if err != nil {
		m := new(D.Msg)
		m.SetRcode(r, D.RcodeServerFailure)
		// does not matter if this write fails
		w.WriteMsg(m)
		return
	}
	if s.isUDP {
		// RFC 6891: fit the reply into the client's advertised buffer size,
		// setting the TC bit if records must be dropped; 512 when no OPT present
		msg.Truncate(resolver.RequestUDPSize(r))
	}
	msg.Compress = true
	w.WriteMsg(msg)
}

func (s *Server) UDPHandler() D.Handler {
	return serverHandler{Server: s, isUDP: true}
}

func (s *Server) TCPHandler() D.Handler {
	return serverHandler{Server: s, isUDP: false}
}

func (s *Server) SetService(service resolver.Service) {
	s.serviceMu.Lock()
	defer s.serviceMu.Unlock()
	s.service = service
}

func ReCreateServer(addr string, lc C.InboundListenConfig, service resolver.Service) {
	serverMu.Lock()
	defer serverMu.Unlock()
	configured = serverConfig{addr, lc, service}
	if err := applyServer(); err != nil {
		log.Errorln("Start DNS server error: %s", err)
	}
}

// SetServerEnabled controls the external sockets while preserving the latest
// configured DNS service for the next connection. Standalone cores default on.
func SetServerEnabled(enabled bool) {
	serverMu.Lock()
	defer serverMu.Unlock()
	serverEnabled = enabled
	if err := applyServer(); err != nil {
		log.Errorln("Start DNS server error: %s", err)
	}
}

func applyServer() error {
	cfg := configured
	active := serverEnabled && cfg.addr != "" && cfg.listen != nil && cfg.service != nil
	if server != nil && (!active || cfg.addr != server.addr) {
		// Release both sockets immediately, even if an upstream query is slow.
		server.cancel()
		if server.tcpServer != nil {
			_ = server.tcpServer.ShutdownContext(server.ctx)
		}
		if server.udpServer != nil {
			_ = server.udpServer.ShutdownContext(server.ctx)
		}
		server = nil
	}
	if !active {
		return nil
	}

	if server == nil {
		_, port, err := net.SplitHostPort(cfg.addr)
		if err != nil || port == "" || port == "0" {
			return err
		}
		ctx, cancel := context.WithCancel(context.Background())
		server = &Server{addr: cfg.addr, service: cfg.service, ctx: ctx, cancel: cancel}
	} else {
		server.SetService(cfg.service)
	}

	var udpErr, tcpErr error
	if server.udpServer == nil {
		var p net.PacketConn
		p, udpErr = cfg.listen.ListenPacket(context.Background(), "udp", cfg.addr)
		if udpErr == nil {
			if err := sockopt.UDPReuseaddr(p); err != nil {
				log.Warnln("Failed to Reuse UDP Address: %s", err)
			}
			server.udpServer, udpErr = startDNSServer(&D.Server{PacketConn: p, Handler: server.UDPHandler()})
			if udpErr != nil {
				p.Close()
			}
		}
	}
	if server.tcpServer == nil {
		var l net.Listener
		l, tcpErr = cfg.listen.Listen(context.Background(), "tcp", cfg.addr)
		if tcpErr == nil {
			server.tcpServer, tcpErr = startDNSServer(&D.Server{Listener: l, Handler: server.TCPHandler()})
			if tcpErr != nil {
				l.Close()
			}
		}
	}
	return errors.Join(udpErr, tcpErr)
}

func startDNSServer(s *D.Server) (*D.Server, error) {
	ready := make(chan struct{})
	done := make(chan error, 1)
	s.NotifyStartedFunc = func() { close(ready) }
	go func() {
		done <- s.ActivateAndServe()
	}()
	select {
	case <-ready:
		var addr net.Addr
		if s.Listener != nil {
			addr = s.Listener.Addr()
		} else {
			addr = s.PacketConn.LocalAddr()
		}
		log.Infoln("DNS server(%s) listening at: %s", addr.Network(), addr)
		return s, nil
	case err := <-done:
		return nil, err
	}
}
