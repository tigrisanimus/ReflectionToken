# ReflectionTokenV2 (Foundry)

This repository contains a Foundry project for a reflection-based ERC20 token with buy/sell fees, multi-DEX AMM support, swapback liquidity provisioning, and ankrBNB-backed buybacks.

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

- `src/ReflectionTokenV2.sol` - Token implementation
- `src/interfaces/` - Minimal UniswapV2 interfaces
- `test/ReflectionTokenV2.t.sol` - Comprehensive unit tests
- `test/mocks/` - Mock AMM and ERC20 contracts for deterministic testing

## Notes

- Fees apply only on AMM buys/sells; wallet transfers remain fee-free.
- Total fee cap is enforced at 100 bps.
- Swapback executes only on sells and is guarded against external call failures.
- Buybacks use ankrBNB and respect cooldown and max-per-call limits.
