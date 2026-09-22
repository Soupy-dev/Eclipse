import argparse
import datetime
import fnmatch
import json
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


TEAM_IDENTIFIER = "ANMK3Y568U"
BUNDLE_IDENTIFIER = "app.Eclipse.Soupy"
CLOUD_CONTAINER = "iCloud.Eclipse.Soupy"
MAC_ARCHITECTURES = ("arm64", "x86_64")
MPVKIT_NATIVE_SYMBOLS = (
    "mpv_apple_pip_api_version",
    "mpv_apple_pip_get_capabilities",
    "mpv_apple_pip_set_callback",
    "mpv_apple_pip_set_mode",
    "mpv_apple_pip_submit_target",
    "mpv_apple_pip_disable_and_drain",
)


def command(*arguments):
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    require(result.returncode == 0, f"{Path(arguments[0]).name} failed with exit status {result.returncode}")
    return result.stdout


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def audit_project(root):
    project = json.loads(command("plutil", "-convert", "json", "-o", "-", str(root / "Eclipse.xcodeproj/project.pbxproj")))
    objects = project["objects"]
    targets = {value.get("name"): value for value in objects.values() if value.get("isa") == "PBXNativeTarget"}
    expected = ["Eclipse-macOS", "Eclipse-macOSTests", "Eclipse-macOSUITests"]
    for name in expected:
        require(name in targets, f"Missing target: {name}")
        target = targets[name]
        if name == "Eclipse-macOS":
            require(any(objects[identifier]["isa"] == "PBXResourcesBuildPhase" for identifier in target["buildPhases"]), "Missing native Mac resources phase")
        configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
        for identifier in configurations:
            configuration = objects[identifier]
            settings = configuration["buildSettings"]
            require(settings.get("ARCHS") == "$(ARCHS_STANDARD)", f"{name} must use standard universal architectures")
            require(not any(key.startswith("EXCLUDED_ARCHS") and value for key, value in settings.items()), f"{name} must not exclude architectures")
            if configuration["name"] == "Release":
                require(settings.get("ONLY_ACTIVE_ARCH") == "NO", f"{name} Release must build every architecture")
            require(settings.get("SUPPORTED_PLATFORMS") == "macosx", f"{name} must use native macOS")
            require(settings.get("MACOSX_DEPLOYMENT_TARGET") == "14.0", f"Unexpected {name} deployment target")
        for phase_id in target["buildPhases"]:
            phase = objects[phase_id]
            if name == "Eclipse-macOS" and phase["isa"] == "PBXResourcesBuildPhase":
                paths = {objects[objects[item]["fileRef"]].get("path", "") for item in phase["files"]}
                required_resources = {"Assets.xcassets", "Localizable.xcstrings", "bundle.js", "Legal/ReaderExtensions", "Legal/OpenSourceLicenses", "Shaders", "PrivacyInfo.xcprivacy", "EclipseMac/Assets.xcassets"}
                require(required_resources <= paths, f"Missing Mac resource membership: {sorted(required_resources - paths)}")
            if phase["isa"] != "PBXSourcesBuildPhase":
                continue
            references = [objects[objects[item]["fileRef"]] for item in phase["files"]]
            require(len({objects[item]["fileRef"] for item in phase["files"]}) == len(references), f"Duplicate sources in {name}")
            for reference in references:
                if reference.get("sourceTree") == "SOURCE_ROOT":
                    require((root / reference["path"]).is_file(), f"Missing source: {reference['path']}")
            if name == "Eclipse-macOS":
                names = {Path(item.get("path", "")).name for item in references}
                forbidden = {"SoraApp.swift", "EclipseTVApp.swift", "PlayerViewController.swift", "MPVNativeRenderer.swift", "MPVTVRenderer.swift", "webToonViewController.swift"}
                require(not (names & forbidden), f"Foreign platform presentation in Mac target: {sorted(names & forbidden)}")
                required = {"EclipseMacApp.swift", "MacWindowCoordinator.swift", "MacRootView.swift", "MacPlaybackCoordinator.swift", "MacReaderSession.swift", "DownloadStorageRegistry.swift", "ServiceModels.xcdatamodeld"}
                require(required <= names, f"Missing Mac entry points: {sorted(required - names)}")
            native_folder = {"Eclipse-macOS": "EclipseMac", "Eclipse-macOSTests": "EclipseMacTests", "Eclipse-macOSUITests": "EclipseMacUITests"}[name]
            native_sources = {str(path.relative_to(root)) for path in (root / native_folder).rglob("*.swift")}
            included_sources = {item.get("path", "") for item in references if item.get("sourceTree") == "SOURCE_ROOT"}
            require(native_sources <= included_sources, f"Uncompiled native sources in {name}: {sorted(native_sources - included_sources)}")
    for scheme, expected_tests in {
        "Eclipse-macOS": {"Eclipse-macOSTests", "Eclipse-macOSUITests"},
        "Eclipse-macOS-UnitTests": {"Eclipse-macOSTests"},
    }.items():
        path = root / f"Eclipse.xcodeproj/xcshareddata/xcschemes/{scheme}.xcscheme"
        require(path.is_file(), f"Missing shared Mac scheme: {scheme}")
        testables = ET.parse(path).findall("TestAction/Testables/TestableReference")
        enabled = {item.find("BuildableReference").get("BlueprintName") for item in testables if item.get("skipped") != "YES"}
        require(enabled == expected_tests, f"Unexpected test membership in {scheme}")
    print("Native Mac target, architecture, entry point, and source membership audit passed.")


def macho(path):
    with path.open("rb") as stream:
        return stream.read(4) in tuple(bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"))


def audit_mpvkit_artifact(artifact, architectures):
    with (artifact / "Info.plist").open("rb") as stream:
        libraries = plistlib.load(stream).get("AvailableLibraries", [])
    candidates = [
        library for library in libraries
        if library.get("SupportedPlatform") == "macos"
        and not library.get("SupportedPlatformVariant")
        and set(architectures) <= set(library.get("SupportedArchitectures", []))
    ]
    require(len(candidates) == 1, "Libmpv must have one complete native Mac library for the requested architectures")
    library = candidates[0]
    location = artifact / library["LibraryIdentifier"] / library["LibraryPath"]
    binary = location / location.stem if location.suffix == ".framework" else location
    require(binary.is_file() and binary.resolve().is_relative_to(artifact), "Missing or invalid native Mac Libmpv binary")
    available = set(command("lipo", "-archs", str(binary)).split())
    require(set(architectures) <= available, f"Libmpv binary lacks requested architectures: {sorted(set(architectures) - available)}")
    for architecture in architectures:
        symbols = command("xcrun", "nm", "-arch", architecture, "-m", "-gU", str(binary))
        for symbol in MPVKIT_NATIVE_SYMBOLS:
            definitions = [line for line in symbols.splitlines() if re.search(r"\s_?" + re.escape(symbol) + r"$", line)]
            require(any(" external " in line and "weak" not in line and "undefined" not in line for line in definitions), f"Libmpv {architecture} lacks strong native inline-frame API export: {symbol}")
    print(f"Native Mac Libmpv architecture and inline-frame API audit passed: {', '.join(architectures)}.")


def require_resource(path, app):
    require(path.is_file() and path.stat().st_size > 0 and path.resolve().is_relative_to(app), f"Missing or invalid runtime resource: {path.relative_to(app)}")


def audit_resources(app, root):
    resources = app / "Contents/Resources"
    for name in ("Assets.car", "EclipseNativeMacAppIcon.icns", "ServiceModels.momd/ServiceModels.mom", "ServiceModels.momd/VersionInfo.plist"):
        require_resource(resources / name, app)
    copied = {"bundle.js": root / "Kanzen/KanzenEngine/Utils/Bundle/bundle.js"}
    for destination, source in (("Shaders", "Eclipse/Player/Shaders"), ("ReaderExtensions", "Eclipse/Legal/ReaderExtensions"), ("OpenSourceLicenses", "Eclipse/Legal/OpenSourceLicenses")):
        source_root = root / source
        files = [path for path in source_root.rglob("*") if path.is_file()]
        require(files, f"Missing source runtime resources: {source}")
        copied.update({str(Path(destination) / path.relative_to(source_root)): path for path in files})
    for name, source in copied.items():
        destination = resources / name
        require_resource(destination, app)
        require(destination.read_bytes() == source.read_bytes(), f"Stale runtime resource: {name}")
    privacy = resources / "PrivacyInfo.xcprivacy"
    require_resource(privacy, app)
    require(plistlib.loads(privacy.read_bytes()) == plistlib.loads((root / "Eclipse/PrivacyInfo.xcprivacy").read_bytes()), "App privacy manifest does not match its source")
    for name in ("Kingfisher_Kingfisher", "PLCrashReporter_CrashReporter", "ZIPFoundation_ZIPFoundation"):
        manifest = resources / f"{name}.bundle/Contents/Resources/PrivacyInfo.xcprivacy"
        require_resource(manifest, app)
        require(isinstance(plistlib.loads(manifest.read_bytes()), dict), f"Invalid {name} privacy manifest")
    catalog = json.loads((root / "Eclipse/Localizable.xcstrings").read_text())
    languages = {catalog["sourceLanguage"]}
    for entry in catalog["strings"].values():
        languages.update(entry.get("localizations", {}))
    for language in sorted(languages):
        strings = resources / f"{language}.lproj/Localizable.strings"
        require_resource(strings, app)
        require(bool(json.loads(command("plutil", "-convert", "json", "-o", "-", str(strings)))), f"Empty compiled localization: {language}")


def required_native_entitlements(application_prefix):
    return {
        "com.apple.developer.icloud-container-identifiers": [CLOUD_CONTAINER],
        "com.apple.developer.icloud-container-environment": "Production",
        "com.apple.developer.icloud-services": ["CloudKit", "CloudDocuments"],
        "com.apple.developer.group-session": True,
        "com.apple.developer.ubiquity-container-identifiers": [CLOUD_CONTAINER],
        "com.apple.developer.ubiquity-kvstore-identifier": application_prefix + "." + BUNDLE_IDENTIFIER,
        "com.apple.security.app-sandbox": True,
        "com.apple.security.network.client": True,
        "com.apple.security.network.server": True,
        "com.apple.security.files.user-selected.read-write": True,
        "com.apple.security.files.bookmarks.app-scope": True,
        "com.apple.security.cs.allow-jit": True,
        "com.apple.developer.aps-environment": "production",
    }


def entitlement_matches(actual, expected):
    if isinstance(expected, bool):
        return actual is expected
    if isinstance(expected, list):
        return isinstance(actual, list) and len(actual) == len(expected) and set(actual) == set(expected)
    return actual == expected


def profile_allows(actual, allowed):
    if isinstance(actual, list):
        return all(profile_allows(value, allowed) for value in actual)
    if isinstance(allowed, list):
        return any(profile_allows(actual, value) for value in allowed)
    if isinstance(actual, bool):
        return actual is allowed
    return isinstance(actual, str) and isinstance(allowed, str) and fnmatch.fnmatchcase(actual, allowed)


def audit_profile(profile, entitlements, leaf_certificate):
    require(profile.get("Platform") and set(profile["Platform"]) <= {"OSX", "macOS"}, "Embedded profile is not a native Mac profile")
    require(profile.get("TeamIdentifier") == [TEAM_IDENTIFIER], "Embedded profile has the wrong team")
    now = datetime.datetime.now(datetime.timezone.utc)
    for key, condition in (("CreationDate", lambda value: value <= now), ("ExpirationDate", lambda value: value > now)):
        value = profile.get(key)
        require(isinstance(value, datetime.datetime) and condition(value.replace(tzinfo=datetime.timezone.utc) if value.tzinfo is None else value), f"Embedded profile has an invalid {key}")
    require(not profile.get("ProvisionedDevices") and profile.get("ProvisionsAllDevices") is not True, "Embedded profile is not for App Store distribution")
    require(leaf_certificate in profile.get("DeveloperCertificates", []), "App signing certificate is not authorized by the embedded profile")
    grants = profile.get("Entitlements", {})
    require(isinstance(grants, dict), "Embedded profile has invalid entitlements")
    for values in (grants, entitlements):
        require(all(values.get(key) in (None, False) for key in ("get-task-allow", "com.apple.security.get-task-allow")), "Distribution app or profile enables debugging")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(len(prefixes) == 1 and isinstance(prefixes[0], str) and bool(prefixes[0]), "Embedded profile has an ambiguous application prefix")
    prefix = prefixes[0].rstrip(".")
    application_id = prefix + "." + BUNDLE_IDENTIFIER
    for values in (grants, entitlements):
        identifiers = [values[key] for key in ("application-identifier", "com.apple.application-identifier") if key in values]
        require(identifiers and all(value == application_id for value in identifiers), "App or embedded profile has the wrong application identity")
        require(values.get("com.apple.developer.team-identifier") == TEAM_IDENTIFIER, "App or embedded profile has the wrong entitlement team")
    expected = required_native_entitlements(prefix)
    for key, value in expected.items():
        require(entitlement_matches(entitlements.get(key), value), f"Missing or incorrect native entitlement: {key}")
        if key.startswith("com.apple.developer."):
            require(profile_allows(value, grants.get(key)), f"Embedded profile does not authorize: {key}")
    allowed_keys = set(expected) | {"application-identifier", "com.apple.application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "com.apple.security.get-task-allow", "beta-reports-active"}
    require(set(entitlements) <= allowed_keys, f"Unexpected app entitlement keys: {sorted(set(entitlements) - allowed_keys)}")


def audit_signature(app, architectures):
    command("codesign", "--verify", "--all-architectures", "--deep", "--strict", "-R", f'=anchor apple generic and certificate leaf[subject.OU] = "{TEAM_IDENTIFIER}"', str(app))
    profile_path = app / "Contents/embedded.provisionprofile"
    require_resource(profile_path, app)
    profile = plistlib.loads(command("security", "cms", "-D", "-i", str(profile_path)).encode())
    with tempfile.TemporaryDirectory(prefix="eclipse-mac-signature-audit-") as directory:
        for architecture in architectures:
            details = command("codesign", "-d", "--architecture", architecture, "--verbose=4", str(app))
            require(f"TeamIdentifier={TEAM_IDENTIFIER}" in details.splitlines(), f"{architecture} app signature has the wrong team")
            require(any(line.startswith(("Authority=Apple Distribution:", "Authority=3rd Party Mac Developer Application:")) for line in details.splitlines()), f"{architecture} app is not signed with an Apple distribution identity")
            require(re.search(r"\bflags=0x[0-9a-fA-F]+\([^)]*\bruntime\b", details) is not None, f"{architecture} app signature does not enable the hardened runtime")
            result = subprocess.run(["codesign", "-d", "--architecture", architecture, "--entitlements", ":-", str(app)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            require(result.returncode == 0, f"Cannot read {architecture} app entitlements")
            entitlements = plistlib.loads(result.stdout)
            certificate_prefix = Path(directory) / architecture
            command("codesign", "-d", "--architecture", architecture, f"--extract-certificates={certificate_prefix}", str(app))
            leaf = Path(str(certificate_prefix) + "0")
            require(leaf.is_file(), f"Cannot read the {architecture} app signing certificate")
            try:
                audit_profile(profile, entitlements, leaf.read_bytes())
            except RuntimeError as error:
                raise RuntimeError(f"{architecture} signature: {error}") from error


def audit_app(app, signed, architectures=MAC_ARCHITECTURES):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = app / "Contents/MacOS" / info["CFBundleExecutable"]
    require(executable.is_file(), "Missing Mac executable")
    require(info.get("EclipseDistributionChannel") == "appstore", "Mac app must use store-managed updates")
    require(info.get("LSMinimumSystemVersion") == "14.0", "Unexpected minimum macOS version")
    require(info.get("CFBundleIdentifier") == BUNDLE_IDENTIFIER, "Unexpected App Store product identity")
    audit_resources(app, Path(__file__).resolve().parents[1])
    binaries = [path for path in app.rglob("*") if path.is_file() and not path.is_symlink() and macho(path)]
    require(executable in binaries, "Main executable is not Mach-O")
    binary_architectures = {path.resolve(): set(command("lipo", "-archs", str(path)).split()) for path in binaries}
    for path in binaries:
        available = binary_architectures[path.resolve()]
        require(set(architectures) <= available, f"Missing required architectures in {path.relative_to(app)}: {sorted(set(architectures) - available)}")
        require(available <= set(MAC_ARCHITECTURES), f"Unexpected architectures in {path.relative_to(app)}: {sorted(available)}")
    commands = {
        (path, architecture): command("otool", "-arch", architecture, "-l", str(path))
        for path in binaries for architecture in binary_architectures[path.resolve()]
    }

    def expanded(value, loader):
        return value.replace("@loader_path", str(loader.parent)).replace("@executable_path", str(executable.parent))

    def rpaths(path, architecture):
        return [expanded(value, path) for value in re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", commands.get((path, architecture), ""))]

    for path in binaries:
        relative = path.relative_to(app)
        for architecture in sorted(binary_architectures[path.resolve()]):
            label = f"{relative} ({architecture})"
            load_commands = commands[path, architecture]
            platforms = re.findall(r"\bplatform\s+(\S+)", load_commands)
            native = all(value in {"1", "MACOS", "macos"} for value in platforms) if platforms else "LC_VERSION_MIN_MACOSX" in load_commands
            require(native, f"Non-native macOS binary: {label}")
            minimums = re.findall(r"\bminos\s+([\d.]+)", load_commands) + re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version ([\d.]+)", load_commands)
            require(minimums and all(tuple(map(int, version.split("."))) <= (14, 0, 0) for version in minimums), f"Binary requires newer than macOS 14: {label}: {minimums}")
            install_names = {line.strip() for line in command("otool", "-arch", architecture, "-D", str(path)).splitlines()[1:]}
            for line in command("otool", "-arch", architecture, "-L", str(path)).splitlines()[1:]:
                dependency = line.strip().split(" (", 1)[0]
                if dependency in install_names:
                    continue
                require(dependency.startswith(("@rpath/", "@loader_path/", "@executable_path/", "/System/Library/", "/usr/lib/")), f"Unbundled dependency in {label}: {dependency}")
                if dependency.startswith(("/System/Library/", "/usr/lib/")):
                    continue
                if dependency.startswith("@rpath/"):
                    suffix = dependency.removeprefix("@rpath/")
                    candidates = [Path(base) / suffix for base in rpaths(path, architecture) + rpaths(executable, architecture)]
                else:
                    candidates = [Path(expanded(dependency, path))]
                resolved = next((candidate.resolve() for candidate in candidates if candidate.is_file()), None)
                require(resolved is not None and resolved.is_relative_to(app), f"Missing bundled dependency in {label}: {dependency}")
                require(architecture in binary_architectures.get(resolved, set()), f"Bundled dependency lacks {architecture} slice in {label}: {dependency}")
    require(not (app / "Contents/Library/LoginItems").exists(), "Unexpected background helper")
    if signed:
        audit_signature(app, sorted(binary_architectures[executable.resolve()]))
    print(f"Native Mac binary audit passed for {len(binaries)} executables; required architectures: {', '.join(architectures)}. Signed archive checks: {'passed' if signed else 'not requested'}.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path)
    parser.add_argument("--signed", action="store_true")
    parser.add_argument("--architectures", nargs="+", choices=MAC_ARCHITECTURES, default=MAC_ARCHITECTURES, help="Required binary architectures; select one only for development builds")
    parser.add_argument("--mpvkit-artifact", type=Path, help="Explicit Libmpv.xcframework input for native inline-frame API preflight")
    arguments = parser.parse_args()
    architectures = tuple(dict.fromkeys(arguments.architectures))
    audit_project(Path(__file__).resolve().parents[1])
    if arguments.mpvkit_artifact:
        audit_mpvkit_artifact(arguments.mpvkit_artifact.resolve(), architectures)
    if arguments.app:
        audit_app(arguments.app.resolve(), arguments.signed, architectures)
    elif arguments.signed:
        parser.error("--signed requires --app")


if __name__ == "__main__":
    main()
