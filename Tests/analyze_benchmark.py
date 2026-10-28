"""Summarize on-device benchmark JSONL, event logs, and raw battery telemetry."""
import argparse, json, re, statistics
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument('directory',type=Path)
a=p.parse_args();d=a.directory
metrics=[json.loads(line) for line in (d/'benchmark.jsonl').read_text().splitlines() if line]
battery=[json.loads(line) for line in (d/'battery.jsonl').read_text().splitlines() if line]
events=(d/'events.log').read_text()
first,last=metrics[0],metrics[-1]
elapsed=last['elapsed']-first['elapsed']
latencies=[v for m in metrics for v in m['captureMilliseconds']]
def percentile(xs,p):
 xs=sorted(xs)
 if not xs:return None
 index=(len(xs)-1)*p; lo=int(index); hi=min(lo+1,len(xs)-1)
 return xs[lo]+(xs[hi]-xs[lo])*(index-lo)
frames=[]
for line in events.splitlines():
 match=re.search(r'frame=(\d+)-screen(\d+)\.jpg capturedAt=([\d.]+).*bytes=(\d+)',line)
 if match:frames.append({'screen':int(match[2]),'at':float(match[3]),'bytes':int(match[4])})
displays={}
for index in sorted({f['screen'] for f in frames}):
 fs=[f for f in frames if f['screen']==index]
 gaps=[r['at']-l['at'] for l,r in zip(fs,fs[1:])]
 displays[str(index)]={'saved':len(fs),'bytes':sum(f['bytes'] for f in fs),'savedFPSOverFullRun':len(fs)/elapsed,'meanCaptureIntervalSeconds':statistics.mean(gaps) if gaps else None,'p95CaptureIntervalSeconds':percentile(gaps,.95)}
# Keep only diagnostic records whose firmware update timestamp lies inside the
# actual test window, and deduplicate its slow republishing cadence.
unique={x['UpdateTime']:x for x in battery if first['at']<=x['UpdateTime']<=last['at']}
bounds=sorted(unique.values(),key=lambda x:x['UpdateTime'])
power=None
if len(bounds)>1:
 b0,b1=bounds[0],bounds[-1]
 t0,t1=b0['PowerTelemetryData'],b1['PowerTelemetryData']
 n=t1['SystemLoadAccumulatorCount']-t0['SystemLoadAccumulatorCount']
 if n>0:
  power={'assumedMilliwattsMean':(t1['AccumulatedSystemLoad']-t0['AccumulatedSystemLoad'])/n,'sampleCountDelta':n,'windowSeconds':b1['UpdateTime']-b0['UpdateTime'],'from':b0['UpdateTime'],'to':b1['UpdateTime'],'caveat':'Assumes SystemLoad uses the milliwatt convention seen in macOS tooling. Private iOS telemetry, not calibrated or recorder-only power.'}
summary={
 'captureDisabled':last.get('captureDisabled',False),'swipeInterval':last.get('swipeInterval',0),
 'elapsedSeconds':elapsed,'startedAt':first['at'],'endedAt':last['at'],'finished':last['finished'],'swipes':last['swipes'],
 'gestureDisplayID':last['gestureDisplayID'],'gestureSize':last['gestureSize'],'gestureOrientation':last['gestureOrientation'],
 'eventLogSavedImages':len(frames),'eventLogSavedBytes':sum(f['bytes'] for f in frames),
 'swipesPerSecond':last['swipes']/elapsed,'swipeErrors':sorted({x['swipeError'] for x in metrics if x['swipeError']}),
 'savedImages':last['frames'],'savedBytes':last['bytes'],'displays':displays,
 'runnerCPUSeconds':last['cpuSeconds']-first['cpuSeconds'],
 'runnerMeanCPUPercentOneCore':100*(last['cpuSeconds']-first['cpuSeconds'])/elapsed,
 'runnerPeakFootprintMiB':max(x['footprintBytes'] for x in metrics)/2**20,
 'runnerFinalFootprintMiB':last['footprintBytes']/2**20,
 'runnerPeakResidentMiB':max(x['residentBytes'] for x in metrics)/2**20,
 'captureAndJPEGms':{'n':len(latencies),'p50':percentile(latencies,.5),'p95':percentile(latencies,.95),'max':max(latencies,default=None)},
 'thermalStates':sorted({x['thermalState'] for x in metrics}),
 'thermalStart':first['thermalState'],'thermalEnd':last['thermalState'],
 'batteryUIKitStart':first['batteryLevel'],'batteryUIKitEnd':last['batteryLevel'],
 'batteryDiagnosticsStart':bounds[0]['CurrentCapacity'] if bounds else None,'batteryDiagnosticsEnd':bounds[-1]['CurrentCapacity'] if bounds else None,
 'externalConnectedSeen':any(x['ExternalConnected'] for x in battery),'chargingSeen':any(x['IsCharging'] for x in battery),
 'brightnessReported':sorted({x['brightness'] for x in metrics}),
 'lowPowerModeSeen':any(x['lowPowerMode'] for x in metrics),
 'uniqueBatteryUpdatesInsideTest':len(bounds),'systemPowerEstimate':power,
 'limitations':['CPU/memory measure only the runner; system screenshot services and SpringBoard are excluded.','XCTest swipes also execute on the main thread and can delay capture.','Capture-disabled control: no screenshots, JPEG conversion, or image writes.' if last.get('captureDisabled',False) else 'Both displays are sampled; display 0 has previously returned black frames.','This is a single run; power includes screen, gestures, Wi-Fi telemetry, and other phone activity.','Five minutes cannot establish 24/7 stability or a reliable battery-life projection.']}
(d/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
