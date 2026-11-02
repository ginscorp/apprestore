"""Invented battery cases; values and identifiers are unrelated to real devices."""
import unittest
from battery import normalize

class BatteryChecks(unittest.TestCase):
 def test_synthetic_shape_and_no_serial(self):
  row=normalize({'AppleRawMaxCapacity':2873,'AppleRawCurrentCapacity':2011,'MaxCapacity':93,'CurrentCapacity':70,'DesignCapacity':3217,'CycleCount':147,'Temperature':2713,'Voltage':3875,'InstantAmperage':-173,'Serial':'SYNTHETIC_SERIAL','OtherPrivate':'CANARY'})
  self.assertEqual(row['full_mah'],2873);self.assertEqual(row['temperature_c'],27.13);self.assertAlmostEqual(row['power_w'],-0.670375);self.assertEqual(len(row['pack_hash']),64);self.assertNotIn('CANARY',str(row));self.assertNotIn('SYNTHETIC_SERIAL',str(row))
 def test_percent_never_becomes_capacity(self):
  row=normalize({'MaxCapacity':93,'CurrentCapacity':47});self.assertIsNone(row['full_mah']);self.assertIsNone(row['design_mah'])
 def test_mac_nested_and_preference(self):
  row=normalize({'BatteryData':{'FullChargeCapacity':4721,'NominalChargeCapacity':4653,'DesignCapacity':5109,'AppleRawCurrentCapacity':3187},'CycleCount':71})
  self.assertEqual(row['full_mah'],4721);self.assertEqual(row['full_source'],'BatteryData.FullChargeCapacity');self.assertIsNone(row['temperature_c'])
 def test_signed_current_and_bad_data(self):
  row=normalize({'InstantAmperage':2**64-137,'Voltage':3750,'Temperature':float('nan'),'DesignCapacity':True,'AppleRawMaxCapacity':-1});self.assertEqual(row['current_ma'],-137);self.assertEqual(row['power_w'],-0.51375);self.assertIsNone(row['temperature_c']);self.assertIsNone(row['design_mah']);self.assertIsNone(row['full_mah'])
 def test_lifetime_units_and_missing_values(self):
  from battery import lifetime_values
  row=lifetime_values({'MinimumTemperature':-17,'MaximumTemperature':427,'AverageTemperature':263,'TotalOperatingTime':713,'MaximumDischargeCurrent':-1873,'TemperatureSamples':47,'Secret':'CANARY'})
  self.assertEqual((row['min_temp_c'],row['max_temp_c'],row['average_temp_c']),(-1.7,42.7,26.3));self.assertEqual(row['operating_hours'],713);self.assertEqual(row['max_discharge_ma'],-1873);self.assertNotIn('CANARY',str(row));self.assertIsNone(lifetime_values(None));self.assertIsNone(lifetime_values({'TotalOperatingTime':True})['operating_hours'])
 def test_invalid_nested_and_inverted_temperature(self):
  from battery import lifetime_values
  self.assertIsNone(normalize({'BatteryData':None})['full_mah']);self.assertIsNone(lifetime_values({'MinimumTemperature':77,'MaximumTemperature':23})['min_temp_c'])
