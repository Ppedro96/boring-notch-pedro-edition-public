package marketing.insight360.batteries;
import android.content.*;
import android.content.res.Configuration;
import android.graphics.*;
import org.json.*;
import java.util.*;

final class BatteryArtwork {
 static final int GREEN=Color.rgb(96,207,112),RED=Color.rgb(238,94,91);
 static Bitmap draw(Context context,int width,int height){
  boolean dark=(context.getResources().getConfiguration().uiMode&Configuration.UI_MODE_NIGHT_MASK)==Configuration.UI_MODE_NIGHT_YES;
  int primary=dark?Color.rgb(245,245,245):Color.rgb(35,37,40),secondary=dark?Color.rgb(164,168,174):Color.rgb(105,109,115);
  Bitmap b=Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888);Canvas c=new Canvas(b);Paint p=new Paint(3);
  java.util.List<JSONObject> list=BatteryData.devices(context,BatteryData.read(context));
  int cols=context.getSharedPreferences("battery",0).getInt("rows",1)==2?3:list.size(),rows=(list.size()+cols-1)/cols;
  float cellW=width/(float)cols,cellH=height/(float)rows;
  float radius=Math.max(18,Math.min(cellW*.34f,(cellH-48)*.46f));
  for(int i=0;i<list.size();i++){
   JSONObject d=list.get(i);int row=i/cols,col=i%cols,count=Math.min(cols,list.size()-row*cols);
   float x=(width-count*cellW)/2+cellW*(col+.5f),y=cellH*row+radius+7;
   int charge=d.optInt("charge",-1);boolean fresh=d.optBoolean("connected")&&System.currentTimeMillis()/1000.0-d.optDouble("updatedAt",0)<180;
   p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(5);p.setStrokeCap(Paint.Cap.ROUND);p.setColor(dark?0xFF44474C:0xFFE2E4E7);c.drawCircle(x,y,radius,p);
   if(charge>=0){p.setColor(fresh?(charge<=20?RED:GREEN):secondary);c.drawArc(new RectF(x-radius,y-radius,x+radius,y+radius),-90,Math.max(0,Math.min(100,charge))*3.6f,false,p);}
   glyph(c,p,d.optString("kind"),x,y,radius*.92f,fresh?primary:secondary);
   if(d.optBoolean("charging")&&fresh){p.setStyle(Paint.Style.FILL);p.setColor(GREEN);Path bolt=new Path();float bx=x+radius*.72f,by=y+radius*.65f;bolt.moveTo(bx+2,by-8);bolt.lineTo(bx-5,by+1);bolt.lineTo(bx,by+1);bolt.lineTo(bx-2,by+8);bolt.lineTo(bx+6,by-2);bolt.lineTo(bx+1,by-2);bolt.close();c.drawPath(bolt,p);}
   p.setStyle(Paint.Style.FILL);p.setColor(primary);p.setTextAlign(Paint.Align.CENTER);p.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));p.setTextSize(Math.min(29,cellW*.21f));
   c.drawText(charge<0?"—":charge+"%",x,y+radius+30,p);
   p.setColor(secondary);p.setTextSize(Math.min(18,cellW*.13f));p.setTypeface(Typeface.create("sans-serif-medium",0));
   c.drawText(d.optString("name"),x,y+radius+52,p);
   if(!fresh){p.setTextSize(14);c.drawText("Offline",x,y+radius+70,p);}
  }
  return b;
 }
 static void glyph(Canvas c,Paint p,String kind,float x,float y,float size,int color){
  c.save();c.translate(x,y);float w=size,h=size*1.08f;
  p.setColor(color);p.setStyle(Paint.Style.STROKE);p.setStrokeWidth(2.2f);p.setStrokeCap(Paint.Cap.ROUND);
  if(kind.equals("tablet")){c.drawRoundRect(-w*.62f,-h*.4f,w*.62f,h*.4f,4,4,p);c.drawCircle(-w*.52f,0,1,p);}
  else if(kind.equals("fold")){c.drawRoundRect(-w*.55f,-h*.52f,w*.55f,h*.52f,4,4,p);c.drawLine(0,-h*.47f,0,h*.47f,p);}
  else if(kind.equals("alienware")){
   Path lid=new Path();lid.moveTo(-w*.58f,-h*.4f);lid.lineTo(w*.58f,-h*.4f);lid.lineTo(w*.62f,h*.25f);lid.lineTo(-w*.62f,h*.25f);lid.close();c.drawPath(lid,p);
   Path base=new Path();base.moveTo(-w*.72f,h*.34f);base.lineTo(w*.72f,h*.34f);base.lineTo(w*.55f,h*.44f);base.lineTo(-w*.55f,h*.44f);base.close();c.drawPath(base,p);
   c.drawOval(new RectF(-w*.18f,-h*.25f,w*.18f,h*.12f),p);
   p.setStyle(Paint.Style.FILL);c.drawOval(new RectF(-w*.12f,-h*.12f,-w*.025f,-h*.025f),p);c.drawOval(new RectF(w*.025f,-h*.12f,w*.12f,-h*.025f),p);
  }
  else if(kind.equals("mac")){c.drawRoundRect(-w*.58f,-h*.4f,w*.58f,h*.28f,3,3,p);c.drawLine(-w*.72f,h*.4f,w*.72f,h*.4f,p);}
  else{float r=kind.equals("s23")?2:7;c.drawRoundRect(-w*.4f,-h*.58f,w*.4f,h*.58f,r,r,p);c.drawCircle(0,-h*.44f,1,p);p.setStyle(Paint.Style.FILL);p.setTextAlign(Paint.Align.CENTER);p.setTypeface(Typeface.create("sans-serif-medium",Typeface.BOLD));p.setTextSize(w*.31f);c.drawText(kind.equals("s23")?"S23":"S25",0,h*.16f,p);}
  c.restore();
 }
}
