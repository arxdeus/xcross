#!/usr/bin/env bash
# Pre-downloads the Gradle wrapper distribution with a bounded retry.
# Only a failure of the download itself is retried: `./gradlew --version`
# builds nothing, so a real project error still fails after the last attempt
# and a genuine build failure later in the job is never retried.
set -uo pipefail
attempts=3
delay=10
for ((i = 1; i <= attempts; i++)); do
  if ./gradlew --version --no-daemon; then
    exit 0
  fi
  if ((i < attempts)); then
    echo "::warning::Gradle wrapper download failed (attempt $i/$attempts), retrying in ${delay}s"
    sleep "$delay"
    delay=$((delay * 3))
  fi
done
echo "::error::Gradle wrapper download failed after $attempts attempts"
exit 1
