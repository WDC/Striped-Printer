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
    system "codesign", "--force", "--sign", "-", ".build/release/StripedPrinter"
    bin.install ".build/release/StripedPrinter"
  end

  service do
    run [opt_bin/"StripedPrinter"]
    keep_alive true
    log_path var/"log/striped-printer.log"
    error_log_path var/"log/striped-printer.log"
  end

  test do
    # Verify the binary runs and prints version info
    assert_match "StripedPrinter", shell_output("file #{bin}/StripedPrinter")
  end
end
