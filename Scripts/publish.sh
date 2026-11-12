#!/bin/zsh
# Publishes the version in project.yml: notarized DMG, git tag, GitHub Release
# and the Homebrew cask in falconsw/homebrew-tap.
#
#   make publish              # or Scripts/publish.sh
#   DRY_RUN=1 make publish    # runs the checks, publishes nothing
#
# Before running: bump MARKETING_VERSION in project.yml, commit and push.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=falconsw/Waitlight
TAP=falconsw/homebrew-tap
VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
TAG="v$VERSION"
DMG="dist/Waitlight-$VERSION.dmg"
fail() { echo "publish: $*" >&2; exit 1; }

# Every check runs before anything is built or published.
[[ "$(git branch --show-current)" == main ]] || fail "not on main"
[[ -z "$(git status --porcelain)" ]] || fail "uncommitted changes"
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "main is not pushed (or is behind origin)"
git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1 && fail "$TAG already exists; bump MARKETING_VERSION first"

echo "Waitlight $VERSION ($TAG)"
if [[ -n "${DRY_RUN:-}" ]]; then echo "DRY_RUN: checks passed, nothing published."; exit 0; fi

Scripts/release.sh
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

NOTES=$(printf '%s\n' "Install with Homebrew:" "" '```sh' "brew install --cask falconsw/tap/waitlight" '```' "" "Requires macOS 15 or later.")
git tag -a "$TAG" -m "Waitlight $VERSION"
git push -q origin "$TAG"
gh release create "$TAG" "$DMG" -R "$REPO" --verify-tag --title "Waitlight $VERSION" --notes "$NOTES" --generate-notes

# What users download must be what was notarized here.
REMOTE_SHA=$(curl -sfL "https://github.com/$REPO/releases/download/$TAG/Waitlight-$VERSION.dmg" | shasum -a 256 | cut -d' ' -f1)
[[ "$REMOTE_SHA" == "$SHA" ]] || fail "downloaded DMG does not match ($REMOTE_SHA != $SHA); cask not updated"

TAPDIR=$(mktemp -d)
trap 'rm -rf "$TAPDIR"' EXIT
gh repo clone "$TAP" "$TAPDIR" -- -q
# Written whole, so the first release creates the cask and later ones update it.
cat > "$TAPDIR/Casks/waitlight.rb" <<CASK
cask "waitlight" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/falconsw/Waitlight/releases/download/v#{version}/Waitlight-#{version}.dmg"
  name "Waitlight"
  desc "Menu bar app showing when Claude Code is waiting for you"
  homepage "https://github.com/falconsw/Waitlight"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Waitlight.app"

  uninstall quit: "com.falconsw.waitlight"

  zap trash: [
    "~/Library/Caches/com.falconsw.waitlight",
    "~/Library/HTTPStorages/com.falconsw.waitlight",
    "~/Library/Preferences/com.falconsw.waitlight.plist",
  ]
end
CASK
git -C "$TAPDIR" add Casks/waitlight.rb
git -C "$TAPDIR" -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" \
  commit -q -m "waitlight $VERSION"
git -C "$TAPDIR" push -q origin HEAD

echo "Published Waitlight $VERSION"
echo "  https://github.com/$REPO/releases/tag/$TAG"
echo "  brew install --cask falconsw/tap/waitlight"
