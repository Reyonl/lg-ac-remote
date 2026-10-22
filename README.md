# LG K05NSA Remote (Flutter)

Aplikasi remote AC **LG K05NSA** untuk HP Android yang punya **IR blaster**,
misalnya POCO F6. Mengirim sinyal infrared langsung dari HP lewat
`ConsumerIrManager`.

## Cara kerja

Protokol LG AC dikirim sebagai pesan **28 bit** dengan signature `0x88`:

```
bits [27..20]  signature 0x88
bits [19..18]  power      (00 = On, 11 = Off)
bits [17..15]  padding
bits [14..12]  mode       (Cool 0, Dry 1, Fan 2, Auto 3, Heat 4)
bits [11..8]   suhu       (setTemp - 15, jadi 16C..30C -> 1..15)
bits [7..4]    fan        (Lowest 0, Low 1, Medium 2, Max 4, Auto 5)
bits [3..0]    checksum   (jumlah nibble bit [4..19] mod 16)
```

Bit dikirim **MSB first** dengan carrier 38 kHz.

LG memakai dua wire format yang membawa payload sama, bedanya cuma timing
header:

| Protokol | Header mark | Header space | Bit mark | Remote      |
|----------|-------------|--------------|----------|-------------|
| LG       | 8500 us     | 4250 us      | 550 us   | 6711A20083V |
| LG2      | 3200 us     | 9900 us      | 480 us   | AKB74395308 |

K05NSA umumnya menjawab **LG2**. Kalau unit tidak merespon, ganti ke LG lewat
toggle protokol di aplikasi.

Format pesan dan konstanta timing mengikuti
[IRremoteESP8266 `ir_LG.h` / `ir_LG.cpp`](https://github.com/crankyoldgit/IRremoteESP8266).

## Fitur

- Power ON / OFF
- Suhu 16-30 C
- Mode Cool / Dry / Fan / Auto / Heat
- Kipas Auto / 1 / 2 / 3 / Max
- Toggle protokol LG / LG2
- Swing vertikal & toggle lampu (kode khusus remote asli)
- Panel status: deteksi IR blaster + carrier frequency

## Struktur

```
lib/
  lg_ac_protocol.dart       # build pesan 28-bit + encoder timing IR
  ir_service.dart           # wrapper plugin IR + cooldown
  main.dart                 # UI remote
test/
  lg_ac_protocol_test.dart  # unit test checksum / bit layout / encoder
```

## Build & test

```bash
flutter pub get
flutter test
flutter build apk --release --split-per-abi --target-platform android-arm64
```

APK hasil build: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

## Catatan

- Aplikasi ini butuh hardware IR blaster. Kalau `hasIrEmitter()` false, tombol
  tetap kelihatan tapi sinyal tidak dikirim dan panel status memberi tahu
  kenapa.
- `TRANSMIT_IR` dideklarasikan di `android/app/src/main/AndroidManifest.xml`.
- Kode IR tidak bisa diverifikasi otomatis tanpa unit AC fisik. Kalau tidak
  ada respon, coba: (1) ganti protokol, (2) dekatkan blaster ke sensor IR AC,
  (3) pakai tombol "Test kirim".