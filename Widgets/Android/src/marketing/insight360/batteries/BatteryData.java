package marketing.insight360.batteries;
import android.content.*;
import android.os.BatteryManager;
import android.os.Build;
import org.json.*;
import java.util.*;

final class BatteryData {
 static final String[] KINDS={"mac","alienware","s23","s25","fold","tablet"};
 static final String[] NAMES={"MacBook Pro","Alienware","S23 Ultra","S25 Ultra","Z Fold6","Tab S8+"};
 static JSONObject read(Context c) {
  try { return new JSONObject(c.getSharedPreferences("battery",0).getString("snapshot","{}")); }
  catch(Exception e){return new JSONObject();}
 }
 static boolean accept(Context c,String payload){
  try {
   if(payload.length()>16384)return false;
   JSONObject source=new JSONObject(payload);
   JSONArray devices=source.getJSONArray("devices");
   if(devices.length()>6)return false;
   long now=System.currentTimeMillis()/1000;
   Set<String> seen=new HashSet<>();
   for(int i=0;i<devices.length();i++){
    JSONObject d=devices.getJSONObject(i);
    String kind=d.getString("kind");
    if(!Arrays.asList(KINDS).contains(kind)||!seen.add(kind))return false;
    if(!d.isNull("charge")&&(d.getInt("charge")<0||d.getInt("charge")>100))return false;
    if(d.optDouble("updatedAt",0)>now+60)return false;
   }
   c.getSharedPreferences("battery",0).edit().putString("snapshot",source.toString()).apply();return true;
  }catch(Exception e){return false;}
 }
 static String ownKind(){
  String m=Build.MODEL.replace('_','-');
  if(m.startsWith("SM-S918"))return "s23";if(m.startsWith("SM-S938"))return "s25";
  if(m.startsWith("SM-F956"))return "fold";if(m.startsWith("SM-X806"))return "tablet";return "";
 }
 static List<JSONObject> devices(Context c,JSONObject snapshot){
  List<JSONObject> result=new ArrayList<>();JSONArray source=snapshot.optJSONArray("devices");
  for(int n=0;n<KINDS.length;n++){
   JSONObject item=null;
   if(source!=null)for(int i=0;i<source.length();i++){JSONObject d=source.optJSONObject(i);if(d!=null&&KINDS[n].equals(d.optString("kind")))item=d;}
   try{
    if(item==null){item=new JSONObject();item.put("kind",KINDS[n]);item.put("name",NAMES[n]);item.put("charge",JSONObject.NULL);item.put("connected",false);}
    else item=new JSONObject(item.toString());
    if(KINDS[n].equals(ownKind())){
     Intent b=c.registerReceiver(null,new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
     if(b!=null){int level=b.getIntExtra(BatteryManager.EXTRA_LEVEL,-1),scale=b.getIntExtra(BatteryManager.EXTRA_SCALE,100),status=b.getIntExtra(BatteryManager.EXTRA_STATUS,0);
      item.put("charge",level<0?JSONObject.NULL:Math.round(level*100f/scale));item.put("charging",status==BatteryManager.BATTERY_STATUS_CHARGING);item.put("connected",true);item.put("updatedAt",System.currentTimeMillis()/1000.0);}
    }
   }catch(Exception ignored){}
   result.add(item);
  }
  return result;
 }
}
