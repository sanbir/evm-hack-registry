// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  QuantAMM — UpliftOnlyExample admin fee divides before multiplying
    (Codehawks, finding #49683)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: `adminFee = hookFee / (1e18 / quantAMMFeeTake)` floors the
    denominator first. At a 60% take, 1e18/0.6e18 is 1, so the admin is
    paid the entire hook fee and the router/owner is paid 0 instead of 40%. */

contract ERC20 {
    string public symbol = "FEE";
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Router {}

contract Hook {
    uint256 public constant WAD = 1e18;
    ERC20 public token;
    address public admin;
    address public router;
    uint256 public quantAMMFeeTake;
    bool public fixedMode;
    uint256 public adminFee;
    uint256 public ownerFee;

    constructor(ERC20 t, address a, address r, uint256 take, bool fixed_) {
        token = t;
        admin = a;
        router = r;
        quantAMMFeeTake = take;
        fixedMode = fixed_;
    }

    function onAfterSwap() external {
        uint256 hookFee = token.balanceOf(address(this));
        uint256 adminCut;
        uint256 ownerCut;
        if (quantAMMFeeTake > 0) {
            if (fixedMode) {
                // FIX: multiply before dividing
                adminCut = hookFee * quantAMMFeeTake / WAD;
            } else {
                adminCut = hookFee / (WAD / quantAMMFeeTake); // @> VULN: denominator floors, so a 60% take becomes 100%
            }
            ownerCut = hookFee - adminCut;
        }
        adminFee = adminCut;
        ownerFee = ownerCut;
        if (adminCut > 0) token.transfer(admin, adminCut);
        if (ownerCut > 0) token.transfer(router, ownerCut);
    }
}

contract Exploit {
    ERC20 public token; // nonce 1
    Router public router; // nonce 2
    Hook public hook; // nonce 3

    constructor() {
        token = new ERC20();
        router = new Router();
        hook = new Hook(token, address(this), address(router), 0.6 ether, false);
        token.mint(address(hook), 1000 ether);
    }

    function run() external {
        hook.onAfterSwap();
        require(hook.adminFee() == 1000 ether, "admin took 1000");
        require(hook.ownerFee() == 0, "router was paid");
        require(token.balanceOf(address(this)) == 1000 ether, "admin balance");
        require(token.balanceOf(address(router)) == 0, "router balance");
    }
}
