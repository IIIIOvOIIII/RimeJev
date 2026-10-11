#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
mkdir -p work artifacts/coverage
swiftc -typecheck scripts/restart_input.swift
swiftc -parse-as-library -profile-generate -profile-coverage-mapping native/JevCore.swift native/JevCandidatePlan.swift native/tests/JevCoreTests.swift -o work/JevCoreCoverage
LLVM_PROFILE_FILE=work/JevCore.profraw work/JevCoreCoverage
xcrun llvm-profdata merge -sparse work/JevCore.profraw -o work/JevCore.profdata
xcrun llvm-cov export work/JevCoreCoverage -instr-profile work/JevCore.profdata native/JevCore.swift -summary-only > work/swift-coverage.json
.venv/bin/python - <<'PY'
import json
x=json.load(open('work/swift-coverage.json'))['data'][0]['totals']
json.dump({'scope':'native/JevCore.swift','totals':x,'minimum_line_percent':80,'branch_metric_available':x['branches']['count']>0},open('artifacts/coverage/native-swift.json','w'),indent=2)
if x['lines']['percent']<80: raise SystemExit('Native line coverage below 80 percent')
print('Swift coordinator lines:',x['lines']['percent'])
PY

bash scripts/test_jev_context.sh
bash scripts/test_training_capture.sh
bash scripts/test_training_store.sh
.venv/bin/python scripts/test_training_pipeline.py
swiftc -parse-as-library native/JevTrainingSettings.swift native/JevTrainingStore.swift native/JevTrainingPreferences.swift native/tests/JevTrainingPreferencesTests.swift -framework AppKit -framework CryptoKit -framework Security -o work/JevTrainingPreferencesTests
work/JevTrainingPreferencesTests
.venv/bin/python scripts/test_context_adapter.py
swiftc -parse-as-library native/JevBadge.swift native/tests/JevBadgeTests.swift -framework AppKit -o work/JevBadgeTests
work/JevBadgeTests

.venv/bin/python scripts/test_runtime_lifecycle.py
.venv/bin/python scripts/test_settings_profiles.py

for component in CandidatePlan Keychain LanguageIndicator; do
  swiftc -parse-as-library native/JevCore.swift "native/Jev${component}.swift" "native/tests/Jev${component}Tests.swift" -framework AppKit -framework Security -o "work/Jev${component}Tests"
  "work/Jev${component}Tests"
done
