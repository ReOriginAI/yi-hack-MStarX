#!/usr/bin/env python3
"""Exercise the native protocol fixture on SD; never flash or play audible audio.

Run rtsp_backchannel_server.cpp with an existing private output file, then supply
--output with that absolute path. The test resets only that caller-owned file.
"""
import argparse
import json
import re
import socket
import shlex
import struct
import subprocess
import tempfile
import time
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('host')
p.add_argument('--port', type=int, default=5556)
p.add_argument('--ssh-control')
p.add_argument('--output', required=True)
a = p.parse_args()
assert a.output.startswith('/tmp/sd/.mstar-bc-test/') and '..' not in Path(a.output).parts, 'Use private SD test output'
output_path = shlex.quote(a.output)


def remote(command):
    args = ['ssh', '-n']
    if a.ssh_control:
        args += ['-S', a.ssh_control]
    return subprocess.check_output(args + ['root@'+a.host, command])


class Client:
    def __init__(self, name):
        self.url = f'rtsp://{a.host}:{a.port}/{name}'
        self.socket = socket.create_connection((a.host, a.port), 5)
        self.socket.settimeout(4)
        self.pending = b''
        self.seq = 0
        self.session = None

    def fill(self, n):
        while len(self.pending) < n:
            block = self.socket.recv(8192)
            if not block:
                raise EOFError('RTSP connection closed')
            self.pending += block

    def request(self, method, target=None, fields=None, expected=200):
        self.seq += 1
        headers = {'CSeq': str(self.seq), 'Require': 'www.onvif.org/ver20/backchannel'}
        if self.session:
            headers['Session'] = self.session
        headers.update(fields or {})
        self.socket.sendall((f'{method} {target or self.url} RTSP/1.0\r\n'+
                             ''.join(k+': '+v+'\r\n' for k, v in headers.items())+'\r\n').encode())
        # RTCP BYE/report packets may precede TEARDOWN responses.
        while True:
            self.fill(1)
            if self.pending[0] != 36:
                break
            self.fill(4)
            size = int.from_bytes(self.pending[2:4], 'big')
            self.fill(4+size)
            self.pending = self.pending[4+size:]
        while b'\r\n\r\n' not in self.pending:
            self.fill(len(self.pending)+1)
        head, self.pending = self.pending.split(b'\r\n\r\n', 1)
        lines = head.decode().split('\r\n')
        assert int(lines[0].split()[1]) == expected, lines[0]
        fields = dict((k.lower(), v.strip()) for k, v in
                      (line.split(':', 1) for line in lines[1:]))
        length = int(fields.get('content-length', 0))
        self.fill(length)
        body, self.pending = self.pending[:length], self.pending[length:]
        return fields, body.decode()

    def describe(self, codec):
        _, sdp = self.request('DESCRIBE', fields={'Accept': 'application/sdp'})
        assert f'{codec}' in sdp and 'a=sendonly' in sdp, sdp
        self.control = re.findall(r'a=control:([^\r\n]+)', sdp)[-1]
        self.payload_type = int(re.search(r'm=audio \d+ RTP/AVP (\d+)', sdp).group(1))
        return sdp

    def setup(self, expected=200):
        headers, _ = self.request('SETUP', self.url+'/'+self.control,
                                 {'Transport': 'RTP/AVP/TCP;unicast;interleaved=0-1'}, expected)
        if expected == 200:
            self.session = headers['session'].split(';')[0]
            self.channel = int(re.search(r'interleaved=(\d+)', headers['transport']).group(1))
            self.request('PLAY')

    def send(self, payloads, step):
        for n, payload in enumerate(payloads):
            packet = struct.pack('!BBHII', 0x80, self.payload_type | (0x80 if self.payload_type >= 96 else 0), n, n*step, 12345)+payload
            self.socket.sendall(b'$'+bytes([self.channel])+struct.pack('!H', len(packet))+packet)
            time.sleep(step / (16000 if self.payload_type >= 96 else 8000))
        time.sleep(.12)

    def close(self, teardown=False):
        if teardown and self.session:
            self.request('TEARDOWN')
        self.socket.close()


def output():
    return remote('cat '+output_path)


for name, codec, silence in [('pcmu', 'PCMU/8000', 0xff), ('pcma', 'PCMA/8000', 0x55)]:
    remote(': > '+output_path)
    owner = Client(name)
    try:
        first = owner.describe(codec)
        assert owner.describe(codec) == first, 'Repeated DESCRIBE changed tracks'
        assert output() == b'', 'DESCRIBE wrote playback data'
        owner.setup()
        contender = Client(name)
        try:
            contender.describe(codec)  # Discovery remains available while busy.
            contender.setup(expected=503)
        finally:
            contender.close()
        owner.send([bytes([silence])*160]*10, 160)
        pcm = output()
        assert len(pcm) == 6400, len(pcm)
        samples = struct.unpack('<'+'h'*(len(pcm)//2), pcm)
        if name == 'pcmu':
            assert all(value == 0 for value in samples)
        else:
            assert all(-16 <= value < 0 for value in samples), samples[:12]
        # AAC discovery must not touch the lock currently held by G711.
        preview = Client('aac')
        try:
            preview.describe('mpeg4-generic/16000')
            preview.setup(expected=503)
        finally:
            preview.close()
    finally:
        owner.close(teardown=True)
    # A subsequent connection can claim playback after TEARDOWN.
    second = Client(name)
    second.describe(codec)
    second.setup()
    second.close()  # Abrupt TCP loss must also release ownership.
    time.sleep(.2)
    third = Client(name)
    third.describe(codec)
    third.setup()
    third.close(teardown=True)
    print(f'PASS: {name} clock/PCM, repeated discovery, busy rejection, TEARDOWN and disconnect', flush=True)

with tempfile.TemporaryDirectory() as folder:
    adts = Path(folder)/'silence.aac'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'anullsrc=r=16000:cl=mono',
                    '-t', '0.4', '-c:a', 'aac', '-f', 'adts', str(adts)], check=True)
    encoded = adts.read_bytes()
    frames = []
    while encoded:
        length = ((encoded[3] & 3) << 11) | (encoded[4] << 3) | (encoded[5] >> 5)
        assert length <= len(encoded)
        raw = encoded[7:length]
        frames.append(b'\x00\x10'+struct.pack('!H', len(raw)<<3)+raw)
        encoded = encoded[length:]
    remote(': > '+output_path)
    client = Client('aac')
    client.describe('mpeg4-generic/16000')
    client.setup()
    client.send(frames, 1024)
    client.close(teardown=True)
    pcm = output()
    assert len(pcm) == len(frames)*2048, (len(pcm), len(frames))
    print(f'PASS: AAC RTP decode, {len(frames)} frames / {len(pcm)} PCM bytes, cleanup', flush=True)
# Repeated connections must not accumulate playback descriptors.
def descriptor_count():
    return int(remote('p=$(cat /tmp/sd/.mstar-bc-test/server.pid); '
                      '/tmp/sd/.mstar-bc-test/busybox ls /proc/$p/fd | '
                      '/tmp/sd/.mstar-bc-test/busybox wc -l'))

before = descriptor_count()
for n in range(20):
    client = Client('pcmu')
    client.describe('PCMU/8000')
    client.setup()
    client.close(teardown=(n % 2 == 0))
    time.sleep(.025)
time.sleep(.2)
after = descriptor_count()
assert after == before, (before, after)
print(f'PASS: 20 mixed TEARDOWN/disconnect sessions, descriptors {before}->{after}', flush=True)
print(json.dumps({'port': a.port, 'output': a.output, 'physical_playback': False}))
