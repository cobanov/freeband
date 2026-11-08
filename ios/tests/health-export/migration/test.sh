#!/bin/sh
set -eu
cd "$(dirname "$0")/../../../.."
tmp=$(mktemp -d /tmp/freeband-migration.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
export FREEBAND_MIGRATION_STORE="$tmp/store.sqlite"
common="ios/tests/ingest/store/stub.swift ios/Freeband/Band/ActivityFiles.swift"
swiftc -parse-as-library -D OLD -module-cache-path "$tmp/cache" $common ios/Freeband/Analytics/*.swift \
    ios/tests/health-export/migration/Models-v0.5.2.swift ios/Freeband/Data/HealthModels.swift \
    ios/Freeband/Data/IngestMapper.swift ios/Freeband/Data/Calibration.swift \
    ios/tests/health-export/migration/main.swift -o "$tmp/old"
"$tmp/old"
swiftc -parse-as-library -module-cache-path "$tmp/cache" $common ios/Freeband/Analytics/*.swift \
    ios/Freeband/Data/Models.swift ios/Freeband/Data/HealthModels.swift ios/Freeband/Data/HealthExportModels.swift \
    ios/Freeband/Data/IngestMapper.swift ios/Freeband/Data/Calibration.swift ios/Freeband/Integrations/HealthExportPlan.swift \
    ios/tests/health-export/migration/main.swift -o "$tmp/new"
"$tmp/new"
