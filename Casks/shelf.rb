cask "shelf" do
  version :latest
  sha256 :no_check

  url "https://github.com/Somamill/Shelf/releases/latest/download/Shelf.dmg"
  name "Shelf"
  desc "Unified Calibre and reading progress dashboard"
  homepage "https://github.com/Somamill/Shelf"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Shelf.app"

  zap trash: [
    "~/Library/Application Support/Shelf",
    "~/Library/Preferences/app.shelf.dashboard.plist",
    "~/Library/Saved Application State/app.shelf.dashboard.savedState",
  ]

  caveats do
    unsigned_accessibility
  end
end
