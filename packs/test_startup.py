"""Output-reader regressions using real child processes, without Java or downloads.

Run with: python3 -I -m unittest discover -s packs -p test_startup.py
"""

from asyncio import create_subprocess_exec, wait_for
from asyncio.subprocess import Process
from pathlib import Path
from subprocess import PIPE, STDOUT
from sys import executable
from unittest import IsolatedAsyncioTestCase, main
from unittest.mock import patch

from startup import wait_for_server


class StartupTests(IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.processes: list[Process] = []

    async def asyncTearDown(self) -> None:
        for process in self.processes:
            if process.returncode is None:
                process.kill()
            await process.wait()

    async def boot(self, program: str, startup_timeout: float = 0.5) -> None:
        process = await create_subprocess_exec(
            executable, "-c", program, stdout=PIPE, stderr=STDOUT
        )
        self.processes.append(process)
        with (
            patch("startup.create_subprocess_exec", return_value=process),
            patch("startup.STARTUP_TIMEOUT_SECONDS", startup_timeout),
        ):
            try:
                await wait_for(wait_for_server("java", Path.cwd(), "test-pack"), timeout=3)
            finally:
                self.assertIsNotNone(process.returncode, "server was not stopped")

    async def test_ready_line_buffered_with_previous_line(self) -> None:
        await self.boot(
            "from os import write; from time import sleep; "
            "write(1, b'Loading\\nDone (0.1s)!\\n'); sleep(60)"
        )

    async def test_partial_line_cannot_block_timeout(self) -> None:
        with self.assertRaisesRegex(TimeoutError, "server did not reach Done"):
            await self.boot(
                "from os import write; from time import sleep; "
                "write(1, b'Loading'); sleep(60)"
            )

    async def test_silent_server_times_out(self) -> None:
        with self.assertRaisesRegex(TimeoutError, "server did not reach Done"):
            await self.boot("from time import sleep; sleep(60)")

    async def test_early_exit_reports_exit_code_promptly(self) -> None:
        with self.assertRaisesRegex(RuntimeError, r"server exited before Done \(exit 7\)"):
            await self.boot("raise SystemExit(7)", startup_timeout=30)


if __name__ == "__main__":
    main()
