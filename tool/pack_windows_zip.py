# Windows の Release フォルダを配布用の zip に固める。
#
#   python tool/pack_windows_zip.py releases/v1.0.0-338-20260908 338
#
# ★ なぜ道具にしてあるか
#   b336 と b337 の zip は `data/` の階層が潰れていて **起動しなかった**。
#   windows/runner/main.cpp が `flutter::DartProject project(L"data")` なので、
#   app.so / flutter_assets / icudtl.dat を exe と同じ所へ平らに置くと、
#   何も出ないまま終わる。 手で固めると同じ事がまた起きるので、
#   固めた後に「起動に要る物が正しい階層に在るか」 をここで必ず見る。
#
# ★ 見ている事
#   1. HisatorNotebook/HisatorNotebook.exe
#   2. HisatorNotebook/data/app.so
#   3. HisatorNotebook/data/icudtl.dat
#   4. HisatorNotebook/data/flutter_assets/AssetManifest.bin
#   5. kernel_blob.bin が混ざっていない事
#      (= `flutter build bundle` を型検査に使うと Release の flutter_assets に
#        残る事がある。 デバッグ成果物なので配ってはいけない)
#   どれか欠けたら zip を消して止まる。
import hashlib
import os
import sys
import zipfile

BUILD = os.path.join('build', 'windows', 'x64', 'runner', 'Release')
ROOT = 'HisatorNotebook'

NEEDED = [
    ROOT + '/HisatorNotebook.exe',
    ROOT + '/data/app.so',
    ROOT + '/data/icudtl.dat',
    ROOT + '/data/flutter_assets/AssetManifest.bin',
]


def main():
    if len(sys.argv) < 3:
        raise SystemExit(
            '使い方: python tool/pack_windows_zip.py <出し先フォルダ> <ビルド番号>')
    out_dir = sys.argv[1]
    build_no = sys.argv[2]
    out_zip = os.path.join(out_dir, 'HisatorNotebook-%s-windows.zip' % build_no)

    if not os.path.isdir(BUILD):
        raise SystemExit('%s がありません。 先に flutter build windows を。' % BUILD)
    os.makedirs(out_dir, exist_ok=True)

    files = []
    skipped = []
    for dirpath, _dirnames, filenames in os.walk(BUILD):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, BUILD).replace(os.sep, '/')
            # ★ msix:create は出来上がった .msix を同じフォルダへ置く。
            #   そのまま固めると zip に 75MB の包みが二重に入る
            #   (= 実測: 65.6MB のはずが 140.9MB になった)。
            if rel.lower().endswith(('.msix', '.appx', '.appxbundle', '.pfx')):
                skipped.append(rel)
                continue
            files.append((full, rel))
    files.sort(key=lambda x: x[1])
    for rel in skipped:
        print('のけました   : %s' % rel)

    bad = [r for _, r in files if r.endswith('kernel_blob.bin')]
    if bad:
        raise SystemExit(
            'デバッグ成果物が混ざっています: %s\n'
            '  → build/windows/.../Release/data/flutter_assets を消して\n'
            '    flutter build windows からやり直してください。' % bad)

    with zipfile.ZipFile(out_zip, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for full, rel in files:
            z.write(full, ROOT + '/' + rel)

    names = set(zipfile.ZipFile(out_zip).namelist())
    missing = [n for n in NEEDED if n not in names]
    if missing:
        os.remove(out_zip)
        raise SystemExit(
            '起動に要る物が入っていません: %s\n'
            '  → data/ の階層を潰していないか確かめてください '
            '(b336 / b337 がこれで起動しませんでした)。' % missing)

    h = hashlib.sha256()
    with open(out_zip, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    digest = h.hexdigest()

    sums = os.path.join(out_dir, 'SHA256SUMS.txt')
    line = '%s *%s\n' % (digest, os.path.basename(out_zip))
    old = []
    if os.path.exists(sums):
        with open(sums, encoding='utf-8') as f:
            old = [x for x in f if os.path.basename(out_zip) not in x]
    with open(sums, 'w', encoding='utf-8', newline='\n') as f:
        f.writelines(old)
        f.write(line)

    print('ファイル数 : %d' % len(files))
    print('zip        : %s' % out_zip)
    print('大きさ     : %.1f MB' % (os.path.getsize(out_zip) / 1024 / 1024))
    print('sha256     : %s' % digest)
    print('data/ の数 : %d' % len([n for n in names if '/data/' in n]))
    print('起動に要る 4 つ: すべて在り')


if __name__ == '__main__':
    main()
