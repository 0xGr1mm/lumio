#!/usr/bin/env python3
import math, os, random, struct, wave

ROOT=os.path.join(os.path.dirname(os.path.dirname(__file__)),"Resources","Audio")
os.makedirs(ROOT,exist_ok=True); RATE=22050

def write(name, chords, beat=0.0, airy=0.0):
    random.seed(name);length=16;frames=[]
    for i in range(RATE*length):
        t=i/RATE;bar=int(t/4)%len(chords);freqs=chords[bar]
        attack=min(1,(t%4)/0.25);release=min(1,(4-t%4)/0.5);env=min(attack,release)*0.22
        value=sum(math.sin(2*math.pi*f*t)/len(freqs) for f in freqs)*env
        if beat and t%0.5<0.055:value+=math.sin(2*math.pi*(80-50*(t%0.055)/0.055)*t)*beat*(1-(t%0.055)/0.055)
        if airy:value+=(random.random()*2-1)*airy*(0.5+0.5*math.sin(2*math.pi*t/8))
        frames.append(struct.pack('<h',int(max(-1,min(1,value))*32767)))
    # Written beside the target and moved into place: opening the target directly stalls when the old file
    # lives in iCloud and has to be downloaded first, and the old bytes are about to be replaced anyway.
    target=os.path.join(ROOT,name+'.wav');temporary=target+'.new'
    with wave.open(temporary,'wb') as f:f.setnchannels(1);f.setsampwidth(2);f.setframerate(RATE);f.writeframes(b''.join(frames))
    os.replace(temporary,target)

write('lofi-drift',[(220,261.63,329.63),(196,246.94,293.66),(174.61,220,261.63),(196,246.94,329.63)],0.05,0.002)
write('ambient-air',[(110,164.81,220),(130.81,196,261.63),(146.83,220,293.66),(98,146.83,196)],0,0.006)
write('warm-keys',[(261.63,329.63,392),(220,261.63,329.63),(196,246.94,293.66),(233.08,293.66,349.23)],0.025,0)
write('neon-pulse',[(164.81,220,329.63),(174.61,233.08,349.23),(146.83,196,293.66),(130.81,174.61,261.63)],0.12,0)
write('cinematic-rise',[(82.41,123.47,164.81),(98,146.83,196),(110,164.81,220),(130.81,196,261.63)],0.04,0.002)

click=os.path.join(ROOT,'click.wav')
with wave.open(click+'.new','wb') as f:
    f.setnchannels(1);f.setsampwidth(2);f.setframerate(RATE)
    data=[]
    for i in range(int(RATE*.09)):
        t=i/RATE;v=(math.sin(2*math.pi*(1100-600*t/.09)*t)+0.3*math.sin(2*math.pi*2400*t))*math.exp(-48*t)*0.6
        data.append(struct.pack('<h',int(v*32767)))
    f.writeframes(b''.join(data))
os.replace(click+'.new',click)
