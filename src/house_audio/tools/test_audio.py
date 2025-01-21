#!/usr/bin/env python3

import asyncio
import logging
import subprocess
from typing import Dict, Optional
from ..interfaces.audio import AudioInterface
from ..interfaces.bluetooth import BluetoothInterface


class AudioTester:
    def __init__(self):
        self.logger = logging.getLogger("audio_test")
        self.audio = AudioInterface()
        self.bluetooth = BluetoothInterface()
        self.connected_devices: Dict[str, dict] = {}  # All connected devices
        self.device_routes: Dict[str, str] = {}  # MAC -> output device
        self.outputs: Dict[str, dict] = {}  # Available audio outputs

    async def setup(self):
        """Initialize interfaces and discover devices"""
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
        """Show available audio outputs and their status"""
        print("\nAvailable outputs:")
        for name, info in self.outputs.items():
            vol = await self.audio.get_volume(name)
            print(f"- {name} ({info['card_name']})")
            if vol is not None:
                print(f"  → Volume: {int(vol * 100)}%")
            else:
                print("  → Volume: Not available")
            # Show which devices are routed here
            routed = [mac for mac, out in self.device_routes.items() if out == name]
            if routed:
                print("  → Connected devices:")
                for mac in routed:
                    device = self.connected_devices.get(mac, {})
                    print(f"    - {device.get('name', mac)}")

    async def handle_device_connect(self, mac: str, device_info: dict):
        """Handle new device connection"""
        self.connected_devices[mac] = device_info
        name = device_info.get("name", mac)
        self.logger.info(f"Device connected: {name}")
        self.logger.info(f"Use 'route {mac} <output>' to route audio")
        await self.show_outputs()

    async def handle_device_disconnect(self, mac: str):
        """Handle device disconnection"""
        if mac in self.connected_devices:
            name = self.connected_devices[mac].get("name", mac)
            self.logger.info(f"Device disconnected: {name}")
            del self.connected_devices[mac]
            if mac in self.device_routes:
                del self.device_routes[mac]

    async def route_audio(self, mac: str, output: str):
        """Route audio from device to specific output"""
        if mac not in self.connected_devices:
            raise ValueError(f"Device {mac} not connected")
        if output not in self.outputs:
            raise ValueError(f"Output {output} not available")

        # Update routing
        self.device_routes[mac] = output
        name = self.connected_devices[mac].get("name", mac)
        self.logger.info(f"Routing {name} → {output}")

        # Configure audio chain
        try:
            # Set initial volume
            await self.set_output_volume(output, 50)
            # Test route with short tone
            await self.test_output(output)
        except Exception as e:
            self.logger.error(f"Failed to configure route: {e}")
            del self.device_routes[mac]
            raise

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

    async def set_device_volume(self, mac: str, volume: float):
        """Set volume for a specific device's output"""
        if mac not in self.connected_devices:
            raise ValueError(f"Device {mac} not connected")
        if not 0 <= volume <= 100:
            raise ValueError("Volume must be between 0 and 100")

        output = self.device_routes.get(mac)
        if not output:
            raise ValueError(f"Device {mac} not routed to any output")

        await self.set_output_volume(output, volume)
        name = self.connected_devices[mac].get("name", mac)
        self.logger.info(f"Set volume for {name} → {output}: {volume}%")

    async def set_output_volume(self, output: str, volume: float):
        """Set volume for a specific output"""
        if output not in self.outputs:
            raise ValueError(f"Output {output} not available")
        if not 0 <= volume <= 100:
            raise ValueError("Volume must be between 0 and 100")

        await self.audio.set_volume(output, volume / 100)
        self.logger.info(f"Set {output} volume to {volume}%")

    async def test_all(self):
        """Test all available outputs"""
        print("\nTesting all outputs...")
        for output in self.outputs:
            print(f"\nTesting {output}:")
            print("1. Setting volume to 50%")
            await self.set_output_volume(output, 50)
            print("2. Playing test tone")
            await self.test_output(output)
            print("3. Resetting volume")
            await self.set_output_volume(output, 0)

    async def interactive_mode(self):
        """Interactive testing mode"""
        print("\nBluebard Audio Tester")
        print("\nCommands:")
        print("s: Show connected devices")
        print("o: Show available outputs")
        print("r: Show current routing")
        print("route <mac> <output>: Route device to output")
        print("v <mac> <0-100>: Set device volume")
        print("m <output> <0-100>: Set output volume")
        print("t: Test all outputs")
        print("h: Show this help")
        print("q: Quit")

        while True:
            try:
                cmd = input("\n> ").strip()
                if cmd == "q":
                    break
                elif cmd == "s":
                    await self.show_devices()
                elif cmd == "o":
                    await self.show_outputs()
                elif cmd == "r":
                    await self.show_devices()
                    await self.show_outputs()
                elif cmd == "t":
                    await self.test_all()
                elif cmd == "h":
                    await self.interactive_mode()
                elif cmd.startswith("route "):
                    _, mac, output = cmd.split()
                    await self.route_audio(mac, output)
                elif cmd.startswith("v "):
                    _, mac, vol = cmd.split()
                    await self.set_device_volume(mac, float(vol))
                elif cmd.startswith("m "):
                    _, output, vol = cmd.split()
                    await self.set_output_volume(output, float(vol))
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

        # Clean up interfaces
        await self.bluetooth.cleanup()
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
