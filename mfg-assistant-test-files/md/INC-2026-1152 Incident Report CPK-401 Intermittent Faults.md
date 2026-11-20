# Incident Report — INC-2026-1152

**Site:** Northgate Assembly Plant (fictional)  
**Asset:** CPK-401 Case Packer, Line 4  
**Date / time:** 2026-11-16, multiple occurrences between 06:30 and 11:15 (first shift)  
**Reported by:** Shift electrician  
**Severity (initial):** Low — short stops, no injury, no product damage reported  
**Total downtime:** approx. 38 min across 9 events

> Synthetic test data for AI assistant evaluation.

## What happened

The case packer stopped nine times during first shift with **fault 7-034 "Flap folder not in position"**. Each stop cleared on a single reset and the machine ran normally for anywhere from 8 to 70 minutes before the next event. Events did not line up with any particular carton size changeover; the shift ran a single SKU all morning.

The electrician observed two events directly. In both cases the flap folder appeared to be fully in position visually, but the fault was present. Wiggling the cable at the sensor connector did not change the fault state on the first occasion; on the second occasion the fault cleared while the electrician was looking at the sensor, before any reset was pressed.

It rained heavily overnight and the roof above the packer area has had a known minor leak logged in facilities since September. No water was seen on the machine.

## Observations

- Sensor is an inductive proximity switch on the flap folder cylinder (sensor ID S7-034). Indicator LED on the sensor was on during one observed fault.
- Cable run passes through a cable tray shared with the Line 4 VFD power cables.
- PLC input status not captured during fault.
- No maintenance has been performed on CPK-401 in the last 30 days according to the electrician's recollection (not verified against CMMS).

## Immediate actions

- None beyond resets. Machine remained in production.

## Question from production

Can we just bridge the input until the weekend so we stop losing time on resets?
