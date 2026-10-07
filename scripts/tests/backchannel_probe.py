#!/usr/bin/env python3
"""Send PCMU silence to an ONVIF/RTSP backchannel; checks no physical acoustics."""
import argparse
import re
import socket
import struct
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('host')
p.add_argument('--port', type=int, default=554)
p.add_argument('--stream', default='ch0_0.h264')
p.add_argument('--seconds', type=float, default=3)
p.add_argument('--ssh-control', help='Also verify an active writer to the camera speaker FIFO')
a = p.parse_args()
assert 0 < a.seconds <= 30
url = f'rtsp://{a.host}:{a.port}/{a.stream}'
s = socket.create_connection((a.host, a.port), 5)
s.settimeout(8)
seq = 0
pending = b''


def fill(n):
    global pending
    while len(pending) < n:
        block = s.recv(8192)
        if not block:
            raise EOFError('RTSP EOF')
        pending += block


def request(method, target, headers=None):
    global seq, pending
    seq += 1
    hdr = {'CSeq': str(seq), 'Require': 'www.onvif.org/ver20/backchannel'}
    hdr.update(headers or {})
    s.sendall((method+' '+target+' RTSP/1.0\r\n'+
               ''.join(k+': '+v+'\r\n' for k, v in hdr.items())+'\r\n').encode())
    while True:
        fill(1)
        if pending[0] != 36:
            break
        fill(4)
        size = int.from_bytes(pending[2:4], 'big')
        fill(4+size)
        pending = pending[4+size:]
    while b'\r\n\r\n' not in pending:
        fill(len(pending)+1)
    head, pending = pending.split(b'\r\n\r\n', 1)
    lines = head.decode().split('\r\n')
    code = int(lines[0].split()[1])
    fields = dict((k.lower(), v.strip()) for k, v in
                  (line.split(':', 1) for line in lines[1:]))
    length = int(fields.get('content-length', '0'))
    fill(length)
    body, pending = pending[:length], pending[length:]
    if code != 200:
        raise RuntimeError(lines[0])
    return fields, body.decode()


try:
    headers, sdp = request('DESCRIBE', url, {'Accept': 'application/sdp'})
    _, repeated = request('DESCRIBE', url, {'Accept': 'application/sdp'})
    assert sdp.count('m=') == repeated.count('m='), 'Duplicate tracks after DESCRIBE'
    tracks = [x for x in re.split(r'(?m)^m=', sdp)
              if x.startswith('audio ') and 'PCMU/8000' in x and 'a=sendonly' in x]
    assert len(tracks) == 1, sdp
    control = re.search(r'a=control:([^\r\n]+)', tracks[0]).group(1)
    base = headers.get('content-base', url+'/')
    target = control if control.startswith('rtsp://') else base.rstrip('/')+'/'+control
    headers, _ = request('SETUP', target, {'Transport': 'RTP/AVP/TCP;unicast;interleaved=0-1'})
    session = headers['session'].split(';')[0]
    channel = int(re.search(r'interleaved=(\d+)', headers['transport']).group(1))
    request('PLAY', url, {'Session': session})
    packets = max(1, int(a.seconds*50))
    for n in range(packets):
        packet = struct.pack('!BBHII', 0x80, 0, n, 160*n, 0x59694861)+b'\xff'*160
        s.sendall(b'$'+bytes([channel])+struct.pack('!H', len(packet))+packet)
        if n == 0 and a.ssh_control:
            command = ('for p in /proc/[0-9]*; do n=$(/bin/cat $p/comm 2>/dev/null); '
                       'case "$n" in speaker|rRTSPServer) /bin/ls -l $p/fd;; esac; done')
            result = subprocess.check_output(['ssh', '-n', '-S', a.ssh_control,
                                             'root@'+a.host, command], text=True)
            assert '/tmp/audio_in_fifo' in result, 'No active speaker FIFO writer'
        time.sleep(.02)
    request('TEARDOWN', url, {'Session': session})
    print(f'PASS: PCMU/8000, repeated DESCRIBE, {packets} silent packets, FIFO writer and TEARDOWN')
finally:
    s.close()
