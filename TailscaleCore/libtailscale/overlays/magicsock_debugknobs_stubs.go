//go:build ios || js

package magicsock

import (
	"net/netip"

	"tailscale.com/envknob"
	"tailscale.com/types/opt"
)

var debugNeverDirectUDPEnabled = envknob.RegisterBool("TS_DEBUG_NEVER_DIRECT_UDP")

func debugBindSocket() bool            { return false }
func debugDisco() bool                 { return false }
func debugOmitLocalAddresses() bool    { return false }
func logDerpVerbose() bool             { return false }
func debugReSTUNStopOnIdle() bool      { return false }
func debugAlwaysDERP() bool            { return false }
func debugUseDERPHTTP() bool           { return false }
func debugEnableSilentDisco() bool     { return false }
func debugSendCallMeUnknownPeer() bool { return false }
func debugPMTUD() bool                 { return false }
func debugUseDERPAddr() string         { return "" }
func debugEnablePMTUD() opt.Bool       { return "" }
func debugRingBufferMaxSizeBytes() int { return 0 }
func inTest() bool                     { return false }
func debugPeerMap() bool               { return false }
func pretendpoints() []netip.AddrPort  { return []netip.AddrPort{} }
func debugNeverDirectUDP() bool        { return debugNeverDirectUDPEnabled() }