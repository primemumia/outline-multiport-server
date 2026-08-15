# GitHub'a yukleme (primemumia)

## 1. GitHub'da repo olustur

https://github.com/new

| Alan | Deger |
|------|--------|
| Owner | `primemumia` |
| Repository name | `outline-libev-server` (onerilen) |
| Public | Evet |
| README / .gitignore | **Ekleme** (bos repo) |

## 2. Ic ice `.git` klasorlerini kaldir

`server/shadowsocks-libev` bir clone; icinde ayri git var. Tek repoya almak icin PowerShell:

```powershell
cd "C:\Users\prime\Desktop\test out"
Remove-Item -Recurse -Force "server\shadowsocks-libev\.git"
Remove-Item -Recurse -Force "server\shadowsocks-libev\libcork\.git"
Remove-Item -Recurse -Force "server\shadowsocks-libev\libbloom\.git"
Remove-Item -Recurse -Force "server\shadowsocks-libev\libipset\.git"
```

## 3. Git ile yukle

```powershell
cd "C:\Users\prime\Desktop\test out"
git init
git add .
git commit -m "Libev server installer, patch'li shadowsocks-libev ve ss-api"
git branch -M main
git remote add origin https://github.com/primemumia/outline-libev-server.git
git push -u origin main
```

GitHub sifre yerine **Personal Access Token** isteyebilir:
https://github.com/settings/tokens → Generate new token (classic) → `repo` yetkisi

## 4. Sunucuda kurulum

```bash
sudo bash -c "$(wget -qO- https://raw.githubusercontent.com/primemumia/outline-libev-server/main/server/install_scripts/install_server.sh)"
```

## Repo yapisi (zorunlu)

```
outline-libev-server/
  .gitignore
  out.sh                          # opsiyonel (Telegram bot kurulumu)
  server/
    install_scripts/install_server.sh
    shadowsocks-libev/            # patch'li kaynak + libcork/libbloom/libipset
    ss-api/
    shadowsocks-manager.service
    ss-api.service
```

`install_server.sh` varsayilan repo: `primemumia/outline-libev-server`
