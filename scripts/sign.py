#!/usr/bin/env python3
"""Signs a build with the certificate kept only for Lumio.

macOS ties screen-recording, camera and microphone permission to the signature.
An ad-hoc signature is different on every build, so the permission would have to
be granted again after each one; signing with this stable local certificate keeps
the grant the user already gave.
"""
import pathlib
import subprocess
import sys

bundle = sys.argv[1]
signing = pathlib.Path.home() / "Library/Application Support/Lumio/Signing"
keychain = signing / "Lumio.keychain-db"
password_file = signing / "keychain-password"

if keychain.exists() and password_file.exists():
    subprocess.run(["security", "unlock-keychain", "-p", password_file.read_text().strip(), str(keychain)], check=True)
    sign = ["codesign", "--force", "--deep", "--sign", "Lumio Local Code Signing",
            "--keychain", str(keychain), "--identifier", "studio.lumio.local", bundle]
else:
    # No local certificate: sign ad hoc so the build still finishes. macOS then treats each build as a
    # different application, so screen-recording and camera permission has to be granted again after
    # every build. Make the certificate once (see the README) to keep the permissions you have granted.
    print("no local signing certificate found; signing ad hoc")
    sign = ["codesign", "--force", "--deep", "--sign", "-", "--identifier", "studio.lumio.local", bundle]

subprocess.run(sign, check=True)
subprocess.run(["codesign", "--verify", "--deep", bundle], check=True)
