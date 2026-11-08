// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Vyper Boost BuyAndBurn — treasury transfer is commented out (Shieldify H-01).
    SYNTHETIC, cheatcode-free. After DragonX is swapped to 100 VYPER, 8 VYPER
    goes to the liquidity wallet and burnVyper() burns the other 92.
    The 50 VYPER transfer to vyper.treasury() is commented out, so the
    treasury balance stays 0. The fixed path sends 50 and burns 42. */

contract Token {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    address public treasury;

    constructor(string memory _name, string memory _symbol, address _treasury) {
        name = _name;
        symbol = _symbol;
        treasury = _treasury;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract Treasury {}

contract Liquidity {}

contract BuyAndBurn {
    uint256 internal constant WAD = 1e18;
    uint256 public constant INCENTIVE_FEE = 0.01e18;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    Token public dragonX;
    Token public vyper;
    address public liquidity;

    struct Interval {
        uint256 amountAllocated;
    }

    Interval public currInterval;

    constructor(Token _dragonX, Token _vyper, address _liquidity) {
        dragonX = _dragonX;
        vyper = _vyper;
        liquidity = _liquidity;
    }

    function seed(uint256 amount) external {
        currInterval.amountAllocated = amount;
    }

    modifier intervalUpdate() {
        _;
    }

    modifier notExpired(uint32 deadline) {
        require(uint256(deadline) >= block.timestamp, "expired");
        _;
    }

    function wmul(uint256 x, uint256 y) public pure returns (uint256) {
        return (x * y) / WAD;
    }

    function swapExactInput(address, address, uint256 amountIn, uint256, uint32) public returns (uint256 vyperAmount) {
        dragonX.transfer(DEAD, amountIn);
        vyperAmount = 100 ether;
        vyper.mint(address(this), vyperAmount);
    }

    function burnVyper() public {
        uint256 bal = vyper.balanceOf(address(this));
        // @> VULN: the 50 VYPER treasury transfer is commented out, so this burns the whole remainder. 92 VYPER goes to the dead address and the treasury balance stays 0.
        vyper.transfer(DEAD, bal);
    }

    function swapDragonXToVyperAndBurn(uint32 _deadline) external virtual intervalUpdate notExpired(_deadline) {
        uint256 incentive = wmul(currInterval.amountAllocated, INCENTIVE_FEE);
        uint256 dragonXToSwapAndBurn = currInterval.amountAllocated - incentive;
        uint256 vyperAmount = swapExactInput(address(dragonX), address(vyper), dragonXToSwapAndBurn, 0, _deadline);
        {
            vyper.transfer(liquidity, wmul(vyperAmount, uint256(0.08e18)));
            // vyper.transfer(address(vyper.treasury()), wmul(vyperAmount, uint256(0.5e18)));
            burnVyper();
        }
        dragonX.transfer(msg.sender, incentive);
    }
}

contract Exploit {
    Token public dragonX; // nonce 1
    Treasury public treasury; // nonce 2
    Token public vyper; // nonce 3
    Liquidity public liquidity; // nonce 4
    BuyAndBurn public burner; // nonce 5

    constructor() {
        dragonX = new Token("DragonX", "DRX", address(0));
        treasury = new Treasury();
        vyper = new Token("Vyper", "VYPER", address(treasury));
        liquidity = new Liquidity();
        burner = new BuyAndBurn(dragonX, vyper, address(liquidity));
    }

    function run() external {
        dragonX.mint(address(burner), 1000 ether);
        burner.seed(1000 ether);
        burner.swapDragonXToVyperAndBurn(type(uint32).max);
        require(vyper.balanceOf(address(treasury)) == 0, "treasury 0");
        require(vyper.balanceOf(address(liquidity)) == 8 ether, "lp 8");
        require(vyper.balanceOf(burner.DEAD()) == 92 ether, "burned 92");
        require(vyper.balanceOf(address(burner)) == 0, "none left");
    }
}
