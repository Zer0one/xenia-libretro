# Xenia libretro core

A [libretro](https://www.libretro.com/) core of [Xenia Edge](https://github.com/has207/xenia-edge), the Xbox 360 emulator, for RetroArch and other libretro frontends.

The emulator is upstream's: this repository follows xenia-edge and adds the libretro frontend in `libretro/`. It holds the core only; upstream's standalone UI, packaging and CI are not part of it (the paths are listed in `.upstream-excluded`). The version the core reports is upstream's, with the upstream commit it is merged to (`upstream.version`). The current source integrates xenia-edge commit d881a29 (full merge through 26 October 2026). See [Roadmap](ROADMAP.md) for validation status and planned work.

## Downloads

The [WizzardSK source port](https://github.com/WizzardSK/xenia-libretro) is built by libretro's buildbot for Windows, Linux (x86_64, arm64) and Android (arm64-v8a, x86_64), and is installed from RetroArch: Online Updater > Core Downloader. Its `libretro` pushes are also built in [Actions](https://github.com/WizzardSK/xenia-libretro/actions/workflows/libretro.yml), macOS (Apple Silicon) included; the builds are the artifacts of a run, and downloading them needs a GitHub login. Those packages do not include this fork's changes. This fork develops on `main`, which triggers its own [build workflow](https://github.com/Zer0one/xenia-libretro/actions/workflows/libretro.yml). Versioned rolling packages are published under [Releases](https://github.com/Zer0one/xenia-libretro/releases), starting with `v0.1.0.1`; subsequent updates increment the fourth component. Each release lists its available platforms and validation limits. The [rolling release workflow](https://github.com/Zer0one/xenia-libretro/actions/workflows/release.yml) builds, verifies, packages and publishes on remote runners. Tags trigger release builds; manual dispatch can rebuild an existing tag without moving it. Local installation uses the downloaded CI artifact.

- **Windows:** `xenia_edge_libretro.dll`, which needs the Visual C++ 2015-2022 runtime. It carries `dxil.dll`, Direct3D 12's shader validator, inside and writes it to `system/Xenia-Edge/D3D12/` on start.
- **Linux:** `xenia_edge_libretro.so`, glibc 2.35 or newer; besides the C/C++ runtime it uses only lz4 and fontconfig; no X11 or Wayland libraries. ARM64 uses the a64 CPU backend.
- **macOS:** `xenia_edge_libretro.dylib`, Apple Silicon only. The x64 CPU backend needs the address space below 4 GB, which a core loaded into RetroArch cannot free, so there is no Intel build.
- **Android:** `xenia_edge_libretro_android.so`.

The release workflow now builds four desktop targets: Windows x86_64, Linux x86_64/ARM64 and macOS ARM64. Android compilation and publication are excluded from future releases until further user instruction; earlier releases may still contain Android packages. Each platform package includes the core, matching `.info`, provenance and checksums; Windows symbols are published separately. Install the two core files in RetroArch's configured core and information directories. Publication requires the complete desktop set and matching Windows symbols; unexpected Android archives block publication under the current policy. The release notes list the actual published targets. MoltenVK is not bundled in this package: original frontend drivers use the core's compatibility path.

This fork uses rolling builds under the standard core filename. Local macOS updates install `xenia_edge_libretro.dylib` and its matching `xenia_edge_libretro.info`; each validated build replaces the previous installed build, with the previous copy retained in deployment backups.

## Video

The core option Graphics API picks Xenia's GPU backend: Vulkan, or on Windows Direct3D 12. The core asks RetroArch for that kind of context, and RetroArch switches its video driver to match when it is allowed to (Settings > Video > Output). Direct3D 12 runs on the system's Direct3D 12 runtime: the Agility SDK runtime that standalone Xenia uses can only be loaded by an executable that exports it, which RetroArch does not.

Shared-device Vulkan keeps blit resources per frontend sync slot and uses GPU semaphores to hand images to RetroArch. On macOS with a shared queue, the core retains CPU completion of the blit in both driver submission modes. Frontend VSync and guest vblank behavior are retained.

On a frontend supporting Vulkan negotiation v2, the macOS core checks the actual loaded MoltenVK provider for the local drawable ownership fix. With the recognized fix it selects asynchronous host submission for that instance. Without it, the core selects synchronous compatibility submission and displays a notification that performance may be reduced. Global driver settings and environment variables are unchanged. The local patch has been exercised on MoltenVK 1.3.0 and the project's 1.4.2 revision; the minimal ownership-only patch does not correct independent queues. A broader local driver candidate now passes the independent-queue reproducer on both versions; its validation scope is documented under `tools/moltenvk/INDEPENDENT_QUEUE_FIX.md`. The driver framework is installed separately from the core. See [Vulkan Presentation](VULKAN_PRESENTATION.md) and [Local MoltenVK Drawable Patch](tools/moltenvk/README.md) for evidence, build inputs and limits.

## Content

Xbox 360 games as a disc image (`.iso`), an executable (`.xex`), or a `.zar` / `.xcp` package. No BIOS or firmware is needed.

Original Xbox games run through XeFu, the Xbox 360's own emulator of the original Xbox, which upstream Xenia Edge can run. It needs XeFu's files from a console (`xbox.xex` and the `xefu*.xex` builds of the system partition's `Compatibility` folder) in `<system>/Xenia-Edge/xefu/`; the game is opened as a disc image (`.iso`), a full dump or one rebuilt to the game partition alone. Only the games the console itself could run have a chance.

Everything the core keeps is in `system/Xenia-Edge/`: saves, title updates and DLC under `content/`, laid out as in standalone Xenia's content folder; the shader and other caches under `cache/`; and Xenia's log, `xenia.log`. Errors and warnings from it also appear in RetroArch's log. The core option Apply Title Updates turns updates off.

Games that need a signed-in profile get one: the core signs in the first profile under `content/`, or creates one when there is none, named after the first line of `system/Xenia-Edge/xbl_profilename.txt` ("Player" if the file is missing, which the core then writes there).

On macOS, native application Quit / Cmd+Q also stops the guest and joins the pause watchdog when the frontend exits without calling the Libretro unload callbacks. See [Core Lifecycle](CORE_LIFECYCLE.md) for the tested paths and the separate exit-confirmation behavior.

## Building

With upstream's build dependencies (see upstream's documentation), from a checkout with its submodules:

```
git clone --recursive https://github.com/Zer0one/xenia-libretro.git
cd xenia-libretro
./xenia-build.py slang
./xenia-build.py fetchdata
./xenia-build.py build --config=Release --target=xenia-libretro
```

The CI workflow `.github/workflows/libretro.yml` contains the platform jobs, including the Android cross build. Pushes to `main` run those jobs; manual dispatch can select individual platforms. A workflow artifact is a build result, not evidence of game compatibility on that platform.

The macOS ARM64 Vulkan/MoltenVK target has been built locally with Apple's Command Line Tools, the macOS SDK and Slang, without Xcode.app. This check concerns the core target; native Metal remains deferred in the roadmap.

## License

BSD, as Xenia. See [LICENSE](LICENSE).
