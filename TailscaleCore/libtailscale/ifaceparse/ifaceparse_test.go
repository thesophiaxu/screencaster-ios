package ifaceparse

import "testing"

func TestParseInterfacesJSONSkipsUTUN(t *testing.T) {
	json := []byte(`[
		{"name":"en0","index":4,"mtu":1500,"up":true,"broadcast":true,"loopback":false,"pointToPoint":false,"multicast":true,"addrs":[{"ip":"192.168.1.10","prefixLen":24}]},
		{"name":"utun7","index":19,"mtu":1280,"up":true,"broadcast":false,"loopback":false,"pointToPoint":true,"multicast":true,"addrs":[{"ip":"100.64.0.38","prefixLen":32}]}
	]`)

	ifaces, stats, err := ParseInterfacesJSONAsNetmon(json)
	if err != nil {
		t.Fatalf("ParseInterfacesJSONAsNetmon: %v", err)
	}
	if got, want := len(ifaces), 1; got != want {
		t.Fatalf("len(ifaces) = %d, want %d", got, want)
	}
	if got, want := ifaces[0].Name, "en0"; got != want {
		t.Fatalf("ifaces[0].Name = %q, want %q", got, want)
	}
	if got, want := stats.IfacesSkipped, 1; got != want {
		t.Fatalf("IfacesSkipped = %d, want %d", got, want)
	}
}