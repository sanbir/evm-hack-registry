// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Xyro — withdrawRakeback always reverts (Zokyo, August 2024)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: Treasury.withdrawRakeback calls IERC20Mint.mint, which is
    declared to return bool, but XyroToken.mint returns no data. The caller
    ABI-decodes a bool and reverts. Earned rakeback cannot be claimed.
    The blamed body is the report's withdrawRakeback. */

contract XyroToken {
    string public symbol = "XYRO";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 value) external {
        balanceOf[to] += value;
    }
}

interface IERC20Mint {
    function mint(address to, uint256 value) external returns (bool);
}

contract Treasury {
    event Credited(address user, uint256 amount);
    XyroToken public token;
    mapping(address => uint256) public earnedRakeback;

    constructor(XyroToken token_) {
        token = token_;
    }

    function credit(address user, uint256 amount) external {
        earnedRakeback[user] = amount;
        emit Credited(user, amount);
    }

    function withdrawRakeback(uint256 amount) public {
        require(earnedRakeback[msg.sender] >= amount, "Amount is greated than earned rakeback");
        earnedRakeback[msg.sender] -= amount;
        IERC20Mint(address(token)).mint(msg.sender, amount); // @> VULN: mint is declared to return bool, XyroToken.mint returns nothing
        // FIX: drop `returns (bool)` from IERC20Mint.mint so it matches XyroToken
    }
}

contract XyroTokenFixed {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 value) external returns (bool) {
        balanceOf[to] += value;
        return true;
    }
}

contract TreasuryFixed {
    XyroTokenFixed public token;
    mapping(address => uint256) public earnedRakeback;

    constructor(XyroTokenFixed token_) {
        token = token_;
    }

    function credit(address user, uint256 amount) external {
        earnedRakeback[user] = amount;
    }

    function withdrawRakeback(uint256 amount) public {
        require(earnedRakeback[msg.sender] >= amount, "amount");
        earnedRakeback[msg.sender] -= amount;
        require(token.mint(msg.sender, amount), "mint");
    }
}

contract Exploit {
    XyroToken public token; // CREATE nonce 1
    Treasury public treasury; // CREATE nonce 2
    bool public claimReverted;
    uint256 public earnedAfter;

    constructor() {
        token = new XyroToken();
        treasury = new Treasury(token);
    }

    function run() external {
        treasury.credit(address(this), 1000 ether);
        try treasury.withdrawRakeback(1000 ether) {
            claimReverted = false;
        } catch {
            claimReverted = true;
        }
        earnedAfter = treasury.earnedRakeback(address(this));
        require(claimReverted, "withdraw did not revert");
        require(token.balanceOf(address(this)) == 0, "tokens minted");
        require(earnedAfter == 1000 ether, "rakeback not stuck");
    }
}
