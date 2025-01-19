import asyncio
from typing import Dict, Optional, List
import logging
import subprocess
import re
import json


class BluetoothInterface:
    """Interface to BlueALSA for Bluetooth audio devices"""

    def __init__(self):
        self.logger = logging.getLogger(__name__)
        self.devices = {}
        self.audio_devices = {}  # Devices with A2DP profile
        self._monitor_task = None

    async def setup(self):
        """Initialize BlueALSA"""
        try:
            # Verify bluealsa is running
            await self._verify_bluealsa()

            # Make discoverable
            await self._set_discoverable(True)

            # Get initial device list
            await self.scan_devices()

            # Start signal monitoring in background
            self._monitor_task = asyncio.create_task(self.start_signal_monitoring())

        except Exception as e:
            self.logger.error(f"BlueALSA setup failed: {e}")
            raise

    async def cleanup(self):
        """Cleanup resources"""
        try:
            # Stop monitoring
            if self._monitor_task:
                self._monitor_task.cancel()
                try:
                    await self._monitor_task
                except asyncio.CancelledError:
                    pass

            # Turn off discoverable
            await self._set_discoverable(False)

            # Disconnect devices
            active = await self.get_active_devices()
            for mac in active:
                await self.disconnect_device(mac)

        except Exception as e:
            self.logger.error(f"Cleanup failed: {e}")

    async def _verify_bluealsa(self):
        """Verify BlueALSA service is running and configured"""
        try:
            # Check service
            proc = await asyncio.create_subprocess_exec(
                "systemctl", "is-active", "bluealsa", stdout=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()
            if proc.returncode != 0:
                raise RuntimeError("BlueALSA service not running")

            # Check bluealsa-aplay
            proc = await asyncio.create_subprocess_exec(
                "bluealsa-aplay",
                "--list-devices",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()
            if proc.returncode != 0:
                raise RuntimeError(f"BlueALSA check failed: {stderr.decode()}")

        except Exception as e:
            self.logger.error(f"BlueALSA verification failed: {e}")
            raise

    async def _set_discoverable(self, enabled: bool):
        """Set discoverable mode"""
        try:
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl",
                "discoverable",
                "on" if enabled else "off",
                stdout=asyncio.subprocess.PIPE,
            )
            await proc.communicate()
        except Exception as e:
            self.logger.error(f"Failed to set discoverable mode: {e}")
            raise

    async def scan_devices(self) -> Dict[str, Dict]:
        """Scan for Bluetooth audio devices"""
        try:
            # Get connected devices from bluetoothctl
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl", "devices", stdout=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()

            devices = self._parse_bluetoothctl_devices(stdout.decode())

            # Check which devices support A2DP
            for mac in devices:
                info = await self._get_device_info(mac)
                if "Audio" in info.get("Class", ""):
                    self.audio_devices[mac] = {**devices[mac], **info}

            return self.audio_devices

        except Exception as e:
            self.logger.error(f"Device scan failed: {e}")
            raise

    def _parse_bluetoothctl_devices(self, output: str) -> Dict[str, Dict]:
        """Parse bluetoothctl devices output"""
        devices = {}
        for line in output.split("\n"):
            if not line.strip():
                continue
            parts = line.strip().split(" ", 2)
            if len(parts) >= 3:
                mac = parts[1]
                name = parts[2]
                devices[mac] = {
                    "name": name,
                    "mac": mac,
                    "connected": False,
                    "trusted": False,
                }
        return devices

    async def _get_device_info(self, mac: str) -> Dict:
        """Get detailed device info"""
        try:
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl", "info", mac, stdout=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()

            info = {}
            for line in stdout.decode().split("\n"):
                if ":" in line:
                    key, value = line.split(":", 1)
                    info[key.strip()] = value.strip()

            return info

        except Exception as e:
            self.logger.error(f"Failed to get device info for {mac}: {e}")
            return {}

    async def connect_device(self, mac: str) -> bool:
        """Connect to a Bluetooth device"""
        try:
            # Trust device first
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl", "trust", mac, stdout=asyncio.subprocess.PIPE
            )
            await proc.communicate()

            # Connect
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl", "connect", mac, stdout=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()

            if b"Connection successful" in stdout:
                if mac in self.audio_devices:
                    self.audio_devices[mac]["connected"] = True
                return True
            return False

        except Exception as e:
            self.logger.error(f"Failed to connect device {mac}: {e}")
            return False

    async def disconnect_device(self, mac: str) -> bool:
        """Disconnect a Bluetooth device"""
        try:
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl", "disconnect", mac, stdout=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()

            if b"Successful disconnected" in stdout:
                if mac in self.audio_devices:
                    self.audio_devices[mac]["connected"] = False
                return True
            return False

        except Exception as e:
            self.logger.error(f"Failed to disconnect device {mac}: {e}")
            return False

    async def get_active_devices(self) -> List[str]:
        """Get list of connected audio devices"""
        try:
            proc = await asyncio.create_subprocess_exec(
                "bluealsa-aplay", "--list-devices", stdout=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()

            devices = []
            for line in stdout.decode().split("\n"):
                if "=" in line:
                    mac = line.split("=")[1].strip()
                    devices.append(mac)

            return devices

        except Exception as e:
            self.logger.error(f"Failed to get active devices: {e}")
            return []

    async def monitor_signal_strength(self, mac: str) -> Optional[float]:
        """Get signal strength (RSSI) for a device"""
        try:
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl",
                "info",
                mac,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, _ = await proc.communicate()

            # Parse RSSI from info
            for line in stdout.decode().split("\n"):
                if "RSSI:" in line:
                    rssi = int(line.split(":")[1].strip())
                    if mac in self.audio_devices:
                        self.audio_devices[mac]["rssi"] = rssi
                    return rssi
            return None

        except Exception as e:
            self.logger.error(f"Failed to get signal strength for {mac}: {e}")
            return None

    async def start_signal_monitoring(self):
        """Start monitoring signal strength of connected devices"""
        while True:
            try:
                active = await self.get_active_devices()
                for mac in active:
                    rssi = await self.monitor_signal_strength(mac)
                    if (
                        rssi is not None and rssi < -80
                    ):  # Typical threshold for poor connection
                        self.logger.warning(
                            f"Weak Bluetooth signal for {mac}: {rssi} dBm"
                        )

                await asyncio.sleep(5)  # Check every 5 seconds

            except asyncio.CancelledError:
                break
            except Exception as e:
                self.logger.error(f"Signal monitoring error: {e}")
                await asyncio.sleep(5)  # Wait before retry

    async def get_status(self) -> Dict:
        """Get current Bluetooth status"""
        return {
            "devices": self.audio_devices,
            "active": await self.get_active_devices(),
            "signal_quality": {
                mac: {
                    "rssi": device.get("rssi"),
                    "quality": "good" if device.get("rssi", -100) > -80 else "poor",
                }
                for mac, device in self.audio_devices.items()
                if device.get("connected")
            },
        }
