package marketing.insight360.batteries;
import android.app.job.*;
public class BatterySyncJob extends JobService {
 @Override public boolean onStartJob(JobParameters p){new Thread(new Runnable(){public void run(){BatteryNetwork.sync(getApplicationContext());jobFinished(p,false);}},"battery-job").start();return true;}
 @Override public boolean onStopJob(JobParameters p){return true;}
}
