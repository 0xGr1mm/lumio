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
password = (signing / "keychain-password").read_text().strip()

subprocess.run(["security", "unlock-keychain", "-p", password, str(keychain)], check=True)
subprocess.run([
    "codesign", "--force", "--deep",
    "--sign", "Lumio Local Code Signing",
    "--keychain", str(keychain),
    "--identifier", "studio.lumio.local",
    bundle,
], check=True)
subprocess.run(["codesign", "--verify", "--deep", bundle], check=True)
