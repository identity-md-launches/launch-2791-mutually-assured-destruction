// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Mutually Assured Destruction (MAD)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 MAD (18 decimals) is minted
///         once, in the constructor, to the deployer. Nothing can mint afterwards.
/// @dev Design, in one paragraph:
///      - No owner, no admin, no pause, no blocklist, no fee on transfer, no upgrade path. The
///        contract has no privileged role at all, so no hand can move or freeze a holder's balance.
///      - The supply can only shrink: any holder may burn their own tokens (`burn`), or tokens they
///        have been given an allowance for (`burnFrom`, which spends that allowance). Burning
///        someone else's balance without their approval is impossible.
///      - ERC-2612 `permit` is included so holders can grant gasless approvals by signature.
///      - The deployer receives the supply because it is `msg.sender` of the constructor; the
///        constructor calls no other contract and takes no arguments.
contract MADToken is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice Token name, as returned by `name()`.
    string public constant TOKEN_NAME = "Mutually Assured Destruction";

    /// @notice Token symbol, as returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "MAD";

    /// @notice Number of whole tokens minted at deployment.
    uint256 public constant WHOLE_TOKENS = 1_000_000_000;

    /// @notice Decimals, as returned by `decimals()`. Fixed by the brief.
    uint8 public constant DECIMALS = 18;

    /// @notice The total supply in minor units: 1,000,000,000 * 10^18. Minted exactly once.
    uint256 public constant INITIAL_SUPPLY = WHOLE_TOKENS * 10 ** uint256(DECIMALS);

    /// @notice Mints the entire fixed supply to the deployer (`msg.sender`).
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
