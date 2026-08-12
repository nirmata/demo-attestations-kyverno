#!/bin/bash
set -e

echo "=== Cosign Key Pair Setup ==="
echo ""

# Check if cosign is installed
if ! command -v cosign &> /dev/null; then
    echo "❌ cosign not found. Please install cosign first:"
    echo ""
    echo "  macOS: brew install cosign"
    echo "  Linux: https://docs.sigstore.dev/cosign/installation/"
    echo ""
    exit 1
fi

echo "✅ cosign found: $(cosign version 2>&1 | head -n1)"
echo ""

# Check if keys already exist
if [ -f "cosign.key" ] || [ -f "cosign.pub" ]; then
    echo "⚠️  Warning: cosign.key or cosign.pub already exists in this directory"
    read -p "Overwrite existing keys? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    rm -f cosign.key cosign.pub
fi

# Generate key pair
echo "Generating cosign key pair..."
echo "You'll be prompted to set a password for the private key."
echo ""
cosign generate-key-pair

if [ ! -f "cosign.key" ] || [ ! -f "cosign.pub" ]; then
    echo "❌ Key generation failed"
    exit 1
fi

echo ""
echo "✅ Key pair generated successfully!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 Next steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Add GitHub Secrets to your repository:"
echo "   Go to: Settings → Secrets and variables → Actions → New repository secret"
echo ""
echo "   Secret name: COSIGN_PRIVATE_KEY"
echo "   Secret value: (paste the content below)"
echo ""
echo "   ┌────────────────────────────────────────┐"
cat cosign.key
echo "   └────────────────────────────────────────┘"
echo ""
echo "   Secret name: COSIGN_PASSWORD"
echo "   Secret value: (the password you just entered)"
echo ""
echo "2. Optionally commit the public key to the repo:"
echo "   git add cosign.pub"
echo "   git commit -m 'Add cosign public key'"
echo ""
echo "3. Keep cosign.key SECURE and NEVER commit it!"
echo "   Add it to .gitignore if not already there."
echo ""
echo "4. Push to GitHub to trigger the workflow:"
echo "   git push"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
