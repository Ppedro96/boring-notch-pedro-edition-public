package marketing.insight360.adbkeeper;
import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.content.pm.ServiceInfo;
import android.database.ContentObserver;
import android.net.*;
import android.os.*;
import android.provider.Settings;
import android.util.Log;
import java.util.*;

public class KeeperService extends Service {
 static final String TAG="InsightAdbKeeper",CHANNEL="wireless_recovery",PAUSE="marketing.insight360.adbkeeper.PAUSE";
 final Handler handler=new Handler(Looper.getMainLooper());
 final Set<Network> wifiNetworks=new HashSet<Network>();
 ConnectivityManager manager;ConnectivityManager.NetworkCallback callback;ContentObserver observer;
 int attempts=0;long lastAttempt=0;boolean ready=false;
 final Runnable recover=new Runnable(){public void run(){recoverNow();}};
 final Runnable heartbeat=new Runnable(){public void run(){recoverNow();handler.postDelayed(this,60000);}};
 static boolean permission(Context c){return c.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS)==PackageManager.PERMISSION_GRANTED;}
 static boolean flag(Context c,String key){return Settings.Global.getInt(c.getContentResolver(),key,0)==1;}
 void status(String value){getSharedPreferences("keeper",0).edit().putString("status",value).putLong("statusAt",System.currentTimeMillis()).apply();getSystemService(NotificationManager.class).notify(41,notification(value));}
 Notification notification(String text){
  PendingIntent open=PendingIntent.getActivity(this,0,new Intent(this,MainActivity.class),PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
  PendingIntent pause=PendingIntent.getService(this,1,new Intent(this,KeeperService.class).setAction(PAUSE),PendingIntent.FLAG_IMMUTABLE|PendingIntent.FLAG_UPDATE_CURRENT);
  return new Notification.Builder(this,CHANNEL).setSmallIcon(R.drawable.ic_launcher).setContentTitle("Depuração Wi-Fi automática").setContentText(text).setStyle(new Notification.BigTextStyle().bigText(text)).setOngoing(true).setContentIntent(open).addAction(new Notification.Action.Builder(null,"Pausar",pause).build()).build();
 }
 @Override public void onCreate(){
  super.onCreate();
  getSystemService(NotificationManager.class).createNotificationChannel(new NotificationChannel(CHANNEL,"Depuração Wi-Fi",NotificationManager.IMPORTANCE_LOW));
  if(Build.VERSION.SDK_INT>=34)startForeground(41,notification("Iniciando proteção local"),ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);else startForeground(41,notification("Iniciando proteção local"));
  manager=getSystemService(ConnectivityManager.class);
  callback=new ConnectivityManager.NetworkCallback(){
   @Override public void onAvailable(final Network n){handler.post(new Runnable(){public void run(){wifiNetworks.add(n);attempts=0;schedule();}});}
   @Override public void onLost(final Network n){handler.post(new Runnable(){public void run(){wifiNetworks.remove(n);attempts=0;schedule();}});}
   @Override public void onCapabilitiesChanged(final Network n,final NetworkCapabilities caps){handler.post(new Runnable(){public void run(){if(caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI))wifiNetworks.add(n);else wifiNetworks.remove(n);schedule();}});}
  };
  manager.registerNetworkCallback(new NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI).build(),callback);
  observer=new ContentObserver(handler){@Override public void onChange(boolean self){schedule();}};
  getContentResolver().registerContentObserver(Settings.Global.getUriFor("adb_wifi_enabled"),false,observer);
  getContentResolver().registerContentObserver(Settings.Global.getUriFor("adb_enabled"),false,observer);
  getContentResolver().registerContentObserver(Settings.Global.getUriFor("development_settings_enabled"),false,observer);
  ready=true;handler.post(heartbeat);
 }
 void schedule(){handler.removeCallbacks(recover);handler.postDelayed(recover,2500);}
 void recoverNow(){
  if(!ready)return;
  boolean enabled=getSharedPreferences("keeper",0).getBoolean("enabled",false),permitted=permission(this),wifi=!wifiNetworks.isEmpty(),developer=flag(this,"development_settings_enabled"),usb=flag(this,"adb_enabled"),wireless=flag(this,"adb_wifi_enabled");
  if(!enabled){stopSelf();return;}
  if(!permitted){status("Permissão de configuração pendente");return;}
  if(!wifi){status("Aguardando conexão Wi-Fi");return;}
  if(!developer||!usb){status("Pausado: opções de desenvolvedor ou depuração USB desligadas");return;}
  if(wireless){if(SystemClock.elapsedRealtime()-lastAttempt>=5000)attempts=0;status("Depuração ativa · recuperação automática ligada");return;}
  if(!RecoveryPolicy.shouldAttempt(enabled,permitted,wifi,developer,usb,wireless,attempts)){status("Abra a depuração e autorize esta rede no Android");return;}
  long now=SystemClock.elapsedRealtime();if(lastAttempt>0&&now-lastAttempt<8000){handler.postDelayed(recover,8000-(now-lastAttempt));return;}
  lastAttempt=now;attempts++;
  try{
   boolean written=Settings.Global.putInt(getContentResolver(),"adb_wifi_enabled",1);
   if(!written)throw new SecurityException("write rejected");
   getSharedPreferences("keeper",0).edit().putInt("recoveries",getSharedPreferences("keeper",0).getInt("recoveries",0)+1).putLong("lastRecovery",System.currentTimeMillis()).apply();
   Log.i(TAG,"Wireless debugging recovery requested; attempt="+attempts);status("Reativando depuração · autorização do Android preservada");
   handler.removeCallbacks(recover);handler.postDelayed(recover,5000);
  }catch(SecurityException e){status("Permissão de configuração indisponível");Log.w(TAG,"Secure setting denied");}
 }
 @Override public int onStartCommand(Intent i,int flags,int id){
  if(i!=null&&PAUSE.equals(i.getAction())){getSharedPreferences("keeper",0).edit().putBoolean("enabled",false).putString("status","Recuperação pausada").apply();stopForeground(STOP_FOREGROUND_REMOVE);stopSelf();return START_NOT_STICKY;}
  if(i!=null&&"marketing.insight360.adbkeeper.START".equals(i.getAction()))getSharedPreferences("keeper",0).edit().putBoolean("enabled",true).apply();
  attempts=0;schedule();return START_STICKY;
 }
 @Override public IBinder onBind(Intent i){return null;}
 @Override public void onDestroy(){ready=false;handler.removeCallbacksAndMessages(null);if(observer!=null)getContentResolver().unregisterContentObserver(observer);if(manager!=null&&callback!=null)manager.unregisterNetworkCallback(callback);super.onDestroy();}
}
