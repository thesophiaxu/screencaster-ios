"""Read battery telemetry over the existing Wi-Fi developer tunnel.
Run with uv run --with pymobiledevice3==11.44.0 python collect_battery.py ...
This observes whole-device diagnostics; undocumented values retain their raw units.
"""
import argparse, json, sys, time
from pathlib import Path
from pymobiledevice3.services.diagnostics import DiagnosticsService
from pymobiledevice3.__main__ import main
p=argparse.ArgumentParser()
p.add_argument('--udid',required=True)
p.add_argument('--output',required=True)
p.add_argument('--seconds',type=int,default=330)
a=p.parse_args()
original=DiagnosticsService.get_battery
start=time.monotonic()
output=Path(a.output)
output.parent.mkdir(parents=True,exist_ok=True)
async def observe(self,*args,**kwargs):
    if time.monotonic()-start>a.seconds: raise KeyboardInterrupt
    raw=await original(self,*args,**kwargs)
    if raw:
        sample={k:raw.get(k) for k in ['CurrentCapacity','Voltage','InstantAmperage','Amperage','IsCharging','ExternalConnected','UpdateTime','BatteryPackCount','BatteryData','PowerTelemetryData']}
        sample['hostAt']=time.time()
        with output.open('a') as f:f.write(json.dumps(sample)+'\n')
    return raw
DiagnosticsService.get_battery=observe
sys.argv=['pymobiledevice3','diagnostics','battery','monitor','--native','--udid',a.udid]
try:sys.exit(main())
finally:DiagnosticsService.get_battery=original
