from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import math

ROOT = Path(__file__).resolve().parents[1]
CHAR = ROOT / "assets/images/characters"
ICONS = ROOT / "assets/images/icons"
REVIEW = ROOT / "assets/review/m5_assets"
S = 3

ORANGE = (240, 138, 42, 255) # #F08A2A
ORANGE_D = (224, 128, 32, 255) # #E08020
CREAM = (240, 240, 208, 255) # #F0F0D0
BLUE = (43, 179, 240, 255)
BLUE_D = (18, 104, 205, 255)
WHITE = (255, 255, 255, 255)

def sc(v): return int(round(v*S))
def box(b): return tuple(sc(x) for x in b)

def ellipse(d, b, fill): d.ellipse(box(b), fill=fill)
def rounded(d, b, r, fill): d.rounded_rectangle(box(b), radius=sc(r), fill=fill)

def draw_gun(d, x, y, recoil=0):
    x -= recoil
    rounded(d, (x-5, y-13, x+65, y+15), 12, CREAM)
    ellipse(d, (x-18, y-18, x+17, y+18), BLUE)
    ellipse(d, (x-13, y-13, x+12, y+12), (126, 225, 255, 255))
    rounded(d, (x+4, y-15, x+18, y+17), 7, ORANGE)
    ellipse(d, (x+35, y-8, x+51, y+8), BLUE)
    rounded(d, (x+18, y+10, x+43, y+33), 9, ORANGE_D)

def draw_sword(d, x, y, angle=0):
    # local blade points toward upper-right; rotate around grip
    pts = [(x, y), (x+10, y-7), (x+67, y-20), (x+79, y-8), (x+67, y+7), (x+10, y+8)]
    def rot(p):
        a=math.radians(angle); dx=p[0]-x; dy=p[1]-y
        return (sc(x+dx*math.cos(a)-dy*math.sin(a)), sc(y+dx*math.sin(a)+dy*math.cos(a)))
    d.polygon([rot(p) for p in pts], fill=ORANGE)
    hi=[rot((x+10,y-3)),rot((x+60,y-14)),rot((x+67,y-8))]
    d.polygon(hi, fill=CREAM)
    rounded(d, (x-13,y-8,x+17,y+8), 6, CREAM)

def character(frame, mode, action, frames):
    im=Image.new("RGBA", (sc(256),sc(256)), (0,0,0,0)); d=ImageDraw.Draw(im)
    t = frame/(frames-1) if frames>1 else 0
    moving = action == "move"
    hurt = action == "hurt"
    swing = action == "swing"
    # Large, measurable poses: move has a full walk cycle; recoil has three
    # distinct center-of-mass/lean states; swing carries the blade through a
    # wide arc instead of repeating the anticipation frames.
    if moving:
        bob = math.sin(t*math.pi*2) * 10 + 8
        foot = math.sin(t*math.pi*2) * 24
        lift = (1.0 - math.cos(t*math.pi*2)) * 5
    elif action == "recoil":
        bob = [-2, 7, 0][frame]
        foot = [8, -5, 0][frame]
        lift = [3, 1, 0][frame]
    else:
        bob = 0
        foot = 0
        lift = 0
    lean = (-8 if hurt and frame == 0 else ([10, 5, 0][frame] if action == "recoil" else 0))
    if swing:
        lean = [-12, -6, 4, 12, 8, -6, -12, 2][frame]
    elif moving:
        lean = [-8, -3, 5, 9, 4, -7][frame]
    ground=200+bob
    # rear arm/equipment first
    if mode == "bubble": draw_gun(d, 65+lean, 139+bob, recoil=(12 if action=="recoil" and frame==0 else 0))
    else:
        swing_angles = [155, 135, 105, 45, -20, -65, -25, 70]
        swing_x = [166, 145, 125, 108, 100, 132, 165, 158]
        draw_sword(d, swing_x[frame] if swing else 166, 166+bob, angle=(swing_angles[frame] if swing else 155))
        if swing and frame in (3, 4):
            draw_sword(d, swing_x[frame]-8, 166+bob+4, angle=swing_angles[frame]+10)
    # legs
    ellipse(d,(91+foot,164+bob-lift,119+foot,ground+5-lift),ORANGE_D); ellipse(d,(130-foot,164+bob-(5-lift),158-foot,ground+5-(5-lift)),ORANGE)
    ellipse(d,(84+foot,190+bob-lift,119+foot,213+bob-lift),ORANGE); ellipse(d,(128-foot,190+bob-(5-lift),163-foot,213+bob-(5-lift)),ORANGE)
    # body, belly
    ellipse(d,(70+lean,70+bob,185+lean,183+bob),ORANGE)
    ellipse(d,(94+lean,126+bob,155+lean,178+bob),CREAM)
    # head dome and antenna
    ellipse(d,(72+lean,30+bob,183+lean,139+bob),ORANGE)
    rounded(d,(124+lean,27+bob,135+lean,55+bob),5,ORANGE_D); ellipse(d,(112+lean,12+bob,147+lean,39+bob),WHITE)
    # goggles and eyes
    rounded(d,(76+lean,66+bob,143+lean,119+bob),23,BLUE); rounded(d,(128+lean,66+bob,190+lean,119+bob),23,BLUE)
    ellipse(d,(92+lean,76+bob,121+lean,111+bob),BLUE_D); ellipse(d,(143+lean,76+bob,172+lean,111+bob),BLUE_D)
    ellipse(d,(101+lean,83+bob,112+lean,98+bob),WHITE); ellipse(d,(151+lean,83+bob,162+lean,98+bob),WHITE)
    ellipse(d,(111+lean,119+bob,142+lean,143+bob),(160,42,32,255)); ellipse(d,(118+lean,123+bob,136+lean,132+bob),(255,105,100,255))
    # ear cups and hands
    ellipse(d,(66+lean,83+bob,91+lean,112+bob),BLUE); ellipse(d,(177+lean,83+bob,202+lean,112+bob),BLUE)
    ellipse(d,(63+lean,129+bob,91+lean,159+bob),ORANGE); ellipse(d,(171+lean,131+bob,199+lean,160+bob),ORANGE)
    if hurt and frame == 1:
        rounded(d,(76+lean,66+bob,190+lean,119+bob),22,WHITE)
    return im.resize((256,256), Image.Resampling.LANCZOS)

def save_quant(im, path):
    # FASTOCTREE preserves RGBA alpha in Pillow 12 while producing a compact P PNG.
    im = im.convert("RGBA").quantize(colors=256, method=Image.Quantize.FASTOCTREE).convert("RGBA")
    im.save(path, optimize=True)

def sheet(name, n, mode, action):
    out=Image.new("RGBA",(256*n,256),(0,0,0,0))
    for i in range(n): out.paste(character(i,mode,action,n),(256*i,0),character(i,mode,action,n))
    path=CHAR/name; save_quant(out,path)
    preview=Image.new("RGB",(n*512,570),(35,44,61,255)); font=ImageFont.load_default()
    for i in range(n):
        cell=out.crop((256*i,0,256*(i+1),256)).resize((512,512),Image.Resampling.NEAREST).convert("RGBA")
        preview.paste(cell,(i*512,0),cell); ImageDraw.Draw(preview).text((i*512+12,535),f"frame {i}",font=font,fill="white")
    preview.save(REVIEW/(name.stem+"_preview.png"))
    return path

def icon(name, kind):
    im=Image.new("RGBA",(384,384),(0,0,0,0)); d=ImageDraw.Draw(im); col=BLUE if kind=="bubble" else ORANGE
    rounded(d,(12,12,372,372),76,col)
    if kind=="bubble": draw_gun(d,150,192)
    else: draw_sword(d,150,210,0)
    path=ICONS/name; final=im.resize((128,128),Image.Resampling.LANCZOS); save_quant(final,path)
    preview=Image.new("RGB",(300,350),(35,44,61)); big=final.resize((300,300),Image.Resampling.NEAREST).convert("RGBA")
    preview.paste(big,(0,0),big); ImageDraw.Draw(preview).text((12,320),name.stem,font=ImageFont.load_default(),fill="white")
    preview.save(REVIEW/(name.stem+"_preview.png")); return path

def main():
    for p in (CHAR,ICONS,REVIEW): p.mkdir(parents=True,exist_ok=True)
    sheet(Path("player_bubble_move.png"),6,"bubble","move")
    sheet(Path("player_sword_move.png"),6,"sword","move")
    sheet(Path("player_sword_swing.png"),8,"sword","swing")
    sheet(Path("player_bubble_recoil.png"),3,"bubble","recoil")
if __name__ == "__main__": main()
