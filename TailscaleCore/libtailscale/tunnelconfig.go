package libtailscale

import (
	"bytes"
	"encoding/json"
	"fmt"
	"log"
	"net/netip"
	"sync"

	"tailscale.com/net/dns"
	"tailscale.com/wgengine/router"
)

var exitNodePublicDNSServers = []string{
	"8.8.8.8",
	"8.8.4.4",
	"2001:4860:4860::8888",
	"2001:4860:4860::8844",
}

var tailscaleServiceDNSServers = map[string]bool{
	"100.100.100.100":    true,
	"fd7a:115c:a1e0::53": true,
}

var coreTunnelRoutes = []netip.Prefix{
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("fd7a:115c:a1e0::/48"),
}

// TunnelConfig is the JSON-serializable tunnel configuration pushed to Swift.
// It contains everything NEPacketTunnelProvider needs to call
// setTunnelNetworkSettings.
type TunnelConfig struct {
	// Routes
	LocalAddresses []string `json:"localAddresses"` // e.g. ["100.64.0.2/32", "fd7a:115c:a1e0::1/128"]
	Routes         []string `json:"routes"`         // CIDR routes to include
	ExcludeRoutes  []string `json:"excludeRoutes,omitempty"`

	// DNS
	DNSServers      []string `json:"dnsServers"`
	DNSDomains      []string `json:"dnsDomains"`
	DNSMatchDomains []string `json:"dnsMatchDomains,omitempty"`

	// Tunnel
	MTU int `json:"mtu"`
}

// tunnelConfigManager holds the callback to Swift and serializes config updates.
type tunnelConfigManager struct {
	mu                        sync.Mutex
	cb                        TunnelConfigCallback
	lastConfigJSON            []byte
	defaultRouteExcludeRoutes func() []netip.Prefix
	exitNodeDNSServers        func() []netip.Addr
}

func (m *tunnelConfigManager) setDefaultRouteExcludeRoutes(fn func() []netip.Prefix) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.defaultRouteExcludeRoutes = fn
}

func (m *tunnelConfigManager) getDefaultRouteExcludeRoutes() []netip.Prefix {
	m.mu.Lock()
	fn := m.defaultRouteExcludeRoutes
	m.mu.Unlock()
	if fn == nil {
		return nil
	}
	return fn()
}

func (m *tunnelConfigManager) setExitNodeDNSServers(fn func() []netip.Addr) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.exitNodeDNSServers = fn
}

func (m *tunnelConfigManager) getExitNodeDNSServers() []string {
	m.mu.Lock()
	fn := m.exitNodeDNSServers
	m.mu.Unlock()
	if fn == nil {
		return nil
	}
	addrs := fn()
	servers := make([]string, 0, len(addrs))
	for _, addr := range addrs {
		server := addr.String()
		if !tailscaleServiceDNSServers[server] {
			servers = append(servers, server)
		}
	}
	return servers
}

func (m *tunnelConfigManager) setCallback(cb TunnelConfigCallback) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.cb = cb
	lastConfigJSON := append([]byte(nil), m.lastConfigJSON...)

	if cb != nil && len(lastConfigJSON) > 0 {
		if err := cb.OnTunnelConfigUpdate(lastConfigJSON); err != nil {
			log.Printf("replay tunnel config: %v", err)
		}
	}
}

func (m *tunnelConfigManager) onConfigUpdate(rcfg *router.Config, dcfg *dns.OSConfig) error {
	if rcfg == nil {
		// Tunnel being torn down
		m.mu.Lock()
		m.lastConfigJSON = nil
		m.mu.Unlock()
		return nil
	}

	tc := TunnelConfig{
		LocalAddresses:  []string{},
		Routes:          []string{},
		DNSServers:      []string{},
		DNSDomains:      []string{},
		DNSMatchDomains: []string{},
		MTU:             rcfg.NewMTU,
	}
	if tc.MTU <= 0 {
		tc.MTU = defaultMTU
	}

	// Local addresses
	for _, addr := range rcfg.LocalAddrs {
		tc.LocalAddresses = append(tc.LocalAddresses, addr.String())
	}

	// Routes
	for _, route := range rcfg.Routes {
		tc.Routes = append(tc.Routes, route.Masked().String())
	}
	hasDefaultRoute := hasDefaultRoute(tc.Routes)
	if hasDefaultRoute {
		tc.Routes = appendMissingCoreTunnelRoutes(tc.Routes)
	}

	// Excluded routes (routes that should stay outside the tunnel).
	for _, route := range rcfg.LocalRoutes {
		tc.ExcludeRoutes = appendExcludeRoute(tc.ExcludeRoutes, route)
	}
	if hasDefaultRoute {
		underlayExcludeStart := len(tc.ExcludeRoutes)
		for _, route := range m.getDefaultRouteExcludeRoutes() {
			tc.ExcludeRoutes = appendExcludeRoute(tc.ExcludeRoutes, route)
		}
		if len(tc.ExcludeRoutes) > underlayExcludeStart {
			log.Printf("exit node: excluding underlay routes from NetworkExtension tunnel: %v", tc.ExcludeRoutes[underlayExcludeStart:])
		}
	}

	// DNS
	if dcfg != nil {
		for _, ns := range dcfg.Nameservers {
			tc.DNSServers = append(tc.DNSServers, ns.String())
		}
		for _, d := range dcfg.SearchDomains {
			tc.DNSDomains = append(tc.DNSDomains, d.WithoutTrailingDot())
		}
		for _, d := range dcfg.MatchDomains {
			tc.DNSMatchDomains = append(tc.DNSMatchDomains, d.WithoutTrailingDot())
		}
	}
	if hasDefaultRoute && dnsServersAreTailscaleServiceIPs(tc.DNSServers) {
		if platformDNSServers := m.getExitNodeDNSServers(); len(platformDNSServers) > 0 {
			log.Printf("exit node: using platform DNS servers for NetworkExtension DNS to avoid PeerAPI DNS proxy timeout")
			tc.DNSServers = platformDNSServers
		} else {
			log.Printf("exit node: using public DNS servers for NetworkExtension DNS because platform DNS is unavailable")
			tc.DNSServers = append([]string(nil), exitNodePublicDNSServers...)
		}
	}

	log.Printf("tunnel config: localAddrs=%d routes=%d excludeRoutes=%d dnsServers=%d searchDomains=%d matchDomains=%d mtu=%d hasDefaultRoute=%t",
		len(tc.LocalAddresses),
		len(tc.Routes),
		len(tc.ExcludeRoutes),
		len(tc.DNSServers),
		len(tc.DNSDomains),
		len(tc.DNSMatchDomains),
		tc.MTU,
		hasDefaultRoute,
	)

	configJSON, err := json.Marshal(tc)
	if err != nil {
		return fmt.Errorf("marshal tunnel config: %w", err)
	}
	m.mu.Lock()
	if bytes.Equal(m.lastConfigJSON, configJSON) {
		m.mu.Unlock()
		return nil
	}
	m.lastConfigJSON = append([]byte(nil), configJSON...)
	cb := m.cb

	if cb == nil {
		m.mu.Unlock()
		return nil
	}

	err = cb.OnTunnelConfigUpdate(configJSON)
	m.mu.Unlock()
	if err != nil {
		log.Printf("tunnel config: callback failed: %v", err)
	}
	return err
}

func shouldSkipExcludeRoute(route netip.Prefix) bool {
	return route.Addr().IsLoopback()
}

func appendExcludeRoute(routes []string, route netip.Prefix) []string {
	if shouldSkipExcludeRoute(route) {
		return routes
	}
	routeStr := route.Masked().String()
	for _, existing := range routes {
		if existing == routeStr {
			return routes
		}
	}
	return append(routes, routeStr)
}

func hasDefaultRoute(routes []string) bool {
	for _, route := range routes {
		prefix, err := netip.ParsePrefix(route)
		if err != nil {
			continue
		}
		prefix = prefix.Masked()
		if (prefix.Addr().Is4() && prefix.Bits() == 0) || (prefix.Addr().Is6() && prefix.Bits() == 0) {
			return true
		}
	}
	return false
}

func appendMissingCoreTunnelRoutes(routes []string) []string {
	seen := make(map[string]bool, len(routes)+len(coreTunnelRoutes))
	for _, route := range routes {
		seen[route] = true
	}
	for _, route := range coreTunnelRoutes {
		routeStr := route.String()
		if !seen[routeStr] {
			routes = append(routes, routeStr)
			seen[routeStr] = true
		}
	}
	return routes
}

func dnsServersAreTailscaleServiceIPs(servers []string) bool {
	if len(servers) == 0 {
		return false
	}
	for _, server := range servers {
		if !tailscaleServiceDNSServers[server] {
			return false
		}
	}
	return true
}

// setTunnelConfigCallback is called from the exported SetTunnelConfigCallback.
func (a *App) setTunnelConfigCallback(cb TunnelConfigCallback) {
	a.tunnelConfigMgr.setCallback(cb)
}
