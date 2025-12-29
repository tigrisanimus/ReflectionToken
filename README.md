# Basalt (BSLT) Pure Reflection Token

Basalt is a minimal, ownerless ERC20 that implements **pure reflections**. Every transfer pays a 1% fee that is redistributed to **all holders**, including the burn address. There are **no buybacks, swaps, or liquidity logic** in the contract, so it behaves like a standard ERC20 that can be paired with any asset.

## WARNING

DEX pairs receive reflections and their balances can change without transfers; integrators must account for reflection-token AMM behavior.

## Tokenomics

- **Name:** Basalt
- **Symbol:** BSLT
- **Decimals:** 18
- **Total supply:** 1000e18 (1,000 tokens)
- **Reflection fee:** 1% on every transfer (no external tax wallet)
- **Initial distribution:** 100% minted to the initial holder (deployer-provided EOA)
- **No exclusions:** every address receives reflections

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

## Deployment

The deploy script reads `INITIAL_HOLDER` from the environment, otherwise derives the holder from `PRIVATE_KEY`.

```bash
export INITIAL_HOLDER=0xYourEOA
forge script script/DeployPureReflection.s.sol:DeployPureReflection \
  --rpc-url <RPC_URL> \
  --private-key <PRIVATE_KEY> \
  --broadcast
```

## Project layout

- `src/PureReflectionToken.sol` - Token implementation
- `test/PureReflectionToken.t.sol` - Unit tests
- `script/DeployPureReflection.s.sol` - Deployment script
