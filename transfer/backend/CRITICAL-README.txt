Critical BE security fixes (TDD) — apply on Mac in glucose-monitor-be
=====================================================================

Branch: cursor/critical-secrets-phi-082b

1) SecretsStartupValidator fails closed for prod, staging, AND docker
2) Root patient PHI CSVs removed from git + ignored
3) application-docker.yml no longer embeds insecure JWT default

Mac:
  cd /path/to/glucose-monitor-be
  git fetch origin && git checkout main && git pull
  curl -fsSL -o /tmp/critical-secrets-phi-082b.patch \
    https://raw.githubusercontent.com/VladChernichenko/glucose-monitor-iphone/cursor/transfer-critical-be-082b/transfer/backend/critical-secrets-phi-082b.patch
  git checkout -b cursor/critical-secrets-phi-082b
  git am /tmp/critical-secrets-phi-082b.patch
  ./gradlew test --tests '*SecretsStartupValidatorTest' --tests '*NoPatientPhiDumpsInRepoTest'
  git push -u origin cursor/critical-secrets-phi-082b
