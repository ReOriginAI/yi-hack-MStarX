#!/usr/bin/env python3
"""Run lifecycle scripts against isolated daemon/ps/socket mocks."""
import os, pathlib, shutil, signal, subprocess, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parents[2]
SOURCE=ROOT/'src/static/static/home/yi-hack'
with tempfile.TemporaryDirectory(prefix='mstar-lifecycle-') as work:
 work=pathlib.Path(work); prefix=work/'hack'; tmp=work/'tmp'; tmp.mkdir();(tmp/'sd').mkdir()
 shutil.copytree(SOURCE,prefix)
 for p in (prefix/'script').glob('*.sh'):
  p.write_text(p.read_text().replace('/tmp/',str(tmp)+'/'))
 (prefix/'model_suffix').write_text('y23\n');(prefix/'version').write_text('test\n');(tmp/'mmap.info').write_bytes(b'0'*1024)
 (prefix/'script/log_store.sh').write_text('#!/bin/sh\nexit 0\n')
 bindir=prefix/'bin';bindir.mkdir(exist_ok=True); state=work/'state';state.mkdir()
 helper=bindir/'mock.py'
 helper.write_text('''#!/usr/bin/python3
import os,sys,pathlib,signal,time
state=pathlib.Path(os.environ['MOCK_STATE']); name=pathlib.Path(sys.argv[0]).name
if name=='ps':
 print('PID USER TIME COMMAND')
 for f in state.iterdir():
  try:os.kill(int(f.name),0)
  except (OSError,ValueError):continue
  print(f.name,'root 0:00',f.read_text())
 sys.exit(0)
if name=='killall':
 target=sys.argv[-1];sig=signal.SIGKILL if '-KILL' in sys.argv else signal.SIGTERM
 for f in list(state.iterdir()):
  if f.read_text()==target:
   try:os.kill(int(f.name),sig)
   except OSError:pass
   f.unlink(missing_ok=True)
 sys.exit(0)
if name=='sleep':time.sleep(.04);sys.exit(0)
if name=='awk':
 args=sys.argv[1:]
 if '/proc/mounts' in args:
  args=[os.environ['MOCK_MOUNTS'] if a=='/proc/mounts' else a for a in args]
 if '/proc/net/tcp' in args:
  live=any(f.read_text() in ('rRTSPServer','rtsp_server_yi','go2rtc') for f in state.iterdir())
  path=pathlib.Path(os.environ['MOCK_TCP']);path.write_text('0: 00000000:022A 00000000:0000 0A\\n' if live else '')
  args=[str(path) if a in ('/proc/net/tcp','/proc/net/tcp6') else a for a in args]
 os.execv('/usr/bin/awk',['awk']+args)
# Match real daemonization: these commands return only after their daemon exists.
if name in ('onvif_notify_server','ipc2file','wsd_simple_server','pure-ftpd','httpd','dropbear','telnetd','ntpd','mdnsd'):
 ready_r,ready_w=os.pipe();pid=os.fork()
 if pid:
  os.close(ready_w);os.read(ready_r,1);sys.exit(0)
 os.close(ready_r)
 null=os.open('/dev/null',os.O_RDWR)
 for fd in (0,1,2):os.dup2(null,fd)
 os.close(null)
else:ready_w=None
record=state/str(os.getpid());record.write_text(name)
if ready_w is not None:os.write(ready_w,b'1');os.close(ready_w)
def stop(sig,frame):
 record.unlink(missing_ok=True);sys.exit(0)
signal.signal(signal.SIGTERM,stop)
while True:time.sleep(.1)
''');helper.chmod(0o755)
 names=['ps','killall','sleep','awk','h264grabber_h','h264grabber_l','h264grabber2','rRTSPServer','rtsp_server_yi','mqttv4','mqtt-config','ipc2file','onvif_notify_server','wsd_simple_server','pure-ftpd','httpd','dropbear','telnetd','ntpd','mdnsd']
 for name in names:(bindir/name).symlink_to(helper.name)
 (prefix/'sbin').mkdir(exist_ok=True)
 (prefix/'sbin/mdnsd').symlink_to(helper)
 mounts=work/'mounts';mounts.write_text('/dev/mmc '+str(tmp/'sd')+' vfat rw 0 0\n')
 env={**os.environ,'YI_HACK_PREFIX':str(prefix),'MOCK_STATE':str(state),'MOCK_TCP':str(work/'tcp'),'MOCK_MOUNTS':str(mounts)}
 def config(**changes):
  p=prefix/'etc/system.conf';d=dict(line.split('=',1) for line in p.read_text().splitlines() if '=' in line)
  d.update(changes);p.write_text(''.join(k+'='+v+'\n' for k,v in d.items()))
 def run(name,action,check=True):
  r=subprocess.run(['bash',str(prefix/'script/service.sh'),name,action],env=env,capture_output=True,timeout=30)
  if check:assert r.returncode==0,(name,action,r.stderr.decode())
  time.sleep(.05);return r
 def count(name):return sum(p.read_text()==name for p in state.iterdir())
 try:
  config(DISABLE_CLOUD='yes',REC_WITHOUT_CLOUD='no',RTSP_STREAM='both',RTSP_ALT='standard',MQTT='no')
  run('all','start');assert count('mqttv4')==count('mqtt-config')==0
  assert count('rRTSPServer')==count('h264grabber_h')==count('h264grabber_l')==1
  calls=[subprocess.Popen(['bash',str(prefix/'script/service.sh'),'rtsp','start'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE) for _ in range(4)]
  for p in calls:out,err=p.communicate(timeout=30);assert p.returncode==0,err
  assert count('rRTSPServer')==count('h264grabber_h')==count('h264grabber_l')==1
  run('rtsp','stop');run('rtsp','ensure');assert count('rRTSPServer')==count('h264grabber_h')==count('h264grabber_l')==0
  run('rtsp','start');run('privacy','on');run('rtsp','ensure');assert count('rRTSPServer')==0
  run('privacy','off');assert count('rRTSPServer')==1
  run('rtsp','stop');run('privacy','on');run('privacy','off');assert count('rRTSPServer')==0
  config(RTSP='no');run('rtsp','start');assert count('rRTSPServer')==0
  config(RTSP='yes',RTSP_ALT='go2rtc');run('rtsp','start');assert count('rRTSPServer')==1 # missing optional binary
  (bindir/'go2rtc').symlink_to(helper.name)
  run('rtsp','restart');assert count('go2rtc')==1 and count('h264grabber_h')==count('h264grabber_l')==0
  run('rtsp','ensure');assert count('go2rtc')==1
  assert run('rtsp','status').stdout.strip()==b'started'
  config(USERNAME="a'quote",PASSWORD='b"slash\\test',RTSP_BACKCHANNEL='G711')
  run('rtsp','recover');yaml=(tmp/'go2rtc.yaml').read_text()
  assert "username: 'a''quote'" in yaml and 'speaker stream ulaw' in yaml
  run('onvif','start');run('onvif','start');assert count('ipc2file')==1
  config(MQTT='yes');run('mqtt','start');run('onvif','stop');assert count('ipc2file')==1
  run('mqtt','stop');assert count('ipc2file')==0
  config(MQTT='no');run('mqtt','start');assert count('mqttv4')==0
  print('PASS: all toggles, concurrent/repeated starts, stop intent, privacy, fallback, lazy go2rtc, backend status, YAML, shared IPC ownership')
 finally:
  for f in state.iterdir():
   try:os.kill(int(f.name),signal.SIGKILL)
   except OSError:pass
