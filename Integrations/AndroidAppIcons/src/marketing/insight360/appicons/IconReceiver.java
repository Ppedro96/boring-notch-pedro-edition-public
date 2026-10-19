package marketing.insight360.appicons;
import android.content.*;
import android.content.pm.*;
import android.graphics.*;
import android.graphics.drawable.Drawable;
import org.json.JSONObject;
import java.io.*;

/** Shell-only icon export. No network, accounts, notification or accessibility permissions. */
public final class IconReceiver extends BroadcastReceiver {
  @Override public void onReceive(Context context, Intent intent) {
    String name=intent.getStringExtra("package");
    if(name==null || !name.matches("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+")) { setResultCode(2); return; }
    try {
      PackageManager pm=context.getPackageManager();
      if(pm.getLaunchIntentForPackage(name)==null) throw new Exception("App sem launcher");
      ApplicationInfo info=pm.getApplicationInfo(name,0);
      Drawable drawable=pm.getApplicationIcon(info);
      Bitmap bitmap=Bitmap.createBitmap(512,512,Bitmap.Config.ARGB_8888);
      Canvas canvas=new Canvas(bitmap); drawable.setBounds(0,0,512,512);drawable.draw(canvas);
      File directory=new File(context.getExternalFilesDir(null),"icons"); directory.mkdirs();
      File image=new File(directory,name+".png");
      try(FileOutputStream out=new FileOutputStream(image)){bitmap.compress(Bitmap.CompressFormat.PNG,100,out);}
      JSONObject meta=new JSONObject();meta.put("id",name);meta.put("name",pm.getApplicationLabel(info).toString());
      try(Writer out=new OutputStreamWriter(new FileOutputStream(new File(directory,name+".json")),"UTF-8")){out.write(meta.toString());}
      setResultCode(0);
    } catch(Exception error){setResultCode(1);setResultData(error.getClass().getSimpleName());}
  }
}
