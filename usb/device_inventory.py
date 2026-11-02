"""Bounded technical inventory after existing USB trust. Never enumerate user content or pairing secrets."""
import asyncio, math, re
from battery import read_battery
from device_storage import read_storage, available_bytes
from content_counts import read_content_counts, passport_fields

# Owner-authorized technical/SIM identifiers. Exclude phone numbers, accounts and secrets.
LOCKDOWN_FIELDS={
 'DeviceName':'identity','SerialNumber':'identity','UniqueDeviceID':'identity','UniqueChipID':'identity',
 'InternationalMobileEquipmentIdentity':'identity','InternationalMobileEquipmentIdentity2':'identity','MobileEquipmentIdentifier':'identity',
 'ProductType':'hardware','ProductName':'hardware','DeviceClass':'hardware','HardwareModel':'hardware','HardwarePlatform':'hardware','ModelNumber':'hardware','RegionInfo':'hardware','RegionCode':'hardware','CPUArchitecture':'hardware','ChipID':'hardware','BoardId':'hardware','ChipSerialNo':'hardware',
 'ProductVersion':'system','BuildVersion':'system','FirmwareVersion':'system','BasebandVersion':'system','BasebandStatus':'system','BootloaderVersion':'system','ProtocolVersion':'system','ProductionSOC':'hardware','ReleaseType':'system','DeviceVariant':'hardware','SupportedDeviceFamilies':'hardware',
 'WiFiAddress':'network','BluetoothAddress':'network','EthernetAddress':'network','ActiveWirelessTechnology':'network','HasSiDP':'network','TelephonyCapability':'hardware',
 'BatteryCurrentCapacity':'battery','BatteryIsCharging':'battery','BatterySerialNumber':'battery','BatteryVoltage':'battery',
 'ActivationState':'system','DeviceColor':'hardware','DeviceEnclosureColor':'hardware','BoardSerialNumber':'components','MLBSerialNumber':'components','SensorSerialNumber':'components','FrontCameraModuleSerialNumber':'components','RearCameraModuleSerialNumber':'components',
 'DisplaySerialNumber':'components','ScreenSerialNumber':'components','CameraSerialNumber':'components','FrontCameraSerialNumber':'components','RearCameraSerialNumber':'components','ProximitySensorSerialNumber':'components','AmbientLightSensorSerialNumber':'components','TouchIDSerialNumber':'components','FaceIDSerialNumber':'components',
}
LOCKDOWN_FIELDS.update({
 'RegulatoryModelNumber':'hardware','PartNumber':'hardware',
 'IntegratedCircuitCardIdentity':'identity','IntegratedCircuitCardIdentity2':'identity',
 'ICCID':'identity','EID':'identity','EUICCIdentifier':'identity','SEID':'identity',
 'SIMStatus':'network','SIMTrayStatus':'network','CarrierName':'network','CarrierBundleVersion':'network',
 'MobileCountryCode':'network','MobileNetworkCode':'network','CurrentMCC':'network','CurrentMNC':'network',
 'RadioAccessTechnology':'network','NetworkName':'network','CarrierLock':'network',
})
LOCKDOWN_FIELDS.update({
 'CarrierSettingsVersion':'network','CurrentCarrier':'network','CarrierMCC':'network','CarrierMNC':'network',
 'WiFiNetworkName':'network','WiFiBSSID':'network','WiFiIPAddress':'network','WiFiIPv6Address':'network',
 'VPNStatus':'network','VPNActive':'network','ExternalIPAddress':'network',
 'WarrantyExpirationDate':'system','LimitedWarrantyExpires':'system',
})
async def direct_fields(ld,values):
 result={};started=asyncio.get_running_loop().time()
 keys=list(dict.fromkeys(['RegulatoryModelNumber','RegionCode','PartNumber','CarrierBundleInfo','SIMInfo','TelephonyInfo']+list(LOCKDOWN_FIELDS)))
 for key in keys:
  if key in values:continue
  remaining=8-(asyncio.get_running_loop().time()-started)
  if remaining<=0:return result,'query_budget_reached'
  try:
   value=await asyncio.wait_for(ld.get_value(key=key),timeout=min(2,remaining))
   if key=='RegulatoryModelNumber' and (not isinstance(value,str) or not re.fullmatch(r'A[0-9]{4}',value)):continue
   if key=='SEID' and isinstance(value,bytes) and 0<len(value)<=64:value=value.hex().upper()
   if key in {'CarrierBundleInfo','SIMInfo','TelephonyInfo'}:
    if isinstance(value,(dict,list)):result[key]=value
   elif scalar(value) is not None:result[key]=value
  except asyncio.TimeoutError:return result,'query_budget_reached'
  except Exception:continue
 return result,'complete'

CARRIER_FIELDS={k:'network' for k in ('CFBundleIdentifier','CFBundleVersion','CarrierName','CarrierBundleVersion','MobileCountryCode','MobileNetworkCode','MCC','MNC','GID1','GID2','RadioAccessTechnology','SIMStatus')}
SIM_FIELDS={**CARRIER_FIELDS,**{k:'identity' for k in ('IntegratedCircuitCardIdentity','ICCID','EID','EUICCIdentifier','InternationalMobileEquipmentIdentity')}}
def cellular_fields(values):
 result=[]
 for key,allowed in [('CarrierBundleInfo',CARRIER_FIELDS),('SIMInfo',SIM_FIELDS),('TelephonyInfo',SIM_FIELDS)]:
  rows=values.get(key,[])
  if isinstance(rows,dict):rows=[rows]
  if isinstance(rows,list):
   for n,row in enumerate(rows[:4]):result+=fields_from(row,allowed,'apple_lockdown',prefix=f'{key}.{n+1}.')
 return result
GESTALT_FIELDS={k:v for k,v in LOCKDOWN_FIELDS.items() if k not in {'DeviceName','UniqueDeviceID'}}
GESTALT_FIELDS.update({'AccelerometerCapability':'hardware','GyroscopeCapability':'hardware','AmbientLightSensorCapability':'hardware','ProximitySensorCapability':'hardware','MagnetometerCapability':'hardware','BarometerCapability':'hardware','NFC':'hardware','DeviceSupportsFaceTime':'hardware','DeviceSupportsSimultaneousVoiceAndData':'hardware','RAMSize':'hardware','MarketingProductName':'hardware'})
WIFI_FIELDS={'IOInterfaceState','IOInterfaceUnit','IO80211RSSI','IO80211Noise','IO80211CurrentChannel','IO80211Channel','CurrentPowerState','IO80211SSID','IO80211BSSID','SSID','BSSID','IPAddress','IPv6Address'}

def scalar(value):
 if isinstance(value,bool):return 'true' if value else 'false'
 if isinstance(value,(int,float)) and math.isfinite(value) and abs(value)<=2**64:return str(value)
 if isinstance(value,str) and 0<len(value)<=256 and not any(ord(c)<32 for c in value):return value
 if isinstance(value,list) and len(value)<=8 and all(isinstance(x,(int,str)) and not isinstance(x,bool) and len(str(x))<=24 for x in value):return ', '.join(map(str,value))
 return None

def fields_from(values,allowed,source,prefix=''):
 if not isinstance(values,dict):return []
 result=[]
 for key,section in allowed.items():
  value=scalar(values.get(key))
  if value is not None:result.append({'key':prefix+key,'section':section,'value':value,'source':source})
 return result

async def inventory(ld):
 from pymobiledevice3.services.diagnostics import DiagnosticsService
 values=ld.all_values;fields=fields_from(values,LOCKDOWN_FIELDS,'apple_lockdown')+cellular_fields(values)
 statuses={};battery={};disk={}
 # Root GetValue omits some keys which still support individual reads.
 direct,query_status=await direct_fields(ld,values)
 values={**values,**direct}
 fields+=fields_from(direct,LOCKDOWN_FIELDS,'apple_lockdown_direct')+cellular_fields(direct)
 if query_status!='complete':statuses['direct_queries']=query_status
 model=values.get('ModelNumber');region=values.get('RegionInfo')
 if not values.get('PartNumber') and isinstance(model,str) and isinstance(region,str) and re.fullmatch(r'[A-Z0-9]{3,20}',model) and re.fullmatch(r'[A-Z]{1,3}/[A-Z]',region):
  fields.append({'key':'PartNumber','section':'hardware','value':model+region,'source':'apple_lockdown_parts'})
 try:
  disk=await read_storage(ld,settings_timeout=2)
  fields+=fields_from(disk,{k:'storage' for k in disk if not k.startswith(('AFC','Settings'))},'apple_disk_usage')
  fields+=fields_from(disk,{k:'storage' for k in disk if k.startswith('AFC')},'apple_afc_filesystem')
  fields+=fields_from(disk,{k:'storage' for k in disk if k.startswith('Settings')},'apple_settings_cachedelete')
  if available_bytes(disk) is None:statuses['storage']='unavailable'
 except Exception:statuses['storage']='unavailable'
 try:
  battery=await asyncio.wait_for(read_battery(ld),timeout=8)
  if battery.get('transient_battery_serial'):fields+=fields_from({'BatterySerialNumber':battery['transient_battery_serial']},{'BatterySerialNumber':'battery'},'apple_iopmpowersource')
  statuses['battery']='available'
 except Exception:statuses['battery']='unavailable'
 try:
  major_minor=tuple(int(x) for x in str(ld.product_version).split('.')[:2]);modern=major_minor>=(17,4)
 except ValueError:modern=True
 if modern:statuses['mobilegestalt']='deprecated_by_ios'
 else:
  try:
   async with DiagnosticsService(ld) as service:gestalt=await asyncio.wait_for(service.mobilegestalt(list(GESTALT_FIELDS)),timeout=6)
   existing={x['key'] for x in fields};fields += [x for x in fields_from(gestalt,GESTALT_FIELDS,'apple_mobilegestalt') if x['key'] not in existing];statuses['mobilegestalt']='available'
  except Exception:statuses['mobilegestalt']='unavailable'
 try:
  async with DiagnosticsService(ld) as service:wifi=await asyncio.wait_for(service.get_wifi(),timeout=5)
  fields+=fields_from(wifi,{k:'network' for k in WIFI_FIELDS},'apple_wifi_ioregistry',prefix='WiFi.')
  statuses['wifi_diagnostics']='available' if any(x['key'].startswith('WiFi.') for x in fields) else 'not_returned'
 except Exception:statuses['wifi_diagnostics']='unavailable'
 # Aggregate counts only. Photo metadata is transient in memory; no asset rows
 # or media originals cross the process boundary or enter the private history.
 content=await read_content_counts(ld,values)
 fields+=passport_fields(content)
 statuses['media_counts']='available' if len(content['values'])==4 else 'partial' if content['values'] else 'not_returned'
 # A capability/serial does not prove a working or replaced component. Never use the Mac IP for the phone.
 statuses.update({'repair_history':'not_exposed_by_trust','live_sensor_tests':'requires_device_app','vpn_status':'available' if any(f['key'] in {'VPNStatus','VPNActive'} for f in fields) else 'not_returned','external_ip':'requires_device_network_request','warranty_expiry':'requires_apple_coverage_check'})
 for name,keys in [('carrier_details',{'CarrierName','CarrierBundleInfo','SIMInfo'}),('sim_identifiers',{'IntegratedCircuitCardIdentity','ICCID','EID','EUICCIdentifier'}),('regulatory_model',{'RegulatoryModelNumber'}),('wifi_connection',{'WiFi.SSID','WiFi.IO80211SSID','WiFi.BSSID','WiFi.IO80211BSSID'})]:
  statuses[name]='available' if any(f['key'] in keys or f['key'].split('.')[0] in keys for f in fields) else 'not_returned'
 fields+=fields_from(statuses,{k:'availability' for k in statuses},'apprestore_capability')
 # Stable output, one value per key; no raw registry dictionaries cross the process boundary.
 fields=list({x['key']:x for x in fields}.values());fields.sort(key=lambda x:x['key'])
 storage=disk
 overview={'model':str(values.get('ProductType','')),'ios':str(ld.product_version),'build':str(values.get('BuildVersion','')),'name':str(values.get('DeviceName','iPhone'))[:120],'camera_serial':str(values.get('SerialNumber','')),'battery':{},'storage':storage,'battery_available':bool(battery),'battery_reading':battery if battery else None}
 overview.update({'content_counts':content['values'],'content_count_sources':content['sources'],'content_count_observed_at':content['observed_at']})
 return {'fields':fields,'battery':battery,'overview':overview}
