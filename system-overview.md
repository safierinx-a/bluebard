# Distributed Audio System

## System Architecture

### Components

1. **Node Components**

   - PipeWire Audio Server
   - Bluetooth Interface
   - Node Manager
   - WirePlumber Session Manager

2. **Central Components** (Future)
   - MQTT Broker
   - Home Assistant Integration

### Audio Flow

```
Bluetooth Device → PipeWire Graph → Physical Outputs
                 ↳ Multiple outputs with individual volume control
```

### State Management

- Each node maintains its own state
- PipeWire handles audio routing and mixing
- Future: Central server for multi-room coordination

## Implementation Details

### Node Stack

- Python async implementation
- PipeWire for audio routing and Bluetooth
- Direct audio links for low latency
- Individual volume control per output

### Features

- Bluetooth device discovery and pairing
- Signal strength monitoring
- Multiple simultaneous outputs
- Independent volume control
- Future: Multi-room synchronization
