# MAD token tests

The original tests remain in `MADToken.t.sol`. Its transfer conservation property
now counts a self-transfer recipient once, with a deterministic regression case.
The expected constructor supply is independently specified as `1_000_000_000 *
10 ** 18`; it is not taken from the implementation's supply constant.

## Added coverage

| File | Properties and failure cases |
| --- | --- |
| `MADTokenEdges.t.sol` | Exactly one constructor mint event; zero, one-wei, full-supply and maximum-uint amounts; transfer round trips; approval replacement, revocation and isolation; shared transfer/burn allowances; finite versus infinite approvals; atomic failure of delegated spending; dust and fully burned supply. |
| `MADTokenPermit.t.sol` | Independent EIP-712 digest construction; exact deadline boundary; expired, malformed, high-s, wrong-signer and altered-message signatures; owner-wide nonces; replay after revocation; contract and chain separation; nonce rollback after rejected permits; permitted transfer/burn spending. |
| `MADTokenInvariant.t.sol` | Random call sequences against `handlers/MADTokenHandler.sol`, plus a deterministic sequence that exercises nonzero movements, burns, permits and expected failures. |

The stateful suite uses four signing actors, starts with the real constructor
supply, and distributes it using real transfers. The token address is also a
passive recipient; its balance is included in conservation, and the handler never
impersonates it to withdraw those tokens. No token balances or storage are changed
with cheatcodes. The original contract deployer is included in attempted admin calls.

Only the handler's 13 explicitly selected actions are fuzzed. Valid amounts are
bounded by the independent model, with extra weight on zero, one wei and full
balances. Approvals include zero, ordinary finite amounts, `uint256.max - 1`, and
`uint256.max`. Expected failures assert their errors; unexpected reverts fail the
campaign (`fail-on-revert = true`). Failed operations do not update the model.

After every random action the suite checks:

- Current supply plus cumulative authorized burns equals the original supply.
- Every tracked balance matches authorized movements, and their sum equals supply.
- Every actor-pair allowance matches approvals and successful delegated spending.
- Nonces increase exactly once per successful permit; rejected permits and other
  operations cannot change them. The zero address has no balance or allowance.

These properties were selected through the five discovery passes in the supplied
Pashov fizz guide and the supplied Trail of Bits property-testing review:

| Discovery pass | Application and source basis |
| --- | --- |
| Conservation | Constructor issuance (`src/MADToken.sol:37`), balance/supply accounting (`ERC20.sol:176`), and authorized burns (`ERC20Burnable.sol:20`, `:35`). |
| Round trips and rounding | Exact transfers between actors, including one wei, repeated cycles, and self-transfers (`ERC20.sol:99`). There are no exchange rates or share conversions. |
| State transitions | Approval replacement and spending (`ERC20.sol:120`, `:142`, `:294`); successful permit nonce increments and complete rollback on failure (`ERC20Permit.sol:42`). |
| Adversarial cases | Unapproved transfers/burns, revoked budgets, oversized amounts, replayed or altered signatures, wrong domains, and attempted mint/pause/freeze calls. |
| Token-specific checks | Zero address restrictions, self-transfers, exact recipient credit, infinite approvals, and constructor metadata/supply. |

Library references above are in the vendored OpenZeppelin
`lib/openzeppelin-contracts/contracts/token/ERC20/` directory (burn/permit under
`extensions/`). The supply invariant permits authorized burns; the implementation
and supplied protected checks explicitly permit supply to shrink after deployment.

## Running

```sh
forge build --offline
FOUNDRY_FUZZ_SEED=0x4320d5a9f8e7aa69755a70eaf5dfd2a85be16e4346f1e9ce31374666d8c3e83d forge test --offline
```

Inline configuration sets 1,000 cases per fuzz property and 256 sequences of 128
calls per invariant. Tests use the project's existing vendored dependencies and
require no RPC, network, environment secrets, FFI, or scratch files. The supplied
launch-floor tests depend on separate factory/pool infrastructure; these local
tests exercise the delivered token, without claiming to run those external checks.
