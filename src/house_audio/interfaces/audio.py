#!/usr/bin/env python3

import asyncio
import subprocess
from typing import Dict, List, Optional
import logging
import os
import re
import json


class AudioInterface:
    """Audio interface using PipeWire for modern audio routing"""

    def __init__(self, mode: str = "standalone"):
        self.logger = logging.getLogger("audio")
        self.mode = mode
        self.outputs = {}
        self.routes = {}
        self.volumes = {}

    async def setup(self):
        """Initialize audio interface"""
        try:
            # Verify PipeWire is running
            await self._verify_services()

            # Initialize PipeWire connection
            proc = await asyncio.create_subprocess_exec(
                "pw-cli",
                "info",
                "0",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, _ = await proc.communicate()
            if proc.returncode != 0:
                raise RuntimeError("Failed to connect to PipeWire")

            # Discover devices
            await self.discover_devices()

        except Exception as e:
            self.logger.error(f"Setup failed: {e}")
            raise

    async def discover_devices(self) -> Dict:
        """Discover available audio devices"""
        devices = {}
        retry_count = 3

        while retry_count > 0:
            try:
                # Get PipeWire sinks
                proc = await asyncio.create_subprocess_exec(
                    "pw-dump",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout, _ = await proc.communicate()

                # Parse JSON output
                nodes = json.loads(stdout.decode())

                for node in nodes:
                    if node.get("type") == "PipeWire:Interface:Node":
                        info = node.get("info", {})
                        props = info.get("props", {})

                        # Only include audio sinks
                        if props.get("media.class") == "Audio/Sink":
                            device_id = str(node["id"])
                            name = props.get(
                                "node.description", props.get("node.name", device_id)
                            )

                            # Check audio channels
                            channels = int(props.get("audio.channels", "2"))
                            is_mono = channels == 1

                            devices[device_id] = {
                                "name": name,
                                "type": "pipewire",
                                "props": props,
                                "channels": channels,
                                "is_mono": is_mono,
                                "format": props.get("audio.format", ""),
                                "rate": int(props.get("audio.rate", "44100")),
                            }

                if devices:  # If we found devices, break the retry loop
                    break

                self.logger.warning("No audio devices found, retrying...")
                retry_count -= 1
                await asyncio.sleep(1)

            except Exception as e:
                self.logger.error(f"Device discovery failed: {e}")
                retry_count -= 1
                if retry_count > 0:
                    await asyncio.sleep(1)
                    continue
                raise

        self.outputs = devices
        return devices

    async def create_route(self, source: str, target: str) -> str:
        """Create audio route using PipeWire"""
        try:
            if target not in self.outputs:
                raise ValueError(f"Unknown output: {target}")

            # Create route ID
            route_id = f"{source}->{target}"

            # Get target device info
            target_info = self.outputs[target]
            is_mono = target_info.get("is_mono", False)

            # Link Bluetooth source to target sink
            links = []

            # Left channel
            proc = await asyncio.create_subprocess_exec(
                "pw-link",
                f"bluez_source.{source}:monitor_FL",
                f"{target}:playback_FL",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()
            links.append(f"bluez_source.{source}:monitor_FL -> {target}:playback_FL")

            # Right channel (if stereo)
            if not is_mono:
                proc = await asyncio.create_subprocess_exec(
                    "pw-link",
                    f"bluez_source.{source}:monitor_FR",
                    f"{target}:playback_FR",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                await proc.communicate()
                links.append(
                    f"bluez_source.{source}:monitor_FR -> {target}:playback_FR"
                )

            # For mono devices, mix down stereo to mono
            elif is_mono:
                self.logger.info(
                    f"Mono device detected: {target}, mixing stereo to mono"
                )
                # The right channel is automatically mixed by PipeWire

            self.routes[route_id] = {
                "source": source,
                "outputs": [target],
                "links": links,
                "is_mono": is_mono,
            }

            return route_id

        except Exception as e:
            self.logger.error(f"Failed to create route: {e}")
            raise

    async def verify_route(self, route_id: str) -> bool:
        """Verify route is working correctly"""
        try:
            route = self.routes.get(route_id)
            if not route:
                return False

            # Check each link
            for link in route["links"]:
                source, target = link.split(" -> ")
                proc = await asyncio.create_subprocess_exec(
                    "pw-link",
                    "-l",
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout, _ = await proc.communicate()

                if link not in stdout.decode():
                    self.logger.error(f"Link verification failed: {link}")
                    return False

            return True

        except Exception as e:
            self.logger.error(f"Route verification failed: {e}")
            return False

    async def repair_route(self, route_id: str) -> bool:
        """Attempt to repair a broken route"""
        try:
            route = self.routes.get(route_id)
            if not route:
                return False

            # Remove existing links
            await self._remove_route_links(route)

            # Recreate the route
            source = route["source"]
            target = route["outputs"][0]
            new_route_id = await self.create_route(source, target)

            # Add additional outputs if any
            for output in route["outputs"][1:]:
                await self.add_output_to_route(source, output)

            return await self.verify_route(new_route_id)

        except Exception as e:
            self.logger.error(f"Route repair failed: {e}")
            return False

    async def _remove_route_links(self, route: Dict):
        """Remove all links for a route"""
        for link in route.get("links", []):
            try:
                source, target = link.split(" -> ")
                proc = await asyncio.create_subprocess_exec(
                    "pw-link",
                    "-d",
                    source,
                    target,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                await proc.communicate()
            except Exception as e:
                self.logger.error(f"Failed to remove link {link}: {e}")

    async def add_output_to_route(self, source: str, new_target: str):
        """Add another output to an existing route"""
        route_id = next(
            (rid for rid in self.routes if rid.startswith(f"{source}->")), None
        )
        if not route_id:
            raise ValueError(f"No existing route for source {source}")

        route = self.routes[route_id]
        if new_target in route["outputs"]:
            return  # Already added

        try:
            # Create additional links
            proc = await asyncio.create_subprocess_exec(
                "pw-link",
                f"bluez_source.{source}:monitor_FL",
                f"{new_target}:playback_FL",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()

            proc = await asyncio.create_subprocess_exec(
                "pw-link",
                f"bluez_source.{source}:monitor_FR",
                f"{new_target}:playback_FR",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()

            # Update route info
            route["outputs"].append(new_target)
            route["links"].extend(
                [
                    f"bluez_source.{source}:monitor_FL -> {new_target}:playback_FL",
                    f"bluez_source.{source}:monitor_FR -> {new_target}:playback_FR",
                ]
            )

        except Exception as e:
            self.logger.error(f"Failed to add output to route: {e}")
            raise

    async def set_volume(self, device: str, volume: float):
        """Set volume using PipeWire"""
        if not 0 <= volume <= 1:
            raise ValueError("Volume must be between 0 and 1")

        try:
            # Try wpctl first (more reliable)
            proc = await asyncio.create_subprocess_exec(
                "wpctl",
                "set-volume",
                device,
                str(volume),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()

            if proc.returncode == 0:
                self.volumes[device] = volume
                return

            # Fallback to pw-cli
            proc = await asyncio.create_subprocess_exec(
                "pw-cli",
                "set-param",
                device,
                "Props",
                f'{{"volume": {volume}}}',
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()

            self.volumes[device] = volume

        except Exception as e:
            self.logger.error(f"Failed to set volume: {e}")
            raise

    async def get_volume(self, device: str) -> float:
        """Get current volume from PipeWire"""
        try:
            # Try wpctl first
            proc = await asyncio.create_subprocess_exec(
                "wpctl",
                "get-volume",
                device,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, _ = await proc.communicate()

            if proc.returncode == 0:
                # Parse volume from wpctl output (format: "Volume: 0.75")
                volume_str = stdout.decode().strip().split()[-1]
                return float(volume_str)

            # Fallback to pw-dump
            proc = await asyncio.create_subprocess_exec(
                "pw-dump",
                device,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, _ = await proc.communicate()

            # Parse volume from PipeWire dump
            data = json.loads(stdout.decode())
            for node in data:
                if str(node.get("id")) == device:
                    props = node.get("info", {}).get("params", {}).get("Props", {})
                    if "volume" in props:
                        return float(props["volume"])

            return self.volumes.get(device, 0.0)

        except Exception as e:
            self.logger.error(f"Failed to get volume: {e}")
            return 0.0

    async def set_default_output(self, device: str) -> bool:
        """Set default output device"""
        try:
            proc = await asyncio.create_subprocess_exec(
                "wpctl",
                "set-default",
                device,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            await proc.communicate()
            return proc.returncode == 0
        except Exception as e:
            self.logger.error(f"Failed to set default output: {e}")
            return False

    async def get_device_status(self) -> Dict:
        """Get detailed device status using wpctl"""
        try:
            proc = await asyncio.create_subprocess_exec(
                "wpctl",
                "status",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, _ = await proc.communicate()

            status = stdout.decode()
            devices = {}

            # Parse wpctl status output
            current_section = None
            for line in status.split("\n"):
                if "Sinks:" in line:
                    current_section = "outputs"
                elif "Sources:" in line:
                    current_section = "inputs"
                elif line.strip() and current_section:
                    if "├" in line or "└" in line:
                        parts = line.strip().split()
                        device_id = parts[1]
                        name = " ".join(parts[2:])
                        devices[device_id] = {
                            "name": name,
                            "type": current_section,
                            "volume": await self.get_volume(device_id),
                        }

            return devices

        except Exception as e:
            self.logger.error(f"Failed to get device status: {e}")
            return {}

    async def get_status(self) -> Dict:
        """Get current audio status"""
        status = {
            "outputs": self.outputs,
            "routes": self.routes,
            "volumes": self.volumes,
            "mode": self.mode,
        }

        # Add route health status
        route_health = {}
        for route_id in self.routes:
            route_health[route_id] = await self.verify_route(route_id)
        status["route_health"] = route_health

        return status

    async def _verify_services(self):
        """Verify required services are running"""
        required = ["pipewire", "pipewire-pulse", "wireplumber"]
        for service in required:
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

    async def cleanup(self):
        """Clean up resources"""
        # Remove all links
        for route_id, route in self.routes.items():
            for link in route.get("links", []):
                try:
                    source, target = link.split(" -> ")
                    proc = await asyncio.create_subprocess_exec(
                        "pw-link",
                        "-d",
                        source,
                        target,
                        stdout=asyncio.subprocess.PIPE,
                        stderr=asyncio.subprocess.PIPE,
                    )
                    await proc.communicate()
                except Exception as e:
                    self.logger.error(f"Failed to remove link {link}: {e}")

        # Reset volumes
        for device in self.volumes:
            try:
                await self.set_volume(device, 0)
            except Exception as e:
                self.logger.error(f"Failed to reset volume for {device}: {e}")
