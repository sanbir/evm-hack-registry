// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  FIVA handle_swap_pt_for_sy (Trail of Bits, AuditVault #57088).
    SYNTHETIC of the FunC check, cheatcode-free, one transaction.

    Other swaps reject `sy_out > total_supply_sy - sy_locked - MINIMUM_LIQUIDITY`.
    The PT-to-SY swap forgets sy_locked. The check passes against the raw
    total, the PT is taken, and the SY payout cannot be filled from the
    unlocked balance. On TON that payout is a later message; here the PT
    pull is committed and the SY transfer is skipped, which is the same loss. */

contract Mini {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract AMM {
    uint256 public constant MIN_SWAP_AMOUNT = 1 ether;
    uint256 public constant MINIMUM_LIQUIDITY = 1 ether;

    Mini public immutable sy;
    Mini public immutable pt;
    uint256 public totalSupplySy;
    uint256 public totalSupplyPt;
    uint256 public syLocked;

    constructor(Mini sy_, Mini pt_) {
        sy = sy_;
        pt = pt_;
    }

    function seed(uint256 syTotal, uint256 locked) external {
        sy.transferFrom(msg.sender, address(this), syTotal);
        totalSupplySy = syTotal;
        syLocked = locked;
    }

    function handle_swap_pt_for_sy(uint256 ptIn, uint256 minSyOut) external returns (uint256 syOut) {
        syOut = ptIn;
        uint256 floorOut = minSyOut > MIN_SWAP_AMOUNT ? minSyOut : MIN_SWAP_AMOUNT;
        // @> VULN: compares syOut to totalSupplySy and ignores syLocked
        if (syOut < floorOut || syOut > (totalSupplySy - MINIMUM_LIQUIDITY)) {
            return 0;
        }
        pt.transferFrom(msg.sender, address(this), ptIn);
        totalSupplyPt += ptIn;
        uint256 available = totalSupplySy - syLocked;
        if (syOut > available) {
            return 0;
        }
        totalSupplySy -= syOut;
        sy.transfer(msg.sender, syOut);
    }
}

contract AMMFixed {
    uint256 public constant MIN_SWAP_AMOUNT = 1 ether;
    uint256 public constant MINIMUM_LIQUIDITY = 1 ether;

    Mini public immutable sy;
    Mini public immutable pt;
    uint256 public totalSupplySy;
    uint256 public syLocked;

    constructor(Mini sy_, Mini pt_) {
        sy = sy_;
        pt = pt_;
    }

    function seed(uint256 syTotal, uint256 locked) external {
        sy.transferFrom(msg.sender, address(this), syTotal);
        totalSupplySy = syTotal;
        syLocked = locked;
    }

    function handle_swap_pt_for_sy(uint256 ptIn, uint256 minSyOut) external returns (uint256 syOut) {
        syOut = ptIn;
        uint256 floorOut = minSyOut > MIN_SWAP_AMOUNT ? minSyOut : MIN_SWAP_AMOUNT;
        if (syOut < floorOut || syOut > (totalSupplySy - syLocked - MINIMUM_LIQUIDITY)) {
            return 0;
        }
        pt.transferFrom(msg.sender, address(this), ptIn);
        totalSupplySy -= syOut;
        sy.transfer(msg.sender, syOut);
    }
}

contract Exploit {
    uint256 internal constant SY_TOTAL = 1_000 ether;
    uint256 internal constant SY_LOCKED = 900 ether;
    uint256 internal constant PT_IN = 200 ether;

    Mini public sy;
    Mini public pt;
    AMM public amm;
    uint256 public availableSy;
    uint256 public quoted;
    uint256 public syReceived;
    uint256 public ptTaken;
    uint256 public ptLeftOnUser;
    uint256 public checkPassed;

    function run() external {
        sy = new Mini("SY", "SY");
        pt = new Mini("PT", "PT");
        amm = new AMM(sy, pt);
        sy.mint(address(this), SY_TOTAL);
        pt.mint(address(this), PT_IN);
        sy.approve(address(amm), SY_TOTAL);
        pt.approve(address(amm), PT_IN);
        amm.seed(SY_TOTAL, SY_LOCKED);
        availableSy = SY_TOTAL - SY_LOCKED;
        checkPassed = PT_IN > (SY_TOTAL - 1 ether) ? 0 : 1;
        quoted = amm.handle_swap_pt_for_sy(PT_IN, 1 ether);
        syReceived = sy.balanceOf(address(this));
        ptTaken = pt.balanceOf(address(amm));
        ptLeftOnUser = pt.balanceOf(address(this));
    }
}
