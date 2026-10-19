package marketing.insight360.adbkeeper;
public class RecoveryPolicyTests {
 public static void main(String[] args){
  check(RecoveryPolicy.shouldAttempt(true,true,true,true,true,false,0),"recovers when enabled on Wi-Fi");
  check(!RecoveryPolicy.shouldAttempt(false,true,true,true,true,false,0),"pause respected");
  check(!RecoveryPolicy.shouldAttempt(true,false,true,true,true,false,0),"permission required");
  check(!RecoveryPolicy.shouldAttempt(true,true,false,true,true,false,0),"no recovery off Wi-Fi");
  check(!RecoveryPolicy.shouldAttempt(true,true,true,false,true,false,0),"master developer off respected");
  check(!RecoveryPolicy.shouldAttempt(true,true,true,true,false,false,0),"USB debugging off respected");
  check(!RecoveryPolicy.shouldAttempt(true,true,true,true,true,true,0),"no redundant writes");
  check(!RecoveryPolicy.shouldAttempt(true,true,true,true,true,false,3),"untrusted network retry bounded");
  System.out.println("ADB Keeper: 8 recovery policy checks passed");
 }
 static void check(boolean v,String message){if(!v)throw new AssertionError(message);}
}
