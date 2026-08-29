# -*- coding: utf-8 -*-
# Stripe のブランド設定用に、 紋章を「枠に合わせて丸く」 切り抜く。
#
# = ユーザー要望: 決済画面で白い下地が見えるのが気になるので、 円で抜きたい。
#   -> 背景を白で埋めず、 透過のまま出す。 円の外は完全に透明。
#
# 気を付けた所:
#   ・元の透過部分は RGB が黒なので、 そのまま縮めると縁に黒いにじみが出る。
#     縁の色で一度埋めてから縮める。
#   ・縁を滑らかにするため、 円のマスクは 4 倍で描いてから縮める。
import math
import os
from PIL import Image, ImageDraw

SRC = r'c:\Users\Study\mindmap_app_out\docs\app_icon_master.png'
OUT_ICON = r'c:\Users\Study\mindmap_app_out\docs\stripe_brand_icon_512.png'
OUT_LOGO = r'c:\Users\Study\mindmap_app_out\docs\stripe_brand_logo_512.png'
LIMIT = 512 * 1024
SS = 4                      # マスクの重ね描き倍率

im = Image.open(SRC).convert('RGBA')
W, H = im.size
alpha = im.getchannel('A')

# ── 1. 円の位置と大きさを測る (中央の縦横の線で、 不透明な範囲を見る) ──
row = [alpha.getpixel((x, H // 2)) for x in range(W)]
col = [alpha.getpixel((W // 2, y)) for y in range(H)]
left = next(i for i, v in enumerate(row) if v > 8)
right = W - 1 - next(i for i, v in enumerate(reversed(row)) if v > 8)
top = next(i for i, v in enumerate(col) if v > 8)
bot = H - 1 - next(i for i, v in enumerate(reversed(col)) if v > 8)
box = (left, top, right + 1, bot + 1)
side = min(box[2] - box[0], box[3] - box[1])
# 正方形に揃える (中心はそのまま)
cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
box = (int(round(cx - side / 2)), int(round(cy - side / 2)),
       int(round(cx + side / 2)), int(round(cy + side / 2)))
print('circle box', box, 'side', side)

cut = im.crop(box)
n = cut.size[0]

# ── 2. 縁の色を拾う (半径 96% あたりを一周) ──
rs, gs, bs, cnt = 0, 0, 0, 0
r0 = n / 2
for deg in range(0, 360, 3):
    x = int(r0 + r0 * 0.96 * math.cos(math.radians(deg)))
    y = int(r0 + r0 * 0.96 * math.sin(math.radians(deg)))
    if 0 <= x < n and 0 <= y < n:
        px = cut.getpixel((x, y))
        if px[3] > 200:
            rs += px[0]; gs += px[1]; bs += px[2]; cnt += 1
edge = (rs // cnt, gs // cnt, bs // cnt) if cnt else (120, 90, 50)
print('edge color', edge, 'samples', cnt)

# ── 3. 透過部分を縁の色で埋めてから縮める (黒いにじみ止め) ──
filled = Image.new('RGB', cut.size, edge)
filled.paste(cut, (0, 0), cut)


def make(size):
    rgb = filled.resize((size, size), Image.LANCZOS)
    # 円のマスク (4 倍で描いてから縮めて滑らかに)
    m = Image.new('L', (size * SS, size * SS), 0)
    ImageDraw.Draw(m).ellipse((0, 0, size * SS - 1, size * SS - 1), fill=255)
    m = m.resize((size, size), Image.LANCZOS)
    # 元の透け具合も掛け合わせる (円の外は確実に 0 に)
    a = cut.getchannel('A').resize((size, size), Image.LANCZOS)
    m = Image.eval(Image.merge('L', [m]), lambda v: v)
    both = Image.new('L', (size, size))
    both.putdata([min(p, q) for p, q in zip(m.getdata(), a.getdata())])
    out = rgb.convert('RGBA')
    out.putalpha(both)
    return out


for size in (512, 448, 384, 320, 256):
    img = make(size)
    img.save(OUT_ICON, 'PNG', optimize=True)
    b = os.path.getsize(OUT_ICON)
    print('%dpx -> %.1f KB' % (size, b / 1024))
    if b < LIMIT:
        img.save(OUT_LOGO, 'PNG', optimize=True)
        chk = Image.open(OUT_ICON)
        print('OK size=%s mode=%s' % (chk.size, chk.mode))
        # 隅が透明・中心が不透明かを確かめる
        c = chk.convert('RGBA')
        print('corner alpha', c.getpixel((1, 1))[3],
              ' center alpha', c.getpixel((size // 2, size // 2))[3])
        break
else:
    print('!! 512KB に収まりませんでした')
