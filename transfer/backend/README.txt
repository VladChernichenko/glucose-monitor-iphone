OpenAI chat gateway + qualitative fallback — apply on Mac
=========================================================

Source: libre-glucose-monitor-be branch cursor/openai-chat-gateway-082b
Commits (vs origin/main):
  15d8b18 fix(ai): prefer OPENAI_API_KEY for chat gateway
  5daed39 fix(assistant): qualitative chat no longer hits reliability template

These files live in this iPhone repo only because we cannot push to
libre-glucose-monitor-be. Download them, apply into glucose-monitor-be
on your Mac, then push from the Mac if desired.

Files
-----
  openai-chat-gateway-with-qualitative-082b.patch  — combined format-patch (recommended)
  openai-chat-gateway-082b.bundle                  — git bundle of the same two commits

Option A — curl + git apply (recommended)
-----------------------------------------
cd /path/to/glucose-monitor-be
git fetch origin
git checkout main
git pull origin main
git checkout -b cursor/openai-chat-gateway-082b

curl -fsSL -o /tmp/openai-chat-gateway-with-qualitative-082b.patch \
  https://raw.githubusercontent.com/VladChernichenko/glucose-monitor-iphone/cursor/transfer-openai-be-082b/transfer/backend/openai-chat-gateway-with-qualitative-082b.patch

git apply --index /tmp/openai-chat-gateway-with-qualitative-082b.patch
git commit -m "fix(ai): OpenAI chat gateway + qualitative fallback (from transfer)"

# or preserve original two commits via am:
# git am /tmp/openai-chat-gateway-with-qualitative-082b.patch

Option B — git bundle
---------------------
cd /path/to/glucose-monitor-be
git fetch origin
git checkout main
git pull origin main

curl -fsSL -o /tmp/openai-chat-gateway-082b.bundle \
  https://raw.githubusercontent.com/VladChernichenko/glucose-monitor-iphone/cursor/transfer-openai-be-082b/transfer/backend/openai-chat-gateway-082b.bundle

git bundle verify /tmp/openai-chat-gateway-082b.bundle
git fetch /tmp/openai-chat-gateway-082b.bundle HEAD:cursor/openai-chat-gateway-082b
git checkout cursor/openai-chat-gateway-082b

One-liners (from glucose-monitor-be on main)
--------------------------------------------
# patch apply:
curl -fsSL -o /tmp/openai-chat-gateway-with-qualitative-082b.patch https://raw.githubusercontent.com/VladChernichenko/glucose-monitor-iphone/cursor/transfer-openai-be-082b/transfer/backend/openai-chat-gateway-with-qualitative-082b.patch && git checkout -b cursor/openai-chat-gateway-082b && git am /tmp/openai-chat-gateway-with-qualitative-082b.patch

# bundle fetch:
curl -fsSL -o /tmp/openai-chat-gateway-082b.bundle https://raw.githubusercontent.com/VladChernichenko/glucose-monitor-iphone/cursor/transfer-openai-be-082b/transfer/backend/openai-chat-gateway-082b.bundle && git fetch /tmp/openai-chat-gateway-082b.bundle HEAD:cursor/openai-chat-gateway-082b && git checkout cursor/openai-chat-gateway-082b
