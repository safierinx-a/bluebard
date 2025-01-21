from setuptools import setup, find_packages

setup(
    name="house_audio",
    version="0.1.0",
    packages=find_packages("src"),
    package_dir={"": "src"},
    install_requires=[
        "dbus-python",  # For D-Bus communication
        "psutil",  # For system monitoring
        "asyncio",  # For async support
    ],
    python_requires=">=3.7",
)
