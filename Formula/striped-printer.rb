class StripedPrinter < Formula
  desc "Native macOS replacement for Zebra Browser Print"
  homepage "https://github.com/WDC/Striped-Printer"
  url "https://github.com/WDC/Striped-Printer/archive/refs/tags/v1.1.2.tar.gz"
  sha256 "a528551061429185632dc434aee35af891e835c69fa0b425a7cbb56c8d58df8c"
  license "MIT"

  depends_on xcode: ["14.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"

    # Create app bundle for .zpl file association and Launch Services
    app_dir = prefix/"StripedPrinter.app/Contents"
    (app_dir/"MacOS").mkpath
    (app_dir/"Resources").mkpath
    (app_dir/"MacOS").install ".build/release/StripedPrinter"
    app_dir.install "Info.plist"
    (app_dir/"Resources").install "AppIcon.icns"
    system "codesign", "--force", "--sign", "-", prefix/"StripedPrinter.app"

    # Symlink binary so brew services and PATH work
    bin.install_symlink app_dir/"MacOS/StripedPrinter"
  end

  def post_install
    # Register with Launch Services for .zpl file association
    system "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
           "-f", prefix/"StripedPrinter.app"
  end

  def caveats
    <<~EOS
      Launch the app once to start it and enable auto-start at login:
        open #{opt_prefix}/StripedPrinter.app

      Then click the printer icon in your menu bar and choose
      "Open at Login" to have it start automatically.

      Note: macOS 26 requires menu bar apps to be launched via
      Launch Services (not `brew services`), which is why this
      formula no longer registers a launchd agent.

      To open .zpl files with Striped Printer by default:
        brew install duti
        duti -s com.striped-printer .zpl all

      Or right-click any .zpl file → Open With → Striped Printer → Always Open With.
    EOS
  end

  test do
    assert_match "StripedPrinter", shell_output("file #{bin}/StripedPrinter")
  end
end
