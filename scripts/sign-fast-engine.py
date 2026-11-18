import pathlib, subprocess, sys
root=pathlib.Path(sys.argv[1]); identity=sys.argv[2]
# Sign individual Mach-O dependencies before their launcher; never follow symlinks twice.
files=[p for p in root.rglob('*') if p.is_file() and not p.is_symlink()]
for p in sorted(files,key=lambda p:(p.name=='yt-dlp_macos',str(p))):
    with p.open('rb') as f: magic=f.read(4)
    if magic not in [bytes.fromhex(x) for x in ['cffaedfe','cefaedfe','feedfacf','feedface','cafebabe','bebafeca']]: continue
    args=['codesign','--force','--sign',identity]
    if identity!='-': args+=['--timestamp','--options','runtime']
    if p.name=='yt-dlp_macos': args+=['--entitlements','app/signing/ytdlp.entitlements.plist']
    subprocess.run(args+[str(p)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
