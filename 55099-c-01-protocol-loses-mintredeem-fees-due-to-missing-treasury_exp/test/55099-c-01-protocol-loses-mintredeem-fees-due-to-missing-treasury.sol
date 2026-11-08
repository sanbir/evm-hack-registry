// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  Terplayer beraBTC — mint and redeem fees never reach a treasury
    (Shieldify, finding C-01 / 55099).

    SYNTHETIC, cheatcode-free reduction. The fee formulas are the audited
    lines. onlyRole / nonReentrant are omitted; they do not move the fee.

    custodianMint subtracts (value * mintFeeRate) / BASE_RATE and mints only
    the remainder. redeem burns the full amount, then reduces the reported
    redeem value by the fee. Neither path credits a treasury. On a 1,000
    beraBTC mint and a 1,000 beraBTC redeem at 10%, 100 is never minted and
    100 is burned. Treasury balance stays 0. The control mints or transfers
    that same fee to the treasury. */

contract BeraBitcoin {
    string public constant name = "beraBTC";
    string public constant symbol = "beraBTC";
    uint8 public constant decimals = 18;

    uint256 public constant BASE_RATE = 10_000;
    uint256 public mintFeeRate = 1_000;
    uint256 public redeemFeeRate = 1_000;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    uint256 public lastMinted;
    uint256 public lastBurned;
    uint256 public lastNet;

    event CustodianMinted(address indexed to, uint256 value);
    event Redeemed(address indexed from, uint256 burned, uint256 value, string recipient);

    function seed(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function custodianMint(address to, uint256 value) public {
        if (mintFeeRate > 0) {
            // @> VULN: mint fee is removed from the minted amount and never forwarded to a treasury
            value -= (value * mintFeeRate) / BASE_RATE;
        }
        lastMinted = value;
        _mint(to, value);
        emit CustodianMinted(to, value);
    }

    function redeem(uint256 value, string memory recipient) public {
        uint256 burned = value;
        // @> VULN: the full redeem amount, fee included, is burned and nothing is forwarded to a treasury
        _burn(msg.sender, burned);
        if (redeemFeeRate > 0) {
            value -= (burned * redeemFeeRate) / BASE_RATE;
        }
        lastBurned = burned;
        lastNet = value;
        emit Redeemed(msg.sender, burned, value, recipient);
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract BeraBitcoinFixed {
    string public constant name = "beraBTC";
    string public constant symbol = "beraBTC";
    uint8 public constant decimals = 18;

    uint256 public constant BASE_RATE = 10_000;
    uint256 public mintFeeRate = 1_000;
    uint256 public redeemFeeRate = 1_000;

    address public immutable treasury;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    uint256 public lastMinted;
    uint256 public lastBurned;
    uint256 public lastNet;

    constructor(address _treasury) {
        treasury = _treasury;
    }

    function seed(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function custodianMint(address to, uint256 value) public {
        uint256 fee;
        if (mintFeeRate > 0) {
            fee = (value * mintFeeRate) / BASE_RATE;
            value -= fee;
        }
        lastMinted = value;
        _mint(to, value);
        if (fee != 0) _mint(treasury, fee);
    }

    function redeem(uint256 value, string memory recipient) public {
        uint256 burned = value;
        uint256 fee;
        if (redeemFeeRate > 0) {
            fee = (burned * redeemFeeRate) / BASE_RATE;
            value -= fee;
        }
        if (fee != 0) _transfer(msg.sender, treasury, fee);
        _burn(msg.sender, burned - fee);
        lastBurned = burned;
        lastNet = value;
        recipient;
    }

    function _mint(address to, uint256 amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function _burn(address from, uint256 amount) internal {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract Treasury {}

contract User {
    BeraBitcoin public immutable token;

    constructor(BeraBitcoin _token) {
        token = _token;
    }

    function redeem(uint256 amount, string memory recipient) external {
        token.redeem(amount, recipient);
    }

    function mint(uint256 amount) external {
        token.custodianMint(address(this), amount);
    }
}

contract Exploit {
    uint256 public constant GROSS = 1000 ether;
    uint256 public constant FEE = 100 ether;

    BeraBitcoin public token;
    Treasury public treasury;
    User public user;

    uint256 public redeemFeeBurned;
    uint256 public mintFeeLost;
    uint256 public feesLost;
    uint256 public treasuryBalance;
    uint256 public contractBalance;

    constructor() {
        token = new BeraBitcoin();
        treasury = new Treasury();
        user = new User(token);
    }

    function run() external {
        this.seedUser();
        this.doRedeem();
        this.readRedeemFee();
        this.doMint();
        this.readMintFee();
        this.assertHarm();
    }

    function seedUser() external {
        token.seed(address(user), GROSS);
    }

    function doRedeem() external {
        user.redeem(GROSS, "bc1q-user");
    }

    function readRedeemFee() external {
        redeemFeeBurned = token.lastBurned() - token.lastNet();
    }

    function doMint() external {
        user.mint(GROSS);
    }

    function readMintFee() external {
        mintFeeLost = GROSS - token.lastMinted();
        treasuryBalance = token.balanceOf(address(treasury));
        contractBalance = token.balanceOf(address(token));
    }

    function assertHarm() external {
        feesLost = redeemFeeBurned + mintFeeLost;
        require(feesLost == FEE + FEE, "fees lost");
        require(redeemFeeBurned == FEE, "redeem fee not burned");
        require(mintFeeLost == FEE, "mint fee not lost");
        require(treasuryBalance == 0, "treasury was paid");
        require(contractBalance == 0, "fee sitting in token contract");
        require(token.balanceOf(address(user)) == GROSS - FEE, "user mint net");
    }
}
