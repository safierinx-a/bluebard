#!/usr/bin/env python3
import asyncio
import subprocess
import sys
from typing import List, Tuple


class SetupChecker:
    def __init__(self):
        self.errors = []
        self.warnings = []

    async def check_command(self, cmd: List[str], name: str) -> Tuple[bool, str]:
        """Check if a command exists and runs"""
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            stdout, stderr = await proc.communicate()
            if proc.returncode != 0:
                return False, f"{name} check failed: {stderr.decode()}"
            return True, f"{name} OK"
        except FileNotFoundError:
            return False, f"{name} not found"

    async def check_service(self, service: str) -> Tuple[bool, str]:
        """Check if a systemd service is running"""
        cmd = ["systemctl", "is-active", service]
        return await self.check_command(cmd, f"Service {service}")

    async def check_dependencies(self):
        """Check all required dependencies"""
        # Check commands
        commands = [
            (["bluealsa", "--version"], "BlueALSA"),
            (["bluealsa-aplay", "--help"], "BlueALSA-aplay"),
            (["bluetoothctl", "--version"], "Bluetoothctl"),
        ]

        for cmd, name in commands:
            ok, msg = await self.check_command(cmd, name)
            if not ok:
                self.errors.append(msg)
            print(f"✓ {msg}" if ok else f"✗ {msg}")

        # Check services
        services = ["bluetooth", "bluealsa"]
        for service in services:
            ok, msg = await self.check_service(service)
            if not ok:
                self.errors.append(msg)
            print(f"✓ {msg}" if ok else f"✗ {msg}")

        # Check user permissions
        groups = subprocess.check_output(["groups"]).decode()
        if "bluetooth" not in groups:
            self.warnings.append("User not in bluetooth group")
            print("✗ Bluetooth permissions")
        else:
            print("✓ Bluetooth permissions")


async def main():
    checker = SetupChecker()
    print("Checking Bluebard setup...")
    await checker.check_dependencies()

    if checker.warnings:
        print("\nWarnings:")
        for warning in checker.warnings:
            print(f"! {warning}")

    if checker.errors:
        print("\nErrors:")
        for error in checker.errors:
            print(f"✗ {error}")
        sys.exit(1)
    else:
        print("\nAll checks passed!")


if __name__ == "__main__":
    asyncio.run(main())
