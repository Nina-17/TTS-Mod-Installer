# Bundled 7-Zip manifest

Release builds bundle the unmodified `7z.exe` and `7z.dll` files from the official 7-Zip 26.02 Windows installers, plus the official Universal `7zz` from the macOS archive.

Official source:

- <https://www.7-zip.org/download.html>
- <https://github.com/ip7z/7zip/releases/tag/26.02>

Release layout:

```text
tools/7zip/
├── License.txt
├── x86/
│   ├── 7z.exe
│   └── 7z.dll
├── x64/
│   ├── 7z.exe
│   └── 7z.dll
└── arm64/
    ├── 7z.exe
    └── 7z.dll
```

The macOS app stores `7zz` and its license under `Contents/Resources/tools/7zip/`.

SHA-256:

| File | SHA-256 |
|---|---|
| `x86/7z.exe` | `285e5220d6d4240b6a4bdb6357d427e457313376e3464d3cb973637a384ed02a` |
| `x86/7z.dll` | `c6989259a78960805b8b646843d2ef3a8a19e5533359e8a252aad2f3cc78c844` |
| `x64/7z.exe` | `83967f1b02b43c4efeda302795722c809e0e81b8307de73558d10484d5676a7d` |
| `x64/7z.dll` | `69fd4df057985c40e510e2fac182881c7f85e90aa13ec703f763a8fdb2ce61f8` |
| `arm64/7z.exe` | `46009c25732880c9d49032ec20da46dfdc669fb60257f50308a0026b4fac3aef` |
| `arm64/7z.dll` | `7346eaea5f333b1d65b6b4eedf6797c416bbc91c75e46159df38aa28e153f7c5` |
| macOS archive `7z2602-mac.tar.xz` | `1cf6760579502f87e591ff5c73a005ec50b3e4d6f507e8b038382d563c3175b9` |
| macOS Universal `7zz` | `9c56cf3379a0d8544e9244958b96fdc7c17f9ce70f5a160eb2b41f5f3df96d8c` |
| macOS ad-hoc signed `7zz` | `29034e8f067c2f939f4bcac26fd552da2c72ffa2c7e572e4b41f3131e5a86208` |
| macOS `License.txt` | `1790374e5352329cedb46ee3808930a88e9ca2f08b82b10fcf5cf605d2c301b1` |

The binaries are intentionally kept in release artifacts rather than duplicated in the source checkout.
