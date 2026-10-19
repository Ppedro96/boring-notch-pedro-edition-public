package marketing.insight360.batteries;
import android.app.*;
import android.app.job.*;
import android.content.*;
import android.content.pm.ServiceInfo;
import android.net.*;
import android.os.*;
import java.util.concurrent.*;
public class BatterySyncService extends Service {
 ScheduledExecutorService executor;BroadcastReceiver receiver;ConnectivityManager.NetworkCallback callback;String lastBattery="";
 static void start(Context c){if(!BatteryNetwork.enabled(c))return;try{c.startForegroundService(new Intent(c,BatterySyncService.class));}catch(Exception ignored){schedule(c);}}
 static void schedule(Context c){
  JobScheduler scheduler=(JobScheduler)c.getSystemService(JOB_SCHEDULER_SERVICE);
  if(!BatteryNetwork.enabled(c)){scheduler.cancel(8201);return;}
  scheduler.schedule(new JobInfo.Builder(8201,new ComponentName(c,BatterySyncJob.class)).setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPersisted(true).setPeriodic(15*60*1000L).build());
 }
 void request(){if(executor!=null&&!executor.isShutdown())executor.execute(new Runnable(){public void run(){BatteryNetwork.sync(getApplicationContext());}});}
 @Override public void onCreate(){super.onCreate();
  NotificationManager manager=(NotificationManager)getSystemService(NOTIFICATION_SERVICE);
  manager.createNotificationChannel(new NotificationChannel("battery-sync","Baterias dos aparelhos",NotificationManager.IMPORTANCE_LOW));
  PendingIntent open=PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
  Notification n=new Notification.Builder(this,"battery-sync").setSmallIcon(R.drawable.ic_launcher).setContentTitle("Baterias Insight").setContentText("Sincronizando seus aparelhos").setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false).build();
  if(Build.VERSION.SDK_INT>=29)startForeground(8200,n,ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE);else startForeground(8200,n);
  executor=Executors.newSingleThreadScheduledExecutor();executor.scheduleWithFixedDelay(new Runnable(){public void run(){BatteryNetwork.sync(getApplicationContext());}},0,60,TimeUnit.SECONDS);
  receiver=new BroadcastReceiver(){public void onReceive(Context c,Intent i){
   if(Intent.ACTION_BATTERY_CHANGED.equals(i.getAction())){String value=i.getIntExtra("level",-1)+":"+i.getIntExtra("status",0);if(value.equals(lastBattery))return;lastBattery=value;}
   request();}};
  IntentFilter filter=new IntentFilter(Intent.ACTION_BATTERY_CHANGED);filter.addAction(Intent.ACTION_SCREEN_ON);filter.addAction(Intent.ACTION_POWER_CONNECTED);filter.addAction(Intent.ACTION_POWER_DISCONNECTED);
  if(Build.VERSION.SDK_INT>=33)registerReceiver(receiver,filter,Context.RECEIVER_NOT_EXPORTED);else registerReceiver(receiver,filter);
  callback=new ConnectivityManager.NetworkCallback(){@Override public void onAvailable(Network network){request();}};
  ((ConnectivityManager)getSystemService(CONNECTIVITY_SERVICE)).registerDefaultNetworkCallback(callback);schedule(this);
 }
 @Override public int onStartCommand(Intent i,int flags,int id){if(!BatteryNetwork.enabled(this)){stopSelf();return START_NOT_STICKY;}request();return START_STICKY;}
 @Override public IBinder onBind(Intent i){return null;}
 @Override public void onDestroy(){if(executor!=null)executor.shutdownNow();try{unregisterReceiver(receiver);}catch(Exception ignored){}try{((ConnectivityManager)getSystemService(CONNECTIVITY_SERVICE)).unregisterNetworkCallback(callback);}catch(Exception ignored){}super.onDestroy();}
}
