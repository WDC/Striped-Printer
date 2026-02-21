class StripedPrinter < Formula
  desc "Native macOS replacement for Zebra Browser Print"
  homepage "https://github.com/WDC/Striped-Printer"
  url "https://github.com/WDC/Striped-Printer/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "a8bdd8623a9e649c53fceafd65f8b3441411fde3782c908c09a4ff44851d3896"
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

  service do
    run [opt_bin/"StripedPrinter"]
    keep_alive true
    log_path var/"log/striped-printer.log"
    error_log_path var/"log/striped-printer.log"
  end

  test do
    assert_match "StripedPrinter", shell_output("file #{bin}/StripedPrinter")
  end
end
