package marketing.insight360.adbkeeper;
import android.app.*;import android.content.*;import android.content.pm.PackageManager;import android.os.*;import android.view.*;import android.widget.*;
public class MainActivity extends Activity {
 TextView status;
 @Override public void onCreate(Bundle b){super.onCreate(b);show();}
 @Override public void onResume(){super.onResume();show();}
 void enable(){
  if(!KeeperService.permission(this)){Toast.makeText(this,"Falta a autorização inicial pelo Mac",Toast.LENGTH_LONG).show();return;}
  getSharedPreferences("keeper",0).edit().putBoolean("enabled",true).apply();startForegroundService(new Intent(this,KeeperService.class));
  if(Build.VERSION.SDK_INT>=33&&checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)requestPermissions(new String[]{android.Manifest.permission.POST_NOTIFICATIONS},2);
  show();
 }
 void show(){
  final boolean dark=(getResources().getConfiguration().uiMode&48)==32;int fg=dark?0xFFF5F5F5:0xFF202124;
  LinearLayout root=new LinearLayout(this);root.setOrientation(1);root.setBackgroundColor(dark?0xFF18191B:0xFFF5F5F5);root.setPadding(40,60,40,32);
  root.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener(){public WindowInsets onApplyWindowInsets(View v,WindowInsets insets){v.setPadding(40,24+insets.getSystemWindowInsetTop(),40,24+insets.getSystemWindowInsetBottom());return insets;}});
  TextView title=new TextView(this);title.setText("Depuração Insight");title.setTextSize(25);title.setTextColor(fg);root.addView(title);
  TextView help=new TextView(this);help.setText("Reativa a depuração sem fio quando o tablet recupera o Wi-Fi. Funciona no próprio tablet, mesmo quando o Mac perde a conexão.\n\nAutorize suas redes no diálogo do Android. Novos computadores continuam exigindo pareamento. A opção Pausar interrompe a recuperação sem desligar sua conexão atual.");help.setTextSize(16);help.setTextColor(fg);help.setPadding(0,24,0,24);root.addView(help);
  status=new TextView(this);status.setTextColor(fg);status.setTextSize(15);status.setText((KeeperService.permission(this)?"Permissão inicial concedida":"Permissão inicial pendente")+"\n"+getSharedPreferences("keeper",0).getString("status","Recuperação ainda não ativada"));root.addView(status);
  Button start=new Button(this);start.setText("Ativar recuperação automática");start.setOnClickListener(new View.OnClickListener(){public void onClick(View v){enable();}});root.addView(start);
  Button pause=new Button(this);pause.setText("Pausar recuperação");pause.setOnClickListener(new View.OnClickListener(){public void onClick(View v){getSharedPreferences("keeper",0).edit().putBoolean("enabled",false).putString("status","Recuperação pausada").apply();stopService(new Intent(MainActivity.this,KeeperService.class));show();}});root.addView(pause);
  Button settings=new Button(this);settings.setText("Abrir depuração do Android");settings.setOnClickListener(new View.OnClickListener(){public void onClick(View v){try{startActivity(new Intent("android.settings.WIRELESS_DEBUGGING_SETTINGS"));}catch(RuntimeException e){startActivity(new Intent(android.provider.Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS));}}});root.addView(settings);
  setContentView(root);root.requestApplyInsets();
 }
}
