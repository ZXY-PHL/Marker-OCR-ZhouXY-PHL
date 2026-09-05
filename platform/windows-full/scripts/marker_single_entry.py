"""Portable entry point for marker_single without an absolute-path .exe shim."""

from marker.scripts.convert_single import convert_single_cli


if __name__ == "__main__":
    convert_single_cli()
