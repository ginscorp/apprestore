"""Allowlisted battery diagnostics only. Raw registry is never returned; selected serials are transient identity fields only."""
import hashlib,math

def number(value,low,high):
    if isinstance(value,bool) or not isinstance(value,(int,float)) or not low<=value<=high or not math.isfinite(value):return None
    return float(value)

def normalize(raw):
    raw=raw if isinstance(raw,dict) else {};nested=raw.get('BatteryData');nested=nested if isinstance(nested,dict) else {}
    def get(keys,low,high):
        for key in keys:
            for obj,prefix in [(raw,''),(nested,'BatteryData.')]:
                value=number(obj.get(key),low,high)
                if value is not None:return value,prefix+key
        return None,None
    fcc,source=get(['AppleRawMaxCapacity','FullChargeCapacity'],100,100000)
    if fcc is None:fcc,source=get(['NominalChargeCapacity'],100,100000)
    # MaxCapacity=100 on modern iOS is percent, never 100 mAh.
    if fcc is None:fcc,source=get(['MaxCapacity'],500,100000)
    design,_=get(['DesignCapacity'],100,100000);current,_=get(['AppleRawCurrentCapacity'],0,100000)
    percent,_=get(['CurrentCapacity','StateOfCharge'],0,100)
    cycles,_=get(['CycleCount'],0,100000)
    temp,_=get(['Temperature'],-4000,10000);temp=temp/100 if temp is not None else None
    voltage,_=get(['Voltage'],1000,30000)
    amps=None
    for key in ['InstantAmperage','Amperage']:
        value=raw.get(key)
        if isinstance(value,int) and not isinstance(value,bool) and 2**63<=value<2**64:value-=2**64
        amps=number(value,-50000,50000)
        if amps is not None:break
    serial=raw.get('Serial',nested.get('Serial'))
    pack=None
    if isinstance(serial,(str,int,bytes)) and not isinstance(serial,bool):
        data=serial if isinstance(serial,bytes) else str(serial).encode()
        if 0<len(data)<=256:pack=hashlib.sha256(b'AppRestore battery v1\0'+data).hexdigest()
    result={'full_mah':fcc,'design_mah':design,'current_mah':current,'charge_percent':percent,'cycles':cycles,'temperature_c':temp,'voltage_mv':voltage,'current_ma':amps,'power_w':amps*voltage/1e6 if amps is not None and voltage is not None else None,'full_source':source,'pack_hash':pack,'source':'apple_usb_iopmpowersource'}
    for key,out in [('IsCharging','charging'),('ExternalConnected','external_power'),('FullyCharged','fully_charged')]:result[out]=raw[key] if isinstance(raw.get(key),bool) else None
    return result

async def read_battery(ld):
    from pymobiledevice3.services.diagnostics import DiagnosticsService
    async with DiagnosticsService(ld) as service:raw=await service.get_battery()
    result=normalize(raw)
    nested=raw.get('BatteryData') if isinstance(raw,dict) else {};nested=nested if isinstance(nested,dict) else {}
    adapter=raw.get('AdapterDetails',{}) if isinstance(raw,dict) else {}
    result['details']={'temperature_source':'IOPMPowerSource.Temperature','lifetime':lifetime_values(nested.get('LifetimeData')),'source':'apple_usb_iopmpowersource','charger_watts':number(adapter.get('Watts'),0,1000) if isinstance(adapter,dict) else None}
    serial=ld.all_values.get('SerialNumber')
    if isinstance(serial,str) and 0<len(serial)<=128:result['device_aliases']=[hashlib.sha256(('AppRestore battery device v1\0alias:iphone:serial:'+serial.strip().upper()).encode()).hexdigest()];result['transient_device_serial']=serial
    pack=raw.get('Serial',nested.get('Serial')) if isinstance(raw,dict) else None
    if isinstance(pack,str) and 0<len(pack)<=200:result['transient_battery_serial']=pack
    return result

def lifetime_values(raw):
    if not isinstance(raw,dict):return None
    def n(key,low,high):return number(raw.get(key),low,high)
    maximum=n('MaximumTemperature',-400,1000);minimum=n('MinimumTemperature',-400,1000);average=n('AverageTemperature',-400,1000)
    divisor=10 if maximum is not None and maximum>100 else 1
    lo=minimum/divisor if minimum is not None else None;hi=maximum/divisor if maximum is not None else None
    valid=lo is not None and hi is not None and -40<=lo<=hi<=100
    avg=average/10 if average is not None and average>100 else average
    return {'operating_hours':n('TotalOperatingTime',0,2000000),'min_temp_c':lo if valid else None,'max_temp_c':hi if valid else None,'average_temp_c':avg if avg is not None and -40<=avg<=100 else None,'min_voltage_mv':n('MinimumPackVoltage',1000,30000),'max_voltage_mv':n('MaximumPackVoltage',1000,30000),'max_charge_ma':n('MaximumChargeCurrent',0,100000),'max_discharge_ma':n('MaximumDischargeCurrent',-100000,0),'temperature_samples':n('TemperatureSamples',0,1e10),'last_calibration_cycles':n('CycleCountLastQmax',0,100000),'updated_epoch':n('UpdateTime',1,4102444800),'temperature_scale':('controller_tenths' if divisor==10 else 'controller_degrees') if valid else None}
