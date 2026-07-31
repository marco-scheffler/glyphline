import {chromium} from 'playwright';
import {PNG} from 'pngjs';
import {writeFileSync} from 'fs';
const file=process.argv[2], q=process.argv[3];
const b=await chromium.launch({headless:true,channel:'chrome'});
const p=await b.newPage({viewport:{width:1500,height:900},deviceScaleFactor:2});
async function shot(){
  await p.goto(`file://${process.cwd()}/${file}?${q}`,{waitUntil:'load'});
  await p.waitForFunction('window.__READY__===true',null,{timeout:60000});
  return await (await p.$('.zx-stage')).screenshot();
}
const a=PNG.sync.read(await shot()), c=PNG.sync.read(await shot());
await b.close();
let n=0,minx=1e9,miny=1e9,maxx=-1,maxy=-1;
const out=new PNG({width:a.width,height:a.height});
for(let y=0;y<a.height;y++)for(let x=0;x<a.width;x++){
  const i=(y*a.width+x)*4;
  const d=Math.abs(a.data[i]-c.data[i])+Math.abs(a.data[i+1]-c.data[i+1])+Math.abs(a.data[i+2]-c.data[i+2]);
  if(d>6){ n++; minx=Math.min(minx,x);maxx=Math.max(maxx,x);miny=Math.min(miny,y);maxy=Math.max(maxy,y);
    out.data[i]=255;out.data[i+1]=0;out.data[i+2]=0;out.data[i+3]=255; }
  else { const g=a.data[i]>>2; out.data[i]=out.data[i+1]=out.data[i+2]=g; out.data[i+3]=255; }
}
writeFileSync('shots/diff.png',PNG.sync.write(out));
console.log(`${a.width}x${a.height}, ${n} abweichende Pixel (${(n/(a.width*a.height)*100).toFixed(3)}%)`);
if(n) console.log(`Bereich x ${minx}..${maxx}, y ${miny}..${maxy}  (Breite ${maxx-minx}, Höhe ${maxy-miny})`);
