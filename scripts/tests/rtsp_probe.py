#!/usr/bin/env python3
"""Read live interleaved video/audio RTP and exercise repeated DESCRIBE."""
import argparse, re, socket, time, json
p=argparse.ArgumentParser();p.add_argument('host');p.add_argument('--port',type=int,default=554);p.add_argument('--stream',default='ch0_0.h264');p.add_argument('--seconds',type=float,default=3);a=p.parse_args()
url=f'rtsp://{a.host}:{a.port}/{a.stream}';s=socket.create_connection((a.host,a.port),5);s.settimeout(10)
buffer=b'';seq=0;packets={};session=None

def fill(n):
 global buffer
 while len(buffer)<n:
  block=s.recv(65536)
  if not block:raise EOFError('RTSP EOF')
  buffer+=block

def skip_packet():
 global buffer
 fill(4);channel=buffer[1];size=int.from_bytes(buffer[2:4],'big');fill(4+size)
 packets[channel]=packets.get(channel,0)+1;buffer=buffer[4+size:]

def request(method,target,headers=None):
 global seq,buffer
 seq+=1;fields={'CSeq':str(seq)};fields.update(headers or {})
 if session:fields['Session']=session
 s.sendall((f'{method} {target} RTSP/1.0\r\n'+''.join(f'{k}: {v}\r\n' for k,v in fields.items())+'\r\n').encode())
 while True:
  fill(1)
  if buffer[:1]==b'$':skip_packet();continue
  while b'\r\n\r\n' not in buffer:fill(len(buffer)+1)
  head,buffer=buffer.split(b'\r\n\r\n',1);lines=head.decode().split('\r\n')
  assert ' 200 ' in lines[0],lines[0]
  fields={k.lower():v.strip() for k,v in (line.split(':',1) for line in lines[1:])}
  length=int(fields.get('content-length','0'));fill(length);body,buffer=buffer[:length],buffer[length:]
  return fields,body

try:
 headers,sdp=request('DESCRIBE',url,{'Accept':'application/sdp'})
 _,again=request('DESCRIBE',url,{'Accept':'application/sdp'})
 assert sdp.count(b'm=')==again.count(b'm='),'duplicate media after DESCRIBE'
 base=headers.get('content-base',url+'/')
 tracks=[]
 for track in re.split(r'(?m)^m=',sdp.decode()):
  if track.startswith(('video ','audio ')) and 'a=sendonly' not in track:
   control=re.search(r'a=control:([^\r\n]+)',track).group(1);tracks.append((track.split()[0],control))
 assert any(kind=='video' for kind,_ in tracks),sdp
 for i,(kind,control) in enumerate(tracks):
  target=control if control.startswith('rtsp://') else base.rstrip('/')+'/'+control
  header,_=request('SETUP',target,{'Transport':f'RTP/AVP/TCP;unicast;interleaved={i*2}-{i*2+1}'})
  session=header['session'].split(';')[0]
 request('PLAY',url)
 end=time.monotonic()+a.seconds
 while time.monotonic()<end:
  fill(1)
  if buffer[:1]==b'$':skip_packet()
  else:raise RuntimeError(buffer[:200])
 assert packets.get(0,0)>10,packets
 for i,(kind,_) in enumerate(tracks):
  assert packets.get(i*2,0)>0,(kind,packets)
 request('TEARDOWN',url)
 print(json.dumps({'url':url,'media':[x[0] for x in tracks],'rtp_packets':packets,'repeat_describe':True}))
finally:s.close()
