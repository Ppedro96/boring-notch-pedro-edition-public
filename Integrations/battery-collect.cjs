#!/usr/bin/env node
'use strict';
// Minimal battery-only KDE query. No notification/media/plugin enumeration.
const {spawn} = require('node:child_process');
const path = require('node:path');
const {LocalKDE, mergeDevices} = require('./kde-phone.cjs');
const ids = new Set(['demo_s23','demo_s25','demo_tablet','demo_fold']);
async function localBatteries(local) {
  const found = await local.call('/modules/kdeconnect','org.kde.kdeconnect.daemon','devices','bb',[false,false]);
  return (await Promise.all(found.filter(id=>ids.has(id)).map(async id=>{
    const base='/modules/kdeconnect/devices/'+id, iface='org.kde.kdeconnect.device';
    const p=await local.props(base,iface);
    const value={id,name:String(p.name||'').slice(0,100),paired:!!p.isPaired,reachable:!!p.isReachable,charge:null,charging:false};
    if(value.paired&&value.reachable)try{
      const b=await local.props(base+'/battery',iface+'.battery');
      if(b.hasBattery!==false&&Number.isInteger(b.charge)&&b.charge>=0&&b.charge<=100)value.charge=b.charge;
      value.charging=!!b.isCharging;
    }catch{}
    return value;
  }))).filter(Boolean);
}
function remoteBatteries(){return new Promise(resolve=>{
  const child=spawn('/usr/bin/ssh',['-T','-o','BatchMode=yes','-o','ConnectTimeout=3','x99','node .local/share/pedro-notch/battery-collect.cjs'],{stdio:['ignore','pipe','ignore']});
  let output='';const timer=setTimeout(()=>child.kill(),6500);
  child.stdout.on('data',data=>{output+=data;if(output.length>32000)child.kill();});
  child.on('error',()=>{});child.on('close',()=>{clearTimeout(timer);try{resolve(JSON.parse(output).devices||[]);}catch{resolve([]);}});
});}
async function main(){
 const local=new LocalKDE();let direct=[],localOK=false;
 const remote=process.platform==='darwin'?remoteBatteries():Promise.resolve([]);
 try{await local.connect();direct=await localBatteries(local);localOK=true;}catch{}finally{local.close();}
 const relayed=await remote;
 return {ok:localOK||relayed.length>0,devices:mergeDevices(direct,relayed),updatedAt:Date.now()/1000};
}
module.exports={localBatteries};
if(require.main===module){const timer=setTimeout(()=>process.exit(1),8500);main().then(value=>{clearTimeout(timer);console.log(JSON.stringify(value));}).catch(()=>process.exit(1));}
