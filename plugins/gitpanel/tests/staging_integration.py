#!/usr/bin/env python3
"""Production Model:comparison/stage_selection + real Git; disposable repositories only."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import io
import runpy
import sys
import time
import shlex

HERE = Path(__file__).resolve().parent
checks = 0

def check(ok, label):
    global checks
    assert ok, label
    checks += 1
    print("PASS", label)

with tempfile.TemporaryDirectory(prefix="lite-xl-staging-") as tmp:
    root = Path(tmp).resolve() / "repo"
    root.mkdir()
    env = {k:v for k,v in os.environ.items() if not k.startswith("GIT_")}
    env.update(HOME=tmp, XDG_CONFIG_HOME=tmp, GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
               GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="test@invalid", GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="test@invalid")
    def git(*args, data=None):
        p = subprocess.run(["git", "--literal-pathspecs", "-C", str(root), *args], input=data, env=env, capture_output=True, timeout=20)
        assert p.returncode == 0, p.stderr
        return p.stdout
    git("init", "-b", "main")
    path = ":(literal) [é]\nfile.txt"
    file = root / path
    head = b"a\nb\nc\nd\ne\n"
    file.write_bytes(head)
    (root / "other").write_bytes(b"other\n")
    git("add", "."); git("commit", "-m", "initial")
    (root / "other").write_bytes(b"unrelated staged\n"); git("add", "other")
    other = git("ls-files", "--stage", "--", "other")
    ref = git("rev-parse", "HEAD")

    def setup(index=head, working=b"A\nb\nc\nD\ne\n"):
        if file.is_symlink(): file.unlink()
        file.write_bytes(index); file.chmod(0o644); git("add", "--", path)
        file.write_bytes(working)
        return (root / ".git/index").read_bytes()

    def stage(group="changes", block=1, x="M", y="M", scenario="", hook=None, rows=None):
        calls=[]
        with subprocess.Popen([shutil.which("luajit"), str(HERE / "staging_bridge.lua"), str(root), path, group, x, y, str(block) if block else "", scenario, *(map(str, rows) if rows else [])],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env) as p:
            def read():
                line=p.stdout.readline(); assert line, p.stderr.read().decode()
                return p.stdout.read(int(line))
            def write(value): p.stdin.write(str(len(value)).encode()+b"\n"+value)
            while True:
                action=p.stdout.readline(); assert action, p.stderr.read().decode()
                if action == b"RESULT\n":
                    stale=int(p.stdout.readline()); error=read().decode(); reason=read().decode()
                    p.stdin.close(); assert p.wait(timeout=10)==0, p.stderr.read().decode()
                    assert not (root / ".git/index.lock").exists() or scenario == "locked", "owned lock leaked"
                    assert not list((root / ".git").glob("gitpanel-index-*")), "alternate index leaked"
                    return dict(stale=stale, error=error, reason=reason, calls=calls)
                assert action==b"REQUEST\n", action
                args=[os.fsdecode(read()) for _ in range(int(p.stdout.readline()))]
                cwd,data=os.fsdecode(read()),read()
                assert cwd==str(root)
                assert args[0]=="git" or (args[:2]==["python3","-I"] and args[2] in [str(HERE.parent / n) for n in ("discard.py","staging.py","remove.py")])
                calls.append(args)
                if hook: hook(args)
                if scenario=="missing-python" and args[0]=="python3":
                    code,out,err=127,b"",b"python3 unavailable"
                else:
                    proc=subprocess.run(args,cwd=cwd,input=data,capture_output=True,env=env,timeout=65)
                    code,out,err=proc.returncode,proc.stdout,proc.stderr
                p.stdin.write(str(code).encode()+b"\n"); write(out);write(err);p.stdin.flush()

    setup(); before=file.read_bytes()
    r=stage()
    check(not r["error"] and git("show",":"+path)==b"A\nb\nc\nd\ne\n", "stage block changes only selected index hunk: literal newline/UTF8 path")
    check(file.read_bytes()==before and git("ls-files","--stage","--","other")==other and git("rev-parse","HEAD")==ref, "worktree/ref and unrelated staged entry preserved")
    setup(b"A\nb\nc\nD\ne\n", b"working remains\n"); before=file.read_bytes()
    r=stage("staged")
    check(not r["error"] and git("show",":"+path)==b"a\nb\nc\nD\ne\n" and file.read_bytes()==before, "unstage block restores HEAD block only; saved worktree untouched")
    for old,new in [(b"a\n",b"a\nnew\n"),(b"a\nb\n",b"a\n"),(b"",b"new"),(b"a\n",b""),("é\r\nold".encode(),"é\r\nβ".encode())]:
        setup(old,new); r=stage()
        check(not r["error"] and git("show",":"+path)==new and file.read_bytes()==new, "stage block exact add/delete/empty/CRLF/EOF bytes")
    setup(); file.unlink(); r=stage(y="D")
    check(not r["error"] and not git("ls-files","--stage","--",path) and not file.exists(), "full deletion removes index entry, never recreates worktree")
    setup(); git("rm","--cached","--",path); before=file.read_bytes(); r=stage("staged",x="D",y=" ")
    check(not r["error"] and git("show",":"+path)==head and file.read_bytes()==before, "unstage staged deletion restores HEAD entry only")
    # New/unborn entries are tested without inventing a committed source.
    original_path, original_file=path,file
    path="new.txt"; file=root/path; file.write_bytes(b"new\n")
    r=stage("untracked",x="?",y="?")
    check(not r["error"] and git("show",":"+path)==b"new\n", "stage untracked addition")
    r=stage("staged",x="A",y=" ")
    check(not r["error"] and not git("ls-files","--stage","--",path) and file.read_bytes()==b"new\n", "unstage entire new-file block removes entry not worktree")
    path,file=original_path,original_file
    for scenario in ("cancel","disabled","missing-python","root-loaded","root-preflight","project-preflight","generation-preflight"):
        before=setup(); working=file.read_bytes(); r=stage(scenario=scenario)
        check((root/".git/index").read_bytes()==before and file.read_bytes()==working and not any(a[0]=="python3" and a[3]=="replace" for a in r["calls"]), scenario+" refuses/no mutation")
    setup(); r=stage(scenario="repeat")
    check(r["stale"] and "Stale" in r["error"], "successful action invalidates old snapshots; repeat refused")
    for what in ("disk","index","HEAD"):
        setup(); changed=[False]
        def hook(args):
            if args[0]=="python3" and args[2].endswith("/staging.py") and args[3]=="replace" and not changed[0]:
                changed[0]=True
                if what=="disk": file.write_bytes(b"external\n")
                elif what=="index":
                    saved=file.read_bytes(); file.write_bytes(b"external staged\n");git("add","--",path);file.write_bytes(saved)
                else: git("update-ref","HEAD",git("commit-tree",git("write-tree").strip().decode(),"-p",ref.strip().decode(),data=b"fixture\n").strip().decode())
        r=stage(hook=hook)
        check(r["error"] and r["stale"], "helper refuses stale "+what+" after model preflight")
        if what=="HEAD": git("update-ref","HEAD",ref.strip().decode())
    for refusal in ("filter","autocrlf","mode","hardlink","symlink","lock"):
        before=setup()
        if refusal=="filter": (root/".gitattributes").write_text("* filter=custom\n")
        if refusal=="autocrlf": git("config","core.autocrlf","true")
        if refusal=="mode": file.chmod(0o755)
        if refusal=="hardlink": os.link(file,root/"hardlink")
        if refusal=="symlink": file.unlink();file.symlink_to("other")
        if refusal=="lock": (root/".git/index.lock").write_bytes(b"external lock")
        r=stage(scenario="locked" if refusal=="lock" else "")
        check(r["error"] and (root/".git/index").read_bytes()==before, refusal+" fails closed, index unchanged")
        if refusal=="filter": (root/".gitattributes").unlink()
        if refusal=="autocrlf": git("config","core.autocrlf","false")
        if refusal=="hardlink": (root/"hardlink").unlink()
        if refusal=="lock":
            check((root/".git/index.lock").read_bytes()==b"external lock", "external Git lock is never removed")
            (root/".git/index.lock").unlink()
    for side in ("left","right"):
        setup(head,b"A\nx\ny\nb\nC\ne\n"); before=file.read_bytes()
        r=stage(scenario="selection-"+side,rows=(1,1,1,1))
        check(not r["error"] and git("show",":"+path)==b"A\nb\nc\nd\ne\n" and file.read_bytes()==before, "selected replacement row from "+side+" changes both sides, no duplicate old line")
    for side in ("left","right"):
        setup(b"A\nx\ny\nb\nC\ne\n",b"independent worktree\n");before=file.read_bytes()
        r=stage("staged",scenario="selection-"+side,rows=(1,1,1,1))
        check(not r["error"] and git("show",":"+path)==b"a\nx\ny\nb\nC\ne\n" and file.read_bytes()==before, "unstage paired replacement from "+side+" preserves tails and worktree")
    for side,selection,expected in [
        ("right",(2,1,2,1),b"a\nx\nb\nc\nd\ne\n"),
        ("left",(4,1,4,1),b"a\nb\nc\ne\n"),
        ("left",(3,2,1,1),b"A\nx\ny\nb\nC\nd\ne\n"),
        ("right",(6,1,5,1),b"a\nb\nC\nd\ne\n"),
        ("right",(6,2,5,1),b"a\nb\nC\ne\n")]:
        setup(head,b"A\nx\ny\nb\nC\ne\n"); before=file.read_bytes()
        r=stage(scenario="selection-"+side,rows=selection)
        check(not r["error"] and git("show",":"+path)==expected and file.read_bytes()==before,"selected unequal tails/gaps/cross-hunk/half-open range "+side+str(selection))
    setup(head,b"A\nx\ny\nb\nC\ne\n")
    staged_bytes=file.read_bytes();git("add","--",path);file.write_bytes(b"separate working edit\n")
    r=stage("staged",scenario="selection-right",rows=(2,1,2,1))
    check(not r["error"] and git("show",":"+path)==b"A\ny\nb\nC\ne\n" and file.read_bytes()==b"separate working edit\n", "unstage selected tail preserves staged neighbors and independent worktree")
    setup("é\r\nold\r\ntail".encode(),"β\r\nNEW\r\ntail".encode())
    r=stage(scenario="selection-left",rows=(2,1,2,1))
    check(not r["error"] and git("show",":"+path)=="é\r\nNEW\r\ntail".encode(), "production selected line exact CRLF/UTF8/no-final-newline")
    before=setup(b"old",b"new\nextra\n");r=stage(scenario="selection-right",rows=(2,1,2,1))
    check(r["error"] and (root/".git/index").read_bytes()==before, "unsafe EOF fragment composition fails before index mutation")
    before=setup();r=stage(scenario="selection-left",rows=(2,1,2,1))
    check(r["error"] and (root/".git/index").read_bytes()==before, "unchanged source selection has no mutation fallback")
    # Partial deleted file must stay indexed until all its rows are selected.
    setup();file.unlink();r=stage(y="D",scenario="selection-left",rows=(2,1,2,1))
    check(not r["error"] and git("show",":"+path)==b"a\nc\nd\ne\n" and not file.exists(), "partial deletion retains index file, not whole-file fallback")
    setup()
    hook_file=root/".git/hooks/post-index-change"
    hook_file.write_text("#!/bin/sh\nprintf 'unexpected hook' > hook-ran\n")
    hook_file.chmod(0o755)
    r=stage()
    check(not r["error"] and not (root/"hook-ran").exists(), "granular index update never runs post-index-change hook")
    hook_file.unlink()
    for option in ("--split-index", "--assume-unchanged", "--skip-worktree"):
        setup()
        git("update-index",option,*( ["--",path] if option != "--split-index" else []))
        before=(root/".git/index").read_bytes();r=stage()
        check(r["error"] and (root/".git/index").read_bytes()==before, option+" unsupported index fails closed")
        git("update-index",option.replace("--","--no-",1),*( ["--",path] if option != "--split-index" else []))
    setup();git("config","core.sparseCheckout","true");before=(root/".git/index").read_bytes();r=stage()
    check(r["error"] and (root/".git/index").read_bytes()==before, "sparse configuration fails closed")
    git("config","core.sparseCheckout","false")
    git("config","index.sparse","true");before=(root/".git/index").read_bytes();r=stage()
    check(r["error"] and (root/".git/index").read_bytes()==before, "sparse index configuration fails closed")
    git("config","index.sparse","false")
    setup();git("mv","--",path,"renamed.txt")
    saved_path,saved_file=path,file;path,file="renamed.txt",root/"renamed.txt"
    before=(root/".git/index").read_bytes();r=stage("staged",x="A",y="M")
    check(r["error"] and (root/".git/index").read_bytes()==before, "real Git rename refuses partial stage/unstage")
    git("mv","--",path,saved_path);path,file=saved_path,saved_file
    before=setup()
    for unsafe in ("../other", ".git/config", "/absolute", "dir/../file"):
        p=subprocess.run(["python3","-I",str(HERE.parent/"staging.py"),"snapshot",str(root),unsafe,"changes"],env=env,capture_output=True)
        check(p.returncode!=0 and b"Unsafe path" in p.stderr and (root/".git/index").read_bytes()==before, "unsafe literal path refused: "+unsafe)
    p=subprocess.run(["python3","-I","-O",str(HERE.parent/"staging.py"),"snapshot",str(root),path,"changes"],env=env,capture_output=True)
    check(p.returncode!=0 and b"Optimized" in p.stderr, "optimized interpreter cannot strip helper validation")
    check(git("ls-files","--stage","--","other")==other and git("rev-parse","HEAD")==ref, "all fixtures preserve unrelated staged entry and HEAD")
    # Review regressions run directly against the isolated helper, not comparison
    # commands (which have their own read-only Git behavior).
    root=Path(tmp).resolve()/"review-regressions";root.mkdir();git("init","-b","main")
    protocol=runpy.run_path(str(HERE.parent/"discard.py"))
    def helper(action, name, group, data=None, late_replace=None):
        args=[sys.executable,"-I",str(HERE.parent/"staging.py"),action,str(root),name,group]
        if late_replace:
            # Inject a real replacement-ref edit after alternate-index preparation,
            # immediately before the helper's final snapshot/install guard.
            script = '''import os, runpy, subprocess, sys
helper, root, name, group, old, new = sys.argv[1:]
original_fsync = os.fsync
def fsync(fd):
    original_fsync(fd)
    subprocess.run(["git", "-C", root, "replace", old, new], check=True, capture_output=True)
os.fsync = fsync
sys.argv = [helper, "replace", root, name, group]
runpy.run_path(helper, run_name="__main__")
'''
            args=[sys.executable,"-I","-c",script,str(HERE.parent/"staging.py"),str(root),name,group,*late_replace]
        return subprocess.run(args,input=data,capture_output=True,env=env,timeout=65)

    for permissions in (0o654,0o644,0o755):
        name="mode-"+oct(permissions);target=root/name
        target.write_bytes(b"new\n");target.chmod(permissions)
        captured=helper("snapshot",name,"untracked")
        assert captured.returncode==0, captured.stderr
        old,new,token=protocol["read_fields"](io.BytesIO(captured.stdout),3)
        result=helper("replace",name,"untracked",protocol["pack"]([token,new]))
        actual=git("ls-files","--stage","--",name)
        git("rm","--cached","-f","--",name);git("add","--",name)
        check(result.returncode==0 and actual==git("ls-files","--stage","--",name) and target.read_bytes()==new,
              "untracked mode %s matches ordinary Git owner-execute rule" % oct(permissions))

    # Keep both rename endpoints refused without worktree status/conversions.
    (root/"rename-old").write_bytes(b"rename contents\n")
    git("add","--","rename-old");git("commit","-m","rename fixture")
    git("mv","rename-old","rename-new")
    (root/"rename-new").write_bytes(b"edited rename contents\n")
    before=(root/".git/index").read_bytes()
    for endpoint,group in (("rename-old","staged"),("rename-new","changes")):
        refused=helper("snapshot",endpoint,group)
        check(refused.returncode!=0 and b"Rename/copy/conflict unsupported" in refused.stderr
              and (root/".git/index").read_bytes()==before,
              "index-only rename detection refuses %s endpoint in %s" % (endpoint,group))
    git("mv","rename-new","rename-old")
    (root/".gitignore").write_text("ignored.txt\n")
    (root/"ignored.txt").write_bytes(b"ignored\n")
    refused=helper("snapshot","ignored.txt","untracked")
    check(refused.returncode!=0 and b"ignored" in refused.stderr, "non-converting untracked check preserves ignored-source refusal")

    name="source.txt";target=root/name;target.write_bytes(b"committed\n")
    git("add","--",name);git("commit","-m","replacement source fixture")
    target.write_bytes(b"indexed\n");git("add","--",name)
    for source in ("original","modified"):
        for timing in ("before-replace","before-install"):
            captured=helper("snapshot",name,"staged")
            assert captured.returncode==0, captured.stderr
            old,new,token=protocol["read_fields"](io.BytesIO(captured.stdout),3)
            oid=git("rev-parse",("HEAD:" if source=="original" else ":")+name).strip().decode()
            replacement_oid=git("hash-object","-w","--stdin",data=b"changed replacement\n").strip().decode()
            before=(root/".git/index").read_bytes();working=target.read_bytes()
            if timing=="before-replace": git("replace",oid,replacement_oid)
            result=helper("replace",name,"staged",protocol["pack"]([token,old]),
                          (oid,replacement_oid) if timing=="before-install" else None)
            git("replace","-d",oid)
            check(result.returncode!=0 and (b"Stale source" in result.stderr or b"changed during staging" in result.stderr)
                  and (root/".git/index").read_bytes()==before and target.read_bytes()==working
                  and not (root/".git/index.lock").exists() and not list((root/".git").glob("gitpanel-index-*")),
                  "changed %s blob replacement %s refuses stale token and preserves index" % (source,timing))

    # A same-size dirty unrelated file forces status to hash through its clean
    # filter. Neither snapshot nor either write guard may run that conversion.
    git("config","core.trustctime","false");git("config","core.checkstat","minimal")
    git("update-index","--assume-unchanged","--","mode-0o755")
    git("update-index","--skip-worktree","--","mode-0o644")
    unrelated=root/"filtered.txt";unrelated.write_bytes(b"before\n")
    # Force a racy index entry with identical cached/disk stat data even on
    # nanosecond filesystems. update-index may otherwise hash it only sporadically.
    racy_time=time.time_ns()+60_000_000_000
    os.utime(unrelated,ns=(racy_time,racy_time))
    git("add","--",unrelated.name)
    (root/".gitattributes").write_text("filtered.txt filter=marker\n")
    git("add","--",".gitattributes");git("commit","-m","filter fixture")
    git("config","filter.marker.clean","printf marker > filter-ran; cat")
    unrelated.write_bytes(b"AFTER!\n");os.utime(unrelated,ns=(racy_time,racy_time))
    unrelated_entry=git("ls-files","--stage","--",unrelated.name,"mode-0o755","mode-0o644")
    unrelated_flags=git("ls-files","-v","--",unrelated.name,"mode-0o755","mode-0o644")
    target.write_bytes(b"working\n")
    fixture_head=git("rev-parse","HEAD")
    for hook_name, marker in (("post-index-change","hook-ran"),("fixture-fsmonitor","fsmonitor-ran")):
        hook_path=root/".git/hooks"/hook_name
        hook_path.write_text("#!/bin/sh\nprintf marker > "+shlex.quote(str(root/marker))+"\n")
        hook_path.chmod(0o755)
    git("config","core.fsmonitor",str(root/".git/hooks/fixture-fsmonitor"))
    before=(root/".git/index").read_bytes()
    captured=helper("snapshot",name,"changes")
    check(captured.returncode==0 and not (root/"filter-ran").exists()
          and (root/".git/index").read_bytes()==before and unrelated.read_bytes()==b"AFTER!\n",
          "snapshot never runs unrelated dirty-file clean filter")
    old,new,token=protocol["read_fields"](io.BytesIO(captured.stdout),3)
    result=helper("replace",name,"changes",protocol["pack"]([token,new]))
    assert result.returncode==0, result.stderr
    assert not (root/"filter-ran").exists(), "private index writer executed filter"
    integrations_quiet=not (root/"hook-ran").exists() and not (root/"fsmonitor-ran").exists()
    git("config","--unset","core.fsmonitor")
    assert git("ls-files","--stage","--",unrelated.name,"mode-0o755","mode-0o644")==unrelated_entry, "unrelated entries changed"
    assert git("ls-files","-v","--",unrelated.name,"mode-0o755","mode-0o644")==unrelated_flags, "unrelated flags changed"
    check(result.returncode==0 and not (root/"filter-ran").exists() and unrelated.read_bytes()==b"AFTER!\n"
          and target.read_bytes()==new and git("show",":"+name)==new
          and git("ls-files","--stage","--",unrelated.name,"mode-0o755","mode-0o644")==unrelated_entry
          and git("ls-files","-v","--",unrelated.name,"mode-0o755","mode-0o644")==unrelated_flags
          and not (root/".git/index.lock").exists() and not list((root/".git").glob("gitpanel-index-*")),
          "both write guards avoid unrelated clean filters; only selected index bytes change")
    check(integrations_quiet and git("rev-parse","HEAD")==fixture_head,
          "isolated index writer and real-source guards disable hooks/fsmonitor and preserve HEAD")
    (root/".gitattributes").write_text("* filter=marker\n")
    target.write_bytes(b"FILTER!\n");before=(root/".git/index").read_bytes()
    refused=helper("snapshot",name,"changes")
    check(refused.returncode!=0 and b"attributes/filters unsupported" in refused.stderr
          and not (root/"filter-ran").exists() and (root/".git/index").read_bytes()==before,
          "selected-path filter refuses before any conversion-capable command")

    # Separate unborn repository; partial add and unstage must preserve entry existence.
    root=Path(tmp).resolve()/"unborn";root.mkdir();git("init","-b","main")
    path="new.txt";file=root/path;file.write_bytes(b"first\nsecond\n")
    r=stage("untracked",x="?",y="?",scenario="selection-right",rows=(2,1,2,1))
    check(not r["error"] and git("show",":"+path)==b"second\n" and file.read_bytes()==b"first\nsecond\n", "unborn partial addition creates only selected index lines")
    file.write_bytes(b"first\nsecond\n");git("add","--",path)
    r=stage("staged",x="A",y=" ",scenario="selection-right",rows=(1,1,1,1))
    check(not r["error"] and git("show",":"+path)==b"second\n" and file.read_bytes()==b"first\nsecond\n", "unborn partial unstage retains remaining index entry")
    r=stage("staged",x="A",y="M")
    check(not r["error"] and not git("ls-files","--stage","--",path), "unborn final block unstage removes entry without creating HEAD")
print(str(checks)+" production-staging real-Git checks passed; temporary repositories removed.")
