# Equipment Specification — Packaging Conveyor Line 4

**Document ID:** EQ-SPEC-CNV-204  
**Site:** Northgate Assembly Plant (fictional)  
**Asset tag:** CNV-204  
**Revision:** C — 2026-03-14  
**Owner:** Reliability Engineering

> This document is synthetic test data for an AI assistant evaluation. All values are illustrative and do not describe any real equipment.

## 1. Overview

CNV-204 is a 42 m belt conveyor transferring finished cartons from the Line 4 case packer (CPK-401) to the palletizer infeed (PAL-410). It operates two shifts, 5 days/week, with a planned utilization of 78%.

## 2. Mechanical

| Parameter | Value |
|---|---|
| Belt type | PVC, 2-ply, 600 mm wide, anti-static |
| Belt length | 85.2 m (endless) |
| Design belt speed | 0.6 – 1.2 m/s (variable) |
| Nominal operating speed | 0.9 m/s |
| Drive | Head-end drum drive, 5.5 kW gearmotor, ratio 23.7:1 |
| Drum diameter | 320 mm (head), 250 mm (tail) |
| Rated load | 35 kg/m |
| Take-up | Screw take-up, tail end, 400 mm travel |
| Bearings | Head drum: SKF 22216 E spherical roller (2). Tail drum: 6210-2RS deep groove (2). |
| Idlers | Return idlers at 3.0 m pitch; carrying idlers at 1.2 m pitch |

## 3. Electrical and Controls

| Parameter | Value |
|---|---|
| Motor | 5.5 kW, 400 V, 3-phase, 1465 rpm, IE3, thermistor (PTC) in windings |
| VFD | 7.5 kW, vector control, braking resistor fitted |
| VFD overcurrent trip | 150% FLA for 60 s; instantaneous at 220% FLA |
| Motor FLA | 11.2 A |
| Motor thermistor trip | 155 °C (class F) |
| Control | PLC rack 4, slot 6. Belt-speed encoder on tail drum. |
| Speed-mismatch alarm | Encoder speed < 85% of commanded for > 3 s → Alarm 4-212, controlled stop |
| Interlocks | E-stops at head, tail, and mid-span (3). Pull-cord along full length. Guard-door switches at head and tail drive enclosures. |

## 4. Operating Limits

| Limit | Value |
|---|---|
| Ambient temperature | 5 – 40 °C |
| Head drum bearing housing temperature | Normal ≤ 65 °C; investigate > 75 °C; stop > 85 °C |
| Gearbox oil temperature | Normal ≤ 70 °C; investigate > 80 °C |
| Belt tracking | ± 15 mm from centre at head drum |
| Vibration (bearing housings, ISO 10816 zone) | Zone A/B acceptable ≤ 4.5 mm/s RMS; Zone C > 4.5 mm/s investigate; Zone D > 7.1 mm/s unacceptable |

## 5. Lubrication

| Point | Lubricant | Interval |
|---|---|---|
| Head drum bearings | Lithium complex EP2 | Every 4 weeks, 12 g per bearing |
| Tail drum bearings | Sealed for life | — |
| Gearbox | Synthetic PAO ISO VG 220 | Oil change every 10,000 h or 24 months |

## 6. Known Failure Modes (from FMEA rev B)

- Belt mistracking due to uneven take-up adjustment or carton debris on tail drum.
- Head drum bearing wear leading to elevated temperature and vibration; typical life 30,000 h.
- VFD overcurrent trips caused by belt jam at palletizer infeed transfer.
- Encoder coupling slip producing false speed-mismatch alarms.
