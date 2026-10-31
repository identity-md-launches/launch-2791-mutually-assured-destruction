# Mutually Assured Destruction (MAD)

A fixed-supply ERC-20 token for Ethereum mainnet, built with Foundry.

| Property | Value |
| --- | --- |
| Solidity contract | `MADToken` (`src/MADToken.sol`) |
| Token name | `Mutually Assured Destruction` |
| Symbol | `MAD` |
| Decimals | 18 |
| Total supply | 1,000,000,000 MAD = `1000000000000000000000000000` minor units |
| Minting | Once, in the constructor, the whole supply to the deployer (`msg.sender`) |
| Constructor arguments | None |
| Owner / admin | None |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## What the contract does

- **Fixed supply.** The constructor mints exactly `INITIAL_SUPPLY` to `msg.sender` and nothing
  else can ever mint. There is no `mint`, no minter role, no owner, no proxy.
- **Plain transfers.** No fee, tax, reflection, blocklist, pause or transfer limit. Every transfer
  moves exactly the amount requested, for every sender and receiver.
- **Burning.** The supply can only shrink. A holder may `burn` their own tokens, or `burnFrom`
  another holder's tokens only up to the allowance that holder granted. Nobody can burn a balance
  they were not approved to spend.
- **Permit (ERC-2612).** Holders can sign an off-chain approval that anyone may submit via
  `permit`. Signatures are bound to the chain id, the contract address, a per-holder nonce and a
  deadline.

The contract is OpenZeppelin Contracts v5.4.0 `ERC20` + `ERC20Burnable` + `ERC20Permit` with the
name, symbol, decimals and supply fixed as constants. There is no custom transfer logic.

## Assumptions

- The brief asks for a token with a fixed supply and standard behaviour. Nothing in it asks for an
  owner, so none exists. This cannot be changed after deployment.
- The deployer is whoever sends the creation transaction. In the IdentityMD launch this is the
  `ProjectFactory`, which then distributes the supply according to the launch economics (see below).
- Decimals are fixed at 18 by the brief. `decimals()` is a `pure` constant.
- The permit domain uses the token name as the EIP-712 name and `"1"` as the version.
- Tokens sent to the zero address are refused by the ERC-20 implementation. Tokens sent to any other
  address, including the token contract itself, are the sender's responsibility: there is no
  rescue function because there is no admin.

## Deployment parameters

The contract takes no constructor arguments and reads no outside contract. Deploying it is a
single `CREATE`/`CREATE2` of the compiled bytecode. Build reproducibly with:

```sh
forge build
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `optimizer = true`,
`optimizer_runs = 200`, `bytecode_hash = "none"` and `cbor_metadata = false`, so the deployed
bytecode is deterministic across machines.

### Launch (Ethereum, chain id 1)

The launch is performed by IdentityMD's deployer through its factory; nothing in this repository
deploys, broadcasts or signs. The launch settings below are decided by the launch and are recorded
here for the operator's reference only:

- Pair currency: FWA, `0xa0df17b5ac76ababa36e1450e2cbcd18a620c845` (18 decimals).
- Pool fee 12500 (1.25%), tick spacing 60.
- Economics: 50% of the supply seeds the single-sided pool at a 2,000,000 FWA opening market cap
  for the whole supply, 10% goes to the swarm's MerkleDistributor, and the remaining 40% goes to
  `0x019817ad02a31b990433542097be29d97613e8cb`.

The token needs no exemptions for these flows because it never taxes or blocks a transfer: the
factory, the pool manager and the distributor all move exactly what they send.

### Local or fork deployment

`script/DeployMADToken.s.sol` wraps `new MADToken()` in `deploy()`, which the tests call directly.
To deploy with your own signer on a fork or test network:

```sh
forge script script/DeployMADToken.s.sol --rpc-url <RPC_URL> --broadcast
```

The signer of that transaction receives the whole supply.

## After launch

There is nothing to configure. The token has no owner-settable values, no setters and no
privileged functions.

## Operational responsibilities

- **Whoever holds the supply holds the supply.** The deployer (the factory at launch) receives all
  1,000,000,000 MAD and is responsible for distributing it. The contract gives no one the power to
  reclaim, freeze or redirect tokens after that.
- **No recovery path.** There is no pause, no upgrade and no admin. A bug could only be addressed by
  deploying a new token and migrating holders socially.
- **Burns are irreversible.** Operators and holders should treat `burn` and `burnFrom` as
  permanent.
- **Permit signatures.** Holders should sign permits only for spenders they trust and with short
  deadlines. A permit is as powerful as an `approve`.
- **Explorer verification** of the source after deployment belongs to the launch's deployer.

## Security notes

Reviewed against the pinned `eth-security` checklist:

- No external calls, no ETH handling (the contract has no `receive`/`fallback`, so sent ETH
  reverts), no reentrancy surface.
- No `selfdestruct`, `delegatecall` or `callcode`. No libraries with external functions.
- `transferFrom` and `burnFrom` move tokens only within the allowance the holder granted.
- No `abi.encodePacked` of dynamic values in the contract itself.
- The verifier's Slither run is not available on the build machine; the contract avoids the six
  rejected detectors by construction.

Tests passing is not an audit. The contract contains no custom logic beyond OpenZeppelin's audited
implementations, but an independent review before relying on it is still recommended.

## Tests

```sh
forge build
forge test
forge fmt --check
```

`test/MADToken.t.sol` covers metadata and supply constants, the single constructor mint (to an EOA,
a contract and the deploy script), the absence of any mint or admin entry point, transfer success
and failure (insufficient balance, zero receiver, one wei over), allowances and `transferFrom`
(within, over and without allowance, unlimited allowance), burns (`burn`, `burnFrom`, over-balance
and without allowance), permit (valid, expired, wrong signer, replay, domain separator) and fuzz
properties (supply conservation, allowance accounting, burn monotonicity, a stranger cannot move a
holder's balance).

## Layout

```
foundry.toml                 compiler and formatter pins
remappings.txt               forge-std and @openzeppelin/contracts remappings
src/MADToken.sol             the token
script/DeployMADToken.s.sol  local deploy helper
test/MADToken.t.sol          tests
lib/forge-std                forge-std v1.10.0 (vendored, MIT/Apache-2.0)
lib/openzeppelin-contracts   OpenZeppelin Contracts v5.4.0 (vendored, MIT)
```

Dependencies are vendored as ordinary files so the project builds offline; there are no git
submodules.
