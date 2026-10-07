#!/usr/bin/env python3
"""Verify PCM/WAV conversion, G711, clipping and process-death lock release."""
import io, os, pathlib, signal, struct, subprocess, tempfile, time, wave
ROOT=pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as temp:
 temp=pathlib.Path(temp); fifo=temp/'fifo'; os.mkfifo(fifo)
 source=(ROOT/'src/storage_tools/speaker.c').read_text().replace('/tmp/audio_in_fifo',str(fifo)).replace('/tmp/yi-speaker.lock',str(temp/'lock'))
 (temp/'speaker.c').write_text(source); exe=temp/'speaker'
 subprocess.run(['cc','-std=gnu99','-Wall','-Wextra','-Werror',str(temp/'speaker.c'),'-o',str(exe),'-lm'],check=True)
 readfd=os.open(fifo,os.O_RDONLY|os.O_NONBLOCK)
 def drain():
  output=b''
  while True:
   try:
    data=os.read(readfd,8192)
    if not data:break
    output+=data
   except BlockingIOError:break
  return output
 samples=struct.pack('<hhhh',1000,-1000,32000,-32000)
 pcm=temp/'input.pcm';pcm.write_bytes(samples)
 subprocess.run([exe,'play',pcm,'2'],check=True)
 assert drain()==struct.pack('<hhhh',2000,-2000,32767,-32768)
 wav=temp/'input.wav'
 with wave.open(str(wav),'wb') as out:
  out.setnchannels(1);out.setsampwidth(2);out.setframerate(8000);out.writeframes(samples)
 subprocess.run([exe,'play',wav],check=True)
 assert drain()==b''.join(samples[i:i+2]*2 for i in range(0,len(samples),2))
 subprocess.run([exe,'stream','ulaw'],input=b'\xff\x7f\x00\x80',check=True)
 assert drain()==struct.pack('<hhhhhhhh',0,0,0,0,-32124,-32124,32124,32124)
 bad=temp/'bad.wav';bad.write_bytes(b'RIFFbad')
 assert subprocess.run([exe,'play',bad]).returncode!=0
 assert drain()==b''
 p=subprocess.Popen([exe,'stream','pcm'],stdin=subprocess.PIPE)
 try:
  time.sleep(.1)
  assert subprocess.run([exe,'play',pcm],capture_output=True).returncode!=0
  p.kill();p.wait(timeout=3)
  subprocess.run([exe,'play',pcm],check=True)
  assert drain()==samples
  p=subprocess.Popen([exe,'stream','pcm'],stdin=subprocess.PIPE)
  time.sleep(.1)
  subprocess.run([exe,'stop'],check=True)
  p.wait(timeout=3)
 finally:
  if p.poll() is None:p.kill();p.wait()
  os.close(readfd)
print('PASS: PCM gain/clipping, WAV chunks/rate, G711, exclusion, SIGKILL release, cancellation')
