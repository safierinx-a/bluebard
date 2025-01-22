import asyncio
import logging
from typing import Dict, Optional
from .interfaces.audio import AudioInterface
from .interfaces.bluetooth import BluetoothInterface


class NodeManager:
    """Manages a single node in the distributed audio system"""

    def __init__(self):
        self.logger = logging.getLogger(__name__)
        self.audio = AudioInterface()
        self.bluetooth = BluetoothInterface()
        self.state: Dict = {}
        self._running = False
        self.default_output = "default"  # Assuming a default output device

    async def start(self):
        """Start the node manager"""
        try:
            self._running = True

            # Initialize interfaces
            await self.audio.setup()
            await self.bluetooth.setup()

            # Initial state
            await self._update_state()

            # Start state monitoring
            while self._running:
                await self._update_state()
                await asyncio.sleep(5)

        except Exception as e:
            self.logger.error(f"Node manager failed: {e}")
            raise
        finally:
            await self.stop()

    async def stop(self):
        """Stop the node manager"""
        self._running = False
        try:
            await self.bluetooth.cleanup()
        except Exception as e:
            self.logger.error(f"Cleanup failed: {e}")

    async def _update_state(self):
        """Update current state"""
        try:
            audio_status = await self.audio.get_status()
            bluetooth_status = await self.bluetooth.get_status()

            self.state = {
                "audio": audio_status,
                "bluetooth": bluetooth_status,
                "status": "running" if self._running else "stopped",
            }

        except Exception as e:
            self.logger.error(f"State update failed: {e}")

    async def get_state(self) -> Dict:
        """Get current node state"""
        return self.state

    async def set_volume(self, device_id: str, volume: float) -> None:
        """Set volume for a device"""
        await self.audio.set_volume(device_id, volume)
        await self._update_state()

    async def connect_bluetooth(self, mac: str) -> bool:
        """Connect to a Bluetooth device"""
        success = await self.bluetooth.connect_device(mac)
        if success:
            await self._update_state()
        return success

    async def disconnect_bluetooth(self, mac: str) -> bool:
        """Disconnect a Bluetooth device"""
        success = await self.bluetooth.disconnect_device(mac)
        if success:
            await self._update_state()
        return success

    async def handle_bluetooth_device(self, mac: str, action: str) -> bool:
        """Handle Bluetooth device connection/disconnection"""
        try:
            if action == "connect":
                if await self.bluetooth.connect_device(mac):
                    # Wait for device to stabilize
                    await asyncio.sleep(2)
                    # Create audio route
                    route_id = await self.audio.create_bluetooth_route(
                        mac, self.default_output
                    )
                    # Set initial volume
                    await self.audio.set_volume(self.default_output, 0.7)
                    return True
            elif action == "disconnect":
                return await self.bluetooth.disconnect_device(mac)
            return False
        except Exception as e:
            self.logger.error(f"Failed to handle device {mac}: {e}")
            return False
