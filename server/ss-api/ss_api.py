#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Outline-compatible HTTP API for shadowsocks-libev (ss-manager backend).
"""

import argparse
import asyncio
import json
import logging
from typing import Any, Dict

from aiohttp import web

from key_store import DEFAULT_METHOD, KeyManager

logging.basicConfig(level=logging.WARNING, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("ss-api")


class SSApiServer:
    def __init__(
        self,
        manager_address: str,
        server_ip: str,
        api_secret: str = "",
        port_store_path: str = "/var/lib/shadowsocks-manager/ports.json",
    ):
        self.keys = KeyManager(
            manager_address=manager_address,
            server_ip=server_ip,
            port_store_path=port_store_path,
        )
        self.api_secret = api_secret.strip("/")

    @property
    def ports(self):
        return self.keys.ports

    def _save_ports(self) -> None:
        self.keys.save()

    def _auth_ok(self, request: web.Request) -> bool:
        if not self.api_secret:
            return True
        path = request.path.strip("/")
        return path == self.api_secret or path.startswith(f"{self.api_secret}/")

    def _route_prefix(self, request: web.Request) -> str:
        if self.api_secret:
            return f"/{self.api_secret}"
        return ""

    async def _require_auth(self, request: web.Request):
        if not self._auth_ok(request):
            raise web.HTTPNotFound()

    def _key_payload(self, port: int, entry: Dict[str, Any]) -> Dict[str, Any]:
        return self.keys.key_payload(port, entry)

    async def handle_create_key(self, request: web.Request) -> web.Response:
        await self._require_auth(request)
        try:
            body = await request.json()
        except json.JSONDecodeError:
            body = {}
        port = body.get("port")
        name = body.get("name")
        if not name:
            name = f"port-{port}" if port is not None else "key"
        try:
            result = self.keys.add_key(
                name=name,
                port=int(port) if port is not None else None,
                password=body.get("password"),
                method=body.get("method", DEFAULT_METHOD),
            )
        except ValueError as exc:
            raise web.HTTPBadRequest(text=str(exc)) from exc
        except RuntimeError as exc:
            raise web.HTTPInternalServerError(text=str(exc)) from exc
        return web.json_response(result, status=201)

    async def handle_list_keys(self, request: web.Request) -> web.Response:
        await self._require_auth(request)
        keys = [self._key_payload(int(port), entry) for port, entry in self.ports.items()]
        return web.json_response({"accessKeys": keys})

    async def handle_delete_key(self, request: web.Request) -> web.Response:
        await self._require_auth(request)
        port = int(request.match_info["key_id"])
        if str(port) not in self.ports:
            raise web.HTTPNotFound()
        entry = self.ports[str(port)]
        name = entry.get("name", str(port))
        try:
            self.keys.delete_key(name)
        except ValueError:
            raise web.HTTPNotFound()
        return web.Response(status=204)

    async def handle_put_name(self, request: web.Request) -> web.Response:
        await self._require_auth(request)
        port = int(request.match_info["key_id"])
        if str(port) not in self.ports:
            raise web.HTTPNotFound()
        body = await request.json()
        self.ports[str(port)]["name"] = body.get("name", self.ports[str(port)].get("name"))
        self._save_ports()
        return web.Response(status=204)

    async def handle_lock_ip(self, request: web.Request) -> web.Response:
        await self._require_auth(request)
        port = int(request.match_info["key_id"])
        if str(port) not in self.ports:
            raise web.HTTPNotFound()
        body = await request.json()
        ip = body.get("ip")
        if not ip:
            raise web.HTTPBadRequest(text="ip required")
        self.keys.client.set_ip(port, ip)
        self.ports[str(port)]["locked_ip"] = ip
        self._save_ports()
        return web.json_response({"ok": True, "port": port, "ip": ip})

    async def handle_clear_lock_ip(self, request: web.Request) -> web.Response:
        await self._require_auth(request)
        port = int(request.match_info["key_id"])
        if str(port) not in self.ports:
            raise web.HTTPNotFound()
        self.keys.client.clear_ip(port)
        self.ports[str(port)]["locked_ip"] = None
        self._save_ports()
        return web.Response(status=204)

    async def handle_port_status(self, request: web.Request) -> web.Response:
        await self._require_auth(request)
        port = int(request.match_info["key_id"])
        if str(port) not in self.ports:
            raise web.HTTPNotFound()
        status = self.keys.port_status(port)
        return web.json_response(status)

    async def handle_server_info(self, request: web.Request) -> web.Response:
        await self._require_auth(request)
        return web.json_response(
            {
                "name": "shadowsocks-libev",
                "serverIp": self.keys.server_ip,
                "managerAddress": self.keys.client.manager_address,
                "method": DEFAULT_METHOD,
            }
        )

    async def _sync_manager_on_startup(self, app: web.Application) -> None:
        loop = asyncio.get_running_loop()
        try:
            result = await loop.run_in_executor(None, self.keys.sync_to_manager)
            if result["added"] or result["errors"]:
                logger.warning(
                    "ss-manager sync: total=%s added=%s already=%s errors=%s",
                    result["total"],
                    result["added"],
                    result["already_active"],
                    len(result["errors"]),
                )
        except Exception as exc:
            logger.error("ss-manager sync failed: %s", exc)

    def build_app(self) -> web.Application:
        app = web.Application()
        secret = f"/{self.api_secret}" if self.api_secret else ""
        app.on_startup.append(self._sync_manager_on_startup)

        app.router.add_post(f"{secret}/access-keys", self.handle_create_key)
        app.router.add_get(f"{secret}/access-keys", self.handle_list_keys)
        app.router.add_delete(f"{secret}/access-keys/{{key_id}}", self.handle_delete_key)
        app.router.add_put(f"{secret}/access-keys/{{key_id}}/name", self.handle_put_name)
        app.router.add_put(f"{secret}/access-keys/{{key_id}}/lock-ip", self.handle_lock_ip)
        app.router.add_delete(f"{secret}/access-keys/{{key_id}}/lock-ip", self.handle_clear_lock_ip)
        app.router.add_get(f"{secret}/access-keys/{{key_id}}/status", self.handle_port_status)
        app.router.add_get(f"{secret}/server", self.handle_server_info)
        return app


def main():
    parser = argparse.ArgumentParser(description="shadowsocks-libev Outline-compatible API")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8087)
    parser.add_argument("--manager-address", default="127.0.0.1:6001")
    parser.add_argument("--server-ip", required=True)
    parser.add_argument("--api-secret", default="")
    parser.add_argument("--port-store", default="/var/lib/shadowsocks-manager/ports.json")
    args = parser.parse_args()

    server = SSApiServer(
        manager_address=args.manager_address,
        server_ip=args.server_ip,
        api_secret=args.api_secret,
        port_store_path=args.port_store,
    )
    web.run_app(server.build_app(), host=args.host, port=args.port)


if __name__ == "__main__":
    main()
