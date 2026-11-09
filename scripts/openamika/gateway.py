"""Private Caddy upstream: wake the stack and stop it after disconnected idle.

Only a Unix socket is exposed. Caddy authenticates before forwarding here.
Persistent browser WebSockets hold a lease; background HTTP health checks do
not wake the stack. The upstream and the managed unit come from argv, which
only the Nix module writes.
"""

import asyncio
import contextlib
import os
import sys
import time

from aiohttp import ClientError, ClientSession, ClientTimeout, WSMsgType, web

HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
       "te", "trailer", "transfer-encoding", "upgrade", "host", "authorization",
       "x-forwarded-for", "x-forwarded-proto", "x-forwarded-host", "forwarded"}


def forwarded(request):
    """Headers for upstream: the browser's own, minus hop-by-hop and login.

    Host and X-Forwarded-Proto are what upstream's same-origin check compares
    the browser's Origin against; without them it sees the container address
    over http and refuses the memory reset. Caddy is the only client of the
    socket and terminates TLS, so the scheme is always https. Client-supplied
    X-Forwarded-* are dropped above and never passed through.
    """
    headers = {k: v for k, v in request.headers.items() if k.lower() not in HOP}
    headers["Host"] = request.host
    headers["X-Forwarded-Proto"] = "https"
    return headers


class Gateway:
    def __init__(self, upstream, unit, idle_seconds=1200):
        self.upstream = upstream
        self.unit = unit
        self.idle_seconds = idle_seconds
        self.last_used = time.monotonic()
        self.users = 0
        self.lock = asyncio.Lock()
        self.session = None

    async def systemctl(self, *args):
        proc = await asyncio.create_subprocess_exec("systemctl", *args, self.unit)
        return await proc.wait()

    async def ready(self):
        try:
            async with self.session.get(self.upstream + "/use", timeout=ClientTimeout(total=2)) as resp:
                return resp.status == 200
        except (ClientError, asyncio.TimeoutError):
            return False

    async def wake(self):
        async with self.lock:
            if await self.ready():
                return
            await self.systemctl("start")
            if await self.systemctl("is-active", "--quiet"):
                raise web.HTTPServiceUnavailable(
                    text="Both high memory usage program slots are occupied, or OpenAmika failed to start. Try again once a program stops.",
                    headers={"Retry-After": "30"})
            deadline = time.monotonic() + 900
            while time.monotonic() < deadline:
                if await self.ready():
                    return
                if await self.systemctl("is-active", "--quiet"):
                    break
                await asyncio.sleep(2)
            raise web.HTTPServiceUnavailable(text="OpenAmika is not ready. Check its service log.")

    async def handle(self, request):
        if request.path == "/_gateway/health":
            return web.Response(text="ok")
        # Acquire the lease BEFORE wake: an idle shutdown cannot race a new
        # request. The wake/stop lock also serializes concurrent cold starts.
        self.users += 1
        try:
            await self.wake()
            headers = forwarded(request)
            url = self.upstream + request.raw_path
            if request.headers.get("Upgrade", "").lower() == "websocket":
                async with self.session.ws_connect(url, headers=headers, max_msg_size=32 * 1024**2) as upstream:
                    downstream = web.WebSocketResponse(max_msg_size=32 * 1024**2)
                    await downstream.prepare(request)

                    async def relay(source, target):
                        async for msg in source:
                            if msg.type == WSMsgType.TEXT:
                                await target.send_str(msg.data)
                            elif msg.type == WSMsgType.BINARY:
                                await target.send_bytes(msg.data)
                            elif msg.type == WSMsgType.ERROR:
                                break

                    tasks = [asyncio.create_task(relay(downstream, upstream)),
                             asyncio.create_task(relay(upstream, downstream))]
                    try:
                        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                    finally:
                        for task in tasks:
                            task.cancel()
                        await asyncio.gather(*tasks, return_exceptions=True)
                        await downstream.close()
                    return downstream
            async with self.session.request(request.method, url, headers=headers,
                                            data=request.content, allow_redirects=False) as response:
                result = web.StreamResponse(status=response.status,
                    headers={k: v for k, v in response.headers.items() if k.lower() not in HOP})
                await result.prepare(request)
                async for chunk in response.content.iter_chunked(65536):
                    await result.write(chunk)
                await result.write_eof()
                return result
        except ClientError as exc:
            raise web.HTTPBadGateway(text="OpenAmika connection failed") from exc
        finally:
            self.users -= 1
            self.last_used = time.monotonic()

    async def reap(self):
        while True:
            await asyncio.sleep(15)
            await self.reap_once()

    async def reap_once(self):
        async with self.lock:
            if not self.users and time.monotonic() - self.last_used >= self.idle_seconds:
                await self.systemctl("stop")
                self.last_used = time.monotonic()

    async def lifecycle(self, app):
        # Preserve compression bytes/headers while streaming transparently.
        async with ClientSession(auto_decompress=False, timeout=ClientTimeout(total=None)) as session:
            self.session = session
            task = asyncio.create_task(self.reap())
            try:
                yield
            finally:
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task

    def application(self):
        app = web.Application(client_max_size=32 * 1024**2)
        app.cleanup_ctx.append(self.lifecycle)
        app.router.add_route("*", "/{path:.*}", self.handle)
        return app


if __name__ == "__main__":
    upstream, unit = sys.argv[1:]
    socket = "/run/openamika-gateway/http.sock"
    with contextlib.suppress(FileNotFoundError):
        os.unlink(socket)
    os.umask(0o007)
    web.run_app(Gateway(upstream, unit).application(), path=socket)
