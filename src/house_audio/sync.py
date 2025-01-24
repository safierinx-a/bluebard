#!/usr/bin/env python3

import asyncio
import logging
import socket
import struct
import time
from typing import Dict, Optional
import uuid


class PTPSync:
    """Precision Time Protocol synchronization"""

    def __init__(self):
        self.logger = logging.getLogger("ptp_sync")
        self.socket = None
        self.master = False
        self.offset = 0.0  # Time offset from master
        self.drift_rate = 0.0
        self.last_sync = 0

    async def setup(self):
        """Initialize PTP sync"""
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.socket.bind(("", 319))  # PTP event port

        # Determine if we're master
        self.master = await self._elect_master()

        if not self.master:
            # Start slave sync process
            await self._initial_sync()

    async def _elect_master(self) -> bool:
        """Elect a master clock"""
        # Implement BMCA (Best Master Clock Algorithm)
        # For now, use simple node ID comparison
        our_id = self._get_node_id()

        # Broadcast our ID
        msg = struct.pack("!Q", our_id)
        self.socket.sendto(msg, ("<broadcast>", 319))

        # Collect other IDs for 1 second
        start = time.time()
        other_ids = set()

        while time.time() - start < 1:
            try:
                data, addr = self.socket.recvfrom(8)
                other_id = struct.unpack("!Q", data)[0]
                other_ids.add(other_id)
            except socket.timeout:
                break

        # We're master if we have the lowest ID
        return our_id < min(other_ids) if other_ids else True

    async def _initial_sync(self):
        """Perform initial synchronization"""
        # Implement IEEE 1588 PTP sync
        # For now, use simplified sync
        offset_sum = 0
        samples = 0

        for _ in range(8):  # Take 8 samples
            t1 = time.time()
            # Send sync request
            self.socket.sendto(b"sync_req", ("<broadcast>", 319))

            # Wait for response
            data, addr = self.socket.recvfrom(1024)
            t4 = time.time()

            if data.startswith(b"sync_resp"):
                t2, t3 = struct.unpack("!dd", data[9:])
                offset = ((t2 - t1) + (t3 - t4)) / 2
                offset_sum += offset
                samples += 1

            await asyncio.sleep(0.1)

        if samples > 0:
            self.offset = offset_sum / samples

    async def check_drift(self) -> float:
        """Check clock drift from master"""
        if self.master:
            return 0.0

        # Simplified drift check
        old_offset = self.offset
        await self._initial_sync()
        drift = self.offset - old_offset

        # Update drift rate
        time_since_sync = time.time() - self.last_sync
        self.drift_rate = drift / time_since_sync if time_since_sync > 0 else 0

        return drift

    async def realign(self):
        """Realign with master clock"""
        if self.master:
            return

        await self._initial_sync()
        self.last_sync = time.time()

    async def get_status(self) -> Dict:
        """Get sync status"""
        return {
            "is_master": self.master,
            "offset": self.offset,
            "drift_rate": self.drift_rate,
            "last_sync": self.last_sync,
        }

    async def cleanup(self):
        """Clean up resources"""
        if self.socket:
            self.socket.close()

    def _get_node_id(self) -> int:
        """Get unique node ID"""
        # Use MAC address for unique ID
        mac = uuid.getnode()
        return mac
