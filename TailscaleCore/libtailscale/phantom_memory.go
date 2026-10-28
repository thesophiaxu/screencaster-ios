package libtailscale

import (
 "runtime"
 "runtime/debug"
)

// The VPN shares its process with the bounded screenshot pipeline. This is a
// Go runtime soft budget, not a promise about the total process footprint.
func init() {
 runtime.GOMAXPROCS(2)
 debug.SetMemoryLimit(18 << 20)
 debug.SetGCPercent(25)
}
