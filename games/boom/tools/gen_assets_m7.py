from pathlib import Path
from PIL import Image, ImageDraw
import math

ROOT=Path(__file__).resolve().parents[1]; CHAR=ROOT/'assets/images/characters'; ICONS=ROOT/'assets/images/icons'; REVIEW=ROOT/'assets/review'
S=3
INK=(48,48,64,255); CREAM=(240,240,240,255); IVORY=(240,240,224,255); BROWN=(192,128,64,255); SAND=(224,192,144,255); BLUE=(112,144,240,255); BLUE_D=(32,80,112,255); PURPLE=(80,96,144,255)
def B(v): return tuple(round(x*S) for x in v)
def rr(d,b,r,c): d.rounded_rectangle(B(b),radius=round(r*S),fill=c)
def el(d,b,c): d.ellipse(B(b),fill=c)
def poly(d,p,c): d.polygon([B(x) for x in p],fill=c)
def line(d,p,w,c): d.line([B(x) for x in p],fill=c,width=round(w*S),joint='curve')
def sword(d,x,y,a,L=250):
    q=math.radians(a); ux,uy=math.cos(q),math.sin(q); vx,vy=-uy,ux
    def pt(t,w): return (x+ux*t+vx*w,y+uy*t+vy*w)
    poly(d,[pt(0,-14),pt(L-24,-30),pt(L,0),pt(L-24,30),pt(0,14)],INK)
    poly(d,[pt(8,-10),pt(L-27,-21),pt(L-5,0),pt(L-27,21),pt(8,10)],SAND)
    line(d,[pt(12,-3),pt(L-28,-10)],5,IVORY); line(d,[pt(-15,-18),pt(15,18)],7,BROWN)
def gun(d,x,y,recoil=0):
    x-=recoil; rr(d,(x-8,y-16,x+68,y+16),10,INK); rr(d,(x-3,y-11,x+62,y+11),8,CREAM); el(d,(x-25,y-22,x+17,y+22),INK); el(d,(x-20,y-17,x+12,y+17),BLUE); rr(d,(x+5,y-15,x+20,y+20),5,BROWN); rr(d,(x+22,y+12,x+48,y+38),7,BROWN); el(d,(x+38,y-7,x+55,y+7),PURPLE)
def actor(i,kind,action,n):
    im=Image.new('RGBA',(S*256,S*256)); d=ImageDraw.Draw(im); t=i/max(1,n-1); bob=math.sin(t*math.pi*2)*(1.0 if action=='idle' else 4) if action in ('idle','move') else (math.sin(t*math.pi)*2 if action=='swing' else 0)
    lean=(t-.5)*10 if action in ('move','recoil') else 0; leg=math.sin(t*math.pi*2)*22 if action=='move' else 0; arm=math.sin(t*math.pi*2+math.pi)*10 if action=='move' else 0
    # silhouette: 200px tall, centered
    rr(d,(62+lean,35+bob,190+lean,108+bob),28,INK); el(d,(72+lean,43+bob,180+lean,100+bob),CREAM); el(d,(103+lean,61+bob,118+lean,76+bob),INK); el(d,(143+lean,61+bob,158+lean,76+bob),INK); el(d,(108+lean,64+bob,114+lean,70+bob),IVORY); el(d,(148+lean,64+bob,154+lean,70+bob),IVORY)
    rr(d,(76+lean,101+bob,177+lean,177+bob),12,INK); rr(d,(83+lean,108+bob,170+lean,171+bob),9,BROWN); rr(d,(96+lean,116+bob,157+lean,154+bob),7,SAND)
    line(d,[(99+lean,170+bob),(88+lean-leg,207),(78+lean-leg,235)],17,INK); line(d,[(99+lean,170+bob),(88+lean-leg,207),(78+lean-leg,235)],9,CREAM)
    line(d,[(153+lean,170+bob),(164+lean+leg,207),(175+lean+leg,235)],17,INK); line(d,[(153+lean,170+bob),(164+lean+leg,207),(175+lean+leg,235)],9,CREAM)
    line(d,[(83+lean,125+bob),(58+lean-arm,158),(48+lean-arm,190)],18,INK); line(d,[(83+lean,125+bob),(58+lean-arm,158),(48+lean-arm,190)],10,CREAM)
    line(d,[(171+lean,125+bob),(198+lean+arm,155),(210+lean+arm,185)],18,INK); line(d,[(171+lean,125+bob),(198+lean+arm,155),(210+lean+arm,185)],10,CREAM)
    if kind=='bubble': gun(d,176+lean,166+bob,recoil=(18 if action=='recoil' else 0))
    else:
        a=([-64,-47,-30,-13,4,21,38,56][i] if action=='swing' else (-35+4*math.sin(t*math.pi*2) if action=='idle' else -38+32*math.sin(t*math.pi*2)))
        if action=='swing': sword(d,15+lean,125+bob,a,270)
        else: sword(d,(78 if action=='move' else 98)+lean,165+bob,a,242 if action=='idle' else 225)
    if action=='hurt': line(d,[(113,92),(124,101),(135,91)],5,BLUE_D)
    return im.resize((256,256),Image.Resampling.LANCZOS)
def save(im,p): im.convert('RGBA').quantize(colors=256,method=Image.Quantize.FASTOCTREE).convert('RGBA').save(p,optimize=True)
def sheet(fn,n,kind,action):
    out=Image.new('RGBA',(256*n,256));
    for i in range(n): out.paste(actor(i,kind,action,n),(256*i,0),actor(i,kind,action,n))
    save(out,CHAR/fn)
def icon(fn,kind):
    im=Image.new('RGBA',(384,384)); d=ImageDraw.Draw(im); rr(d,(18,18,366,366),64,INK); rr(d,(28,28,356,356),56,BLUE if kind=='bubble' else BROWN)
    if kind=='bubble': gun(d,155,190)
    else: sword(d,110,210,0,200)
    save(im.resize((128,128),Image.Resampling.LANCZOS),ICONS/fn)
def main():
    CHAR.mkdir(parents=True,exist_ok=True); ICONS.mkdir(parents=True,exist_ok=True)
    for f,n,k,a in [('player_bubble_idle.png',4,'bubble','idle'),('player_bubble_move.png',6,'bubble','move'),('player_bubble_recoil.png',3,'bubble','recoil'),('player_sword_idle.png',4,'sword','idle'),('player_sword_move.png',6,'sword','move'),('player_sword_swing.png',8,'sword','swing'),('player_hurt.png',1,'bubble','hurt')]: sheet(f,n,k,a)
    icon('weapon_bubble.png','bubble'); icon('weapon_sword.png','sword')
if __name__=='__main__': main()
