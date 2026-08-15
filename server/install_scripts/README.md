# Libev Server Kurulum Scripti

Outline `install_server.sh` benzeri tek komutla shadowsocks-libev sunucu kurulumu.

## Hızlı kurulum (GitHub yüklendikten sonra)

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/KULLANICI/REPO/main/server/install_scripts/install_server.sh)"
```

veya:

```bash
curl -fsSL https://raw.githubusercontent.com/KULLANICI/REPO/main/server/install_scripts/install_server.sh | sudo bash
```

## Özelleştirme

```bash
# Farklı repo / dal
export LIBEV_REPO="kullanici/repo-adi"
export LIBEV_BRANCH="main"

# Public IP manuel
sudo bash install_server.sh --hostname 1.2.3.4

# Port değiştirme
sudo bash install_server.sh --api-tls-port 55555 --api-port 8087
```

Varsayilan dis HTTPS API portu: **55555** (ic API: 8087).

Bulut guvenlik grubunda acin:
- `55555/tcp` — bot/management API
- `444-999/tcp+udp` — VPN anahtar portlari

## Kurulum sonrası

Kurulum **on derlenmis binary** dener (OS tespiti: ubuntu22.04 / ubuntu24.04); uyumsuzsa sunucuda kaynak derleme yapar.
Gelistirici: `bash server/build-wsl.sh` (22.04 + 24.04) + GitHub push.

| Bileşen | Konum |
|---------|--------|
| Dis HTTPS API | `https://SUNUCU_IP:55555/{secret}` |
| Management API (ic) | `http://127.0.0.1:8087/{secret}` |
| Access config | `/opt/libev-server/access.txt` |
| CLI | `libev add key isim` |
| Port izleme | `libev status port 444` (canli; journal/loga yazilmaz) |
| Kaldirma | `sudo libev server delete --yes` |
| ss-manager | Unix socket ` /var/lib/shadowsocks-manager/manager.sock` |
| Port havuzu | 444–999 |

## Bot entegrasyonu

Kurulum sonunda yazdırılan JSON'u bot `config.json` içindeki `outline_apis` dizisine ekleyin (`type: libev`).

## GitHub'a yükleme

Repo kök yapısı:

```
repo/
  server/
    bin/x86_64/           # ss-server, ss-manager (on derlenmis)
    install_scripts/
      install_server.sh
      README.md
    shadowsocks-libev/    # patch kaynak (sadece gelistirici derlemesi icin)
    ss-api/
```

`install_server.sh` içinde varsayılan repo adını güncelleyin:

```bash
readonly LIBEV_REPO="${LIBEV_REPO:-KULLANICI/REPO-ADI}"
```
