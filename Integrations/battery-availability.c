/* Keep the battery bridge available on AC while allowing display sleep.
 * The clamshell selector is defined as kPMSetClamshellSleepState in Apple's
 * IOPMLibDefs.h / RootDomainUserClient.cpp. No global pmset/SIP/TCC changes.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/pwr_mgt/IOPMLibDefs.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
static volatile sig_atomic_t running=1;
static io_connect_t power=0;
static IOPMAssertionID assertion=kIOPMNullAssertionID;
static bool owned=false;
static void stop(int value){running=0;}
static bool property(io_registry_entry_t entry,CFStringRef key,bool fallback){
 CFTypeRef value=IORegistryEntryCreateCFProperty(entry,key,kCFAllocatorDefault,0);
 bool result=value&&CFGetTypeID(value)==CFBooleanGetTypeID()?CFBooleanGetValue(value):fallback;
 if(value)CFRelease(value);return result;
}
static bool acPower(void){
 io_service_t battery=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSmartBattery"));
 if(!battery)return false;
 bool result=property(battery,CFSTR("ExternalConnected"),false);IOObjectRelease(battery);return result;
}
static IOReturn clamshell(bool prevent){
 uint64_t input=prevent?1:0;
 return IOConnectCallScalarMethod(power,kPMSetClamshellSleepState,&input,1,NULL,NULL);
}
static void release(void){
 if(owned){clamshell(false);owned=false;}
 if(assertion!=kIOPMNullAssertionID){IOPMAssertionRelease(assertion);assertion=kIOPMNullAssertionID;}
}
int main(int argc,char**argv){
 if(argc!=2)return 2;
 signal(SIGTERM,stop);signal(SIGINT,stop);signal(SIGHUP,stop);
 power=IOPMFindPowerManagement(MACH_PORT_NULL);if(!power)return 3;
 umask(0077);atexit(release);
 io_registry_entry_t root=IORegistryEntryFromPath(kIOMainPortDefault,"IOPower:/IOPowerConnection/IOPMrootDomain");
 while(running){
  bool ac=acPower();IOReturn result=0;
  if(ac){
   if(assertion==kIOPMNullAssertionID)result=IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep,kIOPMAssertionLevelOn,CFSTR("Insight Batteries: synchronization on AC power"),&assertion);
   IOReturn lid=clamshell(true);if(result==0)result=lid;owned=lid==0;
  }else release();
  bool lidClosed=root?property(root,CFSTR("AppleClamshellState"),false):false;
  bool lidBlocked=root?!property(root,CFSTR("AppleClamshellCausesSleep"),true):false;
  char temporary[4096];snprintf(temporary,sizeof(temporary),"%s.tmp",argv[1]);
  FILE*file=fopen(temporary,"w");
  if(file){fprintf(file,"{\"updatedAt\":%ld,\"acPower\":%s,\"active\":%s,\"lidClosed\":%s,\"lidSleepBlocked\":%s,\"result\":%u}\n",time(NULL),ac?"true":"false",ac&&assertion!=kIOPMNullAssertionID?"true":"false",lidClosed?"true":"false",lidBlocked?"true":"false",result);fclose(file);rename(temporary,argv[1]);}
  for(int i=0;i<10&&running;i++)sleep(1);
 }
 release();if(root)IOObjectRelease(root);IOServiceClose(power);power=0;return 0;
}
