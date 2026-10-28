"""Render the saved five-minute measurements (requires matplotlib)."""
from pathlib import Path
import json, sys
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=Path(sys.argv[1])
m=[json.loads(x) for x in (root/'benchmark.jsonl').read_text().splitlines()]
b=[json.loads(x) for x in (root/'battery.jsonl').read_text().splitlines()]
start=m[0]['at']; t=[x['elapsed']/60 for x in m]
plt.rcParams.update({'font.family':'sans-serif','font.size':10,'axes.spines.top':False,'axes.spines.right':False})
fig,axes=plt.subplots(2,2,figsize=(11,7),layout='constrained')
mode = 'Capture disabled' if m[-1].get('captureDisabled',False) else 'Phantom capture'
fig.suptitle(f'{mode} + Home Screen swipes · 5 minutes',fontsize=15,fontweight='bold')
a=axes[0,0]; a.plot(t,[x['frames'] for x in m],color='#6954d9',linewidth=2);a.set(title='Saved JPEG images (both displays)',ylabel='Images')
a=axes[0,1];cpu=[100*(r['cpuSeconds']-l['cpuSeconds'])/(r['elapsed']-l['elapsed']) for l,r in zip(m,m[1:])];a.plot(t[1:],cpu,color='#267d63',linewidth=2);a.set(title='Recorder + swipe-driver CPU',ylabel='% of one CPU core');a.set_ylim(bottom=0)
a=axes[1,0];a.plot(t,[x['footprintBytes']/2**20 for x in m],color='#456bb4',linewidth=2);a.set(title='Runner memory footprint',ylabel='MiB',xlabel='Minutes');a.set_ylim(bottom=0)
u={x['UpdateTime']:x for x in b if start<=x['UpdateTime']<=m[-1]['at']};u=sorted(u.values(),key=lambda x:x['UpdateTime'])
a=axes[1,1];a.step([(x['UpdateTime']-start)/60 for x in u],[x['PowerTelemetryData']['SystemLoad']/1000 for x in u],where='post',color='#bb6a24',linewidth=2);a.set(title='Whole-phone power estimate*',ylabel='Watts (assumed telemetry units)',xlabel='Minutes');a.set_ylim(bottom=0)
for a in axes.flat:a.grid(alpha=.15);a.set_xlim(0,max(t))
fig.supxlabel('*Private battery telemetry, roughly 20-second updates; not calibrated. Includes display, gestures, capture, Wi-Fi and other activity.',fontsize=9)
fig.savefig(root/'measurements.png',dpi=160)
