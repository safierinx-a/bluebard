# House Audio System

A distributed multi-room audio system built for Raspberry Pi, enabling synchronized whole-house audio with seamless Bluetooth connectivity and Home Assistant integration.

## Installation

```bash
# System dependencies
sudo apt install bluez bluez-alsa bluez-alsa-utils snapclient

# Python package
pip install house-audio
```

## Quick Start

1. **Test Single Node**

```bash
# Start services
sudo systemctl start bluetooth bluealsa snapclient

# Run test
python -m house_audio.tools.test_audio
```

2. **Run Node Manager**

```python
from house_audio.node_manager import NodeManager

async def main():
    manager = NodeManager()
    await manager.start()

asyncio.run(main())
```

## Configuration

See `config/` directory for example configurations.

## Architecture

See `system-overview.md` for detailed system architecture.
