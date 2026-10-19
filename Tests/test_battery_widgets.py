import importlib.util
from pathlib import Path
import unittest
spec=importlib.util.spec_from_file_location('battery_widgets',Path(__file__).parents[1]/'Integrations/battery-widgets.py')
widget=importlib.util.module_from_spec(spec);spec.loader.exec_module(widget)
class BatterySnapshotTests(unittest.TestCase):
 def test_only_battery_fields_leave_mac(self):
  source={'devices':[{'id':'phone','kind':'s23','name':'S23 Ultra','charge':79,'charging':False,'connected':True,'updatedAt':10,'notifications':['private'],'messages':'private'}, {'kind':'unknown','charge':10}]}
  result=widget.build_snapshot(source,{'kind':'mac'},100,True)
  self.assertEqual(len(result['devices']),2)
  self.assertNotIn('notifications',result['devices'][1]);self.assertNotIn('messages',result['devices'][1])
 def test_dead_notch_keeps_last_reading_offline(self):
  phone={'kind':'s25','charge':90,'connected':True,'updatedAt':10}
  result=widget.build_snapshot({'devices':[phone]}, {},100,False)['devices'][1]
  self.assertFalse(result['connected']);self.assertEqual(result['charge'],90);self.assertEqual(result['updatedAt'],10)
 def test_disconnected_phone_does_not_get_new_timestamp(self):
  result=widget.build_snapshot({'devices':[{'kind':'fold','connected':False,'updatedAt':10}]},{},100,True)['devices'][1]
  self.assertEqual(result['updatedAt'],10);self.assertFalse(result['connected'])
 def test_independent_collector_uses_only_known_devices_and_battery_fields(self):
  ident='demo_s25'
  current={'devices':[{'id':ident,'paired':True,'reachable':True,'charge':88,'charging':False,'notifications':['secret']},{'id':'other','paired':True,'reachable':True,'charge':4}]}
  values=widget.normalize_devices(current,{},100)['devices']
  self.assertEqual(len(values),4)
  phone=next(d for d in values if d['id']==ident)
  self.assertTrue(phone['connected']);self.assertEqual(phone['updatedAt'],100);self.assertNotIn('notifications',phone)
 def test_missing_device_retains_charge_without_claiming_freshness(self):
  ident='demo_s23'
  previous={'devices':[{'id':ident,'charge':78,'charging':True,'updatedAt':20}]}
  phone=next(d for d in widget.normalize_devices({},previous,100)['devices'] if d['id']==ident)
  self.assertEqual(phone['charge'],78);self.assertEqual(phone['updatedAt'],20);self.assertFalse(phone['connected'])
 def test_invalid_charge_does_not_replace_last_reading(self):
  ident='demo_s25'
  current={'devices':[{'id':ident,'paired':True,'reachable':True,'charge':1000}]}
  phone=next(d for d in widget.normalize_devices(current,{'devices':[{'id':ident,'charge':88,'updatedAt':40}]},100)['devices'] if d['id']==ident)
  self.assertEqual(phone['charge'],88);self.assertFalse(phone['connected']);self.assertEqual(phone['updatedAt'],40)
 def test_cloud_snapshot_preserves_device_timestamp(self):
  now=1000
  source={'devices':[{'kind':kind,'charge':50,'charging':False,'connected':True,'updatedAt':900} for kind in ('mac','s23','s25','fold','tablet')]}
  value=widget.validate_hub_snapshot(source,now)
  self.assertTrue(value['devices'][1]['connected']);self.assertEqual(value['devices'][1]['updatedAt'],900)
  value=widget.validate_hub_snapshot(source,1100);self.assertFalse(value['devices'][1]['connected'])
 def test_cloud_snapshot_rejects_missing_or_duplicate_devices(self):
  with self.assertRaises(ValueError):widget.validate_hub_snapshot({'devices':[]},1000)
  with self.assertRaises(ValueError):widget.validate_hub_snapshot({'devices':[{'kind':'mac','charge':50,'updatedAt':900}]*5},1000)
 def test_alienware_is_accepted_from_hub_but_excluded_on_mac(self):
  source={'devices':[{'kind':kind,'charge':78,'charging':False,'connected':True,'updatedAt':990} for kind in ('mac','alienware','s23','s25','fold','tablet')]}
  result=widget.validate_hub_snapshot(source,1000)
  self.assertEqual(len(result['devices']),5);self.assertNotIn('alienware',[d['kind'] for d in result['devices']])
if __name__=='__main__':unittest.main()
