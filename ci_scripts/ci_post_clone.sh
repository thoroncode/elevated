#!/bin/sh
# Stamp date-based version: YY.M.D (HH.MM)
# Runs in Xcode Cloud after cloning, before build.

exec "$CI_PRIMARY_REPOSITORY_PATH/stamp-version.sh"
