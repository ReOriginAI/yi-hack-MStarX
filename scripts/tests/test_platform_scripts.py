#!/usr/bin/env python3
"""Test Y23 archive/layout gates and Wi-Fi parsing using ordinary files."""
import io, os, pathlib, subprocess, tarfile, tempfile, hashlib, json
ROOT=pathlib.Path(__file__).resolve().parents[2];SCRIPTS=ROOT/'src/static/static/home/yi-hack/script'
with tempfile.TemporaryDirectory() as tmp:
 t=pathlib.Path(tmp);prefix=t/'hack';sd=t/'sd';sd.mkdir()
 for d in ('bin','etc','script'):(prefix/d).mkdir(parents=True)
 env={**os.environ,'YI_HACK_PREFIX':str(prefix),'MOCK_SD':'yes'}
 for name in ('runtime.sh','configure_wifi.sh','firmware_check.sh'):
  s=(SCRIPTS/name).read_text().replace('/tmp/sd',str(sd)).replace('/tmp/yi-wifi-config.lock.d',str(t/'wifi-lock')).replace('/dev/mtd/mtd5',str(t/'mtd')).replace('/proc/mtd',str(t/'layout'))
  if name=='runtime.sh':
   a=s.index('sd_available()');b=s.index('# The camera',a);s=s[:a]+'sd_available() { [ "$MOCK_SD" = yes ]; }\n'+s[b:]
  p=prefix/'script'/name;p.write_text(s);p.chmod(0o755)
 (prefix/'bin/hexdump').write_text('#!/bin/sh\nexec busybox hexdump "$@"\n');(prefix/'bin/hexdump').chmod(0o755)
 (prefix/'bin/flash_eraseall').write_text('#!/bin/sh\nprintf invoked >> "$YI_HACK_PREFIX/erase-count"\n');(prefix/'bin/flash_eraseall').chmod(0o755)
 (t/'layout').write_text('mtd5: 00010000 00010000 "conf"\n')
 (prefix/'model_suffix').write_text('y23\n')
 subprocess.run(['gcc','-std=gnu99','-Wall','-Wextra','-Werror',ROOT/'src/storage_tools/archive_check.c','-o',prefix/'bin/archive_check'],check=True)
 for body,valid in [(b'\xef\xbb\xbfwifi_ssid=Quoted SSID\r\nwifi_psk=pass"word\\value\r\n',True),(b'wifi_ssid=x\rwifi_psk=12345678\r',True),(b'wifi_ssid=a\nwifi_ssid=b\nwifi_psk=12345678\n',False),(b'\xff\xfea\x00',False),(b'wifi_ssid=a\x00b\nwifi_psk=12345678',False),(b'wifi_ssid=a\nwifi_psk=short\n',False),(b'wifi_ssid='+b'a'*33+b'\nwifi_psk=12345678\n',False)]:
  (t/'mtd').write_bytes(b'\xff'*65536);cfg=t/'wifi.cfg';cfg.write_bytes(body)
  p=subprocess.run(['bash',prefix/'script/configure_wifi.sh'],env={**env,'CFG_FILE':str(cfg)},capture_output=True)
  assert (p.returncode==0)==valid,(body,p.stderr)
  if valid:assert (t/'mtd').stat().st_size==65536 and (t/'mtd').read_bytes()[24:28]==b'\0'*4
  else:assert (t/'mtd').read_bytes()==b'\xff'*65536
  assert not (t/'wifi-lock').exists() and not (sd/'.yi-wifi-config').exists()
 # Exercise the real Wi-Fi CGI too; erase targets remain the fixture file.
 wifi_cgi=t/'wifi.sh';wifi_cgi.write_text((ROOT/'src/www/httpd/cgi-bin/wifi.sh').read_text())
 for name in ('config_work.sh','upload.sh'):
  p=prefix/'script'/name;p.write_text((SCRIPTS/name).read_text().replace('/tmp/sd',str(sd)).replace('/tmp/yi-config-work.lock.d',str(t/'config-lock')));p.chmod(0o755)
 data=json.dumps({'WIFI_ESSID':'Quoted "network', 'WIFI_PASSWORD':"slash\\'pass", 'WIFI_PASSWORD2':"slash\\'pass"}).encode()
 result=subprocess.run(['bash',wifi_cgi],input=data,env={**env,'QUERY_STRING':'action=save','REQUEST_METHOD':'POST','CONTENT_LENGTH':str(len(data))},capture_output=True)
 assert result.returncode==0,(result.stdout,result.stderr)
 assert b'Quoted "network' in (t/'mtd').read_bytes()
 def firmware(label,sysbytes,homebytes,valid):
  arc=t/(label+'.tgz')
  with tarfile.open(arc,'w:gz',format=tarfile.USTAR_FORMAT) as f:
   for name,data in [('sys_y23',sysbytes),('home_y23',homebytes)]:
    i=tarfile.TarInfo(name);i.size=len(data);f.addfile(i,io.BytesIO(data))
  work=t/label;work.mkdir()
  r=subprocess.run(['bash',prefix/'script/firmware_check.sh',arc,work],env=env,capture_output=True)
  assert (r.returncode==0)==valid,(label,r.stderr)
 image=b'\x85\x19'+b'\0'*(65536-2)
 firmware('valid',image,image,True)
 firmware('badmagic',b'\0'*65536,image,False)
 firmware('oversized_sys',b'\x85\x19'+b'\0'*1966080,image,False)
 firmware('truncated_image',image[:100],image,False)
 # The upgrade prepare route validates an actual bundle without boot triggers.
 (prefix/'version').write_text('0.5.7\n')
 for name in ('system.conf','camera.conf'):(prefix/'etc'/name).write_text('SETTING=yes\n')
 local=sd/'y23_x.x.x.tgz';local.write_bytes((t/'valid.tgz').read_bytes())
 sidecar=sd/'y23_x.x.x.tgz.sha256';sidecar.write_text(hashlib.sha256(local.read_bytes()).hexdigest()+'  y23_x.x.x.tgz\n')
 script=t/'upgrade.sh';script.write_text((ROOT/'src/www/httpd/cgi-bin/fw_upgrade.sh').read_text().replace('/tmp/sd',str(sd)).replace('/tmp/yi-upgrade.lock.d',str(t/'upgrade-lock')).replace('/tmp/yi-config-work.lock.d',str(t/'config-lock')))
 prepared=subprocess.run(['bash',script],env={**env,'QUERY_STRING':'get=prepare'},capture_output=True)
 assert prepared.returncode==0,prepared.stdout
 assert (sd/'.yi-upgrade-work/images/sys_y23').exists()
 assert not (sd/'sys_y23').exists() and not (sd/'home_y23').exists() and not (sd/'.fw_upgrade').exists()
 sidecar.write_text('0'*64+'  y23_x.x.x.tgz\n')
 assert subprocess.run(['bash',script],env={**env,'QUERY_STRING':'get=prepare'},capture_output=True).returncode!=0
 assert not (t/'upgrade-lock').exists() and not (t/'config-lock').exists()
 # Native MQTT uses the same lock and requires mounted SD before writing.
 mounts=t/'mounts';mounts.write_text('/dev/mmc '+str(sd)+' vfat rw,relatime 0 0\n')
 source=(ROOT/'src/mqtt-config/mqtt-config/config.c').read_text().replace('/proc/mounts',str(mounts)).replace('/tmp/sd',str(sd)).replace('/tmp/yi-config-work.lock.d',str(t/'config-lock'))
 c=t/'config.c';c.write_text(source)
 harness=t/'harness.c';harness.write_text('#include "config.h"\nint main(int n,char **v){ if(n!=4)return 2;config_replace(v[1],v[2],v[3]);return 0;}\n')
 exe=t/'mqtt-test';subprocess.run(['gcc','-Wall','-Wextra','-Werror','-I',ROOT/'src/mqtt-config/mqtt-config',c,harness,'-o',exe],check=True)
 config=prefix/'etc/test.conf';config.write_text('PASSWORD=before\n')
 subprocess.run([exe,config,'PASSWORD','quote\'slash\\'],check=True);assert config.read_text()=="PASSWORD=quote'slash\\\n"
 lock=t/'config-lock';lock.mkdir();before=config.read_bytes()
 subprocess.run([exe,config,'PASSWORD','blocked'],check=True);assert config.read_bytes()==before;lock.rmdir()
 lock.mkdir();(lock/'pid').write_text('999999999\n');subprocess.run([exe,config,'PASSWORD','recovered'],check=True);assert config.read_text()=='PASSWORD=recovered\n';before=config.read_bytes()
 mounts.write_text('');subprocess.run([exe,config,'PASSWORD','missing_sd'],check=True);assert config.read_bytes()==before
print('PASS: Wi-Fi encoding/layout gates, firmware magic/size gates, bounded native MQTT writes/shared lock/missing SD')
