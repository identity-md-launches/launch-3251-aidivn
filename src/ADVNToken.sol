// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title AIDIVN (ADVN)
/// @notice Fixed-supply ERC-20 with a trade tax: every taxed transfer sends 0.5% of the amount to
///         Jensen Huang's address and burns 1% of the amount; the recipient receives the other 98.5%.
///
/// @dev Launch model (IMD custom token launch, Uniswap v4 pool paired with native ETH):
///      - The constructor mints the whole supply once to `msg.sender` (the launch factory). Nothing
///        can mint afterwards: there is no owner, no minter, no pause, no blocklist, no upgrade.
///      - Launch flows move exactly what they say, so the tax never applies when
///          * the factory sends (swarm share to the MerkleDistributor, pool seed, remainder),
///          * the launch's MerkleDistributor sends (contributor claims), resolved at transfer time
///            through `distributorOf(launchNumber)` on the factory, or
///          * tokens are sent INTO the Uniswap v4 PoolManager (a sell, a liquidity deposit): v4
///            settlement checks the PoolManager received exactly what the payer declared, so a tax
///            here would make every sell revert.
///      - Everything else is taxed, including tokens leaving the PoolManager (a buy from the launch
///        pool, or an LP withdrawal) and wallet-to-wallet transfers.
///      - The tax is an ERC-20 transfer tax, so it can only run when this contract is called.
///        Uniswap v4 lets a trader settle a swap as ERC-6909 claims inside the PoolManager
///        (`mint`/`burn`) and move claims with the PoolManager's own `transfer`; none of that calls
///        this token, so value held or traded as claims is untaxed until it leaves the PoolManager
///        as ERC-20 (`take`), which is taxed like any other transfer out. Taxing pool trades
///        regardless of settlement would need a v4 hook, which this launch kind does not deploy.
///      No stored state is ever changed except ERC-20 balances, allowances and the total supply.
contract ADVNToken is ERC20 {
    /// @notice Where the 0.5% trade fee goes (Jensen Huang, as the requester named it).
    address public constant FEE_RECIPIENT = 0xc59b0c072f73ceEA3Dc354031165501c0Ff25023;

    /// @notice Trade fee forwarded to `FEE_RECIPIENT`, in basis points of the transferred amount.
    uint256 public constant FEE_BPS = 50;

    /// @notice Share of every taxed transfer that is burned, in basis points of the transferred amount.
    uint256 public constant BURN_BPS = 100;

    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice The whole supply, minted once in the constructor: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 1e18;

    /// @notice The launch factory: it receives the supply and its outgoing transfers are untaxed.
    address public immutable FACTORY;

    /// @notice The Uniswap v4 PoolManager: transfers into it are untaxed so swaps settle exactly.
    address public immutable POOL_MANAGER;

    /// @notice This launch's number on the factory, used to look up its MerkleDistributor.
    uint64 public immutable LAUNCH_NUMBER;

    /// @notice Emitted for every taxed transfer with the fee and burn taken from `amount`.
    event TradeTaxed(address indexed from, address indexed to, uint256 amount, uint256 fee, uint256 burned);

    /// @notice A launch address was the zero address.
    error ZeroAddress();

    /// @param factory_ The launch factory, which deploys this token and receives the supply (`$factory`).
    /// @param poolManager_ The chain's Uniswap v4 PoolManager (`$poolManager`).
    /// @param launchNumber_ This launch's number on the factory (`$launchNumber`).
    constructor(address factory_, address poolManager_, uint64 launchNumber_) ERC20("AIDIVN", "ADVN") {
        if (factory_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        FACTORY = factory_;
        POOL_MANAGER = poolManager_;
        LAUNCH_NUMBER = launchNumber_;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice The launch's MerkleDistributor as the factory reports it, or the zero address when
    ///         the factory has no code, reverts, answers short, or answers a word that is not an
    ///         address, or has not recorded one yet. This lookup never reverts a transfer.
    function distributor() public view returns (address) {
        (bool ok, bytes memory data) =
            FACTORY.staticcall(abi.encodeWithSignature("distributorOf(uint64)", LAUNCH_NUMBER));
        if (!ok || data.length < 32) return address(0);
        // Decoded as a word, not an address: `abi.decode(data, (address))` reverts on dirty upper bits.
        uint256 word = abi.decode(data, (uint256));
        if (word > type(uint160).max) return address(0);
        // Casting to uint160 is safe: the line above returned for every word with higher bits set.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }

    /// @notice Whether a transfer from `from` to `to` is one of the launch flows that move exactly
    ///         what they say (and so pays no fee and burns nothing).
    function isExempt(address from, address to) public view returns (bool) {
        if (from == FACTORY || to == POOL_MANAGER) return true;
        address launchDistributor = distributor();
        return launchDistributor != address(0) && from == launchDistributor;
    }

    /// @notice The fee and burn a taxed transfer of `amount` would take, and what the recipient gets.
    /// @dev Divides by the whole-number reciprocals (200 and 100) so the result is defined for every
    ///      uint256; `amount * FEE_BPS / BPS_DENOMINATOR` gives the same values but overflows above
    ///      2^256 / 100. Both rates divide the denominator exactly (10_000 / 50 and 10_000 / 100).
    function previewTransfer(uint256 amount) public pure returns (uint256 fee, uint256 burned, uint256 received) {
        fee = amount / (BPS_DENOMINATOR / FEE_BPS);
        burned = amount / (BPS_DENOMINATOR / BURN_BPS);
        received = amount - fee - burned;
    }

    /// @dev Mints (the constructor) and exempt flows go through untouched. Every other transfer
    ///      splits `value` into the recipient's share, the fee and the burn. OpenZeppelin's
    ///      `_update` with `to == address(0)` is a burn and reduces `totalSupply`.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || isExempt(from, to)) {
            super._update(from, to, value);
            return;
        }
        uint256 fromBalance = balanceOf(from);
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        (uint256 fee, uint256 burned, uint256 received) = previewTransfer(value);
        super._update(from, to, received);
        if (fee > 0) super._update(from, FEE_RECIPIENT, fee);
        if (burned > 0) super._update(from, address(0), burned);
        emit TradeTaxed(from, to, value, fee, burned);
    }
}
