# House Audio System

A distributed multi-room audio system built for Raspberry Pi, enabling synchronized whole-house audio with seamless Bluetooth connectivity and Home Assistant integration.

## Installation

```bash
# System dependencies
sudo apt install pipewire pipewire-pulse wireplumber bluez

# Python package
pip install house-audio
```

## Quick Start

1. **Test Single Node**

```bash
# Start services
systemctl --user start pipewire pipewire-pulse wireplumber
sudo systemctl start bluetooth

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

## Performance Notes

### WiFi/Bluetooth Coexistence

The Raspberry Pi's built-in WiFi/BT combo chip can have issues when both radios are used heavily:

- For best performance, use either WiFi or Bluetooth, not both intensively
- If you need both, consider using a separate USB Bluetooth dongle
- Audio dropouts may occur when WiFi and Bluetooth compete for bandwidth

### Multiple Devices

By default, multiple Bluetooth devices can connect and play simultaneously. To prevent this:

1. Edit the Bluetooth agent configuration
2. Set `allow_multiple_connections = False`
3. Restart the service

## Troubleshooting

### Audio Dropouts

If audio drops after playing for a while:

1. Ensure PulseAudio is completely removed
2. Check logs: `journalctl --user -u pipewire`
3. Try using a dedicated Bluetooth dongle

### Device Management

Use `wpctl` for direct device control:

```bash
# List all devices
wpctl status

# Set default output
wpctl set-default <ID>

# Set volume (0-1.5)
wpctl set-volume <ID> 1.0
```

## Configuration

See `config/` directory for example configurations.

## Architecture

See `system-overview.md` for detailed system architecture.
