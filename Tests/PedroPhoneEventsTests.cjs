'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const {EventEmitter}=require('node:events'), {PassThrough}=require('node:stream');
const fs=require('node:fs'), os=require('node:os'), path=require('node:path');
const { PhoneWatch, LocalKDE, mergeDevices, validateAction, NativePopupOwner } = require('../Integrations/kde-phone.cjs');
const delay = ms => new Promise(r=>setTimeout(r,ms));
const phone=(id='a',fields={})=>({id,name:id,paired:true,reachable:true,charge:50,notifications:[],media:null,...fields});
function child() { const p=new EventEmitter(); p.stdout=new PassThrough();p.stderr=new PassThrough();p.stdin=new PassThrough();p.killed=false;p.kill=()=>{p.killed=true;p.emit('close',0)};return p; }
function local() { return {bus:{},onChange:()=>{},snapshot:async()=>[phone()],close(){this.closed=true}}; }
test('reachable Mac pairing state wins over the stale relay',()=>{
 const d=mergeDevices([phone('a',{paired:false})],[phone('a',{reachable:false}),phone('s23')]);
 assert.equal(d[0].id,'a'); assert.equal(d[0].paired,false); assert.equal(d[1].id,'x99:s23');
});
test('hung X99 never delays local frames; idle has no repeated queries',async()=>{
 const l=local(),r=child(),frames=[];let queries=0;l.snapshot=async()=>{queries++;return[phone()]};
 const w=new PhoneWatch(v=>frames.push(v),{local:l,relay:true,remoteFactory:()=>r});
 try {w.start();await delay(20);assert.equal(frames[0].devices[0].id,'a');await delay(180);assert.equal(queries,1);}
 finally{w.stop()} assert(r.killed);assert(l.closed);
});
test('D-Bus signal bursts coalesce; remote disconnect clears reply/media access',async()=>{
 const l=local(),r=child(),frames=[];let charge=50;l.snapshot=async()=>[phone('a',{charge})];
 const w=new PhoneWatch(v=>frames.push(v),{local:l,relay:true,remoteFactory:()=>r});
 try{
 w.start();await delay(10);charge=51;for(let i=0;i<10;i++)l.onChange();await delay(180);
 assert.equal(frames.at(-1).devices[0].charge,51);assert.equal(frames.length,2);
 r.stdout.write(JSON.stringify({devices:[phone('s23',{media:{playing:true},notifications:[{id:'1'}]})]})+'\n');await delay(10);
 r.emit('close',1);await delay(10);const remote=frames.at(-1).devices.find(p=>p.via==='X99');
 assert.equal(remote.reachable,false);assert.equal(remote.media,null);assert.deepEqual(remote.notifications,[]);
 }finally{w.stop()}
});
test('local failure retains direct device names but never stale connected state',async()=>{
 const l=local(),frames=[];const w=new PhoneWatch(v=>frames.push(v),{local:l,relay:false});
 try{await w.refresh();l.snapshot=async()=>{throw Error('gone')};await w.refresh();assert.equal(frames.at(-1).devices[0].reachable,false);assert.match(frames.at(-1).error,/local/)}finally{w.stop()}
});
test('reply validates exact live notification token before sending',async()=>{
 const l=new LocalKDE(),calls=[];l.props=async(p)=>p.endsWith('/notifications/7')?{replyId:'fresh'}:{isPaired:true,isReachable:true};l.call=async(...a)=>calls.push(a);
 const r={command:'reply',id:'a',notification:'7',replyID:'old',text:'hello'};
 await assert.rejects(l.action(r),/expirou/);assert.equal(calls.length,0);
 await l.action({...r,replyID:'fresh'});assert.equal(calls[0][2],'sendReply');assert.equal(calls[0][4][0],'hello');
});
test('media is restricted to live player and supported controls',async()=>{
 assert.throws(()=>validateAction({command:'media',id:'a',player:'Music',action:'run'}));
 const l=new LocalKDE(),calls=[];l.props=async(p)=>p.endsWith('/mprisremote')?{playerList:['Music'],player:'Music'}:{isPaired:true,isReachable:true};l.call=async(...a)=>calls.push(a);
 await assert.rejects(l.action({command:'media',id:'a',player:'Gone',action:'Next'}),/disponivel/);
 await l.action({command:'media',id:'a',player:'Music',action:'PlayPause'});assert.equal(calls[0][2],'sendAction');
});
test('native popup takeover only changes forwarded notifications and restores on stop',async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'phone-popup-')),file=path.join(dir,'kdeconnect.notifyrc'),state=path.join(dir,'owner.json');
 const original='[Event/pingReceived]\nAction=Popup\n[Event/notification]\nAction=Popup\nFoo=Bar\n[Event/batteryLow]\nAction=Popup\n';
 try{
 fs.writeFileSync(file,original);const owner=new NativePopupOwner({},file,state);await owner.set(true);
 const value=fs.readFileSync(file,'utf8');assert.match(value,/\[Event\/notification\]\nAction=None\nFoo=Bar/);assert.match(value,/\[Event\/batteryLow\]\nAction=Popup/);
 await owner.set(false);assert.equal(fs.readFileSync(file,'utf8'),original);assert(!fs.existsSync(state));
 fs.unlinkSync(file);await owner.set(true);await owner.set(false);assert(!fs.existsSync(file));
 }finally{fs.rmSync(dir,{recursive:true,force:true})}
});
test('manual user changes during native takeover are preserved',async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'phone-popup-')),file=path.join(dir,'config'),state=path.join(dir,'owner');
 try{const owner=new NativePopupOwner({},file,state);await owner.set(true);fs.writeFileSync(file,'[User]\nX=1\n');await owner.set(false);assert.equal(fs.readFileSync(file,'utf8'),'[User]\nX=1\n')}finally{fs.rmSync(dir,{recursive:true,force:true})}
});
test('stale popup override recovers even when native notifications are disabled',async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'phone-popup-')),file=path.join(dir,'config'),state=path.join(dir,'owner');
 try{
  const managed='[Event/notification]\nAction=None\n', original='[Event/notification]\nAction=Popup\n';
  fs.writeFileSync(file,managed);fs.writeFileSync(state,JSON.stringify({original,managed}));
  await new NativePopupOwner({},file,state).recover();assert.equal(fs.readFileSync(file,'utf8'),original);assert(!fs.existsSync(state));
 }finally{fs.rmSync(dir,{recursive:true,force:true})}
});
test('popup restoration preserves added KDE settings without leaving forwarding muted',async()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'phone-popup-')),file=path.join(dir,'config'),state=path.join(dir,'owner');
 try{
  fs.writeFileSync(file,'[Event/notification]\nAction=Popup\n');
  const owner=new NativePopupOwner({},file,state);await owner.set(true);
  fs.appendFileSync(file,'\n[Event/pingReceived]\nAction=Popup\n');await owner.set(false);
  const result=fs.readFileSync(file,'utf8');assert.match(result,/\[Event\/notification\]\nAction=Popup/);assert.match(result,/\[Event\/pingReceived\]\nAction=Popup/);
 }finally{fs.rmSync(dir,{recursive:true,force:true})}
});
