package libtailscale

import (
	_ "unsafe"

	"tailscale.com/wgengine/magicsock"
)

//go:linkname resetMagicsockEndpointStates tailscale.com/wgengine/magicsock.(*Conn).resetEndpointStates
func resetMagicsockEndpointStates(*magicsock.Conn)
