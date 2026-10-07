#!/usr/bin/env python3
"""Exercise byte/line caps, multipart binary handling and SD request locks."""
import os,pathlib,signal,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[2]; SCRIPTS=ROOT/'src/static/static/home/yi-hack/script'
with tempfile.TemporaryDirectory() as temp:
 temp=pathlib.Path(temp);prefix=temp/'hack';(prefix/'script').mkdir(parents=True);(temp/'sd').mkdir()
 for name in ('runtime.sh','config_work.sh','upload.sh'):
  text=(SCRIPTS/name).read_text().replace('/tmp/sd',str(temp/'sd')).replace('/tmp/yi-config-work.lock.d',str(temp/'lock'))
  (prefix/'script'/name).write_text(text)
 # Disable the mount check only in the fixture; exercise both explicit results.
 runtime=prefix/'script/runtime.sh';text=runtime.read_text();a=text.index('sd_available()');b=text.index('# The camera',a)
 runtime.write_text(text[:a]+'''sd_available() { [ "$MOCK_SD" = yes ]; }\n\n'''+text[b:])
 env={**os.environ,'YI_HACK_PREFIX':str(prefix),'MOCK_SD':'yes'}
 logfile=temp/'log'
 for i in range(260):subprocess.run(['sh',SCRIPTS/'bounded_log.sh',logfile,str(i)],check=True)
 assert len(logfile.read_bytes().splitlines())<=200
 subprocess.run(['sh',SCRIPTS/'bounded_log.sh',logfile,'x'*100000],check=True)
 assert logfile.stat().st_size<=65536
 # Strict multipart lengths, arbitrary binary body and headers of varying count.
 payload=b'\0\xff\r\n--not-a-boundary\nlastbyte\xff'
 body=b'--abc123\r\nContent-Disposition: form-data; name="file"; filename="x"\r\nContent-Type: application/octet-stream\r\n\r\n'+payload+b'\r\n--abc123--\r\n'
 (temp/'body').write_bytes(body)
 cmd=f'. "{prefix}/script/upload.sh"; upload_extract "{temp}/body" "{temp}/out"'
 subprocess.run(['bash','-c',cmd],env={**env,'CONTENT_TYPE':'multipart/form-data; boundary=abc123'},check=True)
 assert (temp/'out').read_bytes()==payload
 (temp/'body').write_bytes(body[:-4])
 assert subprocess.run(['bash','-c',cmd],env={**env,'CONTENT_TYPE':'multipart/form-data; boundary=abc123'}).returncode!=0
 cmd=f'. "{prefix}/script/config_work.sh"; config_work_begin || exit 9; echo ready; read WAIT'
 proc=subprocess.Popen(['bash','-c',cmd],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
 assert proc.stdout.readline().strip()=='ready'
 second=f'. "{prefix}/script/config_work.sh"; config_work_begin'
 assert subprocess.run(['bash','-c',second],env=env).returncode!=0
 proc.send_signal(signal.SIGTERM);proc.wait(timeout=3)
 assert not (temp/'lock').exists() and not (temp/'sd/.yi-config-work').exists()
 assert subprocess.run(['bash','-c',second],env={**env,'MOCK_SD':'no'}).returncode!=0
 assert not (temp/'lock').exists()
print('PASS: line/byte bounds, binary multipart/truncation, concurrent config lock, signal cleanup, missing SD')
