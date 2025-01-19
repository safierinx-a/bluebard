import asyncio
import subprocess
from typing import Dict, List, Optional
import logging
import os
import re


class AudioInterface:
    """Audio interface using BlueALSA and ALSA for audio routing"""

    ASOUND_CONF = "/etc/asound.conf"

    def __init__(self):
        self.logger = logging.getLogger(__name__)
        self.routes = {}
        self.devices = {}

    async def setup(self):
        """Initialize audio system"""
        try:
            # Check dependencies
            self._check_dependencies()
            # Verify services
            await self._verify_services()
            # Discover devices
            await self.discover_devices()
        except Exception as e:
            self.logger.error(f"Audio setup failed: {e}")
            raise

    def _check_dependencies(self):
        """Verify required system components"""
        required = ["bluealsa", "bluealsa-aplay", "snapclient", "aplay"]
        for dep in required:
            try:
                subprocess.run(["which", dep], check=True, capture_output=True)
            except subprocess.CalledProcessError:
                raise RuntimeError(f"Missing dependency: {dep}")

    async def _verify_services(self):
        """Verify required services are running"""
        services = ["bluetooth", "bluealsa", "snapclient"]
        for service in services:
            proc = await asyncio.create_subprocess_exec(
                "systemctl", "is-active", service, stdout=asyncio.subprocess.PIPE
            )
            stdout, _ = await proc.communicate()
            if proc.returncode != 0:
                raise RuntimeError(f"Service {service} not running")

    async def discover_devices(self) -> Dict[str, Dict]:
        """Discover available audio devices"""
        try:
            proc = await asyncio.create_subprocess_exec(
                "aplay",
                "-l",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()

            if proc.returncode != 0:
                raise RuntimeError(f"Failed to list ALSA devices: {stderr.decode()}")

            self.devices = self._parse_aplay_output(stdout.decode())

            # Get current volumes
            for device_id in self.devices:
                try:
                    volume = await self.get_volume(device_id)
                    self.devices[device_id]["volume"] = volume
                except Exception:
                    self.devices[device_id]["volume"] = None

            return self.devices

        except Exception as e:
            self.logger.error(f"Device discovery failed: {e}")
            raise

    def _parse_aplay_output(self, output: str) -> Dict[str, Dict]:
        """Parse aplay -l output into device dictionary"""
        devices = {}
        current_card = None

        for line in output.split("\n"):
            card_match = re.match(r"card (\d+).*?\[(.*?)\]", line)
            if card_match:
                current_card = {
                    "id": int(card_match.group(1)),
                    "name": card_match.group(2),
                    "devices": [],
                }

            device_match = re.match(r"  Subdevice #(\d+)", line)
            if device_match and current_card:
                device_id = f"hw:{current_card['id']},{device_match.group(1)}"
                devices[device_id] = {
                    "card_id": current_card["id"],
                    "card_name": current_card["name"],
                    "device_id": int(device_match.group(1)),
                    "device_string": device_id,
                }

        return devices

    async def create_route(
        self, source: str, targets: List[str], volumes: Dict[str, float]
    ) -> str:
        """Create audio route with volumes"""
        try:
            config = self._generate_route_config(source, targets, volumes)
            route_id = f"route_{len(self.routes)}"
            await self._update_alsa_config(route_id, config)

            self.routes[route_id] = {
                "source": source,
                "targets": targets,
                "volumes": volumes,
            }
            return route_id

        except Exception as e:
            self.logger.error(f"Failed to create route: {e}")
            raise

    def _generate_route_config(
        self, source: str, targets: List[str], volumes: Dict[str, float]
    ) -> str:
        """Generate ALSA config for routing"""
        config = [
            f"""
        pcm.{source} {{
            type bluealsa
            device "{source}"
            profile "a2dp"
            interface "hci0"
        }}
        
        # Multi-device output
        pcm.multi_out {{
            type plug
            slave.pcm {{
                type multi
                slaves {{
        """
        ]

        # Add each target
        for i, target in enumerate(targets):
            volume = volumes.get(target, 1.0)
            config.append(f"""
                    {i} {{
                        pcm "hw:{target}"
                        volume {volume}
                    }}
            """)

        # Complete the config
        config.append("""
                }
            }
        }
        """)

        return "\n".join(config)

    async def _update_alsa_config(self, route_id: str, config: str):
        """Update ALSA configuration"""
        try:
            # Backup existing config
            if os.path.exists(self.ASOUND_CONF):
                await asyncio.create_subprocess_exec(
                    "cp", self.ASOUND_CONF, f"{self.ASOUND_CONF}.bak"
                )

            # Write new config
            async with open(self.ASOUND_CONF, "w") as f:
                await f.write(config)

            # Test config
            proc = await asyncio.create_subprocess_exec(
                "alsactl",
                "restore",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            _, stderr = await proc.communicate()
            if proc.returncode != 0:
                raise RuntimeError(f"ALSA config error: {stderr.decode()}")

        except Exception as e:
            self.logger.error(f"Failed to update ALSA config: {e}")
            # Restore backup if exists
            if os.path.exists(f"{self.ASOUND_CONF}.bak"):
                os.rename(f"{self.ASOUND_CONF}.bak", self.ASOUND_CONF)
            raise

    async def create_bluetooth_route(self, bt_mac: str, target_id: str) -> str:
        """Create route from Bluetooth device to audio output"""
        try:
            # Generate BlueALSA PCM config
            config = self._generate_bluealsa_config(bt_mac)

            # Add route to target
            route_id = await self.create_route(bt_mac, [target_id], {target_id: 1.0})

            return route_id

        except Exception as e:
            self.logger.error(f"Failed to create Bluetooth route: {e}")
            raise

    def _generate_bluealsa_config(self, bt_mac: str) -> str:
        """Generate BlueALSA PCM configuration"""
        return f"""
        pcm.bluealsa_{bt_mac.replace(":", "_")} {{
            type bluealsa
            device "{bt_mac}"
            profile "a2dp"
            interface "hci0"
        }}
        """

    async def set_volume(self, device_id: str, volume: float) -> None:
        """Set volume for device (0.0 to 1.0)"""
        if device_id not in self.devices:
            raise ValueError(f"Unknown device: {device_id}")

        try:
            volume_percent = int(max(0, min(100, volume * 100)))
            proc = await asyncio.create_subprocess_exec(
                "amixer",
                "-c",
                str(self.devices[device_id]["card_id"]),
                "sset",
                "Master",
                f"{volume_percent}%",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            _, stderr = await proc.communicate()

            if proc.returncode != 0:
                raise RuntimeError(f"Failed to set volume: {stderr.decode()}")

            self.devices[device_id]["volume"] = volume

        except Exception as e:
            self.logger.error(f"Failed to set volume for {device_id}: {e}")
            raise

    async def get_volume(self, device_id: str) -> Optional[float]:
        """Get current volume level for device"""
        try:
            proc = await asyncio.create_subprocess_exec(
                "amixer",
                "-c",
                str(self.devices[device_id]["card_id"]),
                "sget",
                "Master",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await proc.communicate()

            if proc.returncode != 0:
                raise RuntimeError(f"Failed to get volume: {stderr.decode()}")

            match = re.search(r"\[(\d+)%\]", stdout.decode())
            return float(match.group(1)) / 100 if match else None

        except Exception as e:
            self.logger.error(f"Failed to get volume for {device_id}: {e}")
            raise

    async def get_status(self) -> Dict:
        """Get current audio system status"""
        return {
            "devices": self.devices,
            "routes": self.routes,
        }
