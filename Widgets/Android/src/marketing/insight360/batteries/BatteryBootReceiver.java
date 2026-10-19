package marketing.insight360.batteries;
import android.content.*;
public class BatteryBootReceiver extends BroadcastReceiver {
 @Override public void onReceive(Context c,Intent i){BatterySyncService.schedule(c);BatterySyncService.start(c);}
}
