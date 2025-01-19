import asyncio
import logging
import subprocess
from ..interfaces.audio import AudioInterface
from ..interfaces.bluetooth import BluetoothInterface


async def test_bluetooth_audio():
    """Test basic Bluetooth audio playback"""
    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger("audio_test")

    audio = None
    bluetooth = None
    bluealsa_process = None

    try:
        logger.info("Setting up interfaces...")
        audio = AudioInterface()
        bluetooth = BluetoothInterface()

        # Initialize both interfaces
        await audio.setup()
        await bluetooth.setup()

        # Get default audio device
        devices = await audio.discover_devices()
        default_output = next(iter(devices.keys()))
        logger.info(f"Using audio output: {default_output}")

        print("\nYour Pi is now discoverable as 'House Audio'")
        print("Connect to it from your phone/laptop")
        print("\nCommands:")
        print("s: Show connected devices")
        print("v [0-100]: Set volume")
        print("q: Quit")

        # Start bluealsa-aplay
        bluealsa_process = subprocess.Popen(
            ["bluealsa-aplay", "--profile-a2dp", "--device", default_output]
        )

        while True:
            cmd = input("> ").strip()
            if cmd == "q":
                break
            elif cmd == "s":
                # Show connected devices
                status = await bluetooth.get_status()
                print("\nConnected devices:")
                for mac in status["active"]:
                    device = status["devices"].get(mac, {})
                    print(f"- {device.get('name', mac)}")
                    if mac in status["signal_quality"]:
                        print(f"  Signal: {status['signal_quality'][mac]['quality']}")
            elif cmd.startswith("v "):
                try:
                    vol = float(cmd.split()[1]) / 100
                    await audio.set_volume(default_output, vol)
                except Exception as e:
                    logger.error(f"Volume control failed: {e}")

    except KeyboardInterrupt:
        print("\nStopping audio test...")
    except Exception as e:
        logger.error(f"Test failed: {e}")
    finally:
        # Cleanup
        if bluetooth:
            await bluetooth.cleanup()
        if bluealsa_process:
            bluealsa_process.terminate()
            bluealsa_process.wait()
        print("\nTest complete")


if __name__ == "__main__":
    asyncio.run(test_bluetooth_audio())
