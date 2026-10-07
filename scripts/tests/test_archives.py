import io, tarfile, tempfile, subprocess, pathlib, bz2, os
root=pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory() as t:
 t=pathlib.Path(t);(t/'etc').mkdir()
 for n in ['system.conf','camera.conf','mqttv4.conf']:(t/'etc'/n).write_text('old')
 exe=t/'archive_check';subprocess.run(['gcc','-std=gnu99','-Wall','-Wextra','-Werror',str(root/'src/storage_tools/archive_check.c'),'-o',str(exe)],check=True)
 def case(label,entries,valid=True,trim=0):
  arc=t/(label+'.tar')
  with tarfile.open(arc,'w',format=tarfile.USTAR_FORMAT) as f:
   for name,typ,data in entries:
    i=tarfile.TarInfo(name);i.type=typ;i.linkname='/etc/passwd' if typ==tarfile.SYMTYPE else '';i.size=len(data) if typ==tarfile.REGTYPE else 0;f.addfile(i,io.BytesIO(data) if typ==tarfile.REGTYPE else None)
  if trim:arc.write_bytes(arc.read_bytes()[:trim])
  r=subprocess.run([exe,'config',arc,t],capture_output=True)
  assert (r.returncode==0)==valid,(label,r.stderr)
 valid=[('system.conf',tarfile.REGTYPE,b'A=yes\n'),('camera.conf',tarfile.REGTYPE,b'B=yes\n')]
 case('valid',valid)
 for label,extra in [('traversal',('../x.conf',tarfile.REGTYPE,b'x')),('directory',('dir/',tarfile.DIRTYPE,b'')),('symlink',('hostname',tarfile.SYMTYPE,b'')),('hardlink',('hostname',tarfile.LNKTYPE,b'')),('device',('hostname',tarfile.CHRTYPE,b'')),('unknown',('x.conf',tarfile.REGTYPE,b'x')),('duplicate',valid[0]),('newline',('host\nname',tarfile.REGTYPE,b'x')),('absolute',('/hostname',tarfile.REGTYPE,b'x')),('huge',('hostname',tarfile.REGTYPE,b'x'*65537))]:case(label,valid+[extra],False)
 case('missing',valid[:1],False)
 case('truncated',valid,False,trim=2048)
 case('emptyoptional',valid+[('TZ',tarfile.REGTYPE,b'')])
 # Huge decompression is limited in the shell child, not in the CGI parent.
 (t/'bin').mkdir();(t/'bin/archive_check').symlink_to(exe)
 (t/'bomb.bz2').write_bytes(bz2.compress(b'x'*2000000))
 stage=t/'stage';stage.mkdir()
 r=subprocess.run(['busybox','ash',str(root/'src/static/static/home/yi-hack/script/restore_config.sh'),str(t/'bomb.bz2'),str(stage)],env={**os.environ,'YI_HACK_PREFIX':str(t)},capture_output=True)
 assert r.returncode!=0
 assert (stage/'config.tar').stat().st_size<=1024*1024
 print('PASS: 16 archive cases and decompression cap')
