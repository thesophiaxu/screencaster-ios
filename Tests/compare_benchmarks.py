"""Compare two completed five-minute runs; no statistical significance implied."""
import json, sys
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
recording,control=map(Path,sys.argv[1:3])

def load(root):
    return {name:[json.loads(x) for x in (root/(name+'.jsonl')).read_text().splitlines()] for name in ['benchmark','battery']}

def power(data,skip):
    start,end=data['benchmark'][0]['at'],data['benchmark'][-1]['at']
    samples={x['UpdateTime']:x for x in data['battery'] if start+skip<=x['UpdateTime']<=end}
    samples=sorted(samples.values(),key=lambda x:x['UpdateTime'])
    if len(samples)<2:return None
    a,b=samples[0],samples[-1]
    ta,tb=a['PowerTelemetryData'],b['PowerTelemetryData']
    n=tb['SystemLoadAccumulatorCount']-ta['SystemLoadAccumulatorCount']
    if n<=0:return None
    return {'wattsAssumingMilliwattUnits':(tb['AccumulatedSystemLoad']-ta['AccumulatedSystemLoad'])/n/1000,'windowSeconds':b['UpdateTime']-a['UpdateTime'],'samples':len(samples),'from':a['UpdateTime'],'to':b['UpdateTime']}

a,b=load(recording),load(control)
result={'captureRun':str(recording),'controlRun':str(control),'comparisons':{},'caveats':['Sequential, single trials, not randomized or repeated.','Private SystemLoad units assumed to be milliwatts; not calibrated.','Control paced to approximate earlier average swipe rate; exact gesture timing differs.','Background activity and starting temperature may differ.']}
for skip in [0,60]:
    pa,pb=power(a,skip),power(b,skip)
    result['comparisons'][f'skipFirst{skip}Seconds']={'capture':pa,'control':pb,'differenceWatts':pa['wattsAssumingMilliwattUnits']-pb['wattsAssumingMilliwattUnits'] if pa and pb else None}
(control/'comparison.json').write_text(json.dumps(result,indent=2)+'\n')
plt.rcParams.update({'font.size':10,'axes.spines.top':False,'axes.spines.right':False})
fig,axes=plt.subplots(1,2,figsize=(11,4.5),layout='constrained')
fig.suptitle('Five-minute Home Screen swipe tests: capture enabled vs disabled',fontweight='bold')
for data,label,color in [(a,'Capture enabled','#6954d9'),(b,'Capture disabled','#267d63')]:
    m=data['benchmark'];start=m[0]['at']
    samples={x['UpdateTime']:x for x in data['battery'] if start<=x['UpdateTime']<=m[-1]['at']}
    samples=sorted(samples.values(),key=lambda x:x['UpdateTime'])
    axes[0].step([(x['UpdateTime']-start)/60 for x in samples],[x['PowerTelemetryData']['SystemLoad']/1000 for x in samples],where='post',color=color,label=label,linewidth=2)
    axes[1].plot([x['elapsed']/60 for x in m],[x['swipes'] for x in m],color=color,label=label,linewidth=2)
axes[0].set(title='Whole-phone power estimate',ylabel='Watts (assumed telemetry units)',xlabel='Minutes')
axes[1].set(title='Completed swipe acknowledgements',ylabel='Swipes',xlabel='Minutes')
for ax in axes:
    ax.set_xlim(0,5.05);ax.set_ylim(bottom=0);ax.grid(alpha=.15);ax.legend()
fig.supxlabel('Single sequential trials; private power telemetry is uncalibrated. Swipes paced in control to approximate the earlier run.',fontsize=9)
fig.savefig(control/'comparison.png',dpi=160)
print(json.dumps(result,indent=2))
