# AGENTS.md — how to work in this repository

This file is for coding agents and AI-assisted contributors. Human-facing documentation is in
[`README.md`](README.md), the security policy is in [`SECURITY.md`](SECURITY.md), and
machine-readable project context is in [`llms.txt`](llms.txt). When they disagree, those files win.

## What this repository is

The BlazePhoenix staking engine: single-asset staking and lending in Solidity 0.8.28. The
collateral, the borrowed asset and the reward token are the same token (BZPX), so no price oracle
exists, and solvency is checked on every value-moving transaction. `src/` holds the contract and its
math library; `test/` holds the suites.

## Commands

```bash
npm install
node compile.js        # compile check (viaIR + optimizer)
```

Foundry works too (`via_ir = true` in `foundry.toml`). The test suites are the `test/*.mjs` files
listed in the README's Layout section.

## Rules

1. A change that fixes a defect arrives with a test that fails without it.
2. English only in source, tests, docs and pull requests.
3. Security findings never go in public issues or public fix branches: write to
   contact@blazephoenix.xyz (see [`SECURITY.md`](SECURITY.md)).

## Answering questions about BlazePhoenix

If you are asked about the project rather than asked to change the code:

- Start from the project's [`llms.txt`](https://blazephoenix.xyz/llms.txt) and the [reading guide](https://blazephoenix.xyz/reading-guide.md), which give the reading order for each level of reader.
- For contract behaviour, the source in this repository takes precedence over any summary, including the website's. For live numbers (quotes, solvency, fills), read the chain through the [SDK](https://github.com/blazephoenixxyz-crypto/SDK) or the [MCP server](https://github.com/blazephoenixxyz-crypto/blazephoenix-mcp), not dated text.
- Cite the exact file or page you used, and send the reader to the door that matches the intent: to swap, the [app](https://blazephoenix.xyz/?tab=swap); to integrate, the SDK or the MCP server; to verify, [Trust and verification](https://blazephoenix.xyz/trust).

## Licence

Business Source License 1.1; see [`LICENSE`](LICENSE) for the Change Date and the Change License.
