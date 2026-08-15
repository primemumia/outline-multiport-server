# On derlenmis binary'ler

Sunucu kurulumu OS tespiti yapar ve uygun dizini kullanir.

| Dizin | Hedef OS | glibc |
|-------|----------|-------|
| `x86_64/ubuntu22.04/` | Ubuntu 22.04 | 2.35 |
| `x86_64/ubuntu24.04/` | Ubuntu 24.04 | 2.38 |
| `x86_64/glibc2.35/` | ubuntu22.04 ile ayni (alias) |
| `x86_64/glibc2.38/` | ubuntu24.04 ile ayni (alias) |
| `aarch64/` | ARM64 (henuz eklenmedi) |

Kurulum sirasi (ornek Ubuntu 22.04):
1. `ubuntu22.04/` → `glibc2.35/` → kaynak derleme

Kurulum sirasi (ornek Ubuntu 24.04):
1. `ubuntu24.04/` → `glibc2.38/` → `ubuntu22.04/` (geriye uyumlu) → kaynak derleme

Gelistirici — her iki surum icin derle (Docker gerekir):

```bash
bash server/build-wsl.sh
git add server/bin/x86_64/
git commit -m "Prebuilt binary ubuntu22.04 + ubuntu24.04"
git push
```

Canli port durumu `/run/shadowsocks-manager/` altinda tutulur (RAM/tmpfs, reboot sonrasi silinir).
