const assert=require('node:assert/strict');
const {localBatteries}=require('../Integrations/battery-collect.cjs');
(async()=>{
 const id='demo_s25',calls=[];
 const local={call:async(...args)=>{calls.push(args);return[id,'unrelated'];},props:async(path,iface)=>{
  calls.push([path,iface]);return path.endsWith('/battery')?{charge:88,isCharging:false,hasBattery:true}:{name:'S25 Ultra',isPaired:true,isReachable:true};}};
 const result=await localBatteries(local);
 assert.equal(result.length,1);assert.equal(result[0].charge,88);
 assert.equal(calls.length,3);assert(!JSON.stringify(calls).includes('notification'));assert(!JSON.stringify(calls).includes('unrelated'));
 console.log('Battery collector: known identities, battery-only D-Bus calls passed');
})().catch(error=>{console.error(error);process.exit(1);});
