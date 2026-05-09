# Elma Controller

Raspberry Pi tabanlı **elma soyma makinesi** için Flutter mobil/masaüstü kontrol arayüzü.  
TCP üzerinden JSON-lines protokolüyle RPi'ye bağlanır; makineyi başlatır, durdurur ve parametrelerini ayarlar.

---

## Sistem Mimarisi

```
┌──────────────────────────┐        TCP :8787        ┌──────────────────────────┐
│   Elma Controller        │ ◄──────────────────────► │   RPi — Elma Soyma       │
│   (Flutter App)          │                          │   Sade Sistem            │
│                          │                          │                          │
│  • Bağlantı yönetimi     │   {"cmd":"start_main"}   │  • Ana motor (ESC)        │
│  • Parametre gönderme    │ ─────────────────────►   │  • Bıçak motoru (ESC)    │
│  • Durum izleme          │                          │  • Vakum pompası         │
│  • Log görüntüleme       │   {"data":{state,...}}   │  • E-stop devresi        │
│                          │ ◄─────────────────────   │                          │
└──────────────────────────┘                          └──────────────────────────┘
```

---

## Özellikler

- **TCP bağlantısı** — IP ve port uygulamada elle girilir (gömülü değil)
- **Parametre ayarlama** — Tüm makine parametreleri uygulama üzerinden gönderilebilir
- **Gerçek zamanlı durum** — Makinenin anlık state bilgisi ve vacuum durumu
- **Log görüntüleyici** — Son 500 satır TX/RX logu
- **E-STOP** — Tek tuşla acil durdurma
- **Kalıcı ayarlar** — IP, port ve parametreler `SharedPreferences` ile hatırlanır

---

## Komutlar

### Gönderilen Komutlar (Flutter → RPi)

| Komut | JSON | Açıklama |
|-------|------|---------|
| **GET** | `{"cmd":"get"}` | Makine durumunu sorgula |
| **Start MAIN** | `{"cmd":"start_main"}` | Ana soyma motorunu başlat |
| **Start BLADE** | `{"cmd":"start_blade"}` | Bıçak motorunu başlat |
| **Vacuum ON** | `{"cmd":"vacuum","on":true}` | Vakum pompasını aç |
| **Vacuum OFF** | `{"cmd":"vacuum","on":false}` | Vakum pompasını kapat |
| **E-STOP** | `{"cmd":"estop"}` | Acil durdur |
| **SET** | `{"cmd":"set","params":{...}}` | Parametreleri güncelle |

### Alınan Yanıtlar (RPi → Flutter)

```json
{"data": {"state": "IDLE", "vacuum_on": false, ...}}
{"log": "Motor başlatıldı"}
```

---

## Parametreler

| Parametre | Varsayılan | Birim | Açıklama |
|-----------|-----------|-------|---------|
| `blade_run_s` | 10 | sn | Bıçak motoru çalışma süresi |
| `main_run_s` | 4 | sn | Ana motor çalışma süresi |
| `vacuum_pre_off_s` | 1 | sn | Vakum önceden kapanma süresi |
| `esc_blade_speed_pct` | 60 | % | Bıçak ESC hız yüzdesi |
| `esc_main_speed_pct` | 50 | % | Ana ESC hız yüzdesi |
| `vacuum_start_on` | true | bool | Başlangıçta vakum açık mı |
| `ignore_while_busy` | true | bool | Meşgulken komutları yoksay |

---

## Arayüz Bölümleri

```
┌─────────────────────────────────────┐
│  Elma Controller          [↺] [⚠️]  │  ← GET / E-STOP
├─────────────────────────────────────┤
│  🔌 Connection                       │
│  RPi IP: [__________]  Port:[____]  │
│                    [Connect/Disc.]  │
├─────────────────────────────────────┤
│  🎛️ Parameters              [Send/Save] │
│  blade_run_s: [10] s                │
│  main_run_s: [4] s                  │
│  vacuum_pre_off_s: [1] s            │
│  esc_blade_speed_pct: [60] %        │
│  esc_main_speed_pct: [50] %         │
│  vacuum_start_on: [●]               │
│  ignore_while_busy: [●]             │
├─────────────────────────────────────┤
│  ▶️ Actions                           │
│  [Start MAIN] [Start BLADE]         │
│  [Vacuum ON]  [Vacuum OFF]          │
│  [🔴 E-STOP]                         │
├─────────────────────────────────────┤
│  💓 Device State                     │
│  State: IDLE     Vacuum: OFF        │
│  {JSON durum verisi}                │
├─────────────────────────────────────┤
│  📋 Logs                   [Temizle] │
│  [11:23] Connected                  │
│  [11:23] TX: {"cmd":"get"}          │
│  [11:23] RX: {"data":{"state":...}} │
└─────────────────────────────────────┘
```

---

## Teknoloji

| | |
|--|--|
| **Dil** | Dart 3.9.2+ |
| **Framework** | Flutter |
| **Hedef Platformlar** | Android, iOS, Windows, Linux, macOS, Web |
| **Tema** | Material Design 3 (renk çekirdeği: yeşil) |
| **Bağımlılıklar** | `shared_preferences ^2.2.3`, `cupertino_icons ^1.0.8` |
| **İletişim** | TCP Socket, JSON-lines (`dart:io Socket`) |

---

## Derleme

```bash
flutter pub get

# Android APK
flutter build apk --release

# Windows
flutter build windows --release

# iOS
flutter build ios --release
```

---

## Bağlantı

1. RPi'yi ve elma soyma makinesini açın
2. Uygulamada RPi'nin IP adresini ve portu girin (varsayılan: **8787**)
3. **Connect** butonuna basın
4. **GET** ile makine durumunu sorgulayın
5. Parametreleri ayarlayıp **Send/Save** ile gönderin
6. **Start MAIN** veya **Start BLADE** ile işlemi başlatın

---

## Protokol Detayı

TCP bağlantısı üzerinden satır sonlandırmalı (`\n`) JSON mesajlar gönderilir:

```
Flutter ──► {"cmd":"set","params":{"blade_run_s":10,"main_run_s":4,...}}\n
Flutter ◄── {"data":{"state":"RUNNING","vacuum_on":true}}\n
Flutter ◄── {"log":"Blade motoru başlatıldı"}\n
```
