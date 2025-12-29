# PureReflectionToken (Foundry)

A minimal Foundry project for a pure reflection ERC20 token.

## Requirements

- Foundry (`forge`, `cast`, `anvil`)

If Foundry is not installed:

```bash
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc || source ~/.zshrc || true
foundryup
```

## Quick start

```bash
forge --version
forge fmt
forge test -vvv
```

## Project layout

- `src/PureReflectionToken.sol` - Token implementation
- `test/PureReflectionToken.t.sol` - Unit tests
