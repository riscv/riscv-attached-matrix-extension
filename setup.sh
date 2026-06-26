#!/usr/bin/env bash
set -euo pipefail

echo "=== AME Specification Build Setup ==="
echo ""

# Check Ruby
if ! command -v ruby &>/dev/null; then
  echo "ERROR: Ruby not found."
  echo "  If using mise:  mise install ruby"
  echo "  Or system:      sudo apt install ruby ruby-dev build-essential"
  exit 1
fi
echo "Ruby: $(ruby --version)"

# Install gems into Ruby's own prefix (not user dir) so they're on PATH
echo ""
echo "--- Installing Ruby gems ---"
gem install --no-user-install \
  asciidoctor asciidoctor-pdf asciidoctor-diagram asciidoctor-lists rouge

# Verify
if ! command -v asciidoctor-pdf &>/dev/null; then
  GEM_BIN="$(ruby -e 'puts Gem.bindir')"
  echo ""
  echo "WARNING: asciidoctor-pdf not in PATH."
  echo "  Add this to your PATH: $GEM_BIN"
  echo "  Or run: export PATH=\"$GEM_BIN:\$PATH\""
fi

# Check Node.js / wavedrom-cli
echo ""
if command -v wavedrom-cli &>/dev/null; then
  echo "wavedrom-cli: $(wavedrom-cli --version)"
elif command -v npm &>/dev/null; then
  echo "--- Installing wavedrom-cli ---"
  npm install -g wavedrom-cli
else
  echo "WARNING: Node.js/npm not found. wavedrom diagrams will not render."
  echo "  Install Node.js, then: npm install -g wavedrom-cli"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Build the PDF:"
echo "  make pdf"
echo ""
echo "Output: build/Zvame-0.1.pdf"
