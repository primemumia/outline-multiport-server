#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CLI: libev add/del/list keys, status port, IP lock"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from key_store import KeyManager

DEFAULT_CONFIG = "/etc/libev/cli.json"
UNINSTALL_SCRIPT = Path("/opt/ss-api/uninstall_server.sh")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="libev", description="shadowsocks-libev manuel anahtar yönetimi")
    parser.add_argument("--config", default=DEFAULT_CONFIG, help=f"Config dosyası (varsayılan: {DEFAULT_CONFIG})")
    parser.add_argument("--json", action="store_true", help="JSON çıktı (status/show)")

    sub = parser.add_subparsers(dest="command", required=True)

    server = sub.add_parser("server", help="Sunucu kurulumu yonetimi")
    server_sub = server.add_subparsers(dest="server_target", required=True)
    server_del = server_sub.add_parser("delete", help="Tum libev kurulumunu kaldir")
    server_del.add_argument("-y", "--yes", action="store_true", help="Onay (zorunlu)")

    add = sub.add_parser("add", help="Anahtar ekle")
    add_sub = add.add_subparsers(dest="add_target", required=True)
    add_key = add_sub.add_parser("key", help="Yeni SS anahtarı oluştur")
    add_key.add_argument("name", help="Anahtar adı (ör. mumia)")
    add_key.add_argument("--port", type=int, help="Port (boşsa havuzdan seçilir)")
    add_key.add_argument("--password", help="Şifre (boşsa rastgele üretilir)")

    delete = sub.add_parser("del", help="Anahtar sil")
    delete_sub = delete.add_subparsers(dest="del_target", required=True)
    del_key = delete_sub.add_parser("key", help="Anahtarı sil")
    del_key.add_argument("name", help="Anahtar adı")

    list_cmd = sub.add_parser("list", help="Anahtarları listele")
    list_sub = list_cmd.add_subparsers(dest="list_target", required=True)
    list_keys = list_sub.add_parser("keys", help="Tüm anahtarları listele")
    list_keys.add_argument("--live", action="store_true", help="Canlı baglanti durumunu da goster")

    show = sub.add_parser("show", help="Anahtar detayı")
    show_sub = show.add_subparsers(dest="show_target", required=True)
    show_key = show_sub.add_parser("key", help="Anahtar bilgisi + IP durumu")
    show_key.add_argument("name")

    status = sub.add_parser("status", help="Port baglanti / IP durumu")
    status_sub = status.add_subparsers(dest="status_target", required=True)
    status_port = status_sub.add_parser("port", help="Tek port durumu (or. 444)")
    status_port.add_argument("port", type=int)
    status_sub.add_parser("ports", help="Tum anahtar portlarinin durumu")

    lock = sub.add_parser("lock-ip", help="Port IP kilidi ayarla")
    lock_sub = lock.add_subparsers(dest="lock_target", required=True)
    lock_key = lock_sub.add_parser("key")
    lock_key.add_argument("name")
    lock_key.add_argument("ip")

    unlock = sub.add_parser("unlock-ip", help="Port IP kilidini kaldır")
    unlock_sub = unlock.add_subparsers(dest="unlock_target", required=True)
    unlock_key = unlock_sub.add_parser("key")
    unlock_key.add_argument("name")

    sub.add_parser("sync", help="ports.json anahtarlarini ss-manager'a yukle")

    return parser


def print_json(data) -> None:
    print(json.dumps(data, indent=2, ensure_ascii=False))


def print_ip_list(title: str, ips: list) -> None:
    if ips:
        print(f"{title}:")
        for ip in ips:
            print(f"  - {ip}")
    else:
        print(f"{title:<12}: yok")


def print_port_status(info: dict) -> None:
    name = info.get("name") or "(atanmamis)"
    print(f"Port        : {info['port']}")
    print(f"Anahtar     : {name}")
    print(f"Durum       : {info['state_label']}")
    print(f"Kilitli IP  : {info.get('locked_ip') or '-'}")
    print(f"Baglanti    : {info.get('connections', 0)}")
    print_ip_list("Aktif IP'ler", info.get("active_ips") or [])
    print_ip_list("Gelen IP'ler (son 30 sn)", info.get("recent_incoming") or [])
    print_ip_list("Engellenen IP'ler (son 30 sn)", info.get("blocked_ips") or [])
    if info["state"] == "zombie":
        print("Not         : Kilit kayitli ama canli oturum yok; yeni IP devralabilir.")
    elif info["state"] == "empty":
        print("Not         : Port bos; ilk baglanan IP otomatik kilitlenir.")
    elif info["state"] == "active":
        print("Not         : Kopuk TCP ~10 sn icinde keepalive ile temizlenir.")


def run_server_delete(yes: bool) -> int:
    if os.geteuid() != 0:
        print("❌ Root gerekli: sudo libev server delete --yes", file=sys.stderr)
        return 1
    if not yes:
        print("❌ Onay gerekli: libev server delete --yes", file=sys.stderr)
        print("   Tum servisler, anahtarlar ve API kaldirilir.", file=sys.stderr)
        return 1

    script = UNINSTALL_SCRIPT
    if not script.is_file():
        fallback = Path(__file__).resolve().parent / "uninstall_server.sh"
        if fallback.is_file():
            script = fallback
        else:
            print(f"❌ Kaldirma scripti bulunamadi: {UNINSTALL_SCRIPT}", file=sys.stderr)
            return 1

    subprocess.run(["bash", str(script), "--yes"], check=True)
    return 0


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.command == "server" and args.server_target == "delete":
        try:
            return run_server_delete(args.yes)
        except subprocess.CalledProcessError as exc:
            print(f"❌ Kaldirma basarisiz (cikis {exc.returncode})", file=sys.stderr)
            return exc.returncode or 1

    try:
        manager = KeyManager.from_config(args.config)
    except FileNotFoundError as exc:
        print(f"❌ {exc}", file=sys.stderr)
        print("💡 Kurulum: install_server.sh veya /etc/libev/cli.json oluşturun.", file=sys.stderr)
        return 1

    def ensure_manager():
        try:
            manager.client.ping()
        except Exception as exc:
            raise RuntimeError(
                f"ss-manager erişilemiyor ({manager.client.manager_address}): {exc}"
            ) from exc

    try:
        if args.command == "add" and args.add_target == "key":
            ensure_manager()
            result = manager.add_key(args.name, port=args.port, password=args.password)
            print(f"✅ Anahtar oluşturuldu: {result['name']}")
            print(f"   Port: {result['port']}")
            print(f"   ss:// → {result['accessUrl']}")
            print(f"   Izleme: libev status port {result['port']}")
            return 0

        if args.command == "del" and args.del_target == "key":
            result = manager.delete_key(args.name)
            print(f"✅ Anahtar silindi: {result['name']} (port {result['port']})")
            return 0

        if args.command == "list" and args.list_target == "keys":
            keys = manager.list_keys()
            if not keys:
                print("Anahtar yok.")
                return 0
            for item in keys:
                line = f"- {item['name']}  port={item['port']}  ss={item['accessUrl']}"
                if args.live:
                    ensure_manager()
                    st = manager.port_status(item["port"])
                    line += f"  [{st['state_label']}]"
                    if st.get("locked_ip"):
                        line += f" ip={st['locked_ip']}"
                print(line)
            return 0

        if args.command == "show" and args.show_target == "key":
            ensure_manager()
            data = manager.show_key(args.name)
            if args.json:
                print_json(data)
            else:
                print_port_status(data["status"])
                print(f"ss://       : {data['accessUrl']}")
            return 0

        if args.command == "status" and args.status_target == "port":
            ensure_manager()
            info = manager.port_status(args.port)
            if args.json:
                print_json(info)
            else:
                print_port_status(info)
            return 0

        if args.command == "status" and args.status_target == "ports":
            ensure_manager()
            items = manager.all_port_statuses()
            if not items:
                print("Anahtar yok.")
                return 0
            if args.json:
                print_json(items)
                return 0
            for info in items:
                active = ", ".join(info.get("active_ips") or []) or "-"
                incoming = ", ".join(info.get("recent_incoming") or []) or "-"
                blocked = ", ".join(info.get("blocked_ips") or []) or "-"
                locked = info.get("locked_ip") or "-"
                print(
                    f"port {info['port']:>4}  {info['name'] or '-':<12}  "
                    f"{info['state_label']:<28}  kilit={locked}  "
                    f"aktif={active}  gelen={incoming}  engel={blocked}"
                )
            return 0

        if args.command == "lock-ip" and args.lock_target == "key":
            ensure_manager()
            result = manager.set_lock_ip(args.name, args.ip)
            print(f"✅ IP kilidi: {result['name']} → {result['ip']} (port {result['port']})")
            return 0

        if args.command == "unlock-ip" and args.unlock_target == "key":
            ensure_manager()
            manager.clear_lock_ip(args.name)
            print(f"✅ IP kilidi kaldırıldı: {args.name}")
            return 0

        if args.command == "sync":
            ensure_manager()
            result = manager.sync_to_manager()
            if args.json:
                print_json(result)
            else:
                print(
                    f"✅ Sync: {result['added']} port eklendi, "
                    f"{result['already_active']} zaten aktif, toplam {result['total']}"
                )
                if result["errors"]:
                    print(f"⚠ {len(result['errors'])} hata:", file=sys.stderr)
                    for err in result["errors"][:10]:
                        print(
                            f"  port {err.get('port')} ({err.get('name', '-')}): {err.get('error')}",
                            file=sys.stderr,
                        )
            return 1 if result["errors"] else 0

        parser.print_help()
        return 2
    except Exception as exc:
        print(f"❌ {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
