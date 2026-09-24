# Draws the biome marks (broadleaf, cypress, palm, tuft, marsh, dune) into assets/gfx/terrain.
# Needs Pillow. Run from the repo root: python3 tools/draw_marks.py
import math, random
from PIL import Image, ImageDraw
INK=(59,42,28,255); FILL=(200,199,157,255); DARK=(183,184,140,255); LIGHT=(110,92,70,255)
K=4  # supersampling
OUT='assets/gfx/terrain'  # run from the repo root

def canvas(w,h): im=Image.new('RGBA',(w*K,h*K),(0,0,0,0)); return im, ImageDraw.Draw(im)
def S(p): return [(x*K,y*K) for x,y in p]
def stroke(d,pts,w,col=INK):
    pts=S(pts); d.line(pts,fill=col,width=int(w*K),joint='curve')
    for x,y in (pts[0],pts[-1]): r=w*K/2; d.ellipse((x-r,y-r,x+r,y+r),fill=col)
def poly(d,pts,w,fill):
    d.polygon(S(pts),fill=fill); stroke(d,pts+[pts[0]],w)
def save(im,name,w,h): im.resize((w,h),Image.LANCZOS).save(f'{OUT}/{name}.png')
def arc(cx,cy,rx,ry,a0,a1,n=24): return [(cx+rx*math.cos(a0+(a1-a0)*i/n), cy+ry*math.sin(a0+(a1-a0)*i/n)) for i in range(n+1)]

def broadleaf(v):
    rnd=random.Random(10+v); w,h=64,84; im,d=canvas(w,h)
    cx,cy,r=32,34,22+rnd.uniform(-2,2); bumps=rnd.choice([5,6,7]); pts=[]
    for i in range(bumps*8+1):
        a=math.pi*2*i/(bumps*8)-math.pi/2; bump=1+0.09*abs(math.sin(a*bumps/2))+rnd.uniform(-0.01,0.01)
        pts.append((cx+r*bump*math.cos(a)*1.0, cy+r*bump*math.sin(a)*0.9))
    stroke(d,[(32,55),(32,78)],5)
    poly(d,pts[:-1],4.5,FILL)
    # a couple of leaf strokes on the shaded side
    for k in range(2): a=0.25+k*0.45+rnd.uniform(-0.1,0.1); stroke(d,arc(cx,cy,r*0.62,r*0.55,a,a+0.55,8),2.5)
    save(im,f'broadleaf_{v}',w,h)

def cypress(v):
    rnd=random.Random(20+v); w,h=34,112; im,d=canvas(w,h); top=6+rnd.uniform(-2,2); wid=11+rnd.uniform(-1.5,1.5)
    L=[(17-wid*math.sin(math.pi*t)**0.8, top+t*(88-top)) for t in [i/20 for i in range(21)]]
    R=[(17+wid*math.sin(math.pi*t)**0.8, top+t*(88-top)) for t in [i/20 for i in range(21)]][::-1]
    stroke(d,[(17,86),(17,106)],4.5)
    poly(d,L+R,4.2,DARK)
    stroke(d,[(20,30),(23,52)],2.3); stroke(d,[(20,56),(22,74)],2.3)
    save(im,f'cypress_{v}',w,h)

def palm(v):
    rnd=random.Random(30+v); w,h=72,100; im,d=canvas(w,h); lean=rnd.uniform(-7,7)
    top=(36+lean,30)
    trunk=[(36+lean*(1-(1-t)**2)*0+lean*t*t, 96-t*66) for t in [i/12 for i in range(13)]]
    stroke(d,trunk,5)
    for k in range(4): y=90-k*15; x=36+lean*((96-y)/66)**2; stroke(d,[(x-3.5,y),(x+3.5,y-2)],2.2)
    tx,ty=trunk[-1]
    for ang,length in [(-160,30),(-125,28),(-60,28),(-20,30),(-95,20),(170,24),(10,24)]:
        a=math.radians(ang+rnd.uniform(-8,8)); L=length+rnd.uniform(-3,3)
        pts=[(tx+L*t*math.cos(a), ty+L*t*math.sin(a)+ (L*0.55)*t*t) for t in [i/10 for i in range(11)]]
        stroke(d,pts,4)
    save(im,f'palm_{v}',w,h)

def tuft(v):
    rnd=random.Random(40+v); w,h=44,26; im,d=canvas(w,h); n=rnd.choice([4,5,5,6])
    for i in range(n):
        a=math.radians(-90+(i-(n-1)/2)*24+rnd.uniform(-6,6)); L=rnd.uniform(14,20)*(1-abs(i-(n-1)/2)*0.12)
        bx=22+(i-(n-1)/2)*1.5; stroke(d,[(bx,23),(bx+L*0.5*math.cos(a),23+L*0.5*math.sin(a)-1),(bx+L*math.cos(a),23+L*math.sin(a))],2.4,LIGHT)
    save(im,f'tuft_{v}',w,h)

def marsh(v):
    rnd=random.Random(50+v); w,h=76,34; im,d=canvas(w,h)
    for y,x0,x1 in [(24,6,70),(30,18,60)]:
        stroke(d,[(x0+rnd.uniform(-3,3),y),(x1+rnd.uniform(-3,3),y)],2.4,LIGHT)
    for cx in [22+rnd.uniform(-3,3),50+rnd.uniform(-3,3)]:
        for i in range(5):
            a=math.radians(-90+(i-2)*20+rnd.uniform(-5,5)); L=rnd.uniform(12,17)*(1-abs(i-2)*0.15)
            stroke(d,[(cx+(i-2)*1.2,21),(cx+(i-2)*1.2+L*math.cos(a),21+L*math.sin(a))],2.3,LIGHT)
    save(im,f'marsh_{v}',w,h)

def dune(v):
    rnd=random.Random(60+v); w,h=90,30; im,d=canvas(w,h); k=rnd.uniform(0.8,1.2)
    crest=[(8+74*t, 24-16*k*math.sin(math.pi*t)**1.6*(1+0.25*math.sin(math.pi*t*2+v))) for t in [i/24 for i in range(25)]]
    stroke(d,crest,2.8,LIGHT)
    # hatching on the lee side, south-east of the crest
    for t in [0.58,0.68,0.78]:
        x,y=8+74*t, 24-16*k*math.sin(math.pi*t)**1.6*(1+0.25*math.sin(math.pi*t*2+v))
        stroke(d,[(x,y+2),(x-2,26)],1.8,LIGHT)
    save(im,f'dune_{v}',w,h)

for v in range(4):
    broadleaf(v); cypress(v); palm(v); tuft(v); marsh(v); dune(v)
