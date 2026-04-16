#!/usr/bin/env python3
import argparse
import plistlib
import shutil
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE = REPO_ROOT / "tools" / "audio-bus-probe-au" / "SpliceKitAudioBusProbe.c"
BUILD_ROOT = REPO_ROOT / "build" / "audio-bus-probe-variants"
INSTALL_ROOT = Path.home() / "Library" / "Audio" / "Plug-Ins" / "Components"


def variants(count):
    for index in range(1, count + 1):
        suffix = f"{index:02d}"
        yield {
            "suffix": suffix,
            "name": f"Audio Bus Probe {suffix}",
            "component": f"SpliceKitAudioBusProbe{suffix}.component",
            "executable": f"SpliceKitAudioBusProbe{suffix}",
            "bundle_id": f"com.splicekit.AudioBusProbe{suffix}",
            "subtype": f"Sk{suffix}",
            "manufacturer": "SpKt",
            "metrics": f"splicekit-audio-bus-probe-{suffix}",
        }


def info_plist(variant):
    return {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": variant["executable"],
        "CFBundleIdentifier": variant["bundle_id"],
        "CFBundleName": f"SpliceKit {variant['name']}",
        "CFBundlePackageType": "BNDL",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "NSHumanReadableCopyright": "Copyright SpliceKit. Internal diagnostics only.",
        "AudioComponents": [
            {
                "type": "aufx",
                "subtype": variant["subtype"],
                "manufacturer": variant["manufacturer"],
                "name": f"SpliceKit: {variant['name']}",
                "version": 1,
                "factoryFunction": "SpliceKitAudioBusProbeFactory",
                "resourceUsage": {
                    "temporary-exception.files.all.read-write": True,
                },
                "tags": ["Effect", "Analyzer", "Meter"],
            }
        ],
    }


def define_string(name, value):
    return f'-D{name}="{value}"'


def build_variant(variant):
    component_dir = BUILD_ROOT / variant["component"]
    contents = component_dir / "Contents"
    macos = contents / "MacOS"
    binary = macos / variant["executable"]
    info = contents / "Info.plist"

    if component_dir.exists():
        shutil.rmtree(component_dir)
    macos.mkdir(parents=True, exist_ok=True)
    with info.open("wb") as handle:
        plistlib.dump(info_plist(variant), handle, sort_keys=False)

    command = [
        "clang",
        "-arch", "arm64",
        "-arch", "x86_64",
        "-mmacosx-version-min=14.0",
        "-std=c11",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Wno-deprecated-declarations",
        "-fvisibility=hidden",
        "-dynamiclib",
        "-framework", "AudioToolbox",
        "-framework", "AudioUnit",
        "-framework", "CoreAudio",
        "-framework", "CoreFoundation",
        "-framework", "CoreServices",
        define_string("SKBP_PLUGIN_NAME", f"SpliceKit {variant['name']}"),
        define_string("SKBP_METRICS_BASENAME", variant["metrics"]),
        f"-DSKBP_AU_SUBTYPE='{variant['subtype']}'",
        f"-DSKBP_AU_MANUFACTURER='{variant['manufacturer']}'",
        str(SOURCE),
        "-o",
        str(binary),
    ]
    subprocess.run(command, check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(component_dir)], check=True,
                   stdout=subprocess.DEVNULL)
    return component_dir


def install_variant(component_dir):
    INSTALL_ROOT.mkdir(parents=True, exist_ok=True)
    destination = INSTALL_ROOT / component_dir.name
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(component_dir, destination)
    subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True,
                   stdout=subprocess.DEVNULL)
    return destination


def unregister_components():
    subprocess.run(["killall", "-9", "AudioComponentRegistrar"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    parser = argparse.ArgumentParser(description="Build/install Audio Bus Probe AU variants.")
    parser.add_argument("--count", type=int, default=12)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--uninstall", action="store_true")
    args = parser.parse_args()

    if args.uninstall:
        for variant in variants(args.count):
            destination = INSTALL_ROOT / variant["component"]
            if destination.exists():
                shutil.rmtree(destination)
                print(f"Uninstalled: {destination}")
        unregister_components()
        return 0

    built = []
    for variant in variants(args.count):
        component_dir = build_variant(variant)
        built.append(component_dir)
        print(f"Built: {component_dir}")
        if args.install:
            print(f"Installed: {install_variant(component_dir)}")

    if args.install:
        unregister_components()
    print(f"Variants: {len(built)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
