#!/usr/bin/env python3

import asyncio
import logging
import subprocess
from typing import Dict, Optional
from ..interfaces.audio import AudioInterface
from ..interfaces.bluetooth import BluetoothInterface


class AudioTester:
    def __init__(self, mode: str = "standalone"):
        self.logger = logging.getLogger("audio_test")
        self.mode = mode
        self.audio = AudioInterface(mode=mode)
        self.bluetooth = BluetoothInterface()
        self.connected_devices = {}
        self.device_routes = {}
        self.outputs = {}

    async def setup(self):
        """Initialize interfaces"""
        await self.audio.setup()
        await self.bluetooth.setup()

        # Show available audio outputs
        self.outputs = await self.audio.discover_devices()
        self.logger.info("Available audio outputs:")
        for name, info in self.outputs.items():
            self.logger.info(f"  {name}: {info}")

        # Make discoverable
        await self.bluetooth.set_discoverable(True)
        self.logger.info("Bluetooth discoverable enabled")

    async def show_devices(self):
        """Show connected Bluetooth devices and their status"""
        status = await self.bluetooth.get_status()
        print("\nConnected devices:")
        for mac in status["active"]:
            device = status["devices"].get(mac, {})
            route = self.device_routes.get(mac, "not routed")
            print(f"- {device.get('name', mac)} ({mac})")
            print(f"  → Routed to: {route}")
            if mac in status["signal_quality"]:
                print(f"  → Signal: {status['signal_quality'][mac]['quality']}")
            if mac in self.device_routes:
                vol = await self.audio.get_volume(self.device_routes[mac])
                print(f"  → Volume: {int(vol * 100)}%")

    async def show_outputs(self):
        """Show available audio outputs"""
        print("\nAvailable outputs:")
        for name, info in self.outputs.items():
            vol = await self.audio.get_volume(name)
            print(f"- {name} ({info['name']})")
            if vol is not None:
                print(f"  → Volume: {int(vol * 100)}%")
            else:
                print("  → Volume: Not available")

    async def route_audio(self, mac: str, output: str, add_to_existing: bool = False):
        """Route audio from device to specific output"""
        if mac not in self.connected_devices:
            raise ValueError(f"Device {mac} not connected")
        if output not in self.outputs:
            raise ValueError(f"Output {output} not available")

        if add_to_existing:
            await self.audio.add_output_to_route(mac, output)
            self.device_routes[mac] = f"{self.device_routes.get(mac, '')}+{output}"
        else:
            # Create new route
            route_id = await self.audio.create_route(mac, output)
            self.device_routes[mac] = output

        name = self.connected_devices[mac].get("name", mac)
        self.logger.info(f"Routing {name} → {output}")

        # Set initial volume
        await self.set_output_volume(output, 50)

    async def set_output_volume(self, output: str, volume: float):
        """Set volume for a specific output"""
        if output not in self.outputs:
            raise ValueError(f"Output {output} not available")
        if not 0 <= volume <= 100:
            raise ValueError("Volume must be between 0 and 100")

        await self.audio.set_volume(output, volume / 100)
        self.logger.info(f"Set {output} volume to {volume}%")

    async def test_output(self, output: str, duration: int = 1):
        """Test an output with a short tone"""
        self.logger.info(f"Testing output {output}...")
        try:
            subprocess.run(
                ["speaker-test", "-D", output, "-t", "sine", "-f", "440", "-l", "1"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=duration,
            )
        except subprocess.TimeoutExpired:
            pass

    async def interactive_mode(self):
        """Interactive testing mode"""
        mode_str = (
            "Standalone Mode" if self.mode == "standalone" else "Distributed Mode"
        )
        print(f"\nBluebard Audio Tester ({mode_str})")
        print("\nCommands:")
        print("d: Show available audio devices")
        print("b: Show connected Bluetooth devices")
        print("r <mac> <device>: Route Bluetooth to device")
        print("a <mac> <device>: Add another output to existing route")
        print("v <device> <0-100>: Set device volume")
        print("t <device>: Test audio output")
        print("h: Show this help")
        print("q: Quit")

        while True:
            try:
                cmd = input("\n> ").strip().split()
                if not cmd:
                    continue

                if cmd[0] == "q":
                    break
                elif cmd[0] == "d":
                    await self.show_outputs()
                elif cmd[0] == "b":
                    await self.show_devices()
                elif cmd[0] == "r" and len(cmd) == 3:
                    await self.route_audio(cmd[1], cmd[2], add_to_existing=False)
                elif cmd[0] == "a" and len(cmd) == 3:
                    await self.route_audio(cmd[1], cmd[2], add_to_existing=True)
                elif cmd[0] == "v" and len(cmd) == 3:
                    await self.set_output_volume(cmd[1], float(cmd[2]))
                elif cmd[0] == "t" and len(cmd) == 2:
                    await self.test_output(cmd[1])
                elif cmd[0] == "h":
                    print("\nCommands:")
                    print("d: Show available audio devices")
                    print("b: Show connected Bluetooth devices")
                    print("r <mac> <device>: Route Bluetooth to device")
                    print("a <mac> <device>: Add another output to existing route")
                    print("v <device> <0-100>: Set device volume")
                    print("t <device>: Test audio output")
                    print("h: Show this help")
                    print("q: Quit")
                else:
                    print("Unknown command. Type 'h' for help.")
            except Exception as e:
                self.logger.error(f"Command failed: {e}")

    async def cleanup(self):
        """Clean up resources"""
        # Reset all volumes
        for output in self.outputs:
            try:
                await self.set_output_volume(output, 0)
            except Exception as e:
                self.logger.error(f"Failed to reset {output} volume: {e}")

        await self.bluetooth.cleanup()
        await self.audio.cleanup()
        self.logger.info("Cleanup complete")


async def main():
    """Main test function"""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    tester = AudioTester()

    try:
        await tester.setup()
        await tester.interactive_mode()
    except KeyboardInterrupt:
        print("\nShutting down...")
    except Exception as e:
        logging.error(f"Test failed: {e}")
    finally:
        await tester.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
