package marketing.insight360.batteries;
import android.content.*;
import android.util.Base64;
public class SyncReceiver extends BroadcastReceiver {
 @Override public void onReceive(Context c,Intent intent){
  if(!"marketing.insight360.batteries.SYNC".equals(intent.getAction()))return;
  if(intent.hasExtra("endpoint")){
   try{BatteryNetwork.configure(c,intent.getStringExtra("endpoint"),intent.getStringExtra("token"));c.getSharedPreferences("battery",0).edit().putInt("rows",1).apply();BatterySyncService.schedule(c);BatterySyncService.start(c);setResultCode(-1);}catch(Exception e){setResultCode(1);}return;
  }
  if(BatteryNetwork.configured(c))return;
  try{String value=intent.getStringExtra("snapshot");if(value==null||value.length()>24000)return;
   String payload=new String(Base64.decode(value,Base64.DEFAULT),"UTF-8");
   if(BatteryData.accept(c,payload))BatteryWidget.updateAll(c);
  }catch(Exception ignored){}
 }
}
