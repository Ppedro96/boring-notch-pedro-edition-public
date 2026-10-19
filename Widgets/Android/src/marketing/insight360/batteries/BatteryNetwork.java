package marketing.insight360.batteries;
import android.content.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.*;
final class BatteryNetwork {
 static final String ENDPOINT="https://batteries.example.com/v1/batteries";
 static final AtomicBoolean busy=new AtomicBoolean(false);
 static boolean configured(Context c){return c.getSharedPreferences("network",0).getString("token","").length()>=40;}
 static boolean enabled(Context c){return configured(c)&&c.getSharedPreferences("network",0).getBoolean("enabled",true);}
 static void configure(Context c,String endpoint,String token)throws Exception{
  if(!ENDPOINT.equals(endpoint)||token==null||!token.matches("[A-Za-z0-9_-]{40,100}"))throw new IllegalArgumentException();
  c.getSharedPreferences("network",0).edit().putString("token",token).putBoolean("enabled",true).commit();
 }
 static void sync(Context c){
  if(!enabled(c)||!busy.compareAndSet(false,true))return;
  HttpURLConnection connection=null;
  try{
   JSONObject own=null;for(JSONObject d:BatteryData.devices(c,BatteryData.read(c)))if(BatteryData.ownKind().equals(d.optString("kind")))own=d;
   if(own==null||own.isNull("charge"))throw new IOException();
   JSONObject payload=new JSONObject();payload.put("charge",own.getInt("charge"));payload.put("charging",own.optBoolean("charging"));
   byte[] body=payload.toString().getBytes(StandardCharsets.UTF_8);
   connection=(HttpURLConnection)new URL(ENDPOINT).openConnection();connection.setInstanceFollowRedirects(false);
   connection.setConnectTimeout(7000);connection.setReadTimeout(7000);connection.setRequestMethod("PUT");connection.setDoOutput(true);
   connection.setRequestProperty("Authorization","Bearer "+c.getSharedPreferences("network",0).getString("token",""));
   connection.setRequestProperty("Content-Type","application/json");connection.setRequestProperty("User-Agent","InsightBatteriesAndroid/2");connection.setFixedLengthStreamingMode(body.length);
   try(OutputStream out=connection.getOutputStream()){out.write(body);}
   int status=connection.getResponseCode();if(status!=200)throw new IOException(status==401?"reconfigure":"network");
   ByteArrayOutputStream out=new ByteArrayOutputStream();try(InputStream in=connection.getInputStream()){
    byte[] buffer=new byte[2048];int n;while((n=in.read(buffer))!=-1){if(out.size()+n>16384)throw new IOException();out.write(buffer,0,n);}
   }
   if(!BatteryData.accept(c,new String(out.toByteArray(),StandardCharsets.UTF_8)))throw new IOException();
   c.getSharedPreferences("network",0).edit().putLong("lastSuccess",System.currentTimeMillis()).remove("lastError").apply();
  }catch(Exception e){c.getSharedPreferences("network",0).edit().putString("lastError","reconfigure".equals(e.getMessage())?"Reconecte este aparelho à central":"Aguardando conexão").apply();}
  finally{if(connection!=null)connection.disconnect();busy.set(false);BatteryWidget.updateAll(c);}
 }
}
