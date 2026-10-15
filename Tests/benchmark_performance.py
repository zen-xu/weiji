#!/usr/bin/env python3
"""Compile and measure disposable synthetic scans/gallery queries on macOS."""
import pathlib
import platform
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="wechat-performance-build-") as directory:
    build = pathlib.Path(directory)
    main = build / "main.swift"
    main.write_text('import Foundation\ntry runPerformanceBenchmark()\n')
    sources = sorted(p for p in (root / "Sources").glob("*.swift") if p.name != "main.swift")
    command = ["swiftc", "-O", "-swift-version", "5", "-target", f"{platform.machine()}-apple-macos14.0",
               "-module-cache-path", str(root / "build/module-cache"), *map(str, sources),
               str(root / "Tests/PerformanceBenchmark.swift"), str(main)]
    for framework in ["AppKit", "SwiftUI", "CryptoKit", "VideoToolbox", "CoreImage", "ImageIO", "CoreServices"]:
        command += ["-framework", framework]
    command += ["-lsqlite3", "-o", str(build / "benchmark")]
    subprocess.run(command, check=True)
    subprocess.run([str(build / "benchmark")], check=True)
