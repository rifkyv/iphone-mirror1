# iPhone Mirror: Panduan Lengkap

Mirroring layar iPhone ke PC Windows lewat kabel USB. Bitrate bisa diatur sendiri (2 sampai 60 Mbps), delay rendah, dan suara game ikut masuk ke PC.

Isi project:
- `ios/`: app iPhone (dibuild otomatis oleh GitHub, kamu gak perlu Mac)
- `pc/`: aplikasi penerima di PC (`run.bat`)
- `.github/workflows/build-ios.yml`: resep build app iPhone di server Mac milik GitHub

Proses setup cuma sekali di awal. Sesudah itu tiap mau live cukup Bagian D.

---

## Bagian A. Build app iPhone lewat GitHub (sekali)

1. Buka https://github.com, daftar atau login.
2. Klik tombol **+** di kanan atas, pilih **New repository**.
   - Repository name: `iphone-mirror`
   - Pilih **Public** (build Mac gratis tanpa batas menit buat repo public)
   - Klik **Create repository**
3. Di halaman repo yang baru, klik link **uploading an existing file**.
4. Extract zip project ini di PC. Buka foldernya, blok **semua isinya** (folder `.github`, `ios`, `pc`, dan file lainnya), lalu drag ke halaman upload GitHub.
   - Pastikan folder `.github` ikut ke-upload. Kalau gak keliatan di Explorer, nyalakan View > Show > Hidden items.
5. Scroll ke bawah, klik **Commit changes**.
6. Klik tab **Actions**. Kalau ada tombol hijau "I understand my workflows, go ahead and enable them", klik.
7. Klik **Build iPhone app (IPA)** di kiri, lalu **Run workflow** > **Run workflow**. (Kadang build udah jalan sendiri setelah upload.)
8. Tunggu 5 sampai 10 menit sampai muncul centang hijau.
   - Kalau muncul silang merah, klik build-nya, download artifact **build-log**, terus kirim isinya ke Claude buat dibenerin.
9. Klik build yang centang hijau, scroll ke bawah ke bagian **Artifacts**, download **iPhoneMirror-ipa**. Extract, kamu dapat file `iPhoneMirror.ipa`.

## Bagian B. Install app ke iPhone pakai Sideloadly (sekali, ulang tiap 7 hari)

1. Install **iTunes** dan **iCloud** versi dari website Apple, **bukan** versi Microsoft Store. Kalau sudah ada versi Microsoft Store (termasuk app "Apple Devices"), uninstall dulu.
2. Download dan install **Sideloadly** dari https://sideloadly.io
3. Colok iPhone ke PC pakai kabel. Kalau muncul "Trust This Computer?" di iPhone, pilih **Trust**.
4. Buka Sideloadly:
   - Drag `iPhoneMirror.ipa` ke kotak IPA.
   - Isi **Apple ID** kamu (boleh bikin Apple ID baru khusus ini).
   - Klik **Start**, masukkan password Apple ID dan kode verifikasi kalau diminta.
5. Di iPhone, aktifkan **Developer Mode**: Settings > Privacy & Security > Developer Mode > ON, lalu restart iPhone dan pilih Turn On.
6. Di iPhone, buka Settings > General > **VPN & Device Management**, ketuk Apple ID kamu, lalu **Trust**.
7. App **iPhone Mirror** sekarang muncul di home screen.

Apple ID gratis cuma berlaku 7 hari. Kalau app gak mau kebuka lagi, ulangi langkah 3 dan 4 di Sideloadly pakai file IPA dan Apple ID yang sama.

## Bagian C. Siapkan aplikasi PC (sekali)

1. Copy folder `pc` ke tempat yang gampang dicari, misalnya `D:\iPhone Mirror`.
2. Double klik `run.bat`.
   - Pertama kali dia install Python 3.12 dan library yang dibutuhkan. Butuh internet, sekitar 1 sampai 3 menit.
   - Kalau muncul peringatan Windows SmartScreen, klik More info > Run anyway.
3. Jendela **Pengaturan** muncul. Ini sudah siap dipakai.

## Bagian D. Cara pakai tiap mau live

1. Colok iPhone ke PC pakai kabel USB.
2. Di PC, jalankan `run.bat`. Atur pengaturannya, lalu klik **Mulai Mirroring**. Window hitam "iPhone Mirror" muncul.
3. Di iPhone, buka app **iPhone Mirror**, ketuk tombol bulat merah, pilih **iPhone Mirror**, lalu **Start Broadcast**.
   - Cara lain: buka Control Center, tahan lama tombol Screen Recording, pilih iPhone Mirror, Start Broadcast.
4. Layar iPhone langsung muncul di PC. Buka Mobile Legends.
5. Untuk berhenti: ketuk indikator merah di pojok kiri atas iPhone, lalu Stop.

### Pengaturan yang disarankan buat live TikTok

| Pengaturan | Nilai |
|---|---|
| Codec | H.264 |
| Bitrate | 20 Mbps (naikkan ke 30 sampai 40 kalau masih kotak-kotak pas teamfight) |
| Frame rate | 60 |
| Resolusi | 1920 |

### Hotkey di window iPhone Mirror

| Tombol | Fungsi |
|---|---|
| F11 atau F | Fullscreen on/off |
| 1 | Ukuran window = ukuran asli video (paling tajam buat Window Capture) |
| R | Putar 90 derajat (kalau gambar miring) |
| Panah Atas / Bawah | Bitrate +2 / -2 Mbps, langsung berlaku |
| K | Minta keyframe baru (kalau gambar rusak) |
| M | Mute / unmute suara di PC |
| T | Window selalu di atas on/off |

### Setting di TikTok LIVE Studio

1. Add source > **Window Capture**, pilih window **iPhone Mirror**.
2. Di window iPhone Mirror, tekan **1** biar ukurannya pas ukuran asli video. Jangan di-minimize.
3. Suara: suara game diputar di speaker PC, jadi otomatis ketangkap lewat audio desktop di LIVE Studio.
4. Output LIVE Studio: 1080p 60fps, bitrate setinggi yang dikasih akun kamu.

---

## Kalau ada masalah

**Console bilang "Apple Mobile Device Service tidak ditemukan"**
iTunes belum terinstall. Ikuti Bagian B langkah 1.

**Console bilang "Menunggu iPhone..."**
Kabel belum kecolok atau iPhone belum Trust PC ini. Cabut colok lagi, buka kunci iPhone, pilih Trust.

**Console bilang "iPhone terdeteksi. Buka Control Center..."**
PC udah nyambung ke iPhone, tinggal Start Broadcast (Bagian D langkah 3).

**Window hitam padahal broadcast udah jalan**
Geser-geser layar iPhone sedikit. iOS cuma ngirim gambar kalau layarnya berubah.

**Gambar kotak-kotak pas rame**
Tekan panah Atas beberapa kali buat naikin bitrate. Liat angka Mbps di console.

**Patah-patah atau delay naik**
Turunkan bitrate (panah Bawah) atau ganti resolusi ke 1600. Pakai kabel original dan colok langsung ke port PC, jangan lewat hub.

**Suara gak masuk ke PC**
Pastikan centang "Suara game iPhone masuk ke PC" nyala, terus coba tekan M dua kali. Suara iPhone juga tetap keluar di HP, jadi bisa pakai earphone di iPhone kalau gak mau dobel.

**Broadcast berhenti sendiri**
iOS bisa matiin broadcast kalau HP kepanasan atau memori penuh. Tutup app lain, turunkan resolusi ke 1600, lalu Start Broadcast lagi.
