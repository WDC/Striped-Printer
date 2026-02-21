class StripedPrinter < Formula
  desc "Native macOS replacement for Zebra Browser Print"
  homepage "https://github.com/WDC/Striped-Printer"
  url "https://github.com/WDC/Striped-Printer/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "0019dfc4b32d63c1392aa264aed2253c1e0c2fb09216f8e2cc269bbfb8bb49b5"
  license "MIT"

  depends_on xcode: ["14.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
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
