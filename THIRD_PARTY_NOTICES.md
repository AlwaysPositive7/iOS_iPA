# Third-party notices

## PulseLoopiOS COLMI / QRing protocol

The COLMI BLE service and characteristic identifiers, big-data sleep request,
packet reassembly rule, stage codes, and cross-midnight decoding used by
Daymark Health were adapted from
[PulseLoopiOS](https://github.com/saksham2001/PulseLoopiOS) by Saksham Bhutani
and contributors.

PulseLoopiOS is licensed under
[Creative Commons Attribution 4.0 International](https://creativecommons.org/licenses/by/4.0/).
Daymark's adaptation adds R04 advertisement matching, Flutter integration,
packet validation, deterministic HealthKit sync identifiers, iOS-version stage
fallbacks, and direct HealthKit category-sample writes.

PulseLoop notes that portions of its COLMI sleep decoder were derived from the
[Gadgetbridge Yawell/QRing implementation](https://codeberg.org/Freeyourgadget/Gadgetbridge).
The decoder is experimental and requires validation against real ring data.
