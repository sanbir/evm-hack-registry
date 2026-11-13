// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Taiko AssignmentHooks — ERC20 prover fee always reverts
    (Sigma Prime, Taiko review, finding 36001).

    SYNTHETIC, cheatcode-free reduction. onProposedBlock is only called by
    TaikoL1, so msg.sender is TaikoL1. The ERC20 branch pulls proverFee from
    msg.sender. The proposer holds the tokens and the approval. The pull
    reverts, the prover is paid nothing, and the fee stays with the proposer.

    The quoted line is preserved verbatim. */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract FeeToken is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 bal = balanceOf[from];
        require(bal >= amount, "balance");
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "allowance");
        balanceOf[from] = bal - amount;
        allowance[from][msg.sender] = allowed - amount;
        balanceOf[to] += amount;
        return true;
    }
}

struct Assignment {
    address feeToken;
}

struct BlockData {
    address assignedProver;
}

struct HookInput {
    uint256 tip;
}

contract AssignmentHooks {
    function onProposedBlock(
        Assignment calldata assignment,
        BlockData calldata blk,
        HookInput calldata input,
        address proposer,
        uint256 proverFee
    ) external payable returns (uint256 refund) {
        proposer;
        if (assignment.feeToken == address(0)) {
            if (msg.value < proverFee + input.tip) revert("HOOK_ASSIGNMENT_INSUFFICIENT_FEE");
            unchecked {
                refund = msg.value - proverFee - input.tip;
            }
        } else {
            if (msg.value < input.tip) revert("HOOK_ASSIGNMENT_INSUFFICIENT_FEE");
            unchecked {
                refund = msg.value - input.tip;
            }
            // Paying ERC20 tokens
            // @> VULN: transferFrom sender is msg.sender (TaikoL1), not the proposer
            IERC20(assignment.feeToken).transferFrom(msg.sender, blk.assignedProver, proverFee);
            // FIX: IERC20(assignment.feeToken).transferFrom(proposer, blk.assignedProver, proverFee);
        }
    }
}

contract AssignmentHooksFixed {
    function onProposedBlock(
        Assignment calldata assignment,
        BlockData calldata blk,
        HookInput calldata input,
        address proposer,
        uint256 proverFee
    ) external payable returns (uint256 refund) {
        if (assignment.feeToken == address(0)) {
            if (msg.value < proverFee + input.tip) revert("HOOK_ASSIGNMENT_INSUFFICIENT_FEE");
            unchecked {
                refund = msg.value - proverFee - input.tip;
            }
        } else {
            if (msg.value < input.tip) revert("HOOK_ASSIGNMENT_INSUFFICIENT_FEE");
            unchecked {
                refund = msg.value - input.tip;
            }
            IERC20(assignment.feeToken).transferFrom(proposer, blk.assignedProver, proverFee);
        }
    }
}

contract Proposer {
    function approve(FeeToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

contract TaikoL1 {
    AssignmentHooks public hooks;

    constructor(AssignmentHooks hooks_) {
        hooks = hooks_;
    }

    function proposeBlock(
        Assignment calldata assignment,
        BlockData calldata blk,
        HookInput calldata input,
        address proposer,
        uint256 proverFee
    ) external payable {
        hooks.onProposedBlock{value: msg.value}(assignment, blk, input, proposer, proverFee);
    }
}

contract Exploit {
    address public constant PROVER = 0x4444444444444444444444444444444444444444;
    uint256 public constant FEE = 100 ether;

    FeeToken public token;
    Proposer public proposer;
    AssignmentHooks public hooks;
    TaikoL1 public taiko;
    uint256 public stuck;
    uint256 public proverPaid;
    bool public reverted;

    constructor() {
        token = new FeeToken();
        proposer = new Proposer();
        hooks = new AssignmentHooks();
        taiko = new TaikoL1(hooks);
    }

    function run() external {
        token.mint(address(proposer), FEE);
        proposer.approve(token, address(hooks), FEE);
        Assignment memory assignment = Assignment({feeToken: address(token)});
        BlockData memory blk = BlockData({assignedProver: PROVER});
        HookInput memory input = HookInput({tip: 0});
        (bool ok,) = address(taiko).call(
            abi.encodeCall(taiko.proposeBlock, (assignment, blk, input, address(proposer), FEE))
        );
        reverted = !ok;
        stuck = token.balanceOf(address(proposer));
        proverPaid = token.balanceOf(PROVER);
        require(reverted, "payment should revert");
        require(proverPaid == 0, "prover was paid");
        require(stuck == FEE, "fee did not stay");
    }
}
