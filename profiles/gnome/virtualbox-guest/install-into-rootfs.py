#!/usr/bin/env python3
"""Staging ONLY: safely embed tested VM VirtualBox userspace without build-time execution."""
from __future__ import annotations
import argparse, hashlib, json, os, pathlib, shutil, stat, sys, tarfile

VENDOR='VBoxGuestAdditions-7.0.16'
PREFIX=pathlib.PurePosixPath('opt')/VENDOR
SERVICE=pathlib.Path(__file__).with_name('spectre-vbox-display.service')
class Stop(Exception):pass

def check_member(m:tarfile.TarInfo,seen:set[str]):
    p=pathlib.PurePosixPath(m.name)
    if p.is_absolute() or any(x in ('..','.') for x in p.parts) or not p.parts:
        raise Stop('Unsafe archive pathname: '+m.name)
    if not (p==PREFIX or PREFIX in p.parents or p==pathlib.PurePosixPath('var/lib/VBoxGuestAdditions/config')):
        raise Stop('Unapproved archive content: '+m.name)
    if m.name in seen:raise Stop('Repeated archive member: '+m.name)
    seen.add(m.name)
    if m.islnk() or not(m.isfile() or m.isdir() or m.issym()):
        raise Stop('Special/hardlink file not permitted: '+m.name)
    if m.mode & 0o6000 and p != PREFIX/'bin/VBoxDRMClient':
        raise Stop('Unexpected setuid/setgid file: '+m.name)
    if m.issym():
        target=m.linkname
        if not target:raise Stop('Empty symlink in archive: '+m.name)
        if target.startswith('/'):
            if not target.startswith('/opt/VBoxGuestAdditions-7.0.16/'):
                raise Stop('Absolute symlink outside vendor prefix: '+m.name+' -> '+target)
        else:
            # Resolving relative vendor links must not reach stage filesystem outside vendor subtree
            stack=list(p.parts[:-1]);
            for part in pathlib.PurePosixPath(target).parts:
                if part=='..':
                    if len(stack)<=2:raise Stop('Symlink escapes vendor directory: '+m.name)
                    stack.pop()
                elif part!='.':stack.append(part)
    return p

def archive_check(archive:pathlib.Path,meta:pathlib.Path):
    if not archive.is_file() or archive.is_symlink() or not meta.is_file() or meta.is_symlink():raise Stop('Missing or symlinked proof files')
    data=json.loads(meta.read_text())
    if data.get('format')!='spectre-vboxga-proven-v1' or data.get('version')!='7.0.16' or data.get('guest_kernel')!='7.1.8-spectre' or data.get('guest_os')!='spectre':raise Stop('Unsupported runtime provenance')
    if data.get('payload')!=archive.name:raise Stop('Proof archive name mismatch')
    with archive.open('rb') as source:
        digest=hashlib.file_digest(source,'sha256').hexdigest()
    if digest!=data.get('sha256'):raise Stop('Payload SHA256 does not match VM export proof')
    members=[];seen=set();total_size=0
    with tarfile.open(archive,'r:gz') as tf:
        for m in tf:
            check_member(m,seen)
            total_size+=m.size
            if m.size>512*1024*1024 or total_size>1024*1024*1024 or len(seen)>150000:
                raise Stop('VM runtime archive exceeds guarded size/entry ceilings')
            members.append(m)
    need=[str(PREFIX/'bin/VBoxDRMClient'),str(PREFIX/'sbin/VBoxService'),str(PREFIX/'init/vboxadd-service'),'var/lib/VBoxGuestAdditions/config']
    if not all(n in seen for n in need):raise Stop('Essential Guest Additions files missing')
    return data,len(members)

def validate_stage(root:pathlib.Path):
    if root.is_symlink() or not root.is_dir() or root.resolve()==pathlib.Path('/'):raise Stop('Invalid stage root')
    if not (root/'etc/os-release').is_file() or not(root/'usr').is_dir() or not(root/'etc').is_dir():raise Stop('Not a Spectre OS staging filesystem')
    # Staging path should not be any live root or normal home tree target.
    if root.resolve().is_relative_to(pathlib.Path.home().resolve()):
        # Expected Spectre build STAGE is under user's home; OK only when clearly an ISO stage
        if not all(part not in ('Downloads','Documents','Pictures') for part in root.parts):raise Stop('Refusing ordinary personal directory')

def put_file_from_tar(root:pathlib.Path,tf:tarfile.TarFile,m:tarfile.TarInfo):
    rel=pathlib.Path(m.name)
    dest=root/rel
    # Never overwrite and do not follow an existing symlink ancestor
    cur=root
    for part in rel.parts[:-1]:
        cur=cur/part
        if cur.is_symlink():raise Stop('Parent is symlink: '+str(cur))
        if cur.exists() and not cur.is_dir():raise Stop('Parent not directory: '+str(cur))
        cur.mkdir(exist_ok=True)
    if dest.exists() or dest.is_symlink():raise Stop('Stage collision, refusing overwrite: '+str(dest))
    if m.isdir():
        dest.mkdir()
        os.chmod(dest,m.mode & 0o777)
    elif m.issym():os.symlink(m.linkname,dest)
    elif m.isfile():
        f=tf.extractfile(m)
        if f is None:raise Stop('Cannot read archive member: '+m.name)
        with dest.open('xb') as out:shutil.copyfileobj(f,out)
        os.chmod(dest,m.mode & 0o7777)

def stage(root:pathlib.Path,archive:pathlib.Path,meta:pathlib.Path):
    validate_stage(root)
    archive_check(archive,meta)
    if os.geteuid()!=0:raise Stop('Stage installation must be performed through sudo during ISO build')
    unit=root/'etc/systemd/system/spectre-vbox-display.service'
    link=root/'etc/systemd/system/multi-user.target.wants/spectre-vbox-display.service'
    for f in (unit,link):
        if f.exists() or f.is_symlink():raise Stop('Unexpected pre-existing service: '+str(f))
    for f in ['usr/bin/VBoxDRMClient','usr/sbin/VBoxService','usr/bin/VBoxClient']:
        if (root/f).exists() or (root/f).is_symlink():raise Stop('Existing VBox binary conflict in stage: '+f)
    # Detect vendor tree conflicts before extracting anything
    for folder in (root/PREFIX,root/'var/lib/VBoxGuestAdditions'):
        if folder.exists() or folder.is_symlink():raise Stop('Vendor payload already exists in stage: '+str(folder))
    with tarfile.open(archive,'r:gz') as tf:
        # Phase 1 already thoroughly validated all member paths and link targets
        for member in tf:put_file_from_tar(root,tf,member)
    # Verify extracted essential vendor paths
    for file in [root/PREFIX/'bin/VBoxDRMClient',root/PREFIX/'sbin/VBoxService',root/PREFIX/'init/vboxadd-service']:
        if not file.is_file():raise Stop('Missing essential runtime after stage: '+str(file))
    # Stage only required runtime links; never overwrite system libraries.
    for src,dst in [('/opt/'+VENDOR+'/bin/VBoxDRMClient','usr/bin/VBoxDRMClient'),
                    ('/opt/'+VENDOR+'/sbin/VBoxService','usr/sbin/VBoxService'),
                    ('/opt/'+VENDOR+'/bin/VBoxClient','usr/bin/VBoxClient')]:
        dest=root/dst;dest.parent.mkdir(parents=True,exist_ok=True)
        if dest.exists() or dest.is_symlink():raise Stop('Collision: '+str(dest))
        if (root/src.lstrip('/')).is_file():os.symlink(src,dest)
    # Only vendor-named shared libs; no arbitrary libGL/Mesa overrides.
    lib=root/PREFIX/'lib'
    for file in lib.glob('*') if lib.is_dir() else []:
        if not (file.is_file() or file.is_symlink()):continue
        if not (file.name.startswith(('VBox','libVBox','libvbox'))):continue
        dest=root/'usr/lib'/file.name
        if dest.exists() or dest.is_symlink():raise Stop('Vendor shared library collision: '+str(dest))
        os.symlink('/opt/'+VENDOR+'/lib/'+file.name,dest)
    unit.parent.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(SERVICE,unit)
    os.chmod(unit,0o644)
    link.parent.mkdir(parents=True,exist_ok=True)
    os.symlink('../spectre-vbox-display.service',link)
    assert unit.read_bytes()==SERVICE.read_bytes()
    print('[PASS] VirtualBox 7.0.16 userspace staged and service enabled (no installer or kernel compilation executed)')

def main():
    p=argparse.ArgumentParser();p.add_argument('action',choices=['check','stage']);p.add_argument('--root',type=pathlib.Path);p.add_argument('--archive',required=True,type=pathlib.Path);p.add_argument('--proof',required=True,type=pathlib.Path)
    a=p.parse_args()
    proof,num=archive_check(a.archive,a.proof)
    print('[PASS] Proven vendor archive verified:',num,'entries, SHA256='+proof['sha256'])
    if a.action=='stage':
        if a.root is None:raise Stop('Stage root required')
        stage(a.root,a.archive,a.proof)
if __name__=='__main__':
    try:main()
    except (Stop,OSError,tarfile.TarError,ValueError) as exc:
        print('[STOP]',exc,file=sys.stderr);sys.exit(1)
