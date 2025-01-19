# Distributed Audio System

## System Architecture

### Components

1. **Node Components**

   - Audio Interface (ALSA/BlueALSA)
   - Bluetooth Interface
   - Node Manager
   - Snapcast Client

2. **Central Components**
   - Snapcast Server
   - MQTT Broker
   - Home Assistant Integration

### Audio Flow

```
Bluetooth Device → BlueALSA → ALSA → Snapcast Client → Snapcast Server → Speakers
```

### State Management

- Each node maintains its own state
- Central server coordinates between nodes
- Home Assistant provides user interface

## Implementation Details

### Node Stack

- Python async implementation
- BlueALSA for Bluetooth audio
- ALSA for audio routing
- Snapcast for synchronized playback

### Features

- Bluetooth device discovery and pairing
- Signal strength monitoring
- Volume control per device
- Multi-room synchronization
