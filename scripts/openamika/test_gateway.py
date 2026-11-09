"""Exercise forwarding and leases with real HTTP and WebSocket connections."""

import asyncio
import unittest
from unittest.mock import AsyncMock, patch

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

import gateway


class GatewayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        async def use(request):
            return web.Response(text="ready")

        async def echo(request):
            return web.json_response({"body": await request.text(),
                "auth": request.headers.get("Authorization"),
                "query": request.query.get("name"),
                "host": request.headers.get("Host"),
                "proto": request.headers.get("X-Forwarded-Proto"),
                "xff": request.headers.get("X-Forwarded-For")})

        async def socket(request):
            ws = web.WebSocketResponse()
            await ws.prepare(request)
            async for msg in ws:
                await ws.send_str(msg.data)
            return ws

        backend = web.Application()
        backend.router.add_get("/use", use)
        backend.router.add_post("/echo", echo)
        backend.router.add_get("/ws", socket)
        self.backend = TestServer(backend)
        await self.backend.start_server()
        self.proxy = gateway.Gateway(str(self.backend.make_url("/")).rstrip("/"),
                                     "docker-openamika.service", idle_seconds=1)
        self.proxy.systemctl = AsyncMock(return_value=0)
        self.client = TestClient(TestServer(self.proxy.application()))
        await self.client.start_server()

    async def asyncTearDown(self):
        await self.client.close()
        await self.backend.close()

    async def test_health_does_not_wake_or_hold_lease(self):
        self.proxy.ready = AsyncMock(return_value=False)
        resp = await self.client.get("/_gateway/health")
        self.assertEqual(resp.status, 200)
        self.proxy.systemctl.assert_not_awaited()
        self.assertEqual(self.proxy.users, 0)

    async def test_http_preserves_payload_and_query_but_strips_login(self):
        resp = await self.client.post("/echo?name=Ivan", data="voice text",
                                      headers={"Authorization": "Basic private",
                                               "Host": "openamika.hu-tao.dev",
                                               "X-Forwarded-Proto": "http",
                                               "X-Forwarded-For": "6.6.6.6"})
        self.assertEqual(await resp.json(), {"body": "voice text", "auth": None, "query": "Ivan",
                                             "host": "openamika.hu-tao.dev", "proto": "https",
                                             "xff": None})

    async def test_systemctl_names_the_configured_unit(self):
        with patch("asyncio.create_subprocess_exec") as spawn:
            spawn.return_value.wait = AsyncMock(return_value=0)
            await gateway.Gateway("http://x", "docker-openamika.service").systemctl("start")
        spawn.assert_called_once_with("systemctl", "start", "docker-openamika.service")

    async def test_websocket_holds_lease_until_disconnected(self):
        ws = await self.client.ws_connect("/ws")
        await ws.send_str("hello")
        self.assertEqual((await ws.receive()).data, "hello")
        self.proxy.last_used = 0
        await self.proxy.reap_once()
        self.proxy.systemctl.assert_not_awaited()
        await ws.close()
        for _ in range(100):
            if not self.proxy.users:
                break
            await asyncio.sleep(0.01)
        self.assertEqual(self.proxy.users, 0)
        self.proxy.last_used = 0
        await self.proxy.reap_once()
        self.proxy.systemctl.assert_awaited_once_with("stop")

    async def test_cap_refusal_returns_retryable_503(self):
        self.proxy.ready = AsyncMock(return_value=False)
        self.proxy.systemctl = AsyncMock(return_value=1)
        resp = await self.client.get("/use")
        self.assertEqual(resp.status, 503)
        self.assertEqual(resp.headers["Retry-After"], "30")
        self.assertEqual(self.proxy.users, 0)

    async def test_concurrent_cold_requests_start_once(self):
        running = False

        async def ready():
            return running

        async def command(*args):
            nonlocal running
            await asyncio.sleep(0.01)
            if args == ("start",):
                running = True
            return 0

        self.proxy.ready = ready
        self.proxy.systemctl = AsyncMock(side_effect=command)
        responses = await asyncio.gather(*(self.client.get("/use") for _ in range(4)))
        self.assertTrue(all(r.status == 200 for r in responses))
        self.assertEqual(self.proxy.systemctl.await_args_list.count(unittest.mock.call("start")), 1)


if __name__ == "__main__":
    unittest.main()
