#!/usr/bin/env python3
import psutil
import time
import os
from datetime import datetime


def get_temp():
    """Get CPU temperature"""
    try:
        temp = os.popen("vcgencmd measure_temp").readline()
        return temp.replace("temp=", "").replace("'C\n", "")
    except:
        return "N/A"


def monitor():
    """Monitor system stats"""
    try:
        while True:
            # Clear screen
            os.system("clear")

            # Get stats
            cpu_percent = psutil.cpu_percent(interval=1)
            memory = psutil.virtual_memory()
            disk = psutil.disk_usage("/")
            temp = get_temp()

            # Format output
            print("\033[92m=== Raspberry Pi Monitor ===\033[0m")
            print(f"Time: {datetime.now().strftime('%H:%M:%S')}")
            print(f"\nCPU Usage: {cpu_percent}%")
            print(f"CPU Temp:  {temp}°C")
            print(f"\nMemory:")
            print(f"  Used:  {memory.percent}%")
            print(f"  Total: {memory.total / (1024**3):.1f}GB")
            print(f"  Free:  {memory.available / (1024**3):.1f}GB")
            print(f"\nDisk:")
            print(f"  Used:  {disk.percent}%")
            print(f"  Total: {disk.total / (1024**3):.1f}GB")
            print(f"  Free:  {disk.free / (1024**3):.1f}GB")

            # Show running processes
            print("\nTop Processes:")
            processes = []
            for proc in psutil.process_iter(
                ["pid", "name", "cpu_percent", "memory_percent"]
            ):
                try:
                    pinfo = proc.info
                    processes.append(pinfo)
                except:
                    pass

            # Sort by CPU usage
            processes.sort(key=lambda x: x["cpu_percent"], reverse=True)
            for proc in processes[:5]:
                print(
                    f"  {proc['name'][:20]:<20} CPU: {proc['cpu_percent']:>5.1f}%  MEM: {proc['memory_percent']:>5.1f}%"
                )

            time.sleep(2)

    except KeyboardInterrupt:
        print("\nMonitoring stopped")


if __name__ == "__main__":
    monitor()
