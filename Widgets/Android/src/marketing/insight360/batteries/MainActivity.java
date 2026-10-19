package marketing.insight360.batteries;
import android.app.*;
import android.appwidget.*;
import android.content.*;
import android.os.Bundle;
import android.graphics.Color;
import android.view.View;
import android.widget.*;
public class MainActivity extends Activity {
 @Override public void onCreate(Bundle state){super.onCreate(state);show();if(android.os.Build.VERSION.SDK_INT>=33&&checkSelfPermission("android.permission.POST_NOTIFICATIONS")!=0)requestPermissions(new String[]{"android.permission.POST_NOTIFICATIONS"},1);if(getIntent().getBooleanExtra("pin",false))pin();}
 @Override public void onResume(){super.onResume();show();BatteryWidget.updateAll(this);BatterySyncService.start(this);}
 void show(){
  boolean dark=(getResources().getConfiguration().uiMode&48)==32;
  LinearLayout layout=new LinearLayout(this);layout.setOrientation(1);layout.setPadding(36,44,36,24);layout.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener(){public android.view.WindowInsets onApplyWindowInsets(View view,android.view.WindowInsets insets){view.setPadding(36,24+insets.getSystemWindowInsetTop(),36,24+insets.getSystemWindowInsetBottom());return insets;}});layout.setBackgroundColor(dark?0xFF18191B:0xFFF5F5F5);
  TextView title=new TextView(this);title.setText("Baterias Insight");title.setTextSize(25);title.setTextColor(dark?Color.WHITE:Color.BLACK);layout.addView(title);
  ImageView image=new ImageView(this);image.setImageBitmap(BatteryArtwork.draw(this,900,getSharedPreferences("battery",0).getInt("rows",1)==2?500:300));image.setAdjustViewBounds(true);layout.addView(image,new LinearLayout.LayoutParams(-1,-2));
  TextView help=new TextView(this);help.setText("MacBook Pro, Alienware e seus quatro Galaxy.\nAs baterias sincronizam pela internet, mesmo com o Mac desligado. Sem conexão, mostramos a última leitura; a bateria deste aparelho é lida localmente.\n\nAdicione o widget à tela inicial e ajuste seu tamanho.");help.setTextSize(15);help.setTextColor(dark?0xFFBBBBBB:0xFF555555);help.setPadding(0,24,0,24);layout.addView(help);
  TextView status=new TextView(this);status.setText(BatteryNetwork.configured(this)?(getSharedPreferences("network",0).contains("lastError")?getSharedPreferences("network",0).getString("lastError",""):"Conectado à central"):"Aguardando configuração da central");status.setTextColor(dark?0xFFBBBBBB:0xFF555555);layout.addView(status);
  Switch sync=new Switch(this);sync.setText("Sincronizar em segundo plano");sync.setTextColor(dark?Color.WHITE:Color.BLACK);sync.setChecked(BatteryNetwork.enabled(this));sync.setEnabled(BatteryNetwork.configured(this));sync.setOnCheckedChangeListener(new CompoundButton.OnCheckedChangeListener(){public void onCheckedChanged(CompoundButton button,boolean checked){getSharedPreferences("network",0).edit().putBoolean("enabled",checked).apply();if(checked)BatterySyncService.start(MainActivity.this);else stopService(new Intent(MainActivity.this,BatterySyncService.class));BatterySyncService.schedule(MainActivity.this);}});layout.addView(sync);
  RadioGroup choices=new RadioGroup(this);choices.setOrientation(RadioGroup.HORIZONTAL);
  RadioButton one=new RadioButton(this);one.setId(101);one.setText("Uma linha");one.setTextColor(dark?Color.WHITE:Color.BLACK);choices.addView(one);
  RadioButton two=new RadioButton(this);two.setId(102);two.setText("Duas linhas");two.setTextColor(dark?Color.WHITE:Color.BLACK);choices.addView(two);
  choices.check(getSharedPreferences("battery",0).getInt("rows",1)==2?102:101);
  choices.setOnCheckedChangeListener(new RadioGroup.OnCheckedChangeListener(){public void onCheckedChanged(RadioGroup group,int id){getSharedPreferences("battery",0).edit().putInt("rows",id==102?2:1).apply();BatteryWidget.updateAll(MainActivity.this);image.setImageBitmap(BatteryArtwork.draw(MainActivity.this,900,id==102?500:300));}});
  layout.addView(choices);
  Button add=new Button(this);add.setText("Adicionar widget");add.setOnClickListener(new View.OnClickListener(){public void onClick(View v){pin();}});layout.addView(add);
  Button refresh=new Button(this);refresh.setText("Sincronizar agora");refresh.setOnClickListener(new View.OnClickListener(){public void onClick(View v){new Thread(new Runnable(){public void run(){BatteryNetwork.sync(getApplicationContext());runOnUiThread(new Runnable(){public void run(){show();}});}}).start();}});layout.addView(refresh);setContentView(layout);layout.requestApplyInsets();
 }
 void pin(){AppWidgetManager m=AppWidgetManager.getInstance(this);if(m.isRequestPinAppWidgetSupported())m.requestPinAppWidget(new ComponentName(this,BatteryWidget.class),null,null);else Toast.makeText(this,"Toque e segure a tela inicial → Widgets → Baterias Insight",Toast.LENGTH_LONG).show();}
}
