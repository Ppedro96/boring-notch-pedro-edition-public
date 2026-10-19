package marketing.insight360.adbkeeper;
/** Pure policy: never enable master developer/USB options or bypass Android trust checks. */
final class RecoveryPolicy {
 static boolean shouldAttempt(boolean active,boolean permission,boolean wifi,boolean developer,boolean usb,boolean wireless,int attempts){
  return active&&permission&&wifi&&developer&&usb&&!wireless&&attempts<3;
 }
}
