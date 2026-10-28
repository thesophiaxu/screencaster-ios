import http.client, subprocess, re, time, tempfile, socket
from pathlib import Path
root = Path(__file__).resolve().parents[1]
key = re.search(r'@"(.*?)"', (root/'Shared/MonitorToken.h').read_text())[1]
build = tempfile.TemporaryDirectory(prefix='phantom-monitor-test-')
executable = str(Path(build.name)/'monitor-smoke')
subprocess.run(['clang','-fobjc-arc','-fblocks','-framework','Foundation',str(root/'Tests/MonitorServerSmoke.m'),str(root/'Probe/ProbeMonitor.m'),'-o',executable],check=True)
p=subprocess.Popen([executable])
def request(method,path,auth=None):
 c=http.client.HTTPConnection('127.0.0.1',19727,timeout=2)
 c.request(method,path,headers={} if auth is None else {'Authorization':'Bearer '+auth})
 r=c.getresponse();result=(r.status,r.read());c.close();return result
try:
 time.sleep(.3)
 # A client that connects before sending headers must not be closed early.
 client = socket.create_connection(('127.0.0.1',19727),timeout=2)
 time.sleep(.1)
 client.sendall(b'GET /status HTTP/1.1\r\nHost: localhost\r\n\r\n')
 assert b'403 Forbidden' in client.recv(1024)
 client.close()
 assert request('GET','/status')[0]==403
 assert request('POST','/stop','wrong')[0]==403
 assert request('GET','/missing',key)[0]==404
 status,body=request('GET','/status',key)
 import json
 assert status==200 and json.loads(body)['frames']==42
 assert request('POST','/stop',key)[0]==200
 assert p.wait(timeout=3)==0
 print('PASS: authenticated status, rejected unauthorized reads/stops, unknown route, stop acknowledgement')
finally:
 if p.poll() is None:p.terminate();p.wait()

 build.cleanup()
