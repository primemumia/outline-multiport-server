#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""UDP/Unix client for shadowsocks-libev ss-manager."""

import json
import os
import socket
from typing import Any, Dict, Optional


class LibevManagerClient:
    def __init__(self, manager_address: str, timeout: float = 5.0):
        self.manager_address = manager_address
        self.timeout = timeout
        self._host, self._port = self._parse_address(manager_address)

    @staticmethod
    def _parse_address(address: str):
        if address.startswith("/"):
            return address, None
        if ":" in address:
            host, port = address.rsplit(":", 1)
            return host, int(port)
        return address, 6001

    def _send(self, command: str) -> str:
        if self._port is None:
            return self._send_unix(command, self._host)

        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        target = (self._host, self._port)
        sock.settimeout(self.timeout)
        try:
            sock.sendto(command.encode("utf-8"), target)
            data, _ = sock.recvfrom(65535)
            return data.decode("utf-8", errors="replace").strip("\x00")
        except socket.timeout as exc:
            raise RuntimeError(
                f"ss-manager yanit vermedi ({self.manager_address}). "
                f"Kontrol: systemctl status shadowsocks-manager"
            ) from exc
        finally:
            sock.close()

    def _send_unix(self, command: str, target: str) -> str:
        """Unix DGRAM: istemci bind etmezse ss-manager yanit gonderemez."""
        if not os.path.exists(target):
            raise RuntimeError(
                f"ss-manager socket yok: {target}\n"
                f"Servis calismiyor olabilir:\n"
                f"  systemctl status shadowsocks-manager\n"
                f"  journalctl -u shadowsocks-manager -n 30 --no-pager"
            )
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        client_path = f"/tmp/libev-cli-{os.getpid()}.sock"
        sock.settimeout(self.timeout)
        try:
            if os.path.exists(client_path):
                os.unlink(client_path)
            sock.bind(client_path)
            sock.sendto(command.encode("utf-8"), target)
            data, _ = sock.recvfrom(65535)
            return data.decode("utf-8", errors="replace").strip("\x00")
        except socket.timeout as exc:
            raise RuntimeError(
                f"ss-manager yanit vermedi ({self.manager_address}). "
                f"Kontrol: systemctl status shadowsocks-manager"
            ) from exc
        finally:
            sock.close()
            if os.path.exists(client_path):
                os.unlink(client_path)

    @staticmethod
    def _check_response(resp: str, action: str) -> None:
        if resp == "ok":
            return
        if resp == "err":
            raise RuntimeError(
                f"ss-manager '{action}' reddetti. "
                f"Log: journalctl -u shadowsocks-manager -n 30 --no-pager"
            )
        raise RuntimeError(resp or f"{action} failed")

    def _command(self, action: str, payload: Optional[dict] = None) -> str:
        """ss-manager protokolu: 'action: {json}' (iki nokta + bosluk zorunlu)."""
        if payload is None:
            message = action
        else:
            message = f"{action}: {json.dumps(payload, separators=(',', ':'))}"
        return self._send(message)

    def add_port(self, port: int, password: str, method: str = "chacha20-ietf-poly1305") -> None:
        payload = {
            "server_port": port,
            "password": password,
            "method": method,
        }
        resp = self._command("add", payload)
        self._check_response(resp, "add")

    def remove_port(self, port: int) -> None:
        payload = {"server_port": port}
        resp = self._command("remove", payload)
        self._check_response(resp, "remove")

    def list_ports(self) -> list:
        resp = self._command("list")
        if not resp:
            return []
        return json.loads(resp)

    def ping(self) -> Dict[str, Any]:
        resp = self._command("ping")
        if resp.startswith("stat:"):
            resp = resp.split(":", 1)[1].strip()
        return json.loads(resp or "{}")

    def set_ip(self, port: int, ip: str) -> None:
        payload = {"server_port": port, "ip": ip}
        resp = self._command("set_ip", payload)
        self._check_response(resp, "set_ip")

    def clear_ip(self, port: int) -> None:
        payload = {"server_port": port}
        resp = self._command("clear_ip", payload)
        self._check_response(resp, "clear_ip")

    def ip_status(self, port: int) -> Dict[str, Any]:
        payload = {"server_port": port}
        resp = self._command("ip_status", payload)
        try:
            return json.loads(resp or "{}")
        except json.JSONDecodeError:
            return {"locked_ip": "", "connections": 0, "active_ips": [],
                    "recent_incoming": [], "blocked_ips": []}
