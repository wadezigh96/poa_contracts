# POA Agent Finance

A human-controlled spending authority for autonomous and AI finance agents.

## V1

`POAAgentFinance.sol` provides:

- Owner-controlled agent activation and revocation
- Expiring agent authority
- Native-asset spending caps
- ERC-20 spending caps
- Target + function-selector allowlisting for agent calls
- Recipient allowlisting for ERC-20 transfers
- Emergency pause
- Replay-safe execution accounting through a monotonic nonce
- On-chain events for agent configuration and execution
- No private key custody by the AI/agent

## Security model

The agent is an execution delegate, not the owner. The owner decides which agent address is active, how long it is valid, how much it may spend, which contract functions it may call, and which token recipients it may use.

This is a V1 foundation and has **not** been independently audited. Do not fund production deployments until tests, static analysis, fuzzing, and an external security review are completed.

## Planned V2

- EIP-712 signed agent intents
- Per-action and per-day limits
- Protocol adapters for swaps/lending/payments
- Human approval thresholds
- Simulation / shadow mode
- ERC-4337 / smart-account integration
- Formal invariants and fuzz tests
- Deployment scripts and verified deployments
