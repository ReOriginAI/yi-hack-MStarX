#!/usr/bin/env python3
"""Round-trip backups and validate real CGI JSON updates in an isolated tree."""
import json, os, pathlib, subprocess, tempfile, bz2, io, tarfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
SCRIPTS=ROOT/'src/static/static/home/yi-hack/script'; CGI=ROOT/'src/www/httpd/cgi-bin'
with tempfile.TemporaryDirectory() as t:
 t=pathlib.Path(t);prefix=t/'hack';sd=t/'sd';sd.mkdir()
 for d in ('script','bin','etc','cgi'):(prefix/d).mkdir(parents=True)
 for name in ('runtime.sh','config_work.sh','upload.sh','restore_config.sh'):
  s=(SCRIPTS/name).read_text().replace('/tmp/sd',str(sd)).replace('/tmp/yi-config-work.lock.d',str(t/'lock'))
  if name=='runtime.sh':
   a=s.index('sd_available()');b=s.index('# The camera',a);s=s[:a]+'sd_available() { [ "$MOCK_SD" = yes ]; }\n'+s[b:]
  p=prefix/'script'/name;p.write_text(s);p.chmod(0o755)
 for name in ('save.sh','load.sh','set_configs.sh'):(prefix/'cgi'/name).write_text((CGI/name).read_text())
 (prefix/'script/service.sh').write_text('#!/bin/sh\nexit 0\n');(prefix/'script/service.sh').chmod(0o755)
 (prefix/'bin/ipc_cmd').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$YI_HACK_PREFIX/ipc-calls"\n');(prefix/'bin/ipc_cmd').chmod(0o755)
 subprocess.run(['gcc','-std=gnu99','-Wall','-Wextra','-Werror',ROOT/'src/storage_tools/archive_check.c','-o',prefix/'bin/archive_check'],check=True)
 (prefix/'etc/system.conf').write_text('RTSP=yes\nMQTT=no\nUSERNAME=before\nPASSWORD=before\nRTSP_PORT=554\nHTTPD_PORT=80\nRTSP_BACKCHANNEL=NONE\nONVIF_AUDIO_BC=NONE\n')
 (prefix/'etc/camera.conf').write_text('SWITCH_ON=yes\nROTATE=no\nSAVE_VIDEO_ON_MOTION=yes\nSENSITIVITY=medium\nLED=no\nIR=yes\n')
 (prefix/'etc/TZ').write_text('UTC0')
 env={**os.environ,'YI_HACK_PREFIX':str(prefix),'MOCK_SD':'yes'}
 def call(name,data=b'',query='',more=None):
  e={**env,'REQUEST_METHOD':'POST','CONTENT_LENGTH':str(len(data)),'QUERY_STRING':query,**(more or {})}
  p=subprocess.run(['bash',prefix/'cgi'/name],input=data,env=e,capture_output=True)
  assert not (sd/'.yi-config-work').exists() and not (t/'lock').exists(),p.stderr
  return p
 backup=call('save.sh');assert backup.returncode==0,backup.stderr
 archive=backup.stdout.split(b'\r\n\r\n',1)[1]
 original=(prefix/'etc/system.conf').read_bytes();(prefix/'etc/system.conf').write_text('RTSP=no\n')
 body=b'--part\r\nContent-Disposition: form-data; name="file"; filename="config.tar.bz2"\r\n\r\n'+archive+b'\r\n--part--\r\n'
 restored=call('load.sh',body,more={'CONTENT_TYPE':'multipart/form-data; boundary=part'})
 assert restored.returncode==0,restored.stderr
 assert (prefix/'etc/system.conf').read_bytes()==original
 assert '-r off' in (prefix/'ipc-calls').read_text()
 for key,value,valid in [('PASSWORD','quote\' slash\\ and $(touch /tmp/unwanted)',True),('RTSP_PORT','65536',False),('PASSWORD','line\nbreak',False),('PASSWORD','nul\0byte',False),('PASSWORD','control\x01byte',False),('RTSP_BACKCHANNEL','AAC',True),('UNKNOWN_KEY','yes',False)]:
  before=(prefix/'etc/system.conf').read_bytes();r=call('set_configs.sh',json.dumps({key:value}).encode(),'conf=system')
  assert (r.returncode==0)==valid,(key,value,r.stdout,r.stderr)
  if not valid:assert (prefix/'etc/system.conf').read_bytes()==before
  else:assert (key+'='+value+'\n').encode() in (prefix/'etc/system.conf').read_bytes()
 # Maintenance profile validation prevents an unusable enabled fallback.
 with (prefix/'etc/system.conf').open('a') as f:f.write('WIFI_MAINTENANCE_ENABLED=no\nWIFI_MAINTENANCE_SSID=\nWIFI_MAINTENANCE_PASSWORD=\nMOTION_IMAGE_DELAY=2\nTIMELAPSE_DT=60\n')
 assert call('set_configs.sh',json.dumps({'WIFI_MAINTENANCE_ENABLED':'yes'}).encode(),'conf=system').returncode!=0
 assert call('set_configs.sh',json.dumps({'WIFI_MAINTENANCE_ENABLED':'yes','WIFI_MAINTENANCE_SSID':'Recovery','WIFI_MAINTENANCE_PASSWORD':'validpassword'}).encode(),'conf=system').returncode==0
 assert call('set_configs.sh',json.dumps({'MOTION_IMAGE_DELAY':'5,0','TIMELAPSE_DT':'1440+120'}).encode(),'conf=system').returncode==0
 assert 'MOTION_IMAGE_DELAY=5.0' in (prefix/'etc/system.conf').read_text()
 assert call('set_configs.sh',json.dumps({'MOTION_IMAGE_DELAY':'6'}).encode(),'conf=system').returncode!=0
 assert call('set_configs.sh',json.dumps({'TIMELAPSE_DT':'1440+1441'}).encode(),'conf=system').returncode!=0
 # Unsupported files and truncated compressed uploads never mutate settings.
 for data in (b'not-an-archive',archive[:-8]):
  before=(prefix/'etc/system.conf').read_bytes();assert call('load.sh',data).returncode!=0
  assert (prefix/'etc/system.conf').read_bytes()==before
 assert call('save.sh',more={'MOCK_SD':'no'}).returncode!=0
 # A backup must fit the restore compressed limit too.
 (prefix/'etc/extra.conf').write_bytes(os.urandom(64000))
 (prefix/'etc/more.conf').write_bytes(os.urandom(64000))
 assert call('save.sh').returncode!=0
print('PASS: CGI backup/restore, JSON quoting/controls/ports, AAC migration, rollback on bad input, missing SD, compressed save cap')
