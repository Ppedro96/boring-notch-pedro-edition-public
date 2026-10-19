package marketing.insight360.batteries;
import android.app.*;
import android.appwidget.*;
import android.content.*;
import android.os.Bundle;
import android.widget.RemoteViews;
import org.json.*;
import java.text.SimpleDateFormat;
import java.util.*;

public class BatteryWidget extends AppWidgetProvider {
 static void updateAll(Context c){AppWidgetManager m=AppWidgetManager.getInstance(c);int[] ids=m.getAppWidgetIds(new ComponentName(c,BatteryWidget.class));for(int id:ids)update(c,m,id);}
 static void update(Context c,AppWidgetManager m,int id){
  Bundle options=m.getAppWidgetOptions(id);int wd=options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH,320),hd=options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT,180);
  int width=Math.max(500,Math.min(1200,wd*2)),height=c.getSharedPreferences("battery",0).getInt("rows",1)==2?width*5/9:width/3;
  RemoteViews views=new RemoteViews(c.getPackageName(),R.layout.battery_widget);views.setImageViewBitmap(R.id.battery_image,BatteryArtwork.draw(c,width,height));
  JSONObject value=BatteryData.read(c);long timestamp=(long)(value.optDouble("updatedAt",0)*1000);boolean stale=System.currentTimeMillis()-timestamp>180000;
  String label=timestamp==0?"Abra Baterias Insight para conectar":(stale?"Última leitura ":"Atualizado ")+new SimpleDateFormat("HH:mm",Locale.getDefault()).format(new Date(timestamp))+(stale?" · Sem atualização recente":"");
  views.setTextViewText(R.id.updated,label);
  Intent activity=new Intent(c,MainActivity.class);PendingIntent action=PendingIntent.getActivity(c,0,activity,PendingIntent.FLAG_UPDATE_CURRENT|PendingIntent.FLAG_IMMUTABLE);
  views.setOnClickPendingIntent(R.id.battery_image,action);m.updateAppWidget(id,views);
 }
 @Override public void onUpdate(Context c,AppWidgetManager m,int[] ids){for(int id:ids)update(c,m,id);}
 @Override public void onAppWidgetOptionsChanged(Context c,AppWidgetManager m,int id,Bundle options){update(c,m,id);}
}
