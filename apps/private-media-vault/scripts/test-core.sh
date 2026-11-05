#!/bin/sh
# Runs the portable VaultCore suite.
# This does not compile or execute UIKit, LocalAuthentication, Security,
# Photos, AVFoundation, App Intents, or an iOS signing flow.
set -eu
cd "$(dirname "$0")/.."
swift test
