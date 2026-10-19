package marketing.insight360.adbkeeper;
import android.content.*;
public class BootReceiver extends BroadcastReceiver {
 @Override public void onReceive(Context c,Intent i){
  if((Intent.ACTION_BOOT_COMPLETED.equals(i.getAction())||Intent.ACTION_MY_PACKAGE_REPLACED.equals(i.getAction()))&&c.getSharedPreferences("keeper",0).getBoolean("enabled",false)){
   try{c.startForegroundService(new Intent(c,KeeperService.class));}catch(RuntimeException e){android.util.Log.w("InsightAdbKeeper","Background start unavailable: "+e.getClass().getSimpleName());}
  }
 }
}
