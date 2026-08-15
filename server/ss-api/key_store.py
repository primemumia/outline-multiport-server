#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Shared shadowsocks-libev key/port store."""

import base64
import json
import secrets
import string
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from libev_client import LibevManagerClient

DEFAULT_METHOD = "chacha20-ietf-poly1305"
DEFAULT_PORT_START = 444
DEFAULT_PORT_END = 999


def generate_password(length: int = 22) -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def make_access_url(method: str, password: str, host: str, port: int) -> str:
    creds = base64.urlsafe_b64encode(f"{method}:{password}".encode()).decode().rstrip("=")
    return f"ss://{creds}@{host}:{port}/"


class KeyManager:
    def __init__(
        self,
        manager_address: str = "127.0.0.1:6001",
        server_ip: str = "127.0.0.1",
        port_store_path: str = "/var/lib/shadowsocks-manager/ports.json",
        port_start: int = DEFAULT_PORT_START,
        port_end: int = DEFAULT_PORT_END,
    ):
        self.client = LibevManagerClient(manager_address)
        self.server_ip = server_ip
        self.port_store_path = Path(port_store_path)
        self.port_start = port_start
        self.port_end = port_end
        self.ports: Dict[str, Dict[str, Any]] = self._load_ports()

    @classmethod
    def from_config(cls, config_path: str = "/etc/libev/cli.json") -> "KeyManager":
        path = Path(config_path)
        if not path.exists():
            raise FileNotFoundError(f"Config bulunamadı: {config_path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        port_range = data.get("port_range", {})
        return cls(
            manager_address=data.get("manager_address", "127.0.0.1:6001"),
            server_ip=data.get("server_ip", "127.0.0.1"),
            port_store_path=data.get("port_store", "/var/lib/shadowsocks-manager/ports.json"),
            port_start=int(port_range.get("start", DEFAULT_PORT_START)),
            port_end=int(port_range.get("end", DEFAULT_PORT_END)),
        )

    def _load_ports(self) -> Dict[str, Dict[str, Any]]:
        if not self.port_store_path.exists():
            return {}
        try:
            return json.loads(self.port_store_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            return {}

    def save(self) -> None:
        self.port_store_path.parent.mkdir(parents=True, exist_ok=True)
        self.port_store_path.write_text(
            json.dumps(self.ports, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

    def _used_ports(self) -> set:
        return {int(port) for port in self.ports.keys()}

    def allocate_port(self, preferred: Optional[int] = None) -> int:
        used = self._used_ports()
        if preferred is not None:
            preferred = int(preferred)
            if preferred in used:
                raise ValueError(f"Port {preferred} zaten kullanılıyor")
            if not (self.port_start <= preferred <= self.port_end):
                raise ValueError(f"Port {preferred} aralık dışında ({self.port_start}-{self.port_end})")
            return preferred
        for port in range(self.port_start, self.port_end + 1):
            if port not in used:
                return port
        raise RuntimeError(f"Boş port yok ({self.port_start}-{self.port_end})")

    def find_by_name(self, name: str) -> Optional[Tuple[int, Dict[str, Any]]]:
        target = name.strip().lower()
        for port_str, entry in self.ports.items():
            entry_name = str(entry.get("name", "")).lower()
            if entry_name == target:
                return int(port_str), entry
        return None

    def key_payload(self, port: int, entry: Dict[str, Any]) -> Dict[str, Any]:
        method = entry.get("method", DEFAULT_METHOD)
        password = entry["password"]
        return {
            "id": str(port),
            "name": entry.get("name", f"port-{port}"),
            "password": password,
            "port": port,
            "method": method,
            "accessUrl": make_access_url(method, password, self.server_ip, port),
            "lockedIp": entry.get("locked_ip"),
        }

    def add_key(
        self,
        name: str,
        port: Optional[int] = None,
        password: Optional[str] = None,
        method: str = DEFAULT_METHOD,
    ) -> Dict[str, Any]:
        name = name.strip()
        if not name:
            raise ValueError("Anahtar adı boş olamaz")
        if self.find_by_name(name):
            raise ValueError(f"Anahtar zaten var: {name}")

        chosen_port = self.allocate_port(port)
        chosen_password = password or generate_password()

        self.client.add_port(chosen_port, chosen_password, method)
        self.ports[str(chosen_port)] = {
            "password": chosen_password,
            "method": method,
            "name": name,
            "locked_ip": None,
        }
        self.save()
        return self.key_payload(chosen_port, self.ports[str(chosen_port)])

    def delete_key(self, name: str) -> Dict[str, Any]:
        found = self.find_by_name(name)
        if not found:
            raise ValueError(f"Anahtar bulunamadı: {name}")
        port, entry = found
        try:
            self.client.clear_ip(port)
        except Exception:
            pass
        self.client.remove_port(port)
        del self.ports[str(port)]
        self.save()
        return self.key_payload(port, entry)

    def list_keys(self) -> List[Dict[str, Any]]:
        items = []
        for port_str in sorted(self.ports.keys(), key=lambda x: int(x)):
            items.append(self.key_payload(int(port_str), self.ports[port_str]))
        return items

    def find_by_port(self, port: int) -> Optional[Tuple[int, Dict[str, Any]]]:
        entry = self.ports.get(str(int(port)))
        if entry is None:
            return None
        return int(port), entry

    @staticmethod
    def derive_port_state(status: Dict[str, Any]) -> str:
        locked = (status.get("locked_ip") or "").strip()
        connections = int(status.get("connections") or 0)
        if connections > 0:
            return "active"
        if locked:
            return "zombie"
        return "empty"

    @staticmethod
    def state_label(state: str) -> str:
        return {
            "active": "AKTIF",
            "zombie": "ZOMBIE (kilitli, baglanti yok)",
            "empty": "BOS",
        }.get(state, state)

    @staticmethod
    def _parse_ip_list(raw: Any, key: str) -> List[str]:
        value = raw.get(key)
        if isinstance(value, list):
            return [str(x) for x in value if x]
        if isinstance(value, dict):
            return list(value.keys())
        return []

    def port_status(self, port: int) -> Dict[str, Any]:
        port = int(port)
        found = self.find_by_port(port)
        raw = self.client.ip_status(port)
        if isinstance(raw, str):
            try:
                raw = json.loads(raw or "{}")
            except json.JSONDecodeError:
                raw = {
                    "locked_ip": "",
                    "connections": 0,
                    "active_ips": [],
                    "recent_incoming": [],
                    "blocked_ips": [],
                }
        state = self.derive_port_state(raw)
        active_list = self._parse_ip_list(raw, "active_ips")
        incoming_list = self._parse_ip_list(raw, "recent_incoming")
        blocked_list = self._parse_ip_list(raw, "blocked_ips")
        return {
            "port": port,
            "name": found[1].get("name") if found else None,
            "method": found[1].get("method", DEFAULT_METHOD) if found else DEFAULT_METHOD,
            "locked_ip": (raw.get("locked_ip") or "") or None,
            "connections": int(raw.get("connections") or 0),
            "active_ips": active_list,
            "recent_incoming": incoming_list,
            "blocked_ips": blocked_list,
            "state": state,
            "state_label": self.state_label(state),
            "assigned": found is not None,
        }

    def all_port_statuses(self) -> List[Dict[str, Any]]:
        items = []
        for port_str in sorted(self.ports.keys(), key=lambda x: int(x)):
            items.append(self.port_status(int(port_str)))
        return items

    def show_key(self, name: str) -> Dict[str, Any]:
        found = self.find_by_name(name)
        if not found:
            raise ValueError(f"Anahtar bulunamadı: {name}")
        port, entry = found
        payload = self.key_payload(port, entry)
        payload["status"] = self.port_status(port)
        return payload

    def set_lock_ip(self, name: str, ip: str) -> Dict[str, Any]:
        found = self.find_by_name(name)
        if not found:
            raise ValueError(f"Anahtar bulunamadı: {name}")
        port, entry = found
        self.client.set_ip(port, ip)
        entry["locked_ip"] = ip
        self.ports[str(port)] = entry
        self.save()
        return {"ok": True, "name": name, "port": port, "ip": ip}

    def clear_lock_ip(self, name: str) -> None:
        found = self.find_by_name(name)
        if not found:
            raise ValueError(f"Anahtar bulunamadı: {name}")
        port, entry = found
        self.client.clear_ip(port)
        entry["locked_ip"] = None
        self.ports[str(port)] = entry
        self.save()

    def sync_to_manager(self) -> Dict[str, Any]:
        """ports.json kayitlarini ss-manager'a yukler (manager restart sonrasi)."""
        manager_ports: set = set()
        try:
            for item in self.client.list_ports():
                port_val = item.get("server_port") or item.get("port")
                if port_val is not None:
                    manager_ports.add(int(port_val))
        except Exception:
            pass

        added = 0
        skipped = 0
        errors: List[Dict[str, Any]] = []

        for port_str in sorted(self.ports.keys(), key=lambda x: int(x)):
            port = int(port_str)
            entry = self.ports[port_str]
            method = entry.get("method", DEFAULT_METHOD)
            password = entry["password"]
            locked_ip = (entry.get("locked_ip") or "").strip()

            if port in manager_ports:
                skipped += 1
                if locked_ip:
                    try:
                        status = self.client.ip_status(port)
                        current = (status.get("locked_ip") or "").strip()
                        if current != locked_ip:
                            self.client.set_ip(port, locked_ip)
                    except Exception as exc:
                        errors.append(
                            {"port": port, "name": entry.get("name"), "error": f"lock_ip: {exc}"}
                        )
                continue

            try:
                self.client.add_port(port, password, method)
                if locked_ip:
                    self.client.set_ip(port, locked_ip)
                added += 1
            except Exception as exc:
                errors.append({"port": port, "name": entry.get("name"), "error": str(exc)})

        return {
            "total": len(self.ports),
            "already_active": skipped,
            "added": added,
            "errors": errors,
        }
