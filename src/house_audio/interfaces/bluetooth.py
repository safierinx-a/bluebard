import asyncio
from typing import Dict, Optional, List
import logging
import subprocess
import re
import json


class BluetoothInterface:
    """Interface for Bluetooth audio devices using PipeWire"""

    def __init__(self):
        self.logger = logging.getLogger(__name__)
        self.devices = {}
        self.audio_devices = {}  # Devices with A2DP profile
        self._monitor_task = None

    async def setup(self):
        """Initialize Bluetooth interface"""
        try:
            # Verify PipeWire Bluetooth is running
            await self._verify_services()

            # Set up pairing agent
            await self._setup_agent()

            # Make discoverable
            await self.set_discoverable(True)

            # Get initial device list
            await self.scan_devices()

            # Start signal monitoring in background
            self._monitor_task = asyncio.create_task(self.start_signal_monitoring())

        except Exception as e:
            self.logger.error(f"Bluetooth setup failed: {e}")
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
            await self.set_discoverable(False)

            # Disconnect devices
            active = await self.get_active_devices()
            for mac in active:
                await self.disconnect_device(mac)

        except Exception as e:
            self.logger.error(f"Cleanup failed: {e}")

    async def _verify_services(self):
        """Verify required services are running"""
        try:
            # Check PipeWire services
            for service in ["pipewire", "pipewire-pulse", "wireplumber"]:
                proc = await asyncio.create_subprocess_exec(
                    "systemctl",
                    "--user",
                    "is-active",
                    service,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout, _ = await proc.communicate()
                if stdout.decode().strip() != "active":
                    raise RuntimeError(f"Service {service} not running")

            # Check Bluetooth service
            proc = await asyncio.create_subprocess_exec(
                "systemctl",
                "is-active",
                "bluetooth",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, _ = await proc.communicate()
            if stdout.decode().strip() != "active":
                raise RuntimeError("Bluetooth service not running")

        except Exception as e:
            self.logger.error(f"Service verification failed: {e}")
            raise

    async def _setup_agent(self):
        """Configure Bluetooth agent for pairing"""
        try:
            # Use async subprocess for better error handling
            # Remove existing agents
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl",
                "agent",
                "off",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()

            # Set up DisplayOnly agent for PIN code pairing
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl",
                "agent",
                "DisplayOnly",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()
            if proc.returncode != 0:
                self.logger.error(f"Failed to set agent mode: {stderr.decode()}")
                # Continue anyway - some systems don't support DisplayOnly
                self.logger.info("Falling back to NoInputNoOutput agent")
                proc = await asyncio.create_subprocess_exec(
                    "bluetoothctl",
                    "agent",
                    "NoInputNoOutput",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout, stderr = await proc.communicate()
                if proc.returncode != 0:
                    self.logger.error(
                        f"Failed to set fallback agent: {stderr.decode()}"
                    )
                    return False

            # Set as default
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl",
                "default-agent",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()
            if proc.returncode != 0:
                self.logger.error(f"Failed to set default agent: {stderr.decode()}")
                # Not a fatal error - continue
                self.logger.warning("Agent setup incomplete but continuing")

            return True
        except Exception as e:
            self.logger.error(f"Failed to setup agent: {e}")
            return False

    async def set_discoverable(self, enabled: bool):
        """Set discoverable mode"""
        try:
            mode = "on" if enabled else "off"
            subprocess.run(
                ["bluetoothctl", "discoverable", mode], check=True, capture_output=True
            )
            subprocess.run(
                ["bluetoothctl", "pairable", mode], check=True, capture_output=True
            )
            if enabled:
                # Set no timeout when enabling
                subprocess.run(
                    ["bluetoothctl", "discoverable-timeout", "0"],
                    check=True,
                    capture_output=True,
                )
            return True
        except Exception as e:
            logging.error(f"Failed to set discoverable mode: {e}")
            return False

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
            # Set up notification monitoring
            proc_notify = await asyncio.create_subprocess_exec(
                "bluetoothctl",
                "--monitor",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            # Remove device if previously paired
            subprocess.run(
                ["bluetoothctl", "remove", mac], check=True, capture_output=True
            )

            # Trust device first
            subprocess.run(
                ["bluetoothctl", "trust", mac], check=True, capture_output=True
            )

            # Pair device with timeout
            proc = await asyncio.create_subprocess_exec(
                "bluetoothctl",
                "pair",
                mac,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )

            # Monitor for pairing events
            while True:
                if proc_notify.stdout:
                    line = await proc_notify.stdout.readline()
                    if b"Pairing successful" in line:
                        self.logger.info(f"Successfully paired with {mac}")
                        break
                    elif b"Failed to pair" in line:
                        self.logger.error(f"Failed to pair with {mac}")
                        return False

            # Wait for pairing with timeout
            try:
                stdout, stderr = await asyncio.wait_for(
                    proc.communicate(), timeout=30.0
                )
                if proc.returncode != 0:
                    self.logger.error(f"Pairing failed: {stderr.decode()}")
                    return False
            except asyncio.TimeoutError:
                self.logger.error("Pairing timed out")
                return False

            # Connect
            result = subprocess.run(
                ["bluetoothctl", "connect", mac],
                capture_output=True,
                text=True,
            )

            if "Connection successful" in result.stdout:
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
            # Use pw-dump to get active Bluetooth sources
            proc = await asyncio.create_subprocess_exec(
                "pw-dump",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, _ = await proc.communicate()

            devices = []
            nodes = json.loads(stdout.decode())
            for node in nodes:
                if node.get("type") == "PipeWire:Interface:Node":
                    props = node.get("info", {}).get("props", {})
                    if props.get(
                        "media.class"
                    ) == "Audio/Source" and "bluez" in props.get("node.name", ""):
                        # Extract MAC from node name (bluez_source.XX_XX_XX_XX_XX_XX)
                        mac = props["node.name"].split(".")[-1].replace("_", ":")
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
