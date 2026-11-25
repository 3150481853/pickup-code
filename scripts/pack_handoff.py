import io, os, zipfile, pathlib, shutil, datetime

root = pathlib.Path(r'G:\取件码小程序')
hand = root / 'handoff'
src_android = root / 'android'
apk = root / 'dist' / 'PickupCode-0.15.1-android.apk'
wf = root / '.github' / 'workflows' / 'android.yml'
out = root / 'dist' / '茉莉取件-安卓客制化-0.15.1.zip'

top = '茉莉取件-安卓客制化-0.15.1'
skip_dirs = {'build', '.gradle', '.idea'}

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    z.write(hand / 'HANDOFF.md', f'{top}/HANDOFF.md')
    z.write(hand / 'VERSIONS.md', f'{top}/VERSIONS.md')
    z.write(apk, f'{top}/apk/{apk.name}')
    z.write(wf, f'{top}/src/workflow-android.yml')
    n = 0
    for dirpath, dirnames, filenames in os.walk(src_android):
        dirnames[:] = [d for d in dirnames if d not in skip_dirs]
        for fn in filenames:
            p = pathlib.Path(dirpath) / fn
            rel = p.relative_to(src_android)
            z.write(p, f'{top}/src/android/{rel.as_posix()}')
            n += 1
    print('source files', n)

print('zip', out.name, out.stat().st_size)
with zipfile.ZipFile(out) as z:
    for i in z.infolist()[:14]:
        print(f'  {i.filename}  {i.file_size}')
    print('  total entries', len(z.infolist()))
