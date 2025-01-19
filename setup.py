from setuptools import setup, find_packages

setup(
    name="house_audio",
    version="0.1.0",
    packages=find_packages("src"),
    package_dir={"": "src"},
    install_requires=[
        # Add dependencies if needed
    ],
)
