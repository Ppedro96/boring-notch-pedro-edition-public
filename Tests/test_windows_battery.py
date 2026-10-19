import importlib.util,unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('windows_battery',Path(__file__).parents[1]/'Integrations/battery-hub/windows-publisher.py');w=importlib.util.module_from_spec(spec);spec.loader.exec_module(w)
class WindowsBatteryTests(unittest.TestCase):
 def test_charging_uses_native_flag_not_just_ac(self):
  s=w.PowerStatus();s.ac=1;s.flags=1;s.percent=78
  self.assertEqual(w.payload(s),{'charge':78,'charging':False})
  s.flags=9;self.assertEqual(w.payload(s),{'charge':78,'charging':True})
 def test_unknown_or_missing_battery_is_never_published_as_fresh(self):
  for flag,charge in ((255,78),(128,78),(1,255)):
   s=w.PowerStatus();s.flags=flag;s.percent=charge
   with self.assertRaises(ValueError):w.payload(s)
if __name__=='__main__':unittest.main()
