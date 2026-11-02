"""Synthetic identity fixtures only; zero IMEI and locally administered dummy MAC."""
import unittest
from device_inventory import fields_from,LOCKDOWN_FIELDS,scalar,cellular_fields
class InventoryChecks(unittest.TestCase):
 def test_hardware_identifiers_allowed_secrets_excluded(self):
  data={'SerialNumber':'SYNTHETIC_SERIAL','InternationalMobileEquipmentIdentity':'000000000000000','WiFiAddress':'02:00:00:00:00:01','ProductVersion':'26.7.1','AppleID':'PRIVATE_CANARY','PhoneNumber':'PRIVATE_CANARY','Password':'PRIVATE_CANARY','HostPrivateKey':'PRIVATE_CANARY','PairRecordData':b'PRIVATE_CANARY'}
  result=fields_from(data,LOCKDOWN_FIELDS,'fixture');self.assertEqual(len(result),4);self.assertNotIn('PRIVATE_CANARY',str(result));self.assertIn('SYNTHETIC_SERIAL',str(result))
 def test_untrusted_values_bounded(self):
  for value in [float('nan'),float('inf'),{},b'opaque','x'*257,'line\nvalue',[{}],[1]*9]:self.assertIsNone(scalar(value))
  self.assertEqual(scalar(False),'false');self.assertEqual(scalar([1,2]),'1, 2')

 def test_sim_and_carrier_only_allowlisted_scalars(self):
  result=cellular_fields({'CarrierBundleInfo':[{'CarrierName':'Fixture Carrier','CFBundleVersion':'73.0','MobileCountryCode':'999','Password':'CANARY_SECRET'}],'SIMInfo':[{'ICCID':'SYNTHETIC_ICCID','EID':'SYNTHETIC_EID','InternationalMobileSubscriberIdentity':'CANARY_SECRET','PhoneNumber':'CANARY_SECRET'}]})
  self.assertEqual(len(result),5);self.assertNotIn('CANARY_SECRET',str(result));self.assertTrue(any(x['key'].endswith('.ICCID') for x in result))
 def test_nested_carrier_data_is_bounded(self):
  result=cellular_fields({'CarrierBundleInfo':[{'CarrierName':'Fixture'}]*100})
  self.assertEqual(len(result),4);self.assertEqual(cellular_fields({'CarrierBundleInfo':'untrusted'}),[])

class DirectQueryChecks(unittest.IsolatedAsyncioTestCase):
 async def test_model_missing_in_snapshot_is_returned_directly(self):
  from device_inventory import direct_fields
  class Device:
   def __init__(self):self.queried=[]
   async def get_value(self,key=None):
    self.queried.append(key)
    if key=='RegulatoryModelNumber':return 'A2221'
    if key=='RegionCode':return 'RU'
    if key=='DeviceVariant':return 'fixture_variant'
    raise ValueError('unsupported')
  device=Device();fields,status=await direct_fields(device,{'ModelNumber':'FIXTURE'})
  self.assertEqual(fields['RegulatoryModelNumber'],'A2221');self.assertEqual(status,'complete')
  self.assertNotIn('Password',device.queried);self.assertNotIn('AppleID',device.queried);self.assertNotIn('PairRecordData',device.queried)
  self.assertEqual(fields['DeviceVariant'],'fixture_variant')
 async def test_invalid_model_and_opaque_values_not_exported(self):
  from device_inventory import direct_fields
  class Device:
   async def get_value(self,key=None):
    if key=='RegulatoryModelNumber':return 'A2221\nCANARY'
    if key=='SEID':return b'\x01\x02'
    return {'Password':'CANARY'}
  fields,_=await direct_fields(Device(),{})
  self.assertNotIn('RegulatoryModelNumber',fields);self.assertEqual(fields['SEID'],'0102')
  self.assertNotIn('Password',str(fields_from(fields,LOCKDOWN_FIELDS,'fixture')))
