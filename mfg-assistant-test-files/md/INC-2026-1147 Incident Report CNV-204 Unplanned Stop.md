# Incident Report — INC-2026-1147

**Site:** Northgate Assembly Plant (fictional)  
**Asset:** CNV-204 Packaging Conveyor Line 4  
**Date / time of incident:** 2026-11-14, 13:42 (second shift, approx. 2 h after start-up)  
**Reported by:** Line 4 team lead  
**Severity (initial):** Medium — production stop, no injury  
**Downtime to time of report:** 3 h 10 min (line still down)

> Synthetic test data for AI assistant evaluation. Any resemblance to real events is coincidental.

## What happened

At approximately 13:42 the conveyor stopped unexpectedly. The HMI showed **Alarm 4-212 (belt speed mismatch)** followed about 4 seconds later by **VFD fault F-OT (overtemperature)**. Operators report hearing a "grinding/rumbling" noise from the head end for "maybe 10–15 minutes" before the stop. One operator says she noticed the belt "running toward the walkway side" at the head drum during the morning but did not log it.

The team lead attempted one reset from the HMI at 13:50. The VFD cleared, the belt moved for about 20 seconds, and the same two alarms returned. No further resets were attempted. The area was taped off and maintenance was called.

## Observations by maintenance (first visit, 14:20)

- Head drum bearing housing, **non-drive end**, measured **91 °C** with a handheld IR thermometer. Drive end measured 58 °C. Ambient in the area approx. 24 °C.
- Visible dark grease discolouration around the NDE bearing housing seal; some grease on the floor below.
- Belt sitting approximately **30 mm** toward the walkway side at the head drum.
- No visible belt damage. No carton jam at palletizer infeed.
- Gearbox temperature not measured.
- VFD fault log shows F-OT at 13:42:19 and 13:50:44. Motor current in the 10 minutes before the first trip is not yet downloaded.
- Vibration not measured (handheld unit was not available on shift).

## Immediate actions taken

- Equipment left in stopped state, isolated at local disconnect, lock applied by shift electrician.
- Area barriered. Palletizer PAL-410 placed in manual.
- Production diverted to Line 3 at reduced rate.

## Open questions from the team lead

1. Is this the bearing, or did the belt tracking cause the bearing problem, or the other way round?
2. Can we restart on the drive-end bearing only to clear the backlog tonight?
3. Should the gearbox oil be changed while we're in there?

## Attachments referenced (not included)

- HMI alarm history export (pending)
- VFD trend download (pending)
- Photos of NDE bearing housing (on team lead's phone)
